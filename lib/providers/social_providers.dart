import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/firestore_social_data_source.dart';
import '../data/social_data_source.dart';
import '../repositories/social_repository.dart';
import '../social/social_models.dart';
import '../social/social_validation.dart';
import 'account_providers.dart';
import 'providers.dart';

typedef SocialDataSourceFactory = SocialDataSource Function(String uid);

/// Builds the social data source for a uid. Overridden in tests with fakes.
final socialDataSourceFactoryProvider = Provider<SocialDataSourceFactory>(
  (ref) =>
      (uid) => FirestoreSocialDataSource(uid: uid),
);

/// Depends on the uid, so it is recreated when the account changes; signed
/// out = inert.
final socialDataSourceProvider = Provider<SocialDataSource>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return const SignedOutSocialDataSource();
  return ref.watch(socialDataSourceFactoryProvider)(uid);
});

final socialRepositoryProvider = Provider<SocialRepository>(
  (ref) => SocialRepository(ref.watch(socialDataSourceProvider)),
);

enum SocialPhase {
  loading,

  /// Friendships are off (the default).
  inactive,
  active,

  /// The rules that allow the feature are not published yet.
  unavailable,

  /// Could not read the state (offline with nothing on the device, ...).
  loadFailed,

  /// Signed in with something other than Google.
  notGoogle,
  signedOut,
}

class SocialState {
  final SocialPhase phase;
  final SocialProfile? profile;

  /// The state shown came from this device, not from the server.
  final bool fromCache;

  /// An action is running (buttons are disabled).
  final bool busy;

  /// Why the last load failed (phase [SocialPhase.loadFailed]).
  final SocialFailure? failure;

  /// Friendships are off but the last cleanup sweep did not finish: the
  /// section offers "Concluir limpeza".
  final bool cleanupPending;

  const SocialState({
    this.phase = SocialPhase.loading,
    this.profile,
    this.fromCache = false,
    this.busy = false,
    this.failure,
    this.cleanupPending = false,
  });

  SocialState copyWith({bool? busy}) => SocialState(
    phase: phase,
    profile: profile,
    fromCache: fromCache,
    busy: busy ?? this.busy,
    failure: failure,
    cleanupPending: cleanupPending,
  );
}

/// State of the "Amizades" section of the profile. Reads the state once per
/// session (and on demand); every action is confirmed by the server and is
/// followed by a fresh read. Nothing is written for an account that did not
/// turn friendships on.
class SocialController extends Notifier<SocialState> {
  /// Bumped on every `build()`: an operation that started for another account
  /// (or before a reset) must not touch the current state.
  int _generation = 0;

  @override
  SocialState build() {
    final generation = ++_generation;
    final user = ref.watch(currentUserProvider.select((u) => (u?.uid, u?.isGoogle)));
    if (user.$1 == null) return const SocialState(phase: SocialPhase.signedOut);
    if (user.$2 != true) return const SocialState(phase: SocialPhase.notGoogle);
    Future.microtask(() {
      if (generation == _generation) _load(generation);
    });
    return const SocialState();
  }

  /// Reads the state again (server first, then the device).
  Future<void> refresh() async {
    if (state.phase == SocialPhase.signedOut || state.phase == SocialPhase.notGoogle) return;
    state = const SocialState();
    await _load(_generation);
  }

  Future<void> _load(int generation, {bool keepOnFailure = false}) async {
    SocialState next;
    try {
      final load = await ref.read(socialRepositoryProvider).load();
      next = SocialState(
        phase: load.profile == null ? SocialPhase.inactive : SocialPhase.active,
        profile: load.profile,
        fromCache: load.fromCache,
        cleanupPending: load.profile == null && _cleanupFlag(),
      );
    } on SocialFailure catch (e) {
      if (keepOnFailure) return;
      next = SocialState(
        phase: e.kind == SocialFailureKind.denied
            ? SocialPhase.unavailable
            : SocialPhase.loadFailed,
        failure: e,
      );
    } catch (_) {
      if (keepOnFailure) return;
      next = const SocialState(
        phase: SocialPhase.loadFailed,
        failure: SocialFailure(SocialFailureKind.unknown),
      );
    }
    if (generation == _generation) state = next;
  }

