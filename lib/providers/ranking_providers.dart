import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/shared_profile_repository.dart';
import '../shared_profile/shared_profile_doc.dart';
import '../shared_profile/shared_profile_models.dart';
import '../shared_profile/shared_stats_reading.dart';
import '../social/social_models.dart';
import 'friend_profile_providers.dart';
import 'friends_count_providers.dart';
import 'providers.dart';
import 'shared_profile_providers.dart';
import 'sharing_providers.dart';
import 'social_lists_providers.dart';
import 'social_providers.dart';

/// Ranking among friends, data side (docs/91 §4, §8.2, §10; Fatia 2). No UI:
/// the screen (Fatia 3) combines [RankingState] with the pure ranking of
/// Fatia 1 (`lib/ranking/`), so this file only hands over raw snapshots.

// ---------------------------------------------------------------------------
// Access (O8)

enum RankingAccess {
  /// Not known yet: no redirect (skeleton), entry hidden.
  pending,

  /// Entry visible, `/ranking` allowed.
  allowed,

  /// Signed out: `/ranking` goes to `/`.
  noSession,

  /// Not Google / friendships off / rules not published: goes to `/friends`.
  inactive,

  /// Confirmed 0 friends: goes to `/friends`.
  noFriends,
}

/// Who may open the ranking (docs/91 O8; the first true row wins). Pure:
/// the router adds it to its `refreshListenable` and the 4 entries watch it.
final rankingAccessProvider = Provider<RankingAccess>((ref) {
  final auth = ref.watch(authStateProvider);
  if (auth.isLoading && !auth.hasValue) return RankingAccess.pending;
  final user = auth.valueOrNull;
  if (user == null) return RankingAccess.noSession;
  if (!user.isGoogle) return RankingAccess.inactive;
  final phase = ref.watch(socialControllerProvider.select((s) => s.phase));
  switch (phase) {
    case SocialPhase.signedOut:
      return RankingAccess.noSession;
    case SocialPhase.notGoogle:
    case SocialPhase.inactive:
    case SocialPhase.unavailable:
      return RankingAccess.inactive;
    case SocialPhase.loadFailed:
      return RankingAccess.pending;
    case SocialPhase.loading:
    case SocialPhase.active:
      break;
  }
  final signal = ref.watch(friendsCountControllerProvider);
  final hinted = signal.hint == true;
  if (phase == SocialPhase.loading && !hinted) return RankingAccess.pending;
  final count = signal.count;
  if (count != null && count > 0) return RankingAccess.allowed;
  if (count == 0 && signal.confirmed) return RankingAccess.noFriends;
  if (count == null && hinted) return RankingAccess.allowed;
  return RankingAccess.pending;
});

// ---------------------------------------------------------------------------
// Seams

/// Most friends considered by one load (D5): `FriendsController.state.items.take(50)`.
const kRankingMaxFriends = 50;

/// Reads in flight at once (sliding window, §10.3).
const kRankingWindow = 10;

/// Longest wait for one friend's snapshot; a later answer is ignored.
final rankingReadTimeoutProvider = Provider<Duration>((ref) => const Duration(seconds: 8));

/// "Atualizar" of the ranking within this time of [RankingState.freshAt] does
/// nothing (N1). The friends list keeps its own 15 s.
final rankingCooldownProvider = Provider<Duration>((ref) => const Duration(seconds: 60));

/// One friend's snapshot from the SERVER (null = the document does not exist).
/// Throws [SharedProfileFailure]. Tests inject their own.
final rankingFriendReaderProvider = Provider<Future<FriendSharedView?> Function(String uid)>((ref) {
  return (uid) => ref.read(sharedProfileRepositoryProvider).readFriend(uid);
});

/// The owner's side of the ranking: whether "I" take part ([sharing], null =
/// not confirmed yet: D9 waits) and the document that gives my row (0 reads).
class RankingMe {
  final bool? sharing;

  /// Only when [sharing] is true.
  final SharedProfileDoc? doc;

