import 'dart:async';
import 'dart:math' as math;

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/data/shared_profile_data_source.dart';
import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/data/sync_status.dart';
import 'package:cinetrack/providers/friend_profile_providers.dart';
import 'package:cinetrack/providers/friends_count_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/ranking_providers.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/providers/social_lists_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_doc.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/favorites_harness.dart';

/// docs/91 §10 and §12 (Fatia 2): the ranking controller over fakes. Every
/// friend read is a `Completer` answered in the order the test chooses (the
/// "order of arrival" of O9), counted by uid, with the peak of reads in
/// flight; list queries count the documents they read; the aggregate count
/// and every write are counted too (writes must stay at 0).

const _ana = AppUser(uid: 'uid-ana', displayName: 'Ana', email: 'ana@example.test');
const _bia = AppUser(uid: 'uid-bia', displayName: 'Bia', email: 'bia@example.test');
final _t0 = DateTime.utc(2026, 10, 15, 15);

/// How a friend's read ends.
enum A { stats, noStats, notFound, statsNotMap, emptyStats, denied, failed, quota, unauth }

class _Social extends SocialController {
  @override
  SocialState build() => const SocialState(phase: SocialPhase.active);
}

class _Sync extends SyncStatusNotifier {
  @override
  SyncStatus build() => const SyncStatus(serverConfirmed: true);

  /// [fromCache] alone: the last answer came from the device but the drop is
  /// not settled yet (not `offline`), the window the profile guards too.
  void set({required bool offline, bool fromCache = false}) => state = offline
      ? const SyncStatus(serverConfirmed: true, fromCache: true, graceOver: true)
      : SyncStatus(fromCache: fromCache, serverConfirmed: !fromCache);
}

class _Friends extends FriendsController {
  _Friends(this.rig);
  final Rig rig;

  @override
  Future<PageData<Friend>> fetch(Object? cursor, int limit) async {
    rig.listQueries.add(math.min(rig.friends.length, limit + 1));
    final failure = rig.listFailure;
    if (failure != null) {
      rig.listFailure = null;
      throw failure;
    }
    final items = rig.friends.take(limit).toList();
    return PageData(items, null, rig.friends.length > limit, rig.listFromCache);
  }
}

class _Pending {
  final String uid;
  final Completer<Map<String, dynamic>?> k = Completer();
  _Pending(this.uid);
}

class _Shared extends SignedOutSharedProfileDataSource {
  _Shared(this.rig, this.me);
  final Rig rig;
  final String me;

  @override
  String get uid => me;

  @override
  Future<Map<String, dynamic>?> readFriend(String friendUid) {
    rig.reads.add(friendUid);
    rig.inFlight++;
    rig.peak = math.max(rig.peak, rig.inFlight);
    final p = _Pending(friendUid);
    rig.pending.add(p);
    return p.k.future.whenComplete(() => rig.inFlight--);
  }

  @override
  Future<Map<String, dynamic>?> readOwn({required bool fromServer}) {
    rig.readOwn++;
    return Future.value(null);
  }

  @override
  Future<void> toggle(SocialWrite Function(Map<String, dynamic>? current) plan) {
    rig.writes++;
    return super.toggle(plan);
  }

  @override
  Future<void> writeSections(SocialWrite write) {
    rig.writes++;
    return super.writeSections(write);
  }

  @override
  Future<void> deleteOwn() {
    rig.writes++;
    return super.deleteOwn();
  }
}

final _me = StateProvider<RankingMe>((ref) => const RankingMe());

SharedProfileDoc _myDoc() => SharedProfileDoc(
  sharing: {SharedSection.stats},
  updatedAt: _t0,
  tz: -180,
  stats: const SharedStats(
    total: TotalStats(watchedEpisodes: 3),
    year: PeriodStats(key: '2026', watchedEpisodes: 3),
    month: PeriodStats(key: '2026-10', watchedEpisodes: 1),
  ),
);

class Rig {
  final auth = StreamController<AppUser?>();
  final store = FakeLocalStore();
  DateTime now = _t0;
  List<Friend> friends = [];
  SocialFailure? listFailure;
  bool listFromCache = false;

  /// Documents read by each friends-list query (one entry per query).
  final List<int> listQueries = [];
  final List<String> reads = [];
  final List<_Pending> pending = [];
  final List<Completer<int>> counts = [];
  int inFlight = 0;
  int peak = 0;
  int readOwn = 0;
  int writes = 0;
  late final ProviderContainer c;
  ProviderSubscription<RankingState>? _screen;

