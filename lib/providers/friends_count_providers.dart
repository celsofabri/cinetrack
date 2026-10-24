import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../social/social_models.dart';
import 'providers.dart';
import 'social_lists_providers.dart';
import 'social_providers.dart';
import 'sync_providers.dart';

/// The "tenho ≥ 1 amigo" signal of the ranking entry (docs/91 §8.1, O7):
/// ONE aggregate `count()` per session, a local hint (24 h TTL, per uid) so the
/// entry can show before the count answers, local ±1 adjustments from what
/// this device did, and a recount when a friendship may have ended elsewhere.
/// Never a listener.

/// How long the local "has friends" hint may stand in for the count.
const kFriendsHintTtl = Duration(hours: 24);

/// Asks the server how many friends this user has (one `count()`). Tests
/// inject their own (a `Completer` per call).
final friendsCountReaderProvider = Provider<Future<int> Function()>((ref) {
  return () => ref.read(socialRepositoryProvider).friendsCount();
});

/// What the social features need to know about the connection: `offline` (the
/// device is known to be without the server) and `fromCache` (the last answer
/// came from the device). Tests override it.
final socialConnectivityProvider = Provider<({bool offline, bool fromCache})>((ref) {
  final status = ref.watch(syncStatusProvider);
  return (offline: status.offline, fromCache: status.fromCache);
});

const _keep = Object();

class FriendsCountState {
  /// Number of friends (null = not known). A local adjustment may move it
  /// without a read.
  final int? count;

  /// [count] came from the server (aggregate or a complete first page) and
  /// only changed afterwards by certain local adjustments.
  final bool confirmed;

  /// A count is travelling.
  final bool inFlight;

  /// A local adjustment happened while [inFlight]: that answer is discarded.
  final bool dirty;

  /// The fresh local hint of this uid (null = none or older than 24 h).
  final bool? hint;

  const FriendsCountState({
    this.count,
    this.confirmed = false,
    this.inFlight = false,
    this.dirty = false,
    this.hint,
  });

  FriendsCountState copyWith({
    Object? count = _keep,
    bool? confirmed,
    bool? inFlight,
    bool? dirty,
    Object? hint = _keep,
  }) => FriendsCountState(
    count: identical(count, _keep) ? this.count : count as int?,
    confirmed: confirmed ?? this.confirmed,
    inFlight: inFlight ?? this.inFlight,
    dirty: dirty ?? this.dirty,
    hint: identical(hint, _keep) ? this.hint : hint as bool?,
  );

  @override
  String toString() => '{$count, $confirmed, $inFlight, $dirty, hint: $hint}';
}

class FriendsCountController extends Notifier<FriendsCountState> {
  int _generation = 0;

  /// The shell drew a frame in this app run (survives rebuilds: a new
  /// account or friendships turned on count once more).
  bool _shellSeen = false;

  /// Generation that already used its "first frame of the shell" trigger.
  int _triggered = -1;

  /// An [invalidate] arrived while a count travelled: ask again after it.
  bool _recountAfter = false;

  /// Friends this device added in this generation (dedupe: a crossed
  /// request + an accept of the same person count once).
  final Set<String> _addedHere = {};

  @override
  FriendsCountState build() {
    final generation = ++_generation;
    _recountAfter = false;
    _addedHere.clear();
    final uid = ref.watch(currentUidProvider);
    // Another account, friendships turned off / on: everything is forgotten
    // (same period as the lists and the profile cache).
    final active = ref.watch(socialPeriodProvider).$1;
    ref.listen(socialConnectivityProvider.select((c) => c.offline), (previous, offline) {
      // A real reconnection (offline -> online): one count if still unknown.
      if (previous == true && !offline) ensureConfirmed();
    });
    if (uid == null) return const FriendsCountState();
    if (active && _shellSeen) {
      _triggered = generation;
      Future.microtask(() {
        if (generation == _generation) ensureConfirmed();
      });
    }
    return FriendsCountState(hint: _freshHint(uid));
  }

  DateTime _now() => ref.read(socialClockProvider)();

  bool? _freshHint(String uid) {
    try {
      final hint = ref.read(localStoreProvider).friendsHint(uid);
      if (hint == null) return null;
      final age = _now().difference(hint.at);
      return !age.isNegative && age <= kFriendsHintTtl ? hint.has : null;
    } catch (_) {
      return null;
    }
  }

