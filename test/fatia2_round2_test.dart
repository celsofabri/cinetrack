import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/providers/sharing_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/in_memory_favorites_data_source.dart';
import 'support/sharing_rig.dart';

/// Fatia 2, rodada 2 (docs/86): Code Review 🟡1–3 and QA 🟡 findings.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SharingController _ctl(ProviderContainer c) => c.read(sharingControllerProvider.notifier);
SharingState _st(ProviderContainer c) => c.read(sharingControllerProvider);
int _reads(SharingRig rig) => rig.log.where((o) => o == 'readOwn').length;

Future<void> _blip(SharingRig rig) async {
  rig.cloud.offline = true;
  await _settle();
  rig.cloud.offline = false;
  await _settle();
}

const _timeout = SocialFailure(SocialFailureKind.uncertain, code: 'timeout');

void main() {
  group('A: an uncertain toggle that commits AFTER the caller gave up', () {
    test('turning on: stays "uncertain" until the transaction ends, then ON', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = rig.container();
      addTearDown(c.dispose);
      await _settle();
      rig.shared
        ..lateUncertainToggles = true
        ..failNext('toggle', _timeout);
      unawaited(
        _ctl(c).turnOn(SharedSection.stats, c.read(sharedPreviewProvider(SharedSection.stats))!),
      );
      await _settle();
      expect(_st(c).uncertain, {SharedSection.stats: true});
      // A reconnection read BEFORE the commit must not decide anything.
      await _blip(rig);
      expect(_st(c).uncertain, {SharedSection.stats: true});
      expect(_st(c).notice?.text, isNot('Compartilhamento ligado.'));
      final before = _reads(rig);
      rig.shared.commitLate();
      await _settle();
      expect(rig.doc, isNotNull);
      expect(_st(c).uncertain, isEmpty);
      expect(_st(c).sections, {SharedSection.stats});
      expect(_st(c).notice!.text, 'Compartilhamento ligado.');
      expect(_reads(rig), before + 1, reason: 'one read after the transaction ended');
    });

    test('turning off: no premature "Não foi possível desligar"; ends OFF', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final c = rig.container();
      addTearDown(c.dispose);
      await _settle();
      rig.shared
        ..lateUncertainToggles = true
        ..failNext('toggle', _timeout);
      unawaited(_ctl(c).turnOff(SharedSection.stats));
      await _settle();
      await _blip(rig);
      expect(_st(c).uncertain, {SharedSection.stats: false});
      expect(_st(c).notice?.text, isNot('Não foi possível desligar. Tente de novo.'));
      rig.shared.commitLate();
      await _settle();
      expect(rig.doc, isNull);
      expect(_st(c).sections, isEmpty);
      expect(_st(c).notice!.text, 'Seus amigos não veem mais suas estatísticas.');
    });

    test('the transaction ends WITHOUT committing: off, no "ligado"', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = rig.container();
      addTearDown(c.dispose);
      await _settle();
      rig.shared
        ..lateUncertainToggles = true
        ..failNext('toggle', _timeout);
      unawaited(
        _ctl(c).turnOn(SharedSection.stats, c.read(sharedPreviewProvider(SharedSection.stats))!),
      );
      await _settle();
      rig.shared.abortLate();
      await _settle();
      expect(_st(c).uncertain, isEmpty);
      expect(_st(c).sections, isEmpty);
      expect(_st(c).notice?.text, isNot('Compartilhamento ligado.'));
    });

    test('a transaction that never ends is waited for 60 s at most', () {
      fakeAsync((async) {
        final rig = SharingRig()..seed(sharingMovie(1));
        final c = rig.container();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1));
        rig.shared
          ..lateUncertainToggles = true
          ..failNext('toggle', _timeout);
        unawaited(
          _ctl(c).turnOn(SharedSection.stats, c.read(sharedPreviewProvider(SharedSection.stats))!),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 59));
        expect(_st(c).uncertain, isNotEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(_st(c).uncertain, isEmpty);
        c.dispose();
      });
    });

    test('reconciling fails while online, no reconnection: one more read after 30 s', () {
      fakeAsync((async) {
        final rig = SharingRig()..seed(sharingMovie(1));
        final c = rig.container();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1));
        rig.shared
          ..deliverUncertainToggles = true
          ..failNext('toggle', _timeout)
          ..failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
        unawaited(
          _ctl(c).turnOn(SharedSection.stats, c.read(sharedPreviewProvider(SharedSection.stats))!),
        );
        async.flushMicrotasks();
        expect(_st(c).uncertain, isNotEmpty);
        async.elapse(const Duration(seconds: 29));
        expect(_st(c).uncertain, isNotEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(_st(c).uncertain, isEmpty);
        expect(_st(c).sections, {SharedSection.stats});
        async.elapse(const Duration(minutes: 5));
        expect(_reads(rig), 3, reason: 'session + failed + the single retry');
        c.dispose();
      });
    });
  });

  group('B/C: reads of the owner state', () {
    test('C: cache then server snapshot while the session read is in flight: 1 read', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.store.socialHints['uid-ana'] = (active: true, at: DateTime.now());
      rig.shared.readGate = Completer<void>();
      final c = rig.container();
      addTearDown(c.dispose);
      await _settle();
      await _blip(rig);
      rig.shared.readGate!.complete();
      await _settle();
      expect(_st(c).confirmed, isTrue);
      expect(_reads(rig), 1);
    });

    test('B: the cache->server switch at session start is not a reconnection: 1 read', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.cloud.offline = true;
      final c = rig.container();
      addTearDown(c.dispose);
      await _settle();
      expect(_st(c).confirmed, isTrue);
      rig.cloud.offline = false;
      await _settle();
      expect(_reads(rig), 1);
    });

    test('B: every real reconnection reads once (2 devices, RF-P10)', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = rig.container();
      addTearDown(c.dispose);
      await _settle();
      await _blip(rig);
      await _blip(rig);
      expect(_reads(rig), 3);
    });
  });

  group('rules gate decision (Q1)', () {
    Future<List<String>> probeLog(SharingRig rig) async {
      final c = rig.container();
      addTearDown(c.dispose);
      c.listen(sharedRulesGateProvider, (_, _) {});
      await _settle();
      expect(c.read(sharedRulesGateProvider).open, isTrue);
      return rig.log;
    }

    test('fresh "inactive" hint (friendships state never loaded): the dedicated probe', () async {
      final rig = SharingRig(active: false);
      rig.store.socialHints['uid-ana'] = (active: false, at: DateTime.now());
      expect(await probeLog(rig), ['probe']);
    });

    test('stale "active" hint while friendships are off: the session read still decides', () async {
      final rig = SharingRig(active: false);
      rig.store.socialHints['uid-ana'] = (active: true, at: DateTime.now());
      expect(await probeLog(rig), contains('readOwn'));
    });

    test('non-Google account: the dedicated probe', () async {
      final rig = SharingRig(active: false, user: const AppUser(uid: 'uid-ana', isGoogle: false));
      expect(await probeLog(rig), ['probe']);
    });
  });

  group('engine', () {
    ProviderContainer start(FakeAsync async, SharingRig rig) {
      final c = rig.container();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      return c;
    }

    void mark(SharingRig rig, int id) => rig.cloud.write('uid-ana', (d) {
      d['$id-movie'] = d['$id-movie']!.copyWith(watchedMovie: true, lastWatchedAt: rig.now);
    });

    test('friendships active, nothing shared: mark + 1 min = 0 write attempts', () {
      fakeAsync((async) {
        final rig = SharingRig()..seed(sharingMovie(1));
        final c = start(async, rig);
        mark(rig, 1);
        async.elapse(const Duration(minutes: 1));
        expect(rig.shared.writeAttempts, 0);
        expect(rig.shared.toggles, isEmpty);
        c.dispose();
      });
    });

    test('account deletion running (before markDeleting) holds the write; abandoned: it goes', () {
      fakeAsync((async) {
        final rig = SharingRig()..seed(sharingMovie(1));
        rig.seedShared({SharedSection.stats});
        final c = start(async, rig);
        c.listen(accountControllerProvider, (_, _) {});
        rig.auth.reauthGate = Completer<void>();
        unawaited(c.read(accountControllerProvider.notifier).deleteAccount());
        async.flushMicrotasks();
        expect(c.read(accountControllerProvider).running, isTrue);
        mark(rig, 1);
        async.elapse(const Duration(seconds: 40));
        expect(rig.shared.writeAttempts, 0);
        rig.auth.reauthFailure = const AuthFailure(AuthFailureKind.cancelled);
        rig.auth.reauthGate!.complete();
        async.flushMicrotasks();
        expect(c.read(accountControllerProvider).running, isFalse);
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 1, reason: 'the pending change is not lost');
        c.dispose();
      });
    });

    test('deactivation with a held recalculation: 0 write attempts', () {
      fakeAsync((async) {
        final rig = SharingRig();
        for (var i = 1; i <= 3; i++) {
          rig.seed(sharingMovie(i));
        }
        rig.seedShared({SharedSection.stats});
        final c = start(async, rig);
        rig.social.writeGate = Completer<void>();
        unawaited(c.read(socialControllerProvider.notifier).deactivate());
        async.flushMicrotasks();
        mark(rig, 1);
        async.elapse(const Duration(seconds: 40));
        rig.social.writeGate!.complete();
        rig.social.writeGate = null;
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));
        expect(rig.shared.writeAttempts, 0);
        expect(rig.doc, isNull);
        c.dispose();
      });
    });

    test('what the engine wrote reads back "equal" in the next session: 0 writes', () {
      fakeAsync((async) {
        final rig = SharingRig();
        for (var i = 1; i <= 3; i++) {
          rig.seed(sharingMovie(i));
        }
        rig.seed(
          FavoriteDoc(
            id: 50,
            mediaType: MediaType.tv,
            title: 'Série X',
            posterPath: null,
            overview: '',
            addedAt: DateTime.utc(2026, 1, 1),
          ),
        );
        final since = kSharingNow.subtract(const Duration(hours: 1));
        rig.seedShared({SharedSection.stats, SharedSection.activity}, actSince: since);
        var c = start(async, rig);
        mark(rig, 1);
        InMemoryFavoritesDataSource(
          rig.cloud,
          uid: 'uid-ana',
        ).setEpisodes('50-tv', {'1_3': true}, current: rig.cloud.server['uid-ana']!['50-tv']);
        async.elapse(const Duration(seconds: 40));
        final first = rig.writes;
        expect(first, 1);
        c.dispose();
        rig.now = rig.now.add(const Duration(minutes: 10));
        c = start(async, rig);
        async.elapse(const Duration(minutes: 3));
        expect(rig.writes, first);
        expect(_st(c).confirmed, isTrue);
        c.dispose();
      });
    });
  });
}