  Rig({int n = 0, RankingMe? me}) {
    friends = [
      for (var i = 0; i < n; i++) Friend(uid: uidOf(i), name: 'Amigo ${'$i'.padLeft(2, '0')}'),
    ];
    c = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith((ref) => auth.stream),
        socialControllerProvider.overrideWith(_Social.new),
        syncStatusProvider.overrideWith(_Sync.new),
        localStoreProvider.overrideWithValue(store),
        socialClockProvider.overrideWithValue(() => now),
        sharedProfileClockProvider.overrideWithValue(() => now),
        friendsControllerProvider.overrideWith(() => _Friends(this)),
        sharedProfileDataSourceFactoryProvider.overrideWithValue((uid) => _Shared(this, uid)),
        friendsCountReaderProvider.overrideWithValue(() {
          final k = Completer<int>();
          counts.add(k);
          return k.future;
        }),
        rankingMeProvider.overrideWith((ref) => ref.watch(_me)),
      ],
    );
    c.read(_me.notifier).state = me ?? RankingMe(sharing: true, doc: _myDoc());
    c.listen(friendsCountControllerProvider, (_, _) {});
  }

  static String uidOf(int i) => 'uid-f${'$i'.padLeft(2, '0')}';

  Future<void> signIn([AppUser user = _ana]) async {
    auth.add(user);
    await settle();
  }

  /// The friends list already in memory (read at [now]); its query is not counted.
  Future<void> listInMemory() async {
    await c.read(friendsControllerProvider.notifier).ensureLoaded();
    listQueries.clear();
  }

  /// Puts [uids] in the shared memory cache as read at [at] (with stats).
  void cached(Iterable<String> uids, DateTime at) {
    final cache = c.read(friendProfileCacheProvider);
    for (final uid in uids) {
      final f = friends.firstWhere((f) => f.uid == uid);
      cache.put(uid, FriendProfileEntry(friend: f, view: FriendSharedViewFor.stats(), at: at));
    }
  }

  Future<void> open() async {
    _screen = c.listen(rankingControllerProvider, (_, _) {});
    await settle();
  }

  Future<void> leave() async {
    _screen?.close();
    _screen = null;
    await settle();
  }

  RankingState get s => c.read(rankingControllerProvider);
  RankingController get n => c.read(rankingControllerProvider.notifier);
  FriendProfileCache get cache => c.read(friendProfileCacheProvider);
  int get started => reads.length;

  List<_Pending> get open_ => [
    for (final p in pending)
      if (!p.k.isCompleted) p,
  ];

  void _complete(_Pending p, A a) {
    final k = p.k;
    switch (a) {
      case A.stats:
        k.complete({
          'updatedAt': now,
          'tz': -180,
          'calc': 1,
          'stats': {
            'total': {'watchedEpisodes': 5},
          },
        });
      case A.noStats:
        k.complete({'updatedAt': now, 'activity': []});
      case A.notFound:
        k.complete(null);
      case A.statsNotMap:
        k.complete({'updatedAt': now, 'stats': 3});
      case A.emptyStats:
        k.complete({'updatedAt': now, 'stats': <String, dynamic>{}});
      case A.denied:
        k.completeError(const SocialFailure(SocialFailureKind.denied, code: 'permission-denied'));
      case A.failed:
        k.completeError(const SocialFailure(SocialFailureKind.unknown, code: 'unavailable'));
      case A.quota:
        k.completeError(
          const SocialFailure(SocialFailureKind.quotaExceeded, code: 'resource-exhausted'),
        );
      case A.unauth:
        k.completeError(
          const SocialFailure(SocialFailureKind.sessionExpired, code: 'unauthenticated'),
        );
    }
  }

  /// Answers the oldest read still open (or the one of [uid]).
  Future<void> respond(A a, {String? uid}) async {
    final p = uid == null ? open_.first : open_.firstWhere((p) => p.uid == uid);
    _complete(p, a);
    await settle();
  }

  Future<void> respondEach(List<A> answers) async {
    for (final a in answers) {
      await respond(a);
    }
  }

  /// Answers every read, including the ones that start meanwhile.
  Future<void> respondAll(A a) async {
    while (open_.isNotEmpty) {
      await respond(a);
    }
  }

  void dispose() {
    c.dispose();
  }
}

extension FriendSharedViewFor on Never {
  static FriendSharedView stats() => FriendSharedView.parse({
    'updatedAt': DateTime.utc(2026, 10, 15, 15),
    'stats': {
      'total': {'watchedEpisodes': 2},
    },
  });
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Rig r;

  Future<Rig> rig(int n, {RankingMe? me, bool listInMemory = true}) async {
    r = Rig(n: n, me: me);
    await r.signIn();
    if (listInMemory) await r.listInMemory();
    return r;
  }

  tearDown(() {
    expect(r.writes, 0, reason: 'the ranking never writes');
    r.dispose();
  });

