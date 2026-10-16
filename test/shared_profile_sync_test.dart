import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/data/profile_data_source.dart';
import 'package:cinetrack/data/sync_status.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/providers/sharing_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/in_memory_favorites_data_source.dart';
import 'support/sharing_rig.dart';

/// The recalculation engine `SharedProfileSync` (docs/82 §6, docs/81 RF-S5–S8,
/// D4, D7), with a fake clock (`fake_async`) and the operation log of the
/// fakes. Ana is in America/Sao_Paulo; "hoje" = 15/10/2026 12:00.
void main() {
  /// Starts the engine for [rig] and lets the session read settle.
  ProviderContainer start(FakeAsync async, SharingRig rig, {List<Override> extra = const []}) {
    final c = rig.container(extra: extra);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1));
    async.flushMicrotasks();
    return c;
  }

  /// Marks movie [id] as watched "now" straight in the fake server (what the
  /// listener sees after the app's own write).
  void watch(SharingRig rig, int id) => rig.cloud.write('uid-ana', (docs) {
    final key = '$id-movie';
    docs[key] = docs[key]!.copyWith(watchedMovie: true, lastWatchedAt: rig.now);
  });

  void unwatch(SharingRig rig, int id) => rig.cloud.write('uid-ana', (docs) {
    final key = '$id-movie';
    docs[key] = docs[key]!.copyWith(watchedMovie: false);
  });

  SharingRig sharingStats({int movies = 6}) {
    final rig = SharingRig();
    for (var i = 1; i <= movies; i++) {
      rig.seed(sharingMovie(i));
    }
    rig.seedShared({SharedSection.stats});
    return rig;
  }

  int watchedTotal(SharingRig rig) =>
      ((rig.doc!['stats'] as Map)['total'] as Map)['watchedMovies'] as int;

  group('session start', () {
    test('content equal to the server: 0 writes; 1 read (the session read)', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        final gate = c.read(sharedRulesGateProvider);
        async.elapse(const Duration(minutes: 2));
        expect(gate.open, isTrue, reason: 'the session read fed the SAME gate');
        expect(rig.store.sharedRules, isNotEmpty);
        expect(rig.writes, 0);
        expect(rig.log.where((o) => o == 'readOwn'), hasLength(1));
        expect(rig.log, isNot(contains('probe')), reason: 'the session read is the probe (Q1)');
        c.dispose();
      });
    });

    test('content different (another device / old app changed the favorites): 1 write', () {
      fakeAsync((async) {
        final rig = sharingStats();
        // An old client marked a movie without the shared copy following.
        rig.cloud.server['uid-ana']!['1-movie'] = sharingMovie(1, watched: true);
        final c = start(async, rig);
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 1);
        expect(watchedTotal(rig), 1);
        c.dispose();
      });
    });

    test('nothing shared / no active friendships: 0 reads of the document, 0 writes', () {
      fakeAsync((async) {
        final rig = SharingRig(active: false)..seed(sharingMovie(1));
        final c = start(async, rig);
        // The real favorites factory reads the gate at session start.
        c.read(sharedRulesGateProvider);
        watch(rig, 1);
        async.elapse(const Duration(minutes: 1));
        expect(rig.writes, 0);
        expect(rig.shared.writeAttempts, 0);
        expect(rig.log, isNot(contains('readOwn')));
        expect(rig.log.where((o) => o == 'probe'), hasLength(1), reason: 'the dedicated probe');
        c.dispose();
      });
    });
  });

  group('coalescing (W = 5 s, max 30 s), relógio falso', () {
    test('1 mark: 0 writes at 4.9 s, 1 at 5 s', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        watch(rig, 1);
        async.elapse(const Duration(milliseconds: 4900));
        expect(rig.writes, 0);
        async.elapse(const Duration(milliseconds: 100));
        expect(rig.writes, 1);
        expect(watchedTotal(rig), 1);
        c.dispose();
      });
    });

    test('4 marks 2 s apart: 1 write, 5 s after the last', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        for (var i = 1; i <= 4; i++) {
          watch(rig, i);
          async.elapse(const Duration(seconds: 2));
        }
        expect(rig.writes, 0);
        async.elapse(const Duration(seconds: 3));
        expect(rig.writes, 1);
        expect(watchedTotal(rig), 4);
        c.dispose();
      });
    });

    test('a mark every 4 s for 40 s: the first write 30 s after the first mark', () {
      fakeAsync((async) {
        final rig = sharingStats(movies: 12);
        final c = start(async, rig);
        var t = 0;
        var id = 0;
        while (t < 40) {
          watch(rig, ++id);
          async.elapse(const Duration(seconds: 4));
          t += 4;
          if (t == 28) expect(rig.writes, 0);
          if (t == 32) expect(rig.writes, 1, reason: 'max wait of 30 s');
        }
        c.dispose();
      });
    });

    test('mark and unmark the same title within 2 s: 0 writes ("só grava se mudou")', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        watch(rig, 1);
        async.elapse(const Duration(seconds: 2));
        unwatch(rig, 1);
        async.elapse(const Duration(seconds: 10));
        expect(rig.writes, 0);
        c.dispose();
      });
    });

    test('hiding the page writes what is ready at once', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        watch(rig, 1);
        async.elapse(const Duration(seconds: 2));
        expect(rig.writes, 0);
        for (final cb in [...rig.hidden]) {
          cb();
        }
        async.flushMicrotasks();
        expect(rig.writes, 1);
        async.elapse(const Duration(seconds: 10));
        expect(rig.writes, 1, reason: 'nothing left pending');
        c.dispose();
      });
    });
  });

  group('never in the favorite\'s write (D4)', () {
    test('the favorite is written first, alone; the shared update 5 s later, apart', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        final source = InMemoryFavoritesDataSource(rig.cloud, uid: 'uid-ana');
        source.setWatchedMovie('1-movie', true);
        async.flushMicrotasks();
        expect(rig.cloud.server['uid-ana']!['1-movie']!.watchedMovie, isTrue);
        expect(rig.writes, 0, reason: 'nothing shared goes with the favorite');
        async.elapse(const Duration(seconds: 5));
        expect(rig.writes, 1);
        final op = rig.shared.writes.single.ops.single;
        expect(op.op, 'update');
        expect(op.path, 'shared_profiles/uid-ana');
        expect(op.data!.keys, isNot(contains('sharing')));
        expect(op.data!.keys, isNot(contains('actSince')));
        c.dispose();
      });
    });

    test('a refused shared write never undoes the mark, shows no banner, re-reads once', () {
      fakeAsync((async) {
        final rig = sharingStats();
        rig.shared.failNext(
          'write',
          const SocialFailure(SocialFailureKind.denied, code: 'permission-denied'),
        );
        final c = start(async, rig);
        final reads = rig.log.where((o) => o == 'readOwn').length;
        watch(rig, 1);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(rig.shared.writeAttempts, 1);
        expect(rig.cloud.server['uid-ana']!['1-movie']!.watchedMovie, isTrue);
        expect(c.read(syncStatusProvider).failure, isNull);
        expect(rig.log.where((o) => o == 'readOwn'), hasLength(reads + 1));
        async.elapse(const Duration(minutes: 2));
        expect(rig.shared.writeAttempts, 1, reason: 'no new attempt until the next trigger');
        c.dispose();
      });
    });

    test('10 triggers failing with quota: at most 10 attempts, each tied to a trigger', () {
      fakeAsync((async) {
        final rig = sharingStats(movies: 10);
        for (var i = 0; i < 20; i++) {
          rig.shared.failNext('write', const SocialFailure(SocialFailureKind.quotaExceeded));
        }
        final c = start(async, rig);
        for (var i = 1; i <= 10; i++) {
          watch(rig, i);
          async.elapse(const Duration(seconds: 6));
        }
        async.elapse(const Duration(minutes: 5));
        expect(rig.shared.writeAttempts, equals(10), reason: 'exactly one per trigger');
        expect(rig.writes, 0);
        c.dispose();
      });
    });
  });

  group('only with trustworthy data (RF-S6)', () {
    test('favorites only from the device cache (offline): 0 writes; online again: 1', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        rig.cloud.offline = true;
        async.flushMicrotasks();
        watch(rig, 1);
        async.elapse(const Duration(minutes: 1));
        expect(rig.writes, 0);
        rig.cloud.offline = false;
        rig.cloud.flush('uid-ana');
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 1);
        c.dispose();
      });
    });

    test('a new device that only saw the cache never publishes zeros', () {
      fakeAsync((async) {
        final rig = sharingStats();
        rig.cloud.server['uid-ana']!['1-movie'] = sharingMovie(1, watched: true);
        rig.cloud.offline = true;
        final c = start(async, rig);
        async.elapse(const Duration(minutes: 2));
        expect(rig.writes, 0);
        expect(c.read(syncStatusProvider).serverConfirmed, isFalse);
        c.dispose();
      });
    });

    test('served from the cache with nothing pending: a due pulse is not written', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        rig.cloud.offline = true;
        async.flushMicrotasks();
        expect(c.read(syncStatusProvider).fromCache, isTrue);
        expect(c.read(syncStatusProvider).hasPendingWrites, isFalse);
        rig.now = rig.now.add(const Duration(hours: 25));
        async.elapse(const Duration(hours: 25));
        expect(rig.shared.writeAttempts, 0);
        rig.cloud.offline = false;
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 1, reason: 'back online: the pulse');
        c.dispose();
      });
    });

    test('pending writes: 0 writes; once acknowledged: 1', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        rig.cloud.stuck = true;
        watch(rig, 1);
        async.elapse(const Duration(minutes: 1));
        expect(rig.writes, 0);
        rig.cloud.stuck = false;
        rig.cloud.flush('uid-ana');
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 1);
        c.dispose();
      });
    });

    test('account deletion (deleting) drops the pending write: 0 writes after markDeleting', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        watch(rig, 1);
        async.elapse(const Duration(seconds: 2));
        rig.cloud.profiles['uid-ana'] = const UserProfile(deleting: true);
        rig.cloud.write('uid-ana', (_) {});
        async.elapse(const Duration(minutes: 1));
        expect(rig.writes, 0);
        // A change seen while the deletion runs is not written either.
        watch(rig, 2);
        async.elapse(const Duration(minutes: 1));
        expect(rig.shared.writeAttempts, 0);
        c.dispose();
      });
    });

    test('a friendships operation holds the write; when it ends, 1 write', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        rig.social.writeGate = Completer<void>();
        unawaited(c.read(socialControllerProvider.notifier).revokeInvite());
        async.flushMicrotasks();
        expect(c.read(socialControllerProvider).busy, isTrue);
        watch(rig, 1);
        async.elapse(const Duration(seconds: 40));
        expect(rig.shared.writeAttempts, 0);
        rig.social.writeGate!.complete();
        rig.social.writeGate = null;
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 1);
        c.dispose();
      });
    });

    test('session switched with a pending write: nothing is written under any uid', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        watch(rig, 1);
        async.elapse(const Duration(seconds: 2));
        rig.auth.switchSessionTo(const AppUser(uid: 'uid-bruno', displayName: 'Bruno'));
        async.elapse(const Duration(minutes: 1));
        expect(rig.shared.writeAttempts, 0);
        c.dispose();
      });
    });

    test('signed out with a pending write: nothing is written', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        watch(rig, 1);
        async.elapse(const Duration(seconds: 2));
        rig.auth.signOut();
        async.elapse(const Duration(minutes: 1));
        expect(rig.shared.writeAttempts, 0);
        c.dispose();
      });
    });
  });

  group('pulse, "não regredir", month turn', () {
    test('same content, updatedAt 3 h old: 0 writes; 25 h old: 1 write with only updatedAt', () {
      fakeAsync((async) {
        final fresh = sharingStats()..now = kSharingNow;
        fresh.seedShared({
          SharedSection.stats,
        }, updatedAt: kSharingNow.subtract(const Duration(hours: 3)));
        final c1 = start(async, fresh);
        async.elapse(const Duration(seconds: 10));
        expect(fresh.writes, 0);
        c1.dispose();

        final old = sharingStats();
        old.seedShared({
          SharedSection.stats,
        }, updatedAt: kSharingNow.subtract(const Duration(hours: 25)));
        final c2 = start(async, old);
        async.elapse(const Duration(seconds: 10));
        expect(old.writes, 1);
        expect(old.shared.writes.single.ops.single.data!.keys, ['updatedAt']);
        c2.dispose();
      });
    });

    test('the owner\'s month turns with the app open: 1 write with month.key = 2026-11', () {
      fakeAsync((async) {
        final rig = SharingRig()..now = DateTime.utc(2026, 11, 1, 2, 59, 50); // 31/10 23:59:50
        rig.seed(sharingMovie(1));
        rig.seedShared({SharedSection.stats});
        final c = start(async, rig);
        expect(((rig.doc!['stats'] as Map)['month'] as Map)['key'], '2026-10');
        // The session's own triggers settle first: nothing to write in October.
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 0);
        // No mark, no other trigger: only the engine's wake-up at the turn.
        rig.now = DateTime.utc(2026, 11, 1, 3, 0, 1);
        async.elapse(const Duration(seconds: 20));
        expect(rig.writes, 1);
        expect(((rig.doc!['stats'] as Map)['month'] as Map)['key'], '2026-11');
        c.dispose();
      });
    });
  });

  group('activities', () {
    test('"Atividades" off: the document has no activity; mark dates are still kept', () {
      fakeAsync((async) {
        final rig = SharingRig();
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
        rig.seedShared({SharedSection.stats});
        final c = start(async, rig);
        InMemoryFavoritesDataSource(
          rig.cloud,
          uid: 'uid-ana',
        ).setEpisodes('50-tv', {'1_3': true}, current: rig.cloud.server['uid-ana']!['50-tv']);
        async.elapse(const Duration(seconds: 6));
        expect(rig.cloud.episodeWrites.single.dates.isEmpty, isFalse);
        expect(rig.writes, 1, reason: 'the stats changed and were written');
        expect(rig.doc!.containsKey('activity'), isFalse);
        expect(rig.shared.writes.every((w) => !w.ops.single.data!.containsKey('activity')), isTrue);
        c.dispose();
      });
    });

    test('marking T1E3 publishes "watched_episodes" and +1 episode in total, year and month', () {
      fakeAsync((async) {
        final rig = SharingRig();
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
        final c = start(async, rig);
        InMemoryFavoritesDataSource(
          rig.cloud,
          uid: 'uid-ana',
        ).setEpisodes('50-tv', {'1_3': true}, current: rig.cloud.server['uid-ana']!['50-tv']);
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 1);
        final stats = rig.doc!['stats'] as Map;
        for (final p in ['total', 'year', 'month']) {
          expect((stats[p] as Map)['watchedEpisodes'], 1, reason: p);
        }
        expect((stats['month'] as Map)['key'], '2026-10');
        expect(rig.doc!['tz'], -180);
        final first = (rig.doc!['activity'] as List).first as Map;
        expect(first['type'], 'watched_episodes');
        expect(first['season'], 1);
        expect(first['episode'], 3);
        c.dispose();
      });
    });

    test('a late device: the server refuses a section turned off elsewhere; it re-reads', () {
      fakeAsync((async) {
        final rig = sharingStats();
        final c = start(async, rig);
        // Another device turned "Estatísticas" off (doc deleted).
        rig.shared.docs.remove('uid-ana');
        watch(rig, 1);
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(rig.writes, 0);
        expect(c.read(sharingControllerProvider).sections, isEmpty);
        c.dispose();
      });
    });
  });

  test('two devices marking at the same time: both marks kept, the copy reflects both', () {
    fakeAsync((async) {
      final rig = sharingStats();
      final a = start(async, rig);
      final b = start(async, rig);
      final da = InMemoryFavoritesDataSource(rig.cloud, uid: 'uid-ana');
      final db = InMemoryFavoritesDataSource(rig.cloud, uid: 'uid-ana');
      da.setWatchedMovie('1-movie', true);
      db.setWatchedMovie('2-movie', true);
      async.elapse(const Duration(seconds: 6));
      expect(rig.cloud.server['uid-ana']!['1-movie']!.watchedMovie, isTrue);
      expect(rig.cloud.server['uid-ana']!['2-movie']!.watchedMovie, isTrue);
      expect(watchedTotal(rig), 2);
      expect(rig.writes, lessThanOrEqualTo(2), reason: 'at most one per device, same content');
      a.dispose();
      b.dispose();
    });
  });

  test('sharedDataReady: confirmed, from the server, nothing pending, catalog not holding', () {
    const ok = SyncStatus(serverConfirmed: true);
    expect(sharedDataReady(ok, catalogHeld: false), isTrue);
    expect(sharedDataReady(ok, catalogHeld: true), isFalse);
    expect(
      sharedDataReady(const SyncStatus(serverConfirmed: true, fromCache: true), catalogHeld: false),
      isFalse,
    );
    expect(
      sharedDataReady(
        const SyncStatus(serverConfirmed: true, hasPendingWrites: true),
        catalogHeld: false,
      ),
      isFalse,
    );
    expect(sharedDataReady(const SyncStatus(), catalogHeld: false), isFalse);
  });
}