  const RankingMe({this.sharing, this.doc});

  @override
  bool operator ==(Object other) =>
      other is RankingMe && other.sharing == sharing && identical(other.doc, doc);

  @override
  int get hashCode => Object.hash(sharing, identityHashCode(doc));
}

/// How "I share my statistics" is decided, injected here so the ranking does
/// not depend on it (the single "Aparecer na busca" switch of docs/95 may
/// change the rule): today, the confirmed own document with the `stats`
/// consent and section (docs/91 §10.6).
final rankingMeProvider = Provider<RankingMe>((ref) {
  final sharing = ref.watch(sharingControllerProvider);
  if (!sharing.confirmed) return const RankingMe();
  final doc = sharing.doc;
  final shares = doc != null && doc.sharing.contains(SharedSection.stats) && doc.stats != null;
  return shares ? RankingMe(sharing: true, doc: doc) : const RankingMe(sharing: false);
});

/// Whether a friend's answer takes part (has statistics), injected for the
/// same reason as [rankingMeProvider]. Default: the `stats` section is a map.
final rankingFriendSharesProvider = Provider<bool Function(FriendSharedView? view)>((ref) {
  return (view) => view?.stats != null;
});

// ---------------------------------------------------------------------------
// State

enum RankingPhase { loading, content, offline, error, quota, sessionExpired }

/// What "Atualizar" did.
enum RankingRefresh {
  /// A load ran.
  loaded,

  /// Within the cooldown: nothing (the screen says "A lista já está atualizada…").
  cooldown,

  /// A load was already running: it joined it.
  joined,
}

/// One friend that takes part: their card and the snapshot read at [at]
/// (Fatia 3 turns it into a `RankingParticipant` with Fatia 1's reader).
class RankingFriend {
  final Friend friend;
  final FriendSharedView view;
  final DateTime at;

  const RankingFriend({required this.friend, required this.view, required this.at});
}

const _keep = Object();

class RankingState {
  final RankingPhase phase;

  /// Friends with statistics, in the order they were considered.
  final List<RankingFriend> friends;

  /// My document when I take part (from [RankingMe], 0 reads).
  final SharedProfileDoc? me;

  /// Null = not confirmed yet (band D9, summary and RF-E8/E9 wait).
  final bool? meSharing;

  /// Ok answers without statistics (D10 footer): not-found, no `stats`,
  /// `stats` not a map. Never failures, denials or friends beyond 50.
  final int notSharing;

  /// Friends whose read failed (unavailable / timeout / unknown / not
  /// started because of the circuit breaker; D13).
  final Set<String> failed;

  /// 50 when more friends exist than were considered (RF-R12).
  final int? limitedTo;

  /// The confirmed number of friends (null = not confirmed: text without N).
  final int? totalFriends;

  /// Oldest server read among ALL ok answers of the considered friends (with
  /// or without stats, from the server or the memory cache; O10).
  final DateTime? freshAt;

  /// A load runs with the previous ranking still on screen.
  final bool refreshing;

  /// Every considered friend was denied: skeleton until the recount answers.
  final bool awaitingRecount;

  const RankingState({
    this.phase = RankingPhase.loading,
    this.friends = const [],
    this.me,
    this.meSharing,
    this.notSharing = 0,
    this.failed = const {},
    this.limitedTo,
    this.totalFriends,
    this.freshAt,
    this.refreshing = false,
    this.awaitingRecount = false,
  });

  /// Rows (mine included) are shown only with content (O9: "nenhuma, nem a minha").
  bool get showsRows => phase == RankingPhase.content;

  RankingState copyWith({
    RankingPhase? phase,
    List<RankingFriend>? friends,
    Object? me = _keep,
    Object? meSharing = _keep,
    int? notSharing,
    Set<String>? failed,
    bool? refreshing,
    bool? awaitingRecount,
  }) => RankingState(
    phase: phase ?? this.phase,
    friends: friends ?? this.friends,
    me: identical(me, _keep) ? this.me : me as SharedProfileDoc?,
    meSharing: identical(meSharing, _keep) ? this.meSharing : meSharing as bool?,
    notSharing: notSharing ?? this.notSharing,
    failed: failed ?? this.failed,
    limitedTo: limitedTo,
    totalFriends: totalFriends,
    freshAt: freshAt,
    refreshing: refreshing ?? this.refreshing,
    awaitingRecount: awaitingRecount ?? this.awaitingRecount,
  );
}