  group('O9 — phases of the load', () {
    test('1: 5 friends, all failed -> error, no rows (not even mine)', () async {
      await rig(5);
      await r.open();
      await r.respondAll(A.failed);
      expect(r.s.phase, RankingPhase.error);
      expect(r.s.showsRows, isFalse);
      expect(r.s.friends, isEmpty);
      expect(r.s.failed, hasLength(5));
      expect(r.started, 5);
      expect(r.cache.contains(Rig.uidOf(0)), isFalse);
    });

    test('2: 50 friends, the 10 first answers failed -> error with EXACTLY 10 started', () async {
      await rig(50);
      await r.open();
      expect(r.started, 10);
      await r.respondEach(List.filled(9, A.failed));
      expect(r.started, 10, reason: 'the window does not slide before an ok/denied');
      await r.respond(A.failed);
      expect(r.s.phase, RankingPhase.error);
      expect(r.s.failed, hasLength(50));
      expect(r.started, 10);
      expect(r.open_, isEmpty);
    });

    test(
      '3: 9 failed + 1 ok (the 10th), the rest ok -> content, 41 friends, all 50 read',
      () async {
        await rig(50);
        await r.open();
        await r.respondEach(List.filled(9, A.failed));
        await r.respond(A.stats);
        expect(r.started, 11, reason: 'started = 10 + R, R = 1 (the first ok)');
        await r.respondAll(A.stats);
        expect(r.s.phase, RankingPhase.content);
        expect(r.s.friends, hasLength(41));
        expect(r.s.failed, hasLength(9));
        expect(r.s.notSharing, 0);
        expect(r.started, 50);
        expect([for (var i = 0; i < 50; i++) Rig.uidOf(i)].where(r.cache.contains), hasLength(41));
      },
    );

    test('4: 10 friends, all denied -> skeleton until the recount; 0 => noFriends', () async {
      await rig(10);
      await r.open();
      await r.respondAll(A.denied);
      expect(r.s.awaitingRecount, isTrue);
      expect(r.s.phase, RankingPhase.loading);
      expect(r.started, 10);
      expect(r.counts, hasLength(1), reason: 'ONE recount for the whole load');
      expect(r.c.read(friendsControllerProvider).items, isEmpty, reason: '10 dropLocal');
      expect(r.cache.contains(Rig.uidOf(0)), isFalse);
      r.counts.single.complete(0);
      await settle();
      expect(r.c.read(friendsCountControllerProvider).count, 0);
      expect(r.c.read(friendsCountControllerProvider).confirmed, isTrue);
      expect(r.s.awaitingRecount, isTrue, reason: 'the router leaves; no frame of content');
      expect(r.started, 10);
    });

    test('4b: all denied, the recount says there are more friends -> loads again', () async {
      await rig(10);
      await r.open();
      await r.respondAll(A.denied);
      r.counts.single.complete(4);
      await settle();
      expect(r.s.awaitingRecount, isFalse);
      expect(r.s.phase, RankingPhase.content, reason: 'nobody left in the list: only me');
      expect(r.started, 10);
    });

    test('5: 20; ok, ok, quota -> quota, 12 started, the 9 in flight discarded', () async {
      await rig(20);
      await r.open();
      await r.respondEach([A.stats, A.stats, A.quota]);
      expect(r.s.phase, RankingPhase.quota);
      expect(r.s.showsRows, isFalse);
      expect(r.started, 12);
      expect(r.open_, hasLength(9));
      await r.respondAll(A.stats);
      expect(r.started, 12, reason: 'nothing new after a terminal answer');
      expect(r.s.phase, RankingPhase.quota);
      expect([for (var i = 0; i < 20; i++) Rig.uidOf(i)].where(r.cache.contains), hasLength(2));
    });

    test('6: Carla times out at 8 s and answers at 9 s -> failed, never cached', () {
      fakeAsync((async) {
        r = Rig(n: 5);
        r.auth.add(_ana);
        async.flushMicrotasks();
        r.c.read(friendsControllerProvider.notifier).ensureLoaded();
        async.flushMicrotasks();
        r.c.listen(rankingControllerProvider, (_, _) {});
        async.flushMicrotasks();
        expect(r.started, 5);
        final carla = r.pending.first;
        for (final p in r.pending.skip(1)) {
          r._complete(p, A.stats);
        }
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 8));
        expect(r.s.phase, RankingPhase.content);
        expect(r.s.failed, {carla.uid});
        expect(r.s.friends, hasLength(4));
        async.elapse(const Duration(seconds: 1));
        r._complete(carla, A.stats);
        async.flushMicrotasks();
        expect(r.cache.contains(carla.uid), isFalse);
        expect(r.s.failed, {carla.uid});
        expect(r.started, 5);
      });
    });

    test(
      '7: 2 failed + "Tentar novamente": Carla ok, Davi denied -> both gone from failed',
      () async {
        await rig(5);
        await r.open();
        final carla = Rig.uidOf(1), davi = Rig.uidOf(3);
        for (var i = 0; i < 5; i++) {
          await r.respond(i == 1 || i == 3 ? A.failed : A.stats);
        }
        expect(r.s.failed, {carla, davi});
        expect(r.s.friends, hasLength(3));
        r.reads.clear();
        final retry = r.n.retry();
        await settle();
        expect(r.reads, [carla, davi]);
        await r.respond(A.stats, uid: carla);
        await r.respond(A.denied, uid: davi);
        await retry;
        expect(r.s.phase, RankingPhase.content);
        expect(r.s.friends.map((f) => f.friend.uid), containsAll([carla]));
        expect(r.s.friends.map((f) => f.friend.uid), isNot(contains(davi)));
        expect(r.s.friends, hasLength(4));
        expect(r.s.failed, isEmpty);
        expect(r.counts, hasLength(1), reason: '+1 aggregate for the denial');
        expect(r.cache.contains(carla), isTrue);
        expect(r.c.read(friendsControllerProvider).items.map((f) => f.uid), isNot(contains(davi)));
      },
    );

