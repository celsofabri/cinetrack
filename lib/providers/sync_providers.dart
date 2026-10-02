import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_repository.dart';
import '../data/sync_status.dart';
import 'providers.dart';

/// How long the first server answer may take before an empty cache stops
/// being trusted as "no favorites" (and offline is announced). Overridden in
/// tests.
final syncGraceProvider = Provider<Duration>((ref) => const Duration(seconds: 5));

/// How long local writes may stay unacknowledged while connected before the
/// user is told. Overridden in tests (zero = disabled).
final syncStallProvider = Provider<Duration>((ref) => const Duration(seconds: 30));

/// Synchronization state of the signed-in account: pending writes, offline,
/// rejected writes (rules/quota), expired session. Rebuilt (reset) when the
/// account changes or on [retrySync].
class SyncStatusNotifier extends Notifier<SyncStatus> {
  /// Generation of the current `build()`. Every closure of a build captures
  /// its own number and drops its result when the number moved on (account
  /// switch, retry, dispose), so work still in flight for account A can never
  /// write into the state of account B (a single `_disposed` field would be
  /// reset by the next `build()`).
  int _generation = 0;

  @override
  SyncStatus build() {
    final generation = ++_generation;
    bool current() => generation == _generation;

    final uid = ref.watch(currentUidProvider);
    if (uid == null) return SyncStatus.signedOut;

    final source = ref.watch(favoritesDataSourceProvider);
    final sink = ref.watch(syncFailureSinkProvider);
    final grace = ref.watch(syncGraceProvider);
    final stall = ref.watch(syncStallProvider);

    // Armed while connected (not from cache) with unacknowledged writes.
    Timer? stallTimer;
    final metaSub = source.watchSyncMeta().listen((meta) {
      if (!current()) return;
      final waiting = meta.hasPendingWrites && !meta.fromCache;
      if (!waiting) {
        stallTimer?.cancel();
        stallTimer = null;
      } else if (stallTimer == null && stall != Duration.zero) {
        stallTimer = Timer(stall, () {
          if (current()) state = state.copyWith(pendingStalled: true);
        });
      }
      state = state.copyWith(
        fromCache: meta.fromCache,
        hasPendingWrites: meta.hasPendingWrites,
        serverConfirmed: state.serverConfirmed || !meta.fromCache,
        pendingStalled: waiting ? null : false,
      );
    }, onError: (_) {});
    final failureSub = sink.stream.listen((failure) => _onFailure(failure, uid, current));
    // A failure reported before this notifier existed (or while it was being
    // rebuilt) is still waiting in the sink: pick it up.
    final earlier = sink.unacknowledged;
    if (earlier != null) {
      scheduleMicrotask(() => _onFailure(earlier, uid, current));
    }
    final timer = grace == Duration.zero
        ? null
        : Timer(grace, () {
            if (current()) state = state.copyWith(graceOver: true);
          });
    ref.onDispose(() {
      // Invalidates every closure of this build, even if a new build starts.
      if (current()) _generation++;
      metaSub.cancel();
      failureSub.cancel();
      timer?.cancel();
      stallTimer?.cancel();
    });
    return SyncStatus(graceOver: grace == Duration.zero);
  }

  Future<void> _onFailure(SyncFailure failure, String uid, bool Function() current) async {
    var effective = failure;
    if (failure.kind == SyncFailureKind.permissionDenied) {
      // "Permission denied" is either the rules refusing this write or a
      // dead session; only the provider can tell which. The check is tied to
      // the account that owns the failure, not to whoever is signed in now.
      final check = await ref.read(authRepositoryProvider).verifySession(expectedUid: uid);
      if (check == SessionCheck.expired) {
        effective = SyncFailure(SyncFailureKind.sessionExpired, code: failure.code);
      }
    }
    if (!current()) return;
    state = state.copyWith(failure: effective);
  }

  /// The user acknowledged the failure banner.
  void dismissFailure() {
    ref.read(syncFailureSinkProvider).acknowledge();
    state = state.copyWith(clearFailure: true);
  }
}

final syncStatusProvider = NotifierProvider<SyncStatusNotifier, SyncStatus>(SyncStatusNotifier.new);

/// Re-subscribes to the user's data (new listeners, fresh sync status).
/// Pending local writes are untouched: they live in the local database.
void retrySync(WidgetRef ref) => ref.invalidate(favoritesDataSourceProvider);

/// What the favorites list should render, so "could not load" is never shown
/// as "you have no favorites".
enum FavoritesGate {
  /// Safe to render the list or its empty state.
  ready,

  /// Empty so far and the server has not answered yet.
  loading,

  /// Empty, unconfirmed by the server and the grace period is over.
  unconfirmed,
}

final favoritesGateProvider = Provider<FavoritesGate>((ref) {
  final status = ref.watch(syncStatusProvider);
  if (!status.signedIn || status.serverConfirmed) return FavoritesGate.ready;
  final favorites = ref.watch(favoritesListProvider).valueOrNull;
  if (favorites != null && favorites.isNotEmpty) return FavoritesGate.ready;
  return status.graceOver ? FavoritesGate.unconfirmed : FavoritesGate.loading;
});
