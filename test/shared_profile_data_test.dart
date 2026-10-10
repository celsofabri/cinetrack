import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/account/account_deleter.dart';
import 'package:cinetrack/account/account_deletion_failure.dart';
import 'package:cinetrack/data/export_data_source.dart';
import 'package:cinetrack/data/firestore_shared_profile_data_source.dart';
import 'package:cinetrack/data/profile_data_source.dart';
import 'package:cinetrack/data/shared_profile_data_source.dart';
import 'package:cinetrack/data/shared_rules_gate.dart';
import 'package:cinetrack/export/data_exporter.dart';
import 'package:cinetrack/export/export_serializer.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/repositories/social_repository.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/widgets/privacy_summary.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_export_data_source.dart';
import 'support/fake_shared_profile_cloud.dart';
import 'support/fake_social_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Fatia 1 (docs/82 §8, §9, §15): the shared-profile source (inert), the
/// rules gate, deletion before/after closing `social`, export schema 3,
/// privacy text.
FirebaseException _fx(String code) => FirebaseException(plugin: 'cloud_firestore', code: code);

void main() {
  group('FirestoreSharedProfileDataSource (seams, no Firebase)', () {
    FirestoreSharedProfileDataSource source({
      SharedDocGet? get,
      SharedDocDelete? delete,
      Duration timeout = const Duration(seconds: 30),
    }) => FirestoreSharedProfileDataSource(
      uid: 'uid-ana',
      getter: get,
      deleter: delete,
      timeout: timeout,
    );

    test('probe: readable = ready (exists or not); denied = old rules; else unreachable', () async {
      expect(
        await source(get: (p, {required server}) async => null).probeRules(),
        RulesProbe.ready,
      );
      expect(
        await source(get: (p, {required server}) async => {'v': 1}).probeRules(),
        RulesProbe.ready,
      );
      expect(
        await source(
          get: (p, {required server}) async => throw _fx('permission-denied'),
        ).probeRules(),
        RulesProbe.oldRules,
      );
      expect(
        await source(get: (p, {required server}) async => throw _fx('unavailable')).probeRules(),
        RulesProbe.unreachable,
      );
      expect(
        await source(get: (p, {required server}) async => throw StateError('x')).probeRules(),
        RulesProbe.unreachable,
      );
    });

    test('probe reads the OWN document from the server', () async {
      final calls = <(String, bool)>[];
      await source(
        get: (p, {required server}) async {
          calls.add((p, server));
          return null;
        },
      ).probeRules();
      expect(calls, [('shared_profiles/uid-ana', true)]);
    });

    test('deleteOwn: success, denied (old rules) = success, timeout = uncertain', () async {
      final deleted = <String>[];
      await source(delete: (p) async => deleted.add(p)).deleteOwn();
      expect(deleted, ['shared_profiles/uid-ana']);
      await source(delete: (p) async => throw _fx('permission-denied')).deleteOwn();
      await expectLater(
        source(
          delete: (p) => Completer<void>().future,
          timeout: const Duration(milliseconds: 10),
        ).deleteOwn(),
        throwsA(isA<SocialFailure>().having((e) => e.kind, 'kind', SocialFailureKind.uncertain)),
      );
      await expectLater(
        source(delete: (p) async => throw _fx('resource-exhausted')).deleteOwn(),
        throwsA(
          isA<SocialFailure>().having((e) => e.kind, 'kind', SocialFailureKind.quotaExceeded),
        ),
      );
    });

    test(
      'readOwn: device cache miss = absent; server failure maps; readFriend server only',
      () async {
        expect(
          await source(
            get: (p, {required server}) async => throw _fx('unavailable'),
          ).readOwn(fromServer: false),
          isNull,
        );
        await expectLater(
          source(
            get: (p, {required server}) async => throw _fx('unavailable'),
          ).readOwn(fromServer: true),
          throwsA(isA<SocialFailure>().having((e) => e.kind, 'kind', SocialFailureKind.offline)),
        );
        final calls = <(String, bool)>[];
        await source(
          get: (p, {required server}) async {
            calls.add((p, server));
            return null;
          },
        ).readFriend('uid-bruno');
        expect(calls, [('shared_profiles/uid-bruno', true)]);
      },
    );

    test('signed-out source is inert', () async {
      const s = SignedOutSharedProfileDataSource();
      expect(await s.readOwn(fromServer: true), isNull);
      expect(await s.probeRules(), RulesProbe.unreachable);
      await s.deleteOwn();
    });
  });

  group('SharedRulesGate (D17)', () {
    test('ready: opens and is remembered; later sessions do not read', () async {
      final shared = FakeSharedProfileCloud();
      final store = FakeLocalStore();
      SharedRulesGate gate() => SharedRulesGate(
        probe: InMemorySharedProfileDataSource(shared, uid: 'u').probeRules,
        isStoredReady: () => store.sharedRulesReady('p'),
        storeReady: () => store.setSharedRulesReady('p'),
      );
      final first = gate();
      expect(first.open, isFalse);
      expect(await first.start(), RulesProbe.ready);
      await first.start();
      expect(first.open, isTrue);
      expect(shared.log.where((o) => o == 'probe'), hasLength(1), reason: 'once per session');
      final next = gate();
      expect(next.open, isTrue);
      await next.start();
      expect(shared.log.where((o) => o == 'probe'), hasLength(1), reason: 'once per device');
    });

    test('old rules / no answer: stays closed, probes again next session', () async {
      final shared = FakeSharedProfileCloud()..oldRules = true;
      final store = FakeLocalStore();
      SharedRulesGate gate() => SharedRulesGate(
        probe: InMemorySharedProfileDataSource(shared, uid: 'u').probeRules,
        isStoredReady: () => store.sharedRulesReady('p'),
        storeReady: () => store.setSharedRulesReady('p'),
      );
      final g = gate();
      expect(await g.start(), RulesProbe.oldRules);
      expect(g.open, isFalse);
      shared
        ..oldRules = false
        ..failNext('probe', const SocialFailure(SocialFailureKind.offline));
      final g2 = gate();
      expect(await g2.start(), RulesProbe.unreachable);
      expect(g2.open, isFalse);
      expect(store.sharedRules, isEmpty);
      final g3 = gate();
      expect(await g3.start(), RulesProbe.ready);
      expect(g3.open, isTrue);
    });

    test(
      'provider: probes once at session start; the app with no friendships reads 1 doc ever',
      () async {
        final shared = FakeSharedProfileCloud();
        final store = FakeLocalStore();
        final c = ProviderContainer(
          overrides: cloudOverrides(
            auth: FakeAuthRepository(initialUser: kAna),
            cloud: FakeCloud(),
            store: store,
            sharedCloud: shared,
          ),
        );
        addTearDown(c.dispose);
        c.listen(authStateProvider, (_, _) {});
        await Future<void>.delayed(Duration.zero);
        final gate = c.read(sharedRulesGateProvider);
        await gate.start();
        expect(gate.open, isTrue);
        expect(shared.reads, 1);
        expect(store.sharedRules, {c.read(firebaseProjectIdProvider)});
        expect(
          shared.log.where((o) => o != 'probe'),
          isEmpty,
          reason: 'nothing else is read or written',
        );
      },
    );
  });

  group('deletion before AND after closing social (D11)', () {
    test('deactivate: delete, sweep, close, delete, sweep', () async {
      final log = <String>[];
      final social = FakeSocialCloud(log: log)
        ..seedActive('uid-ana', 'ana')
        ..seedFriendship('uid-ana', 'uid-bruno');
      final shared = FakeSharedProfileCloud(log: log)..docs['uid-ana'] = {'v': 1};
      final repo = SocialRepository(
        InMemorySocialDataSource(social, uid: 'uid-ana'),
        sharedProfile: InMemorySharedProfileDataSource(shared, uid: 'uid-ana'),
      );
      await repo.deactivate();
      final relevant = log
          .where((o) => o == 'deleteSharedProfile' || o == 'closeSocial' || o.startsWith('delete:'))
          .toList();
      expect(relevant.first, 'deleteSharedProfile');
      final close = relevant.indexOf('closeSocial');
      expect(relevant.indexOf('delete:friendships:1'), lessThan(close));
      expect(relevant[close + 1], 'deleteSharedProfile');
      expect(shared.docs, isEmpty);
    });

    test('deactivate: the first delete fails = friendships stay on (retry)', () async {
      final social = FakeSocialCloud()..seedActive('uid-ana', 'ana');
      final shared = FakeSharedProfileCloud()
        ..failNext('deleteOwn', const SocialFailure(SocialFailureKind.offline));
      final repo = SocialRepository(
        InMemorySocialDataSource(social, uid: 'uid-ana'),
        sharedProfile: InMemorySharedProfileDataSource(shared, uid: 'uid-ana'),
      );
      await expectLater(
        repo.deactivate(),
        throwsA(
          isA<SocialFailure>().having(
            (e) => e.code,
            'code',
            isNot(SocialRepository.cleanupPendingCode),
          ),
        ),
      );
      expect(social.social.containsKey('uid-ana'), isTrue);
    });

    test(
      'deactivate: the second delete fails = cleanup pending; finishCleanup deletes again',
      () async {
        final social = FakeSocialCloud()..seedActive('uid-ana', 'ana');
        final shared = FakeSharedProfileCloud();
        final repo = SocialRepository(
          InMemorySocialDataSource(social, uid: 'uid-ana'),
          sharedProfile: InMemorySharedProfileDataSource(shared, uid: 'uid-ana'),
        );
        // A device created the document in the window; the second delete fails.
        var calls = 0;
        final wrapped = _CountingShared(InMemorySharedProfileDataSource(shared, uid: 'uid-ana'), (
          n,
        ) {
          calls = n;
          if (n == 2) {
            shared.docs['uid-ana'] = {'v': 1};
            throw const SocialFailure(SocialFailureKind.offline);
          }
        });
        final repo2 = SocialRepository(
          InMemorySocialDataSource(social, uid: 'uid-ana'),
          sharedProfile: wrapped,
        );
        await expectLater(
          repo2.deactivate(),
          throwsA(
            isA<SocialFailure>().having((e) => e.code, 'code', SocialRepository.cleanupPendingCode),
          ),
        );
        expect(calls, 2);
        expect(shared.docs, contains('uid-ana'));
        await repo.finishCleanup();
        expect(shared.docs, isEmpty);
      },
    );

    test('account deletion: shared profile deleted before and after the social step', () async {
      final cloud = FakeCloud();
      final social = FakeSocialCloud(log: cloud.deletionLog)..seedActive('uid-ana', 'ana');
      final shared = FakeSharedProfileCloud(log: cloud.deletionLog)..docs['uid-ana'] = {'v': 1};
      cloud.profiles['uid-ana'] = const UserProfile(nickname: 'Ana');
      final deleter = AccountDeleter(
        uid: 'uid-ana',
        auth: FakeAuthRepository(initialUser: kAna),
        profile: InMemoryProfileDataSource(cloud, uid: 'uid-ana'),
        social: SocialRepository(InMemorySocialDataSource(social, uid: 'uid-ana')),
        sharedProfile: InMemorySharedProfileDataSource(shared, uid: 'uid-ana'),
      );
      await deleter.run();
      final log = cloud.deletionLog;
      final first = log.indexOf('deleteSharedProfile');
      final second = log.lastIndexOf('deleteSharedProfile');
      expect(first, greaterThan(log.indexOf('markDeleting')));
      expect(first, lessThan(log.indexOf('closeSocial')));
      expect(second, greaterThan(log.indexOf('closeSocial')));
      expect(second, lessThan(log.indexOf('deleteAllFavorites')));
      expect(shared.docs, isEmpty);
    });

    test('account deletion: a failing delete stops before the sweeps; rerun completes', () async {
      final cloud = FakeCloud();
      final social = FakeSocialCloud(log: cloud.deletionLog)..seedActive('uid-ana', 'ana');
      final shared = FakeSharedProfileCloud(log: cloud.deletionLog)
        ..docs['uid-ana'] = {'v': 1}
        ..deliverUncertainDeletes = true
        ..failNext('deleteOwn', const SocialFailure(SocialFailureKind.uncertain, code: 'timeout'));
      cloud.profiles['uid-ana'] = const UserProfile(nickname: 'Ana');
      final auth = FakeAuthRepository(initialUser: kAna);
      final deleter = AccountDeleter(
        uid: 'uid-ana',
        auth: auth,
        profile: InMemoryProfileDataSource(cloud, uid: 'uid-ana'),
        social: SocialRepository(InMemorySocialDataSource(social, uid: 'uid-ana')),
        sharedProfile: InMemorySharedProfileDataSource(shared, uid: 'uid-ana'),
      );
      await expectLater(
        deleter.run(),
        throwsA(
          isA<AccountDeletionFailure>().having(
            (e) => e.kind,
            'kind',
            AccountDeletionFailureKind.uncertain,
          ),
        ),
      );
      expect(cloud.deletionLog, isNot(contains('closeSocial')));
      expect(auth.deleteUserCalls, 0);
      await deleter.run();
      expect(shared.docs, isEmpty);
      expect(social.leftoversOf('uid-ana'), isEmpty);
      expect(auth.deleteUserCalls, 1);
    });

    test('old rules: deleting is a no-op success (nothing can exist)', () async {
      final shared = FakeSharedProfileCloud()..oldRules = true;
      await InMemorySharedProfileDataSource(shared, uid: 'uid-ana').deleteOwn();
      expect(shared.log, ['deleteSharedProfile']);
    });

    test('the app wires the REAL shared source into deactivation and account deletion', () async {
      final cloud = FakeCloud();
      final shared = FakeSharedProfileCloud(log: cloud.deletionLog)..docs['uid-ana'] = {'v': 1};
      final social = FakeSocialCloud()..seedActive('uid-ana', 'ana');
      final c = ProviderContainer(
        overrides: cloudOverrides(
          auth: FakeAuthRepository(initialUser: kAna),
          cloud: cloud,
          socialCloud: social,
          sharedCloud: shared,
        ),
      );
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      await c.read(socialRepositoryProvider).deactivate();
      expect(shared.log.where((o) => o == 'deleteSharedProfile'), hasLength(2));
      expect(shared.docs, isEmpty);
      expect(c.read(sharedProfileDataSourceProvider), isA<InMemorySharedProfileDataSource>());
      // AccountController builds its deleter from the same provider.
      shared.docs['uid-ana'] = {'v': 1};
      cloud.profiles['uid-ana'] = const UserProfile(nickname: 'Ana');
      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
      expect(shared.docs, isEmpty);
    });
  });

  group('export schema 3', () {
    Future<Map<String, dynamic>> export(FakeExportDataSource source) async {
      final file = await runExport(
        source: source,
        from: ExportSource.server,
        now: () => DateTime.utc(2026, 10, 10),
        isCurrent: () => true,
        uid: 'uid-ana',
      );
      return jsonDecode(file.json) as Map<String, dynamic>;
    }

    test('never shared: same file as before + sharedProfile null, schemaVersion 3', () async {
      final source = FakeExportDataSource({'1-movie': fakeMovieDoc(1)});
      final json = await export(source);
      expect(json['schemaVersion'], 3);
      expect(json.containsKey('sharedProfile'), isTrue);
      expect(json['sharedProfile'], isNull);
      expect(source.sharedProfileReads, 1);
    });

    test('raw shared profile (with sharing) and favorites with epsAt are exported', () async {
      final at = DateTime.utc(2026, 10, 5, 21);
      final source =
          FakeExportDataSource({
              '7-tv': fakeSeriesDoc(
                7,
                seasons: 1,
                perSeason: 2,
                extra: {
                  'epsAt': {'1_1': at},
                },
              ),
            })
            ..sharedProfile = RawDoc('uid-ana', {
              'v': 1,
              'updatedAt': at,
              'sharing': {'stats': true, 'activity': true},
              'actSince': at,
              'activity': [
                {'type': 'watched_movie', 'id': 3, 'mediaType': 'movie', 'title': 'M', 'at': at},
              ],
              'futureField': 'kept',
            });
      final json = await export(source);
      final sp = json['sharedProfile'] as Map<String, dynamic>;
      expect(sp['id'], 'uid-ana');
      expect(sp['timestampFields'], unorderedEquals(['updatedAt', 'actSince']));
      expect((sp['data'] as Map)['sharing'], {'stats': true, 'activity': true});
      expect(((sp['data'] as Map)['activity'] as List).single['at'], at.toIso8601String());
      expect((sp['data'] as Map)['futureField'], 'kept');
      final fav = (json['favorites'] as List).single as Map;
      expect((fav['data'] as Map)['epsAt'], {'1_1': at.toIso8601String()});
    });
  });

  testWidgets('PrivacySummary tells that the mark date is kept, only for the owner', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: cloudOverrides(
          auth: FakeAuthRepository(initialUser: kAna),
          cloud: FakeCloud(),
        ),
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: PrivacySummary())),
        ),
      ),
    );
    expect(
      find.textContaining(
        'Quando você marca um episódio, guardamos também a data dessa marcação, só para você, '
        'para as estatísticas por mês e por ano.',
      ),
      findsOneWidget,
    );
  });
}

/// Calls [onCall] with the call number before delegating (may throw).
class _CountingShared implements SharedProfileDataSource {
  final SharedProfileDataSource inner;
  final void Function(int n) onCall;
  int _n = 0;

  _CountingShared(this.inner, this.onCall);

  @override
  String get uid => inner.uid;

  @override
  Future<void> deleteOwn() async {
    onCall(++_n);
    await inner.deleteOwn();
  }

  @override
  Future<RulesProbe> probeRules() => inner.probeRules();

  @override
  Future<Map<String, dynamic>?> readFriend(String friendUid) => inner.readFriend(friendUid);

  @override
  Future<Map<String, dynamic>?> readOwn({required bool fromServer}) =>
      inner.readOwn(fromServer: fromServer);
}