    test('8: "Tentar novamente" and both fail again -> same rows, 2 failed, 2 reads', () async {
      await rig(5);
      await r.open();
      for (var i = 0; i < 5; i++) {
        await r.respond(i < 2 ? A.failed : A.stats);
      }
      r.reads.clear();
      unawaited(r.n.retry());
      await settle();
      await r.respondAll(A.failed);
      expect(r.s.phase, RankingPhase.content);
      expect(r.s.friends, hasLength(3));
      expect(r.s.failed, hasLength(2));
      expect(r.reads, hasLength(2));
    });

    test(
      '9: 20; 3 ok, then the connection drops -> offline, 13 started, in flight discarded',
      () async {
        await rig(20);
        await r.open();
        await r.respondEach([A.stats, A.stats, A.stats]);
        (r.c.read(syncStatusProvider.notifier) as _Sync).set(offline: true);
        await settle();
        expect(r.s.phase, RankingPhase.offline);
        expect(r.s.showsRows, isFalse);
        expect(r.started, 13);
        await r.respondAll(A.stats);
        expect(r.started, 13);
        expect([for (var i = 0; i < 20; i++) Rig.uidOf(i)].where(r.cache.contains), hasLength(3));
        expect(r.s.phase, RankingPhase.offline);
      },
    );

    test('10: 20; 3 ok, 4th unauthenticated -> sessionExpired, 13 started', () async {
      await rig(20);
      await r.open();
      await r.respondEach([A.stats, A.stats, A.stats, A.unauth]);
      expect(r.s.phase, RankingPhase.sessionExpired);
      expect(r.started, 13);
      await r.respondAll(A.stats);
      expect([for (var i = 0; i < 20; i++) Rig.uidOf(i)].where(r.cache.contains), hasLength(3));
    });

    test('11: 20 friends, 12 fresh in the cache, the 8 reads fail -> content with 12', () async {
      await rig(20);
      r.cached([for (var i = 0; i < 12; i++) Rig.uidOf(i)], _t0);
      await r.open();
      expect(r.started, 8);
      await r.respondAll(A.failed);
      expect(r.s.phase, RankingPhase.content);
      expect(r.s.friends, hasLength(12));
      expect(r.s.failed, hasLength(8));
      expect([for (var i = 12; i < 20; i++) Rig.uidOf(i)].where(r.cache.contains), isEmpty);
    });

    test('12: 9 considered: 7 ok of every shape + 2 failed -> 4 rows, notSharing 3', () async {
      await rig(9);
      await r.open();
      await r.respondEach([
        A.stats,
        A.stats,
        A.stats,
        A.notFound,
        A.noStats,
        A.statsNotMap,
        A.emptyStats,
        A.failed,
        A.failed,
      ]);
      expect(r.s.phase, RankingPhase.content);
      expect(r.s.friends, hasLength(4));
      expect(r.s.notSharing, 3);
      expect(r.s.failed, hasLength(2));
      expect(r.started, 9);
      expect([for (var i = 0; i < 9; i++) Rig.uidOf(i)].where(r.cache.contains), hasLength(7));
    });

    test('13: the list fails (unavailable) -> error, 0 reads', () async {
      await rig(5, listInMemory: false);
      r.listFailure = const SocialFailure(SocialFailureKind.unknown, code: 'unavailable');
      await r.open();
      expect(r.s.phase, RankingPhase.error);
      expect(r.started, 0);
    });

    test('14: the list fails with resource-exhausted -> quota, 0 reads', () async {
      await rig(5, listInMemory: false);
      r.listFailure = const SocialFailure(SocialFailureKind.quotaExceeded);
      await r.open();
      expect(r.s.phase, RankingPhase.quota);
      expect(r.started, 0);
    });

    test('14b: session expired / offline list -> those phases, 0 reads', () async {
      await rig(5, listInMemory: false);
      r.listFailure = const SocialFailure(SocialFailureKind.sessionExpired);
      await r.open();
      expect(r.s.phase, RankingPhase.sessionExpired);
      await r.leave();
      r.listFailure = const SocialFailure(SocialFailureKind.offline);
      await r.open();
      expect(r.s.phase, RankingPhase.offline);
      expect(r.started, 0);
    });

    test('14c: a list served by the device (fromCache) = offline, 0 reads', () async {
      await rig(5, listInMemory: false);
      r.listFromCache = true;
      await r.open();
      expect(r.s.phase, RankingPhase.offline);
      expect(r.started, 0);
    });