// ---------------------------------------------------------------------------
// Controller

enum _Outcome { ok, denied, failed, quota, unauthenticated }

_Outcome _classify(Object error) {
  if (error is SharedProfileFailure) {
    return switch (error.kind) {
      SharedProfileFailureKind.denied => _Outcome.denied,
      SharedProfileFailureKind.quota => _Outcome.quota,
      SharedProfileFailureKind.sessionExpired => _Outcome.unauthenticated,
      _ => _Outcome.failed,
    };
  }
  return _Outcome.failed; // timeout, unknown
}

RankingPhase _phaseForList(SocialFailure? failure) => switch (failure?.kind) {
  SocialFailureKind.quotaExceeded => RankingPhase.quota,
  SocialFailureKind.sessionExpired => RankingPhase.sessionExpired,
  SocialFailureKind.offline => RankingPhase.offline,
  _ => RankingPhase.error,
};

/// One load: stopped by a terminal answer, the connection dropping or a new
/// generation; every answer that arrives after that is discarded.
class _Run {
  bool stopped = false;

  /// Stopped because the connection dropped.
  bool dropped = false;
  final Completer<void> done = Completer<void>();

  void stop() {
    stopped = true;
    if (!done.isCompleted) done.complete();
  }
}

/// Loads the ranking (docs/91 §10): the 50 first friends of the list in
/// memory, each snapshot from the shared memory cache (TTL 5 min) or ONE
/// server `get`, at most 10 in flight, with a circuit breaker; zero writes.
class RankingController extends AutoDisposeNotifier<RankingState> {
  int _generation = 0;
  Future<void>? _inFlight;
  _Run? _run;

  /// Friends of the last load (after denials), in list order.
  List<Friend> _considered = const [];

  /// Ok answers of [_considered] (server or cache), by uid.
  final Map<String, FriendProfileEntry> _results = {};
  int? _limitedTo;

  @override
  RankingState build() {
    final generation = ++_generation;
    _inFlight = null;
    _run = null;
    _considered = const [];
    _results.clear();
    _limitedTo = null;
    ref.watch(currentUidProvider);
    ref.watch(socialPeriodProvider);
    ref.onDispose(() {
      // Leaving the screen / another account: nothing late writes anything.
      _generation++;
      _run?.stop();
    });
    ref.listen(rankingMeProvider, (_, me) {
      // My row follows the owner's document at once (toggles), no read.
      state = state.copyWith(me: me.doc, meSharing: me.sharing);
    });
    ref.listen(socialConnectivityProvider.select((c) => c.offline), (previous, offline) {
      if (offline) {
        // D10: the connection dropped; reads in flight are discarded and
        // nothing of the friends stays on screen.
        final run = _run;
        if (run != null && !run.stopped) {
          run.dropped = true;
          run.stop();
        }
        state = _bare(RankingPhase.offline);
      } else if (previous == true && state.phase == RankingPhase.offline) {
        _start(force: false);
      }
    });
    ref.listen(friendsCountControllerProvider, (previous, next) {
      if (!state.awaitingRecount || previous == null) return;
      if (!previous.inFlight || next.inFlight) return;
      // The recount answered: 0 = the router leaves; otherwise load again.
      if ((next.count ?? 1) > 0) {
        state = state.copyWith(awaitingRecount: false);
        _start(force: false);
      }
    });
    Future.microtask(() {
      if (generation == _generation) _start(force: false);
    });
    final me = ref.read(rankingMeProvider);
    return RankingState(me: me.doc, meSharing: me.sharing);
  }

