import 'dart:async';

import 'package:cinetrack/data/firestore_shared_profile_data_source.dart';
import 'package:cinetrack/data/firestore_social_data_source.dart';
import 'package:cinetrack/providers/friend_profile_providers.dart';
import 'package:cinetrack/repositories/shared_profile_repository.dart';
import 'package:cinetrack/repositories/social_repository.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_shared_profile_cloud.dart';
import 'support/fake_social_cloud.dart';

/// Fatia 3 (docs/82 §7.2): the pieces under the friend's profile screen.
void main() {
  group('isValidFriendUid (rules validUid + usable id)', () {
    for (final ok in ['uid-bruno', 'AbC123xyz', 'x' * 128, 'é', '.a']) {
      test('"${ok.length > 20 ? '128 chars' : ok}" is valid', () {
        expect(isValidFriendUid(ok), isTrue);
      });
    }
    for (final bad in ['', 'a_b', 'a/b', '/../', 'x' * 129, '.', '..']) {
      test('"${bad.length > 20 ? '129 chars' : bad}" is NOT valid', () {
        expect(isValidFriendUid(bad), isFalse);
      });
    }
  });

  group('FriendProfileCache (TTL D15)', () {
    final at = DateTime.utc(2026, 10, 15, 15);
    const ttl = Duration(minutes: 5);
    const friend = Friend(uid: 'uid-bruno', name: 'Bruno');

    test('4:59 is fresh, 5:00 is not', () {
      final cache = FriendProfileCache()
        ..put('uid-bruno', FriendProfileEntry(friend: friend, view: null, at: at));
      expect(
        cache.fresh('uid-bruno', at.add(const Duration(minutes: 4, seconds: 59)), ttl),
        isNotNull,
      );
      expect(cache.fresh('uid-bruno', at.add(ttl), ttl), isNull);
      expect(cache.fresh('uid-other', at, ttl), isNull);
    });

    test('remove forgets the entry AND the handed-over header', () {
      final cache = FriendProfileCache()
        ..rememberHeader(friend)
        ..put('uid-bruno', FriendProfileEntry(friend: friend, view: null, at: at));
      cache.remove('uid-bruno');
      expect(cache.contains('uid-bruno'), isFalse);
      expect(cache.header('uid-bruno'), isNull);
    });
  });

  group('lenient reading (RF-F9)', () {
    test('a malformed document never throws; sections absent when not map/list', () {
      final view = FriendSharedView.parse({
        'v': 7,
        'tz': 5000, // out of range: UTC
        'updatedAt': 'yesterday',
        'stats': 'nope',
        'activity': {'a': 1},
        'future': [1, 2],
      });
      expect(view.tz, 0);
      expect(view.updatedAt, isNull);
      expect(view.stats, isNull);
      expect(view.activity, isNull);
    });

    test('missing / mistyped numbers are null (never 0); negatives too', () {
      final r = SharedStatsReading.read({
        'total': {'favorites': 3, 'movies': -1, 'series': 2.5},
        'month': {'key': '2026-10', 'watchedMovies': 1},
        'year': 'x',
      })!;
      expect(r.favorites, 3);
      expect(r.movies, isNull);
      expect(r.series, isNull);
      expect(r.total.watchedMovies, isNull);
      expect(r.month.watchedMovies, 1);
      expect(r.month.watchedEpisodes, isNull);
      expect(r.year.key, isNull);
      expect(r.undatedMovies, 0);
    });

    test('a period: current = as stored; older = zeros; unknown key = unknown', () {
      const p = PeriodReading(key: '2026-10', watchedMovies: 4);
      expect(p.current('2026-10').watchedMovies, 4);
      expect(p.current('2026-11').watchedMovies, 0);
      expect(p.current('2026-11').watchedSeries, 0);
      expect(const PeriodReading(watchedMovies: 4).current('2026-10').watchedMovies, isNull);
    });

    test('the owner preview reads every number as known', () {
      final r = SharedStatsReading.of(
        const SharedStats(
          total: TotalStats(favorites: 2, movies: 1, series: 1, watchedSeries: 1, minutes: 30),
          year: PeriodStats(key: '2026', watchedEpisodes: 5),
          month: PeriodStats(key: '2026-10', completedSeries: 1),
        ),
      );
      expect(r.favorites, 2);
      expect(r.total.watchedSeries, 1);
      expect(r.total.minutes, 30);
      expect(r.year.watchedEpisodes, 5);
      expect(r.month.completedSeries, 1);
      expect(r.month.watchedMovies, 0);
    });
  });

  group('FirestoreSharedProfileDataSource.readFriend', () {
    test('ALWAYS asks the server (Source.server), path shared_profiles/<friend>', () async {
      final calls = <(String, bool)>[];
      final source = FirestoreSharedProfileDataSource(
        uid: 'uid-ana',
        getter: (path, {required server}) async {
          calls.add((path, server));
          return {'v': 1};
        },
      );
      expect(await source.readFriend('uid-bruno'), {'v': 1});
      expect(calls, [('shared_profiles/uid-bruno', true)]);
    });

    test('no answer in 8 s: offline / timeout (the screen shows "Não foi possível…")', () {
      fakeAsync((async) {
        final source = FirestoreSharedProfileDataSource(
          uid: 'uid-ana',
          getter: (path, {required server}) => Completer<Map<String, dynamic>?>().future,
        );
        Object? error;
        source.readFriend('uid-bruno').catchError((Object e) {
          error = e;
          return null;
        });
        async.elapse(const Duration(seconds: 7, milliseconds: 900));
        expect(error, isNull);
        async.elapse(const Duration(milliseconds: 200));
        expect(error, isA<SocialFailure>());
        expect((error as SocialFailure).kind, SocialFailureKind.offline);
        expect(error!.toString(), contains('timeout'));
      });
    });

    test('permission-denied maps to denied (never shown raw)', () async {
      final source = FirestoreSharedProfileDataSource(
        uid: 'uid-ana',
        getter: (path, {required server}) async =>
            throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      );
      await expectLater(
        source.readFriend('uid-bruno'),
        throwsA(isA<SocialFailure>().having((f) => f.kind, 'kind', SocialFailureKind.denied)),
      );
    });
  });

  group('SharedProfileRepository.readFriend', () {
    test('null = not shared; document = lenient view; denied = SharedProfileFailure', () async {
      final cloud = FakeSharedProfileCloud()..befriend('uid-ana', 'uid-bruno');
      final repo = SharedProfileRepository(InMemorySharedProfileDataSource(cloud, uid: 'uid-ana'));
      expect(await repo.readFriend('uid-bruno'), isNull);
      cloud.docs['uid-bruno'] = {'tz': -180, 'activity': <Object?>[]};
      final view = await repo.readFriend('uid-bruno');
      expect(view!.tz, -180);
      expect(view.activity, isEmpty);
      expect(view.stats, isNull);
      await expectLater(
        repo.readFriend('uid-carla'),
        throwsA(
          isA<SharedProfileFailure>().having(
            (f) => f.kind,
            'kind',
            SharedProfileFailureKind.denied,
          ),
        ),
      );
    });
  });

  group('the pair (opened by address)', () {
    test(
      'FirestoreSocialDataSource.readFriendship: ONE server get of the sorted pair id',
      () async {
        final reads = <String>[];
        final at = Timestamp.fromDate(DateTime.utc(2026, 1, 2));
        final source = FirestoreSocialDataSource(
          uid: 'uid-z',
          docReader: (path) async {
            reads.add(path);
            return path == 'friendships/uid-a_uid-z'
                ? (exists: true, data: <String, dynamic>{'createdAt': at})
                : (exists: false, data: null);
          },
        );
        final pair = await source.readFriendship('uid-a');
        expect(reads, ['friendships/uid-a_uid-z']);
        expect(pair!['createdAt'], DateTime.utc(2026, 1, 2).toLocal());
        expect(await source.readFriendship('uid-b'), isNull);
      },
    );

    test(
      'SocialRepository.friendship: the other half; a pair not between the two = null',
      () async {
        final cloud = FakeSocialCloud();
        final repo = SocialRepository(InMemorySocialDataSource(cloud, uid: 'uid-ana'));
        cloud.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana', bName: 'Bruno');
        final friend = await repo.friendship('uid-bruno');
        expect(friend!.uid, 'uid-bruno');
        expect(friend.name, 'Bruno');
        expect(friend.since, isNotNull);
        expect(await repo.friendship('uid-carla'), isNull);
        // A malformed document under the right id is never shown.
        cloud.friendships[FakeSocialCloud.pairId('uid-ana', 'uid-davi')] = {
          'members': ['uid-ana', 'uid-x'],
          'aName': 'Ana',
          'bName': 'X',
        };
        expect(await repo.friendship('uid-davi'), isNull);
        expect(cloud.readLog.where((r) => r.startsWith('friendship:')).length, 3);
      },
    );
  });
}
