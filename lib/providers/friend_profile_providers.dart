import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/shared_profile_repository.dart';
import '../shared_profile/shared_stats_reading.dart';
import '../social/social_models.dart';
import 'providers.dart';
import 'shared_profile_providers.dart';
import 'sharing_providers.dart';
import 'social_lists_providers.dart';
import 'social_providers.dart';
import 'sync_providers.dart';

/// The friend's profile (docs/82 §7.2, docs/81 RF-F, Fatia 3).

/// How long a friend's profile read from the server may be shown again
/// without a new read (D15). "Atualizar"/"Tentar novamente" ignore it.
final friendProfileTtlProvider = Provider<Duration>((ref) => const Duration(minutes: 5));

/// The uid of `/friends/u/:uid` must pass the rules' `validUid` (`^[^_/]{1,128}$`)
/// and be a usable document id ('.'/'..' are not). Anything else is "not
/// available" WITHOUT a read (docs/81 "uid inválido").
bool isValidFriendUid(String uid) => _friendUid.hasMatch(uid) && uid != '.' && uid != '..';

final _friendUid = RegExp(r'^[^_/]{1,128}$');

/// What was read of one friend: their card (header) and what they share
/// (null = the document does not exist: "não compartilha nada além do cartão").
class FriendProfileEntry {
  final Friend friend;
  final FriendSharedView? view;

  /// When it came from the server (the TTL counts from here).
  final DateTime at;

  const FriendProfileEntry({required this.friend, required this.view, required this.at});
}

/// MEMORY-only cache of friends' profiles, for ONE account and ONE
/// "friendships on" period (the provider builds a new, empty one when
/// either changes): nothing is ever written to disk, and offline it is
/// never shown (D10).
class FriendProfileCache {
  final Map<String, FriendProfileEntry> _entries = {};

  /// Cards handed over by the friends list (navigation `extra`): the header
  /// without a read (RF-F3).
  final Map<String, Friend> _headers = {};

  /// The entry of [uid] if it is younger than [ttl] at [now].
  FriendProfileEntry? fresh(String uid, DateTime now, Duration ttl) {
    final entry = _entries[uid];
    if (entry == null) return null;
    return now.difference(entry.at) < ttl ? entry : null;
  }

  void put(String uid, FriendProfileEntry entry) => _entries[uid] = entry;

  /// Forgets everything about [uid] (not a friend any more).
  void remove(String uid) {
    _entries.remove(uid);
    _headers.remove(uid);
  }

  void rememberHeader(Friend friend) => _headers[friend.uid] = friend;

  Friend? header(String uid) => _headers[uid] ?? _entries[uid]?.friend;

  bool contains(String uid) => _entries.containsKey(uid);
}

final friendProfileCacheProvider = Provider<FriendProfileCache>((ref) {
  // Another account, signing out, or friendships turned off / on: an empty
  // cache (nothing of one account ever reaches the next, RF-F4).
  ref.watch(currentUidProvider);
  ref.watch(socialPeriodProvider);
  return FriendProfileCache();
});

enum FriendProfilePhase {
  loading,

  /// The document exists: its sections (an absent one = "não compartilha").
  content,

  /// `not-found` (the reader is a friend): "ainda não compartilha nada além do cartão".
  notShared,

  /// Not a friend / blocked / malformed uid / deleted account: one neutral text.
  unavailable,

  /// The device is offline: nothing is shown, not even the memory cache (D10).
  offline,

  /// Online but no answer (`unavailable`, timeout of 8 s, unknown).
  error,
  quota,
  sessionExpired,
}

class FriendProfileState {
  final FriendProfilePhase phase;

  /// Header (null while not known: opened by address, pair still loading).
  final Friend? friend;

  /// Only in [FriendProfilePhase.content].
  final FriendSharedView? view;

  const FriendProfileState({required this.phase, this.friend, this.view});

  bool get hasContent => phase == FriendProfilePhase.content;
}

/// One friend's profile screen. Reads (docs/82 §11): from the list, cold =
/// 1 `get` of `shared_profiles/{uid}` (Source.server); by address with no
/// list in memory = + 1 `get` of the pair; within the TTL = 0. Every
/// failure maps to the table of docs/82 §7.2.
class FriendProfileController extends AutoDisposeFamilyNotifier<FriendProfileState, String> {
  int _generation = 0;
  Future<void>? _inFlight;

  @override
  FriendProfileState build(String uid) {
    final generation = ++_generation;
    _inFlight = null;
    ref.watch(currentUidProvider);
    ref.watch(socialPeriodProvider);
    if (!isValidFriendUid(uid)) {
      return const FriendProfileState(phase: FriendProfilePhase.unavailable);
    }
    // Back online after "Sem conexão": read (served from memory if fresh).
    ref.listen(syncStatusProvider.select((s) => s.offline), (previous, offline) {
      if (previous == true && !offline && state.phase == FriendProfilePhase.offline) {
        _load(force: false);
      }
    });
    Future.microtask(() {
      if (generation == _generation) _load(force: false);
    });
    final cache = ref.read(friendProfileCacheProvider);
    return FriendProfileState(
      phase: FriendProfilePhase.loading,
      friend: cache.header(uid) ?? _fromList(uid),
    );
  }