  DateTime _now() => ref.read(sharedProfileClockProvider)();

  RankingState _bare(RankingPhase phase) {
    final me = ref.read(rankingMeProvider);
    return RankingState(phase: phase, me: me.doc, meSharing: me.sharing);
  }

  /// "Atualizar": within the cooldown nothing; a load already running is
  /// joined; otherwise the list ("Atualizar" of its own, 15 s) and every
  /// considered friend from the server.
  Future<RankingRefresh> refresh() async {
    final running = _inFlight;
    if (running != null) {
      await running;
      return RankingRefresh.joined;
    }
    final at = state.freshAt;
    if (at != null && _now().difference(at) < ref.read(rankingCooldownProvider)) {
      return RankingRefresh.cooldown;
    }
    await _start(force: true, refreshList: true);
    return RankingRefresh.loaded;
  }

  /// "Tentar novamente" (never with the cooldown): after a partial failure,
  /// only the friends that failed; after an error / quota / session, a full
  /// load (fresh cache entries still count).
  Future<void> retry() {
    final running = _inFlight;
    if (running != null) return running;
    if (state.phase == RankingPhase.content && state.failed.isNotEmpty) {
      return _start(force: true, only: state.failed);
    }
    return _start(force: false);
  }

  /// One load at a time: a second request joins the one running.
  Future<void> _start({required bool force, bool refreshList = false, Set<String>? only}) {
    final running = _inFlight;
    if (running != null) return running;
    final generation = _generation;
    final run = _load(generation, force: force, refreshList: refreshList, only: only);
    _inFlight = run;
    return run.whenComplete(() {
      if (generation == _generation) _inFlight = null;
    });
  }