    test('15: 3 friends without stats and I do not share -> content, nobody, footer 3', () async {
      await rig(3, me: const RankingMe(sharing: false));
      await r.open();
      await r.respondEach([A.noStats, A.notFound, A.statsNotMap]);
      expect(r.s.phase, RankingPhase.content);
      expect(r.s.friends, isEmpty);
      expect(r.s.me, isNull);
      expect(r.s.meSharing, isFalse);
      expect(r.s.notSharing, 3);
      expect(r.started, 3);
      expect([for (var i = 0; i < 3; i++) Rig.uidOf(i)].where(r.cache.contains), hasLength(3));
    });

    test('16: account switch with 6 in flight -> B starts clean, nothing of A cached', () async {
      await rig(6);
      await r.open();
      expect(r.open_, hasLength(6));
      final cacheA = r.cache;
      await r.signIn(_bia);
      final inFlightOfA = r.pending.take(6).toList();
      for (final p in inFlightOfA) {
        r._complete(p, A.stats);
      }
      await settle();
      expect([for (var i = 0; i < 6; i++) Rig.uidOf(i)].where(r.cache.contains), isEmpty);
      expect([for (var i = 0; i < 6; i++) Rig.uidOf(i)].where(cacheA.contains), isEmpty);
      expect(r.s.friends.where((f) => inFlightOfA.any((p) => p.uid == f.friend.uid)), isEmpty);
    });

    test(
      '17: leave with 6 in flight; reopen reads only what was not cached before leaving',
      () async {
        await rig(8);
        await r.open();
        await r.respondEach([A.stats, A.stats]);
        expect(r.open_, hasLength(6));
        await r.leave();
        for (final p in r.open_) {
          r._complete(p, A.stats);
        }
        await settle();
        expect([for (var i = 0; i < 8; i++) Rig.uidOf(i)].where(r.cache.contains), hasLength(2));
        r.reads.clear();
        await r.open();
        expect(r.reads, [for (var i = 2; i < 8; i++) Rig.uidOf(i)]);
      },
    );

    test('18: 20 all ok -> content, peak 10, the 11th starts when the 1st ends', () async {
      await rig(20);
      await r.open();
      expect(r.started, 10);
      await r.respond(A.stats);
      expect(r.started, 11);
      await r.respondAll(A.stats);
      expect(r.s.phase, RankingPhase.content);
      expect(r.s.friends, hasLength(20));
      expect(r.peak, 10);
      expect(r.started, 20);
      expect(r.s.failed, isEmpty);
    });

    test('window: started = min(N, 10 + R) counting from the first ok/denied, inclusive', () async {
      await rig(30);
      await r.open();
      await r.respondEach([A.failed, A.failed, A.failed]);
      expect(r.started, 10);
      await r.respond(A.denied);
      expect(r.started, 11, reason: 'R = 1: the window refills ONE, not up to 10 in flight');
      await r.respond(A.failed);
      expect(r.started, 12);
      await r.respond(A.stats);
      expect(r.started, 13);
      await r.respondAll(A.stats);
      expect(r.started, 30);
      expect(r.peak, 10);
    });

    test('fewer than 10 to read: all start, no breaker (9 failed -> error)', () async {
      await rig(9);
      await r.open();
      expect(r.started, 9);
      await r.respondAll(A.failed);
      expect(r.s.phase, RankingPhase.error);
      expect(r.s.failed, hasLength(9));
    });

    test('considered = state.items.take(50) at load time; limitedTo = 50 with more', () async {
      await rig(80, listInMemory: false);
      await r.open();
      expect(r.listQueries, [51]);
      await r.respondAll(A.stats);
      expect(r.started, 50);
      expect(r.reads.toSet(), {for (var i = 0; i < 50; i++) Rig.uidOf(i)});
      expect(r.s.limitedTo, 50);
      expect(r.s.friends, hasLength(50));
    });

    test('considered follows the list in memory (an added friend slots in by name)', () async {
      await rig(50);
      r.c.read(friendsControllerProvider.notifier).add(const Friend(uid: 'uid-aaa', name: 'Aaa'));
      await r.open();
      await r.respondAll(A.stats);
      expect(r.reads, contains('uid-aaa'));
      expect(r.reads, isNot(contains(Rig.uidOf(49))), reason: 'the 51st in memory is out');
      expect(r.s.limitedTo, 50);
    });

    test('my row comes from RankingMe (0 reads) and follows it without a read', () async {
      await rig(2);
      await r.open();
      await r.respondAll(A.stats);
      expect(r.s.meSharing, isTrue);
      expect(r.s.me, isNotNull);
      expect(r.readOwn, 0);
      final before = r.started;
      r.c.read(_me.notifier).state = const RankingMe(sharing: false);
      await settle();
      expect(r.s.me, isNull);
      expect(r.s.meSharing, isFalse);
      r.c.read(_me.notifier).state = const RankingMe();
      await settle();
      expect(r.s.meSharing, isNull, reason: 'not confirmed: D9 waits');
      expect(r.started, before);
      expect(r.s.phase, RankingPhase.content);
    });

