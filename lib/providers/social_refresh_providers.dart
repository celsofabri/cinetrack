import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../social/social_models.dart';
import 'providers.dart';
import 'social_providers.dart';
import 'sync_providers.dart';

enum SocialRefreshPhase { idle, running, failed }

class SocialRefreshState {
  final SocialRefreshPhase phase;

  /// Why the last run stopped (phase [SocialRefreshPhase.failed]).
  final SocialFailure? failure;

  const SocialRefreshState({this.phase = SocialRefreshPhase.idle, this.failure});

  bool get running => phase == SocialRefreshPhase.running;
}

/// Keeps the copies of this user's nickname / photo in the friendships fresh
/// (D8, docs/68): after the card changes, [request] writes this user's half of
/// every pair, in the background, nobody is told.
///
/// - **Resumable**: [request] saves a flag per uid on the device BEFORE
///   anything runs; it is cleared only when a run finishes (and no newer
///   request arrived). A failed or interrupted run leaves it set and the next
///   social load ([resumeIfPending]) or [retry] continues. Repeating is safe:
///   a run writes the card as it is NOW and skips pairs already up to date.
/// - **Coalesced**: requests during a run do not start another one; the run
///   goes once more at the end, so changing the nickname five times in a row
///   costs one pass (plus at most one more), never five.
/// - **Account safe**: everything is tied to the uid and to the "friendships
///   on" period (like the lists); a run for another account or before a
///   deactivation stops at its next step and touches nothing.
class SocialRefreshController extends Notifier<SocialRefreshState> {
  int _generation = 0;
  bool _running = false;
  bool _again = false;

  @override
  SocialRefreshState build() {
    _generation++;
    _running = false;
    _again = false;
    ref.watch(currentUidProvider);
    ref.watch(socialPeriodProvider);
    return const SocialRefreshState();
  }

  bool _flag(String uid) {
    try {
      return ref.read(localStoreProvider).socialRefreshPending(uid);
    } catch (_) {
      return false;
    }
  }

  Future<void> _setFlag(String uid, bool pending) async {
    try {
      await ref.read(localStoreProvider).setSocialRefreshPending(uid, pending);
    } catch (_) {}
  }

  /// The card changed: refresh the friendships (starts now, or at the end of
  /// the run that is going).
  Future<void> request() async {
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    await _setFlag(uid, true);
    _kick();
  }

  /// Continues a refresh that did not finish (called after each server read of
  /// the social state). Nothing happens when nothing is pending.
  void resumeIfPending() {
    final uid = ref.read(currentUidProvider);
    if (uid == null || _running || !_flag(uid)) return;
    _kick();
  }

  /// "Tentar de novo" after a failure.
  void retry() => _kick();

  /// Stops the run at its next step but KEEPS the flag (used before a deactivation whose
  /// outcome is not known yet: if it fails, [resumeIfPending] continues).
  void cancelRun() {
    _generation++;
    _running = false;
    _again = false;
    state = const SocialRefreshState();
  }

  /// Friendships were turned off (or the account is being deleted): nothing
  /// left to refresh. Stops the run at its next step and forgets the flag.
  Future<void> cancelAndClear() async {
    final uid = ref.read(currentUidProvider);
    cancelRun();
    if (uid != null) await _setFlag(uid, false);
  }

  void _kick() {
    if (ref.read(currentUidProvider) == null) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    _run();
  }

  Future<void> _run() async {
    final generation = _generation;
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    bool cancelled() => generation != _generation;
    if (ref.read(syncStatusProvider).offline) {
      _running = false;
      state = const SocialRefreshState(
        phase: SocialRefreshPhase.failed,
        failure: SocialFailure(SocialFailureKind.offline, code: 'offline'),
      );
      return;
    }
    state = const SocialRefreshState(phase: SocialRefreshPhase.running);
    final repository = ref.read(socialRepositoryProvider);
    try {
      while (true) {
        _again = false;
        await repository.refreshFriendHalves(cancelled: cancelled);
        if (cancelled()) return;
        if (_again) continue;
        await _setFlag(uid, false);
        if (cancelled()) return;
        if (_again) {
          // A request arrived while the flag was being cleared.
          await _setFlag(uid, true);
          continue;
        }
        _running = false;
        state = const SocialRefreshState();
        return;
      }
    } on SocialFailure catch (e) {
      if (cancelled()) return;
      _running = false;
      state = SocialRefreshState(phase: SocialRefreshPhase.failed, failure: e);
    } catch (_) {
      if (cancelled()) return;
      _running = false;
      state = const SocialRefreshState(
        phase: SocialRefreshPhase.failed,
        failure: SocialFailure(SocialFailureKind.unknown),
      );
    }
  }
}

final socialRefreshProvider = NotifierProvider<SocialRefreshController, SocialRefreshState>(
  SocialRefreshController.new,
);