  Future<void> _load(
    int generation, {
    required bool force,
    required bool refreshList,
    Set<String>? only,
  }) async {
    if (ref.read(currentUidProvider) == null) return;
    final run = _Run();
    _run = run;
    bool gone() => generation != _generation || run.stopped;

    final connection = ref.read(socialConnectivityProvider);
    if (connection.offline) {
      state = _bare(RankingPhase.offline);
      return;
    }
    state = state.phase == RankingPhase.content
        ? state.copyWith(refreshing: true)
        : _bare(RankingPhase.loading);

    final friends = ref.read(friendsControllerProvider.notifier);
    var considered = _considered;
    if (only == null) {
      if (refreshList) {
        await friends.refresh();
      } else {
        await friends.ensureLoaded();
      }
      if (gone()) return;
      final list = ref.read(friendsControllerProvider);
      if (list.phase != SentPhase.loaded) {
        state = _bare(_phaseForList(list.failure));
        return;
      }
      // A list served by the device means no server: offline (D10).
      if (list.fromCache) {
        state = _bare(RankingPhase.offline);
        return;
      }
      considered = list.items.take(kRankingMaxFriends).toList();
      _limitedTo = list.items.length > kRankingMaxFriends || list.hasMore
          ? kRankingMaxFriends
          : null;
      _results.clear();
    }

    final cache = ref.read(friendProfileCacheProvider);
    final ttl = ref.read(friendProfileTtlProvider);
    final now = _now();
    final failed = <String>{};
    final queue = <Friend>[];
    for (final f in considered) {
      if (only != null && !only.contains(f.uid)) continue;
      final entry = !force && !connection.fromCache ? cache.fresh(f.uid, now, ttl) : null;
      if (entry != null) {
        _results[f.uid] = entry;
      } else {
        queue.add(f);
      }
    }

    // Sliding window of 10 with the circuit breaker (§10.3): before the first
    // ok/denied answer the window does not slide (10 reads at most); 10
    // failures first = stop. Afterwards started = min(N, 10 + R).
    final reader = ref.read(rankingFriendReaderProvider);
    final timeout = ref.read(rankingReadTimeoutProvider);
    final denied = <String>{};
    var budget = kRankingWindow;
    var slid = false;
    var failuresFirst = 0;
    var inFlight = 0;
    RankingPhase? terminal;

    void finishIfIdle() {
      if (inFlight == 0 && queue.isEmpty) run.stop();
    }

    late final void Function() pump;

    void arrived(Friend f, _Outcome outcome, FriendSharedView? view) {
      if (gone()) return; // stopped or another generation: discarded
      inFlight--;
      switch (outcome) {
        case _Outcome.quota:
        case _Outcome.unauthenticated:
          terminal = outcome == _Outcome.quota ? RankingPhase.quota : RankingPhase.sessionExpired;
          run.stop();
          return;
        case _Outcome.ok:
          final entry = FriendProfileEntry(friend: f, view: view, at: _now());
          cache.put(f.uid, entry);
          _results[f.uid] = entry;
        case _Outcome.denied:
          // Not a friend any more: gone from the screen, the cache and the
          // list at once; one recount at the end of the load.
          cache.remove(f.uid);
          friends.dropLocal(f.uid);
          _results.remove(f.uid);
          denied.add(f.uid);
        case _Outcome.failed:
          failed.add(f.uid);
      }
      if (outcome != _Outcome.failed) slid = true;
      if (slid) {
        budget++;
      } else if (++failuresFirst == kRankingWindow && queue.isNotEmpty) {
        // Circuit breaker: nothing new starts, the rest is "failed".
        failed.addAll(queue.map((q) => q.uid));
        queue.clear();
      }
      pump();
      finishIfIdle();
    }

    var started = 0;
    pump = () {
      while (!gone() && queue.isNotEmpty && started < budget) {
        final f = queue.removeAt(0);
        started++;
        inFlight++;
        Future.sync(() => reader(f.uid))
            .timeout(timeout)
            .then(
              (view) => arrived(f, _Outcome.ok, view),
              onError: (Object e) => arrived(f, _classify(e), null),
            );
      }
    };

    pump();
    finishIfIdle();
    await run.done.future;
    if (generation != _generation) return;
    if (denied.isNotEmpty) ref.read(friendsCountControllerProvider.notifier).invalidate();
    if (terminal != null) {
      state = _bare(terminal!);
      return;
    }
    if (run.dropped) {
      // The connection dropped while the answers travelled.
      state = _bare(RankingPhase.offline);
      return;
    }

    _considered = [
      for (final f in considered)
        if (!denied.contains(f.uid)) f,
    ];
    final keepFailed = only == null ? <String>{} : ({...state.failed}..removeAll(only));
    final allFailed = {...keepFailed, ...failed}..removeAll(denied);
    if (considered.isNotEmpty && _considered.isEmpty) {
      state = _bare(RankingPhase.loading).copyWith(awaitingRecount: true);
      return;
    }
    if (_results.isEmpty && allFailed.isNotEmpty) {
      state = _bare(RankingPhase.error).copyWith(failed: allFailed);
      return;
    }
    state = _compose(allFailed);
  }

  RankingState _compose(Set<String> failed) {
    final shares = ref.read(rankingFriendSharesProvider);
    final me = ref.read(rankingMeProvider);
    final signal = ref.read(friendsCountControllerProvider);
    final rows = <RankingFriend>[];
    var notSharing = 0;
    DateTime? freshAt;
    for (final f in _considered) {
      final entry = _results[f.uid];
      if (entry == null) continue;
      if (freshAt == null || entry.at.isBefore(freshAt)) freshAt = entry.at;
      final view = entry.view;
      if (view != null && shares(view)) {
        rows.add(RankingFriend(friend: f, view: view, at: entry.at));
      } else {
        notSharing++;
      }
    }
    return RankingState(
      phase: RankingPhase.content,
      friends: rows,
      me: me.doc,
      meSharing: me.sharing,
      notSharing: notSharing,
      failed: failed,
      limitedTo: _limitedTo,
      totalFriends: signal.confirmed ? signal.count : null,
      freshAt: freshAt,
    );
  }
}

final rankingControllerProvider = NotifierProvider.autoDispose<RankingController, RankingState>(
  RankingController.new,
);