  Friend? _fromList(String uid) {
    for (final f in ref.read(friendsControllerProvider).items) {
      if (f.uid == uid) return f;
    }
    return null;
  }

  /// "Atualizar" / "Tentar novamente": a server read, whatever the TTL.
  Future<void> refresh() => _load(force: true);

  /// One load at a time: a second request joins the one running.
  Future<void> _load({required bool force}) {
    final running = _inFlight;
    if (running != null) return running;
    final generation = _generation;
    final run = _run(force, generation);
    _inFlight = run;
    return run.whenComplete(() {
      if (generation == _generation) _inFlight = null;
    });
  }

  bool _gone(int generation) => generation != _generation;

  Future<void> _run(bool force, int generation) async {
    final uid = arg;
    if (!isValidFriendUid(uid)) {
      state = const FriendProfileState(phase: FriendProfilePhase.unavailable);
      return;
    }
    final cache = ref.read(friendProfileCacheProvider);
    var friend = state.friend ?? cache.header(uid) ?? _fromList(uid);
    // D10: offline shows NOTHING, not even the memory cache.
    if (ref.read(syncStatusProvider).offline) {
      state = FriendProfileState(phase: FriendProfilePhase.offline, friend: friend);
      return;
    }
    final now = ref.read(sharedProfileClockProvider);
    if (!force) {
      final entry = cache.fresh(uid, now(), ref.read(friendProfileTtlProvider));
      if (entry != null) {
        state = _shown(friend ?? entry.friend, entry.view);
        return;
      }
    }
    state = FriendProfileState(phase: FriendProfilePhase.loading, friend: friend);
    if (friend == null) {
      // Opened by address with no list in memory: the pair gives the header.
      try {
        friend = await ref.read(socialRepositoryProvider).friendship(uid);
      } on SocialFailure catch (e) {
        if (_gone(generation)) return;
        state = _failed(SharedProfileFailure.fromSocial(e).kind, null);
        return;
      }
      if (_gone(generation)) return;
      if (friend == null) {
        _revoked(uid);
        state = const FriendProfileState(phase: FriendProfilePhase.unavailable);
        return;
      }
      state = FriendProfileState(phase: FriendProfilePhase.loading, friend: friend);
    }
    try {
      final view = await ref.read(sharedProfileRepositoryProvider).readFriend(uid);
      if (_gone(generation)) return;
      cache.put(uid, FriendProfileEntry(friend: friend, view: view, at: now()));
      state = _shown(friend, view);
    } on SharedProfileFailure catch (f) {
      if (_gone(generation)) return;
      state = _failed(f.kind, friend);
    }
  }

  FriendProfileState _shown(Friend friend, FriendSharedView? view) => view == null
      ? FriendProfileState(phase: FriendProfilePhase.notShared, friend: friend)
      : FriendProfileState(phase: FriendProfilePhase.content, friend: friend, view: view);

  FriendProfileState _failed(SharedProfileFailureKind kind, Friend? friend) {
    switch (kind) {
      case SharedProfileFailureKind.denied:
        _revoked(arg);
        return const FriendProfileState(phase: FriendProfilePhase.unavailable);
      case SharedProfileFailureKind.quota:
        return FriendProfileState(phase: FriendProfilePhase.quota, friend: friend);
      case SharedProfileFailureKind.sessionExpired:
        return FriendProfileState(phase: FriendProfilePhase.sessionExpired, friend: friend);
      default:
        // `unavailable` / timeout / unknown: what the device knows decides.
        return FriendProfileState(
          phase: ref.read(syncStatusProvider).offline
              ? FriendProfilePhase.offline
              : FriendProfilePhase.error,
          friend: friend,
        );
    }
  }

  /// `permission-denied` (or no pair): not a friend any more. The memory
  /// cache of this uid goes, and so does their card in the friends list in
  /// memory, AT ONCE (B6).
  void _revoked(String uid) {
    ref.read(friendProfileCacheProvider).remove(uid);
    ref.read(friendsControllerProvider.notifier).dropLocal(uid);
  }

  /// "Remover amizade" from the profile: the Phase 1 flow. Whatever the
  /// outcome, the memory copy of this profile is forgotten (a removal that
  /// happened, or may have, must never be followed by the old content).
  Future<SocialFailure?> remove() async {
    final friend = state.friend;
    if (friend == null) return const SocialFailure(SocialFailureKind.unknown);
    final failure = await ref.read(friendsControllerProvider.notifier).remove(friend);
    if (failure != kBusyFailure) ref.read(friendProfileCacheProvider).remove(friend.uid);
    return failure;
  }

  /// "Bloquear" from the profile: the Phase 1 flow (block + friendship and
  /// requests deleted in one batch); the memory copy is forgotten too.
  Future<SocialFailure?> block() async {
    final friend = state.friend;
    if (friend == null) return const SocialFailure(SocialFailureKind.unknown);
    final failure = await ref.read(friendsControllerProvider.notifier).block(friend);
    if (failure != kBusyFailure) ref.read(friendProfileCacheProvider).remove(friend.uid);
    return failure;
  }
}

final friendProfileControllerProvider = NotifierProvider.autoDispose
    .family<FriendProfileController, FriendProfileState, String>(FriendProfileController.new);
