import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/export/data_exporter.dart';
import 'package:cinetrack/export/export_serializer.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/social_lists_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/providers/social_refresh_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:cinetrack/repositories/social_repository.dart';
import 'package:cinetrack/social/invite_code.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_export_data_source.dart';
import 'support/fake_social_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Slice 5 (docs/68), part 2: deactivate / account deletion / export with an invite and a
/// refresh made by the app itself, and the "busy" guard of blocking from a search result.

void main() {
  late FakeSocialCloud social;
  late FakeAuthRepository auth;
  late FakeLocalStore store;

  ProviderContainer make({void Function(FakeSocialCloud s)? seed}) {
    social = FakeSocialCloud();
    social
      ..seedActive('uid-ana', 'ana', nickname: 'Ana')
      ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno');
    seed?.call(social);
    auth = FakeAuthRepository(initialUser: kAna);
    store = FakeLocalStore();
    final c = ProviderContainer(
      overrides: cloudOverrides(auth: auth, cloud: FakeCloud(), socialCloud: social, store: store),
    );
    addTearDown(c.dispose);
    c.listen(authStateProvider, (_, _) {});
    c.listen(syncStatusProvider, (_, _) {});
    c.listen(socialControllerProvider, (_, _) {});
    c.listen(socialRefreshProvider, (_, _) {});
    c.listen(blockedControllerProvider, (_, _) {});
    return c;
  }

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('deactivate and account deletion with a REAL invite and a pending refresh', () {
    test(
      'deactivate (controller): invite, pointer, friendships and the refresh flag are gone',
      () async {
        final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana Velha'));
        await settle();
        final controller = c.read(socialControllerProvider.notifier);
        expect(await controller.createInvite(), isNull);
        final code = social.social['uid-ana']!['inviteCode'] as String;
        expect(social.invites.containsKey(code), isTrue);
        store.socialRefresh.add('uid-ana'); // an unfinished refresh
        expect(await controller.deactivate(), isNull);
        await settle();
        expect(social.leftoversOf('uid-ana'), isEmpty);
        expect(social.invites.containsKey(code), isFalse);
        expect(store.socialRefresh, isEmpty);
        expect(c.read(socialControllerProvider).phase, SocialPhase.inactive);
        // turning it on again does NOT bring the old link back
        expect(
          await SocialRepository(
            InMemorySocialDataSource(social, uid: 'uid-bruno'),
          ).openInvite(code),
          isA<InviteUnavailable>(),
        );
      },
    );

    test(
      'deactivate failing in the last sweep still deleted the invite (the door is closed first)',
      () async {
        final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno'));
        await settle();
        final controller = c.read(socialControllerProvider.notifier);
        await controller.createInvite();
        // a friendship lands between the first sweep and the close; the 2nd sweep fails
        social.beforeClose = () => social.seedFriendship('uid-ana', 'uid-caio');
        social.failOnDeleteCall = 2;
        final failure = await controller.deactivate();
        expect(failure?.code, SocialRepository.cleanupPendingCode);
        expect(social.invites, isEmpty);
        expect(social.social.containsKey('uid-ana'), isFalse);
      },
    );

    test(
      'AccountController.deleteAccount deletes the invite and forgets the refresh flag',
      () async {
        final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana Velha'));
        await settle();
        await c.read(socialControllerProvider.notifier).createInvite();
        final code = social.social['uid-ana']!['inviteCode'] as String;
        store.socialRefresh.add('uid-ana');
        expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
        expect(social.leftoversOf('uid-ana'), isEmpty);
        expect(social.invites.containsKey(code), isFalse);
        expect(store.socialRefresh, isEmpty);
      },
    );

    test('account deletion with the invite already revoked or expired also finishes', () async {
      final c = make();
      await settle();
      await c.read(socialControllerProvider.notifier).createInvite();
      final code = social.social['uid-ana']!['inviteCode'] as String;
      social.invites[code]!['expiresAt'] = DateTime.now().subtract(const Duration(days: 1));
      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
      expect(social.leftoversOf('uid-ana'), isEmpty);
    });
  });

  group('export carries the active invite (code + validity), schema unchanged', () {
    Future<Map<String, dynamic>> exportSocial(RawSocial raw) async {
      final source = FakeExportDataSource({})..social = raw;
      final file = await runExport(
        source: source,
        from: ExportSource.server,
        now: () => DateTime.utc(2026, 10, 5),
        isCurrent: () => true,
        uid: 'uid-ana',
      );
      return (jsonDecode(file.json) as Map<String, dynamic>)['social'] as Map<String, dynamic>;
    }

    test('an invite made by the app is read back: code, createdAt, expiresAt', () async {
      final clock = DateTime.utc(2026, 10, 5, 12);
      final cloud = FakeSocialCloud(now: () => clock)
        ..seedActive('uid-ana', 'ana', nickname: 'Ana');
      final repo = SocialRepository(
        InMemorySocialDataSource(cloud, uid: 'uid-ana'),
        now: () => clock,
      );
      await repo.createInvite(
        me: const SocialProfile(handle: 'ana', nickname: 'Ana'),
      );
      final raw = await InMemorySocialDataSource(cloud, uid: 'uid-ana').read(fromServer: true);
      final social = await exportSocial(raw);
      final invite = social['invite'] as Map<String, dynamic>;
      expect(invite['code'], cloud.social['uid-ana']!['inviteCode']);
      expect(InviteCode.isValid(invite['code'] as String), isTrue);
      expect(invite['createdAt'], '2026-10-05T12:00:00.000Z');
      expect(invite['expiresAt'], '2026-10-12T12:00:00.000Z');
      expect(invite['exists'], isTrue);
      expect(kExportSchemaVersion, 2, reason: 'additive key inside social: same schema version');
      // the raw pointer already lists it too
      expect(jsonEncode(social['pointer']), contains(invite['code'] as String));
    });

    test(
      'no invite: the key is null; a pointer without a document says exists=false; old files have no key',
      () async {
        expect((await exportSocial(const RawSocial(social: {'handle': 'ana'})))['invite'], isNull);
        final orphan = await exportSocial(
          RawSocial(social: {'handle': 'ana', 'inviteCode': 'A' * 24}),
        );
        expect((orphan['invite'] as Map)['exists'], isFalse);
        expect((orphan['invite'] as Map)['expiresAt'], isNull);
        // a reader of the older shape ignores the unknown key and still finds everything else
        final old = Map<String, dynamic>.of(orphan)..remove('invite');
        expect(old['handle'], 'ana');
        expect(old['counts'], isNotNull);
      },
    );

    test(
      'the other people in the export never get the invite (it is only the user\'s own)',
      () async {
        final source = FakeExportDataSource({})
          ..social = RawSocial(
            social: {'handle': 'ana', 'inviteCode': 'A' * 24},
            invite: {'uid': 'uid-ana', 'expiresAt': DateTime.utc(2026, 11, 1)},
          );
        source.socialLists[SocialExportKind.friends] = {
          'uid-ana_uid-bia': {
            'members': ['uid-ana', 'uid-bia'],
            'aName': 'Ana',
            'bName': 'Bia',
          },
        };
        final file = await runExport(
          source: source,
          from: ExportSource.server,
          now: () => DateTime.utc(2026, 10, 5),
          isCurrent: () => true,
          uid: 'uid-ana',
        );
        final social = (jsonDecode(file.json) as Map<String, dynamic>)['social'] as Map;
        expect(jsonEncode(social['friends']), isNot(contains('A' * 24)));
      },
    );

    test('the payload\'s card fields are what the export lists (nothing extra is written)', () {
      final ops = SocialPayloads.createInvite(
        'uid-ana',
        InviteDraft(code: 'A' * 24, nickname: 'Ana', validity: const Duration(days: 7)),
      ).ops;
      final data = ops.firstWhere((o) => o.path.startsWith('invites/')).data!;
      expect(data.keys.toSet(), {'uid', 'nickname', 'createdAt', 'expiresAt'});
    });
  });

  group('blocking from a search result is guarded against a second call', () {
    test(
      'while a block of the same person is in flight, another call is "busy", never success',
      () async {
        final c = make();
        await settle();
        social.writeGate = Completer<void>();
        final blocked = c.read(blockedControllerProvider.notifier);
        final first = blocked.blockPerson(uid: 'uid-bruno', name: 'Bruno');
        await settle();
        final second = await blocked.blockPerson(uid: 'uid-bruno', name: 'Bruno');
        expect(second, same(kBusyFailure));
        expect(
          social.log.where((e) => e == 'blockUser'),
          isEmpty,
          reason: 'still held at the gate',
        );
        social.writeGate!.complete();
        expect(await first, isNull);
        expect(social.log.where((e) => e == 'blockUser'), hasLength(1));
        expect(c.read(blockedControllerProvider).busy, isEmpty);
        // a different person is not blocked by that guard
        expect(await blocked.blockPerson(uid: 'uid-caio', name: 'Caio'), isNull);
      },
    );

    test('the guard is released after a failure (the person can be tried again)', () async {
      final c = make();
      await settle();
      social.failures['blockUser'] = const SocialFailure(SocialFailureKind.offline);
      final blocked = c.read(blockedControllerProvider.notifier);
      expect(
        (await blocked.blockPerson(uid: 'uid-bruno', name: 'Bruno'))?.kind,
        SocialFailureKind.offline,
      );
      expect(c.read(blockedControllerProvider).busy, isEmpty);
      expect(await blocked.blockPerson(uid: 'uid-bruno', name: 'Bruno'), isNull);
    });
  });
}