  /// Turns friendships on. Returns the failure to show, or null on success.
  Future<SocialFailure?> activate({
    required String handle,
    required String nickname,
    required bool showPhoto,
    required bool discoverable,
  }) {
    final user = ref.read(currentUserProvider);
    return _run(() async {
      await ref
          .read(socialRepositoryProvider)
          .activate(
            rawHandle: handle,
            rawNickname: nickname,
            googlePhotoUrl: user?.photoUrl,
            showPhoto: showPhoto,
            discoverable: discoverable,
          );
      await _syncAppNickname(nickname);
    });
  }

  Future<SocialFailure?> changeHandle(String handle) {
    final current = state.profile;
    if (current == null) return Future.value(const SocialFailure(SocialFailureKind.notActive));
    return _run(() => ref.read(socialRepositoryProvider).changeHandle(handle, current: current));
  }

  Future<SocialFailure?> updateNickname(String nickname) => _run(() async {
    await ref.read(socialRepositoryProvider).updateNickname(nickname);
    await _syncAppNickname(nickname);
  });

  Future<SocialFailure?> setDiscoverable(bool value) =>
      _run(() => ref.read(socialRepositoryProvider).setDiscoverable(value));

  Future<SocialFailure?> setPhotoVisible(bool visible) {
    final photo = ref.read(currentUserProvider)?.photoUrl;
    return _run(
      () => ref.read(socialRepositoryProvider).setPhotoVisible(visible, googlePhotoUrl: photo),
    );
  }

  /// Turns friendships off and deletes friends, requests, blocks and invite.
  Future<SocialFailure?> deactivate() async {
    final failure = await _run(() => ref.read(socialRepositoryProvider).deactivate());
    if (failure == null) await _setCleanupFlag(false);
    if (failure?.code == SocialRepository.cleanupPendingCode) {
      await _setCleanupFlag(true);
      await _load(_generation, keepOnFailure: true);
    }
    return failure;
  }

  bool _cleanupFlag() {
    final uid = ref.read(currentUidProvider);
    if (uid == null) return false;
    try {
      return ref.read(localStoreProvider).socialCleanupPending(uid);
    } catch (_) {
      return false;
    }
  }

  Future<void> _setCleanupFlag(bool pending) async {
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    try {
      await ref.read(localStoreProvider).setSocialCleanupPending(uid, pending);
    } catch (_) {}
  }

  /// Finishes a deactivation whose last sweep failed.
  Future<SocialFailure?> finishCleanup() async {
    final failure = await _run(() => ref.read(socialRepositoryProvider).finishCleanup());
    if (failure == null) {
      await _setCleanupFlag(false);
      await _load(_generation, keepOnFailure: true);
    }
    return failure;
  }

  /// The card's nickname comes from `users/{uid}.displayName` (the source of
  /// truth): keep it in step. Not awaited by the server (works offline).
  Future<void> _syncAppNickname(String raw) async {
    final value = SocialNickname.normalize(raw);
    if (value == null) return;
    final current = ref.read(profileProvider).valueOrNull?.nickname;
    if (current != value) await ref.read(profileDataSourceProvider).setNickname(value);
  }

  Future<SocialFailure?> _run(Future<void> Function() action) async {
    final generation = _generation;
    if (state.busy) return null;
    state = state.copyWith(busy: true);
    SocialFailure? failure;
    try {
      await action();
    } on SocialFailure catch (e) {
      failure = e;
    } catch (_) {
      failure = const SocialFailure(SocialFailureKind.unknown);
    }
    if (generation != _generation) return failure;
    // A failed or uncertain write may still have changed something: look again.
    state = state.copyWith(busy: false);
    await _load(generation, keepOnFailure: true);
    return failure;
  }
}

final socialControllerProvider = NotifierProvider<SocialController, SocialState>(
  SocialController.new,
);