    test('totalFriends only when the count is confirmed', () async {
      await rig(3);
      await r.open();
      await r.respondAll(A.stats);
      expect(r.s.totalFriends, 3, reason: 'a complete server page confirms the count');
      expect(r.s.limitedTo, isNull);
    });

    test('offline when opening: offline, 0 reads; back online loads', () async {
      await rig(3);
      (r.c.read(syncStatusProvider.notifier) as _Sync).set(offline: true);
      await r.open();
      expect(r.s.phase, RankingPhase.offline);
      expect(r.started, 0);
      (r.c.read(syncStatusProvider.notifier) as _Sync).set(offline: false);
      await settle();
      expect(r.started, 3);
      await r.respondAll(A.stats);
      expect(r.s.phase, RankingPhase.content);
    });

    test('a device that just lost the server (fromCache) never serves the memory cache', () async {
      await rig(3);
      r.cached([for (var i = 0; i < 3; i++) Rig.uidOf(i)], _t0);
      (r.c.read(syncStatusProvider.notifier) as _Sync).set(offline: false, fromCache: true);
      await r.open();
      expect(r.started, 3);
    });

    test('a denial removes the friend from screen, cache and list, and recounts ONCE', () async {
      await rig(5);
      r.cached([Rig.uidOf(0)], _t0.subtract(const Duration(minutes: 10))); // stale: read
      await r.open();
      await r.respondEach([A.denied, A.stats, A.denied, A.stats, A.stats]);
      expect(r.s.friends, hasLength(3));
      expect(r.cache.contains(Rig.uidOf(0)), isFalse);
      expect(r.c.read(friendsControllerProvider).items, hasLength(3));
      expect(r.counts, hasLength(1));
    });
  });

  group('O10 — cooldown of "Atualizar" (60 s, anchored on freshAt)', () {
    Future<void> loaded(int n) async {
      await rig(n, listInMemory: false);
      await r.open();
      await r.respondAll(A.stats);
      r.reads.clear();
      r.listQueries.clear();
    }

    test('1-2: at t0+10 s and t0+59 s -> cooldown, 0 reads', () async {
      await loaded(20);
      expect(r.s.freshAt, _t0);
      for (final s in [10, 59]) {
        r.now = _t0.add(Duration(seconds: s));
        expect(await r.n.refresh(), RankingRefresh.cooldown);
      }
      expect(r.reads, isEmpty);
      expect(r.listQueries, isEmpty);
    });

    test('3: at t0+60 s -> 1 list + 20 gets, freshAt = t0+60 s', () async {
      await loaded(20);
      r.now = _t0.add(const Duration(seconds: 60));
      final f = r.n.refresh();
      await settle();
      expect(r.s.refreshing, isTrue);
      expect(r.s.friends, hasLength(20), reason: 'the previous ranking stays visible');
      await r.respondAll(A.stats);
      expect(await f, RankingRefresh.loaded);
      expect(r.listQueries, [20]);
      expect(r.reads, hasLength(20));
      expect(r.s.freshAt, _t0.add(const Duration(seconds: 60)));
      expect(r.s.refreshing, isFalse);
    });

    test('4: list read by Amigos at t0+50 s -> "Atualizar" at t0+60 s reads 20, list 0', () async {
      await loaded(20);
      r.now = _t0.add(const Duration(seconds: 50));
      await r.c.read(friendsControllerProvider.notifier).refresh();
      r.listQueries.clear();
      r.now = _t0.add(const Duration(seconds: 60));
      final f = r.n.refresh();
      await settle();
      await r.respondAll(A.stats);
      await f;
      expect(r.listQueries, isEmpty);
      expect(r.reads, hasLength(20));
    });

    test('5: reopened at t0+4 min from the cache -> "Atualizar" is free (freshAt = t0)', () async {
      await loaded(20);
      await r.leave();
      r.now = _t0.add(const Duration(minutes: 4));
      await r.open();
      expect(r.reads, isEmpty);
      expect(r.s.freshAt, _t0, reason: 'anchored on the reads, not on the reopening');
      final f = r.n.refresh();
      await settle();
      await r.respondAll(A.stats);
      expect(await f, RankingRefresh.loaded);
      expect(r.listQueries, [20]);
      expect(r.reads, hasLength(20));
    });

    test(
      '6: 12 entries from t0-3 min + 8 read at t0 -> freshAt = t0-3 min, free at t0+1 s',
      () async {
        r = Rig(n: 20);
        await r.signIn();
        final old = _t0.subtract(const Duration(minutes: 3));
        r.now = old;
        await r.listInMemory();
        r.cached([for (var i = 0; i < 12; i++) Rig.uidOf(i)], old);
        r.now = _t0;
        await r.open();
        await r.respondAll(A.stats);
        expect(r.reads, hasLength(8));
        expect(r.s.freshAt, old);
        r.reads.clear();
        r.now = _t0.add(const Duration(seconds: 1));
        final f = r.n.refresh();
        await settle();
        await r.respondAll(A.stats);
        expect(await f, RankingRefresh.loaded);
        expect(r.listQueries, [20]);
        expect(r.reads, hasLength(20));
      },
    );

    test(
      '7-8: partial at t0: "Tentar novamente" ignores the cooldown; "Atualizar" does not',
      () async {
        await rig(5);
        await r.open();
        await r.respondEach([A.failed, A.failed, A.stats, A.stats, A.stats]);
        r.reads.clear();
        r.now = _t0.add(const Duration(seconds: 1));
        unawaited(r.n.retry());
        await settle();
        expect(r.reads, hasLength(2));
        await r.respondAll(A.stats);
        r.reads.clear();
        expect(await r.n.refresh(), RankingRefresh.cooldown);
        expect(r.reads, isEmpty);
        expect(r.s.freshAt, _t0);
      },
    );

    test('9: error at t0 -> "Tentar novamente" at t0+1 s = full load', () async {
      await rig(3);
      await r.open();
      await r.respondAll(A.failed);
      expect(r.s.phase, RankingPhase.error);
      r.reads.clear();
      r.now = _t0.add(const Duration(seconds: 1));
      unawaited(r.n.retry());
      await settle();
      expect(r.reads, hasLength(3));
      await r.respondAll(A.stats);
      expect(r.s.phase, RankingPhase.content);
    });

    test('10: quota at t0 -> "Tentar novamente" = full load (fresh cache entries count)', () async {
      await rig(20);
      await r.open();
      await r.respondEach([A.stats, A.stats, A.quota]);
      await r.respondAll(A.stats); // the 9 in flight: discarded
      r.reads.clear();
      r.now = _t0.add(const Duration(seconds: 1));
      unawaited(r.n.retry());
      await settle();
      await r.respondAll(A.stats);
      expect(r.reads, hasLength(18), reason: 'the 2 cached before the quota are fresh');
      expect(r.s.phase, RankingPhase.content);
    });

    test('11: a load running -> "Atualizar" joins it (0 more reads)', () async {
      await rig(3);
      await r.open();
      final f = r.n.refresh();
      await settle();
      expect(r.started, 3);
      await r.respondAll(A.stats);
      expect(await f, RankingRefresh.joined);
      expect(r.started, 3);
    });

    test('12-13: nobody shares (3 ok without stats, 1 not-found) also has the cooldown', () async {
      await rig(3, listInMemory: false);
      await r.open();
      await r.respondEach([A.noStats, A.notFound, A.statsNotMap]);
      expect(r.s.friends, isEmpty);
      expect(r.s.freshAt, _t0);
      r.reads.clear();
      r.listQueries.clear();
      r.now = _t0.add(const Duration(seconds: 10));
      expect(await r.n.refresh(), RankingRefresh.cooldown);
      expect(r.reads, isEmpty);
      r.now = _t0.add(const Duration(seconds: 60));
      final f = r.n.refresh();
      await settle();
      await r.respondAll(A.noStats);
      expect(await f, RankingRefresh.loaded);
      expect(r.listQueries, [3]);
      expect(r.reads, hasLength(3));
      expect(r.s.freshAt, _t0.add(const Duration(seconds: 60)));
    });

    test('no ok answer at all -> freshAt null -> no cooldown', () async {
      await rig(3);
      await r.open();
      await r.respondAll(A.failed);
      expect(r.s.freshAt, isNull);
      r.reads.clear();
      final f = r.n.refresh();
      await settle();
      await r.respondAll(A.stats);
      expect(await f, RankingRefresh.loaded);
      expect(r.reads, hasLength(3));
    });
  });

  group('O11 — reads per scenario (fake counters; writes = 0 in every test)', () {
    test(
      '1: cold, list in memory, owner already read: 20 gets, 0 list, 0 count, 0 readOwn',
      () async {
        await rig(20);
        await r.open();
        await r.respondAll(A.stats);
        expect(r.reads, hasLength(20));
        expect(r.listQueries, isEmpty);
        expect(r.counts, isEmpty);
        expect(r.readOwn, 0);
      },
    );

    test('2/3: cold with the list cold: 20 gets + 1 list query (20 docs); the ranking itself '
        'never asks the aggregate or readOwn', () async {
      await rig(20, listInMemory: false);
      await r.open();
      await r.respondAll(A.stats);
      expect(r.reads, hasLength(20));
      expect(r.listQueries, [20]);
      expect(r.counts, isEmpty);
      expect(r.readOwn, 0);
    });

    test('4: reading the state again (filters live in the screen) = 0 reads', () async {
      await rig(20);
      await r.open();
      await r.respondAll(A.stats);
      final before = (r.reads.length, r.listQueries.length);
      for (var i = 0; i < 5; i++) {
        r.s;
        await settle();
      }
      expect((r.reads.length, r.listQueries.length), before);
    });

    test('5: reopen at 4:59 = 0; 6: at 5:00 = 20 + 1 list', () async {
      await rig(20, listInMemory: false);
      await r.open();
      await r.respondAll(A.stats);
      await r.leave();
      r.reads.clear();
      r.listQueries.clear();
      r.now = _t0.add(const Duration(minutes: 4, seconds: 59));
      await r.open();
      expect(r.reads, isEmpty);
      expect(r.listQueries, isEmpty);
      expect(r.s.phase, RankingPhase.content);
      await r.leave();
      r.now = _t0.add(const Duration(minutes: 5));
      await r.open();
      await r.respondAll(A.stats);
      expect(r.reads, hasLength(20));
      expect(r.listQueries, [20]);
    });

    test('7: reopen at 5:00 with the list re-read by Amigos at t0+3 min = 20, list 0', () async {
      await rig(20, listInMemory: false);
      await r.open();
      await r.respondAll(A.stats);
      await r.leave();
      r.now = _t0.add(const Duration(minutes: 3));
      await r.c.read(friendsControllerProvider.notifier).refresh();
      r.reads.clear();
      r.listQueries.clear();
      r.now = _t0.add(const Duration(minutes: 5));
      await r.open();
      await r.respondAll(A.stats);
      expect(r.reads, hasLength(20));
      expect(r.listQueries, isEmpty);
    });

    test('11: partial (2 timeouts) + "Tentar novamente" = 20 + 2 gets', () {
      fakeAsync((async) {
        r = Rig(n: 20);
        r.auth.add(_ana);
        async.flushMicrotasks();
        r.c.read(friendsControllerProvider.notifier).ensureLoaded();
        async.flushMicrotasks();
        r.c.listen(rankingControllerProvider, (_, _) {});
        async.flushMicrotasks();
        final slow = {r.pending[0].uid, r.pending[1].uid};
        void answerFast() {
          for (var guard = 0; guard < 100; guard++) {
            final open = [
              for (final p in r.pending)
                if (!p.k.isCompleted && !slow.contains(p.uid)) p,
            ];
            if (open.isEmpty) break;
            for (final p in open) {
              r._complete(p, A.stats);
            }
            async.flushMicrotasks();
          }
        }

        answerFast();
        async.elapse(const Duration(seconds: 8));
        expect(r.s.failed, slow);
        expect(r.started, 20);
        r.n.retry();
        async.flushMicrotasks();
        for (final p in r.pending.skip(20)) {
          r._complete(p, A.stats);
        }
        async.flushMicrotasks();
        expect(r.started, 22);
        expect(r.s.failed, isEmpty);
        expect(r.s.friends, hasLength(20));
      });
    });

    test('12: circuit breaker, N = 50 = 10 gets', () async {
      await rig(50);
      await r.open();
      await r.respondAll(A.failed);
      expect(r.reads, hasLength(10));
    });

    test('13: quota on the 3rd answer = 12 gets', () async {
      await rig(20);
      await r.open();
      await r.respondEach([A.stats, A.stats, A.quota]);
      await r.respondAll(A.stats);
      expect(r.reads, hasLength(12));
    });

    test('14-15: 1 or 5 denials = 20 gets + ONE aggregate', () async {
      for (final k in [1, 5]) {
        if (k == 5) {
          r.dispose();
        }
        await rig(20);
        await r.open();
        var denied = 0;
        while (r.open_.isNotEmpty) {
          await r.respond(denied++ < k ? A.denied : A.stats);
        }
        expect(r.reads, hasLength(20));
        expect(r.counts, hasLength(1), reason: '$k denials');
      }
    });

    test('16: the friend profile opened from the ranking within the TTL = 0 reads', () async {
      await rig(3);
      await r.open();
      await r.respondAll(A.stats);
      r.reads.clear();
      r.now = _t0.add(const Duration(minutes: 4, seconds: 59));
      final uid = Rig.uidOf(1);
      final sub = r.c.listen(friendProfileControllerProvider(uid), (_, _) {});
      await settle();
      expect(r.c.read(friendProfileControllerProvider(uid)).phase, FriendProfilePhase.content);
      expect(r.reads, isEmpty);
      sub.close();
    });

    test('17: 80 friends, list cold, signal confirmed = 50 gets + 1 list (51 docs)', () async {
      await rig(80, listInMemory: false);
      await r.open();
      await r.respondAll(A.stats);
      expect(r.reads, hasLength(50));
      expect(r.listQueries, [51]);
      expect(r.counts, isEmpty);
    });

    test('18: offline (open or reopen) = 0', () async {
      await rig(5);
      (r.c.read(syncStatusProvider.notifier) as _Sync).set(offline: true);
      await r.open();
      await r.leave();
      await r.open();
      expect(r.reads, isEmpty);
      expect(r.listQueries, isEmpty);
    });
  });
}