  /// Only with friendships CONFIRMED on: a session that runs on the local
  /// "friendships on" hint reads nothing until something confirms it
  /// (docs/59); meanwhile the "has friends" hint stands in.
  bool get _canCount =>
      ref.read(currentUidProvider) != null &&
      ref.read(socialControllerProvider).phase == SocialPhase.active;

  /// First frame of the shell (called after every navigation; only the
  /// first one of a generation counts).
  void onShellShown() {
    _shellSeen = true;
    if (_triggered == _generation) return;
    if (!_canCount) return;
    _triggered = _generation;
    ensureConfirmed();
  }

  /// The app came back to the front.
  void onResume() => ensureConfirmed();

  /// One count if the number is not confirmed and none is travelling.
  void ensureConfirmed() {
    if (!_canCount || state.confirmed || state.inFlight) return;
    _count();
  }

  Future<void> _count() async {
    final generation = _generation;
    final uid = ref.read(currentUidProvider);
    while (true) {
      _recountAfter = false;
      state = state.copyWith(inFlight: true, dirty: false);
      int? answer;
      try {
        answer = await ref.read(friendsCountReaderProvider)();
      } catch (_) {
        answer = null;
      }
      if (generation != _generation) return; // another account / period
      // Something changed while it travelled: that answer is old, ask again
      // (still "in flight": nothing blinks).
      if (_recountAfter && _canCount) continue;
      if (state.dirty) {
        state = state.copyWith(inFlight: false, dirty: false);
      } else if (answer != null) {
        state = state.copyWith(
          count: answer.clamp(0, kMaxFriends),
          confirmed: true,
          inFlight: false,
        );
        _saveHint(uid, generation, server: true);
      } else {
        // Offline / denied / quota: keep what is known; the next trigger
        // (reconnection, back to the front) asks again.
        state = state.copyWith(inFlight: false);
      }
      return;
    }
  }

  /// This device created a friendship with [uid] (accept, crossed request).
  /// Counted once per person, with the list loaded or not.
  void added(String uid) {
    final friends = ref.read(friendsControllerProvider);
    if (friends.phase == SentPhase.loaded && friends.items.any((f) => f.uid == uid)) return;
    if (!_addedHere.add(uid)) return;
    state = state.copyWith(
      count: math.min((state.count ?? 0) + 1, kMaxFriends),
      dirty: state.inFlight || state.dirty,
    );
    _saveHint(ref.read(currentUidProvider), _generation);
  }

  /// This device ended the friendship with [uid] (remove / block confirmed).
  void removed(String uid) {
    _addedHere.remove(uid);
    final current = state.count;
    if (current == null) {
      invalidate();
      return;
    }
    final next = current > 0 ? current - 1 : 0;
    state = state.copyWith(count: next, dirty: state.inFlight || state.dirty);
    if (!state.confirmed && next == 0) {
      // 0 that is not confirmed proves nothing: ask the server.
      invalidate();
      return;
    }
    _saveHint(ref.read(currentUidProvider), _generation);
  }

  /// The friends list was read from the SERVER (never from the device).
  void fromFirstPage(int shown, {required bool complete}) {
    if (complete) {
      state = state.copyWith(count: shown, confirmed: true, dirty: state.inFlight);
    } else {
      state = state.copyWith(count: math.max(state.count ?? 0, shown + 1));
    }
    _saveHint(ref.read(currentUidProvider), _generation, server: true);
  }

  /// The number may be wrong (a friendship may have ended elsewhere): one
  /// recount. Value and confirmation stay until the answer (no blinking).
  void invalidate() {
    if (!_canCount) return;
    if (state.inFlight) {
      _recountAfter = true;
      state = state.copyWith(dirty: true);
      return;
    }
    _count();
  }

  /// Remembers "has friends" for this uid when it is certain: any count
  /// above 0, or a confirmed 0. Only for the account and generation that
  /// produced it.
  void _saveHint(String? uid, int generation, {bool server = false}) {
    if (uid == null || generation != _generation || ref.read(currentUidProvider) != uid) return;
    final count = state.count;
    if (count == null || (count == 0 && !state.confirmed)) return;
    final has = count > 0;
    if (!server && state.hint == has) return;
    state = state.copyWith(hint: has);
    try {
      ref.read(localStoreProvider).setFriendsHint(uid, has, at: _now());
    } catch (_) {}
  }
}

final friendsCountControllerProvider = NotifierProvider<FriendsCountController, FriendsCountState>(
  FriendsCountController.new,
);
