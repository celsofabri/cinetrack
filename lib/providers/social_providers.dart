import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/firestore_social_data_source.dart';
import '../data/social_data_source.dart';
import '../repositories/social_repository.dart';
import '../social/social_models.dart';
import '../social/social_validation.dart';
import 'account_providers.dart';
import 'social_lists_providers.dart';
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

/// Bumped when friendships are turned on or off: everything held in memory
/// (lists, counts) belongs to ONE such period and is rebuilt empty on a change.
final socialEpochProvider = StateProvider<int>((ref) => 0);

/// `(friendships on, epoch)`: the lists watch this to know when to forget.
final socialPeriodProvider = Provider<(bool, int)>((ref) {
  final active = ref.watch(socialControllerProvider.select((s) => s.phase == SocialPhase.active));
  return (active, ref.watch(socialEpochProvider));
});

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
    // A fresh local hint ("friendships on/off", at most [kSocialHintTtl] old)
    // lets the Amigos icon show without reading the server; the first screen
    // that needs the real state (Profile, /friends) calls [confirm].
    final hinted = _freshHint(user.$1!) != null;
    _started = !hinted;
    if (!hinted) {
      Future.microtask(() {
        if (generation == _generation) _load(generation);
      });
    }
    return const SocialState();
  }

  /// True once the state of this session was asked from the server.
  bool _started = false;

  ({bool active, DateTime at})? _freshHint(String uid) {
    try {
      final hint = ref.read(localStoreProvider).socialHint(uid);
      if (hint == null) return null;
      final age = DateTime.now().difference(hint.at);
      return age < kSocialHintTtl && !age.isNegative ? hint : null;
    } catch (_) {
      return null;
    }
  }

  /// Hint for the icon while the state is not confirmed yet.
  bool get hintedActive {
    final uid = ref.read(currentUidProvider);
    return uid != null && (_freshHint(uid)?.active ?? false);
  }

  /// Reads the real state once per session if the build skipped it (hint).
  void confirm() {
    if (_started) return;
    final phase = state.phase;
    if (phase == SocialPhase.signedOut || phase == SocialPhase.notGoogle) return;
    _started = true;
    Future.microtask(() => _load(_generation));
  }

  /// Remembers the answer for [uid] (captured BEFORE the request started) and
  /// only if that account and this controller generation are still current:
  /// a reply for account A must never become the hint of account B.
  Future<void> _rememberHint(String uid, int generation, bool active) async {
    if (generation != _generation || ref.read(currentUidProvider) != uid) return;
    try {
      await ref.read(localStoreProvider).setSocialHint(uid, active);
    } catch (_) {}
  }

  /// Reads the state again (server first, then the device).
  Future<void> refresh() async {
    if (state.phase == SocialPhase.signedOut || state.phase == SocialPhase.notGoogle) return;
    _started = true;
    state = const SocialState();
    await _load(_generation);
  }

  Future<void> _load(int generation, {bool keepOnFailure = false}) async {
    SocialState next;
    final uid = ref.read(currentUidProvider);
    try {
      final load = await ref.read(socialRepositoryProvider).load();
      next = SocialState(
        phase: load.profile == null ? SocialPhase.inactive : SocialPhase.active,
        profile: load.profile,
        fromCache: load.fromCache,
        cleanupPending: load.profile == null && _cleanupFlag(),
      );
      // Only a server answer is worth remembering (a device copy may be old).
      if (!load.fromCache && uid != null) {
        await _rememberHint(uid, generation, load.profile != null);
      }
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
    final uid = user?.uid;
    final generation = _generation;
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
      // Confirmed by the server: the icon must not wait for the next read.
      if (uid != null) await _rememberHint(uid, generation, true);
      ref.read(socialEpochProvider.notifier).state++;
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
    final uid = ref.read(currentUidProvider);
    final generation = _generation;
    final failure = await _run(() => ref.read(socialRepositoryProvider).deactivate());
    // The pointer is gone in both cases (even if the last sweep did not
    // finish): friendships are off, the lists in memory are void.
    final off = failure == null || failure.code == SocialRepository.cleanupPendingCode;
    if (off) {
      if (uid != null) await _rememberHint(uid, generation, false);
      if (generation == _generation) ref.read(socialEpochProvider.notifier).state++;
    }
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

/// How long the "Enviados" list is served from memory before the next open
/// reads again (docs/50 §9 / D11: cache + TTL, no listener). Tests override.
final sentRequestsTtlProvider = Provider<Duration>((ref) => const Duration(minutes: 5));

enum SentPhase { idle, loading, loaded, error }

class SentRequestsState {
  final SentPhase phase;
  final List<SentRequest> items;
  final bool hasMore;
  final Object? cursor;

  /// The list shown came from this device, not from the server.
  final bool fromCache;
  final bool loadingMore;

  /// A "Ver mais" that failed (the page already shown stays).
  final SocialFailure? moreFailure;

  /// Why the first page failed (phase [SentPhase.error]).
  final SocialFailure? failure;

  /// Recipients whose request is being cancelled right now.
  final Set<String> cancelling;

  /// When the first page was read from the server (null = never / from cache).
  final DateTime? loadedAt;

  const SentRequestsState({
    this.phase = SentPhase.idle,
    this.items = const [],
    this.hasMore = false,
    this.cursor,
    this.fromCache = false,
    this.loadingMore = false,
    this.moreFailure,
    this.failure,
    this.cancelling = const {},
    this.loadedAt,
  });

  bool contains(String toUid) => items.any((r) => r.toUid == toUid);

  SentRequestsState copyWith({
    SentPhase? phase,
    List<SentRequest>? items,
    bool? hasMore,
    Object? cursor,
    bool? fromCache,
    bool? loadingMore,
    SocialFailure? moreFailure,
    bool clearMoreFailure = false,
    Set<String>? cancelling,
  }) => SentRequestsState(
    phase: phase ?? this.phase,
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    cursor: cursor ?? this.cursor,
    fromCache: fromCache ?? this.fromCache,
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailure: clearMoreFailure ? null : (moreFailure ?? this.moreFailure),
    failure: failure,
    cancelling: cancelling ?? this.cancelling,
    loadedAt: loadedAt,
  );
}

/// The pending requests this user sent ("Enviados"). Nothing is read until a
/// screen asks ([ensureLoaded]); no listener; the first page is kept for
/// [sentRequestsTtlProvider]. Sending adds to the list in memory and
/// cancelling removes from it, so no re-read is needed after either.
class SentRequestsController extends Notifier<SentRequestsState> {
  int _generation = 0;

  @override
  SentRequestsState build() {
    _generation++;
    ref.watch(currentUidProvider);
    // Everything in memory belongs to ONE "friendships on" period: turning
    // them off (which deletes the requests on the server), on again, logging
    // out or changing account rebuilds this controller and drops the list.
    // (Changing the handle does not: the requests stay valid.)
    ref.watch(socialPeriodProvider);
    return const SentRequestsState();
  }

  bool get _expired {
    final at = state.loadedAt;
    return at == null || DateTime.now().difference(at) >= ref.read(sentRequestsTtlProvider);
  }

  /// Loads the first page unless a fresh one is already in memory.
  Future<void> ensureLoaded() async {
    if (ref.read(currentUidProvider) == null) return;
    if (state.phase == SentPhase.loading) return;
    if (state.phase == SentPhase.loaded && !_expired) return;
    await _loadFirst();
  }

  /// Reads the first page again (retry / pull).
  Future<void> reload() async {
    if (ref.read(currentUidProvider) == null || state.phase == SentPhase.loading) return;
    await _loadFirst();
  }

  Future<void> _loadFirst() async {
    final generation = _generation;
    // Keep what is shown while refreshing a loaded list (no flicker).
    state = state.phase == SentPhase.loaded
        ? state.copyWith(clearMoreFailure: true)
        : const SentRequestsState(phase: SentPhase.loading);
    try {
      final page = await ref.read(socialRepositoryProvider).sentRequests();
      if (generation != _generation) return;
      state = SentRequestsState(
        phase: SentPhase.loaded,
        items: page.items,
        hasMore: page.hasMore,
        cursor: page.cursor,
        fromCache: page.fromCache,
        loadedAt: page.fromCache ? null : DateTime.now(),
      );
    } on SocialFailure catch (e) {
      if (generation != _generation) return;
      state = state.phase == SentPhase.loaded
          ? state.copyWith(moreFailure: e)
          : SentRequestsState(phase: SentPhase.error, failure: e);
    } catch (_) {
      if (generation != _generation) return;
      state = const SentRequestsState(
        phase: SentPhase.error,
        failure: SocialFailure(SocialFailureKind.unknown),
      );
    }
  }

  Future<void> loadMore() async {
    if (state.phase != SentPhase.loaded || !state.hasMore || state.loadingMore) return;
    final generation = _generation;
    state = state.copyWith(loadingMore: true, clearMoreFailure: true);
    try {
      final page = await ref.read(socialRepositoryProvider).sentRequests(cursor: state.cursor);
      if (generation != _generation) return;
      final known = {for (final r in state.items) r.toUid};
      state = state.copyWith(
        items: [
          ...state.items,
          for (final r in page.items)
            if (!known.contains(r.toUid)) r,
        ],
        hasMore: page.hasMore,
        cursor: page.cursor,
        fromCache: state.fromCache || page.fromCache,
        loadingMore: false,
      );
    } on SocialFailure catch (e) {
      if (generation == _generation) state = state.copyWith(loadingMore: false, moreFailure: e);
    } catch (_) {
      if (generation == _generation) {
        state = state.copyWith(
          loadingMore: false,
          moreFailure: const SocialFailure(SocialFailureKind.unknown),
        );
      }
    }
  }

  /// Sends a request. Returns the failure to show, or null on success;
  /// [outcome] says whether a request now exists or (crossed request, D4) the
  /// two became friends.
  Future<({SocialFailure? failure, SendOutcome? outcome})> send(FriendCard target) async {
    final generation = _generation;
    final me = ref.read(socialControllerProvider).profile;
    if (me == null) {
      return (failure: const SocialFailure(SocialFailureKind.notActive), outcome: null);
    }
    final SendOutcome outcome;
    try {
      outcome = await ref.read(socialRepositoryProvider).sendRequest(target, me: me);
    } on SocialFailure catch (e) {
      return (failure: e, outcome: null);
    } catch (_) {
      return (failure: const SocialFailure(SocialFailureKind.unknown), outcome: null);
    }
    if (outcome == SendOutcome.becameFriends) {
      // Their request is gone and the friend appears without another read.
      ref.read(receivedRequestsControllerProvider.notifier).consumed(target.uid);
      ref
          .read(friendsControllerProvider.notifier)
          .add(
            Friend(
              uid: target.uid,
              name: target.nickname,
              photoUrl: target.photoUrl,
              since: DateTime.now(),
            ),
          );
      return (failure: null, outcome: outcome);
    }
    if (generation == _generation &&
        state.phase == SentPhase.loaded &&
        !state.contains(target.uid)) {
      state = state.copyWith(
        items: [
          SentRequest(
            toUid: target.uid,
            toName: target.nickname,
            toPhoto: target.photoUrl,
            createdAt: DateTime.now(),
          ),
          ...state.items,
        ],
      );
    }
    return (failure: null, outcome: outcome);
  }

  /// Cancels the request sent to [toUid]. Returns the failure to show, or null.
  Future<SocialFailure?> cancel(String toUid) async {
    if (state.cancelling.contains(toUid)) return null;
    final generation = _generation;
    state = state.copyWith(cancelling: {...state.cancelling, toUid});
    SocialFailure? failure;
    try {
      await ref.read(socialRepositoryProvider).cancelRequest(toUid);
    } on SocialFailure catch (e) {
      failure = e;
    } catch (_) {
      failure = const SocialFailure(SocialFailureKind.unknown);
    }
    if (generation != _generation) return failure;
    final left = {...state.cancelling}..remove(toUid);
    state = failure == null
        ? state.copyWith(
            items: [
              for (final r in state.items)
                if (r.toUid != toUid) r,
            ],
            cancelling: left,
          )
        : state.copyWith(cancelling: left);
    // An unconfirmed delete may or may not have happened: look again.
    if (failure?.kind == SocialFailureKind.uncertain) await reload();
    return failure;
  }
}

final sentRequestsControllerProvider = NotifierProvider<SentRequestsController, SentRequestsState>(
  SentRequestsController.new,
);

/// True when this account has friendships on (and the answer is known):
/// drives the Amigos entry in the top bar / menu. Reading it makes the social
/// state load once per session (1-2 reads, docs/59).
final socialActiveProvider = Provider<bool>((ref) {
  final phase = ref.watch(socialControllerProvider.select((s) => s.phase));
  if (phase == SocialPhase.active) return true;
  // Not confirmed yet: trust a fresh local hint, never a stale one.
  if (phase == SocialPhase.loading) return ref.read(socialControllerProvider.notifier).hintedActive;
  return false;
});

/// How long a remembered "friendships on/off" answer lets the icon skip the
/// server (docs/59). After that the next session asks again.
const kSocialHintTtl = Duration(hours: 24);
