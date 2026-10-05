import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/account_deleter.dart';
import '../account/account_deletion_failure.dart';
import '../account/session_expiry.dart';
import '../data/firestore_profile_data_source.dart';
import '../data/profile_data_source.dart';
import '../models/profile_stats.dart';
import 'providers.dart';
import 'social_providers.dart';
import 'sync_providers.dart';

typedef ProfileDataSourceFactory = ProfileDataSource Function(String uid);

/// Builds the profile data source for a uid. Overridden in tests with fakes.
final profileDataSourceFactoryProvider = Provider<ProfileDataSourceFactory>((ref) {
  final sink = ref.watch(syncFailureSinkProvider);
  return (uid) => FirestoreProfileDataSource(uid: uid, sink: sink);
});

/// Like the favorites source: depends on the uid, so it is recreated when
/// the account changes; signed out = inert.
final profileDataSourceProvider = Provider<ProfileDataSource>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return const SignedOutProfileDataSource();
  return ref.watch(profileDataSourceFactoryProvider)(uid);
});

final profileProvider = StreamProvider<UserProfile>((ref) {
  return ref.watch(profileDataSourceProvider).watch();
});

/// Nickname if the user set one, else the Google name/e-mail.
final displayLabelProvider = Provider<String>((ref) {
  final nickname = ref.watch(profileProvider).valueOrNull?.nickname;
  if (nickname != null) return nickname;
  return ref.watch(currentUserProvider)?.label ?? 'Usuário';
});

/// Derived from the user's documents; recomputed on every change. The
/// favorites list is watched only as a trigger for catalog changes (a season
/// finishing its download can complete a series).
final profileStatsProvider = Provider<ProfileStats>((ref) {
  ref.watch(favoritesListProvider);
  final docs = ref.watch(favoriteDocsProvider).valueOrNull ?? const [];
  final store = ref.watch(localStoreProvider);
  return ProfileStats.fromDocs(
    docs,
    catalog: store.readSeasonCatalog,
    movieRuntime: store.readMovieRuntime,
    tvFallbackRuntime: store.readTvFallbackRuntime,
  );
});

class AccountDeletionState {
  final bool running;
  final AccountDeletionStep? step;
  final AccountDeletionFailure? failure;

  const AccountDeletionState({this.running = false, this.step, this.failure});
}

class AccountController extends Notifier<AccountDeletionState> {
  @override
  AccountDeletionState build() {
    // Keeps the sync status alive (and up to date) while a deletion may start,
    // so the offline pre-check below has real data to look at.
    ref.listen(syncStatusProvider, (_, _) {});
    return const AccountDeletionState();
  }

  /// Returns true when the account was deleted. The first thing it does
  /// (synchronously) is open the Google re-authentication, so call it
  /// straight from the confirm button's `onPressed`.
  Future<bool> deleteAccount() async {
    if (state.running) return false;

    final uid = ref.read(currentUidProvider);
    if (uid == null) return false;

    final expiry = ref.read(sessionExpiryProvider.notifier);
    final deleter = AccountDeleter(
      uid: uid,
      auth: ref.read(authRepositoryProvider),
      profile: ref.read(profileDataSourceProvider),
      social: ref.read(socialRepositoryProvider),
      onBeforeUserDelete: expiry.expectSignOut,
      onDeleteAborted: expiry.cancelExpectedSignOut,
    );

    // Offline is detected up front (no popup, nothing written). Only when
    // the status is trustworthy: connected before, or the server is silent.
    if (ref.read(syncStatusProvider).offline) {
      state = const AccountDeletionState(
        failure: AccountDeletionFailure(AccountDeletionFailureKind.offline, code: 'offline'),
      );
      return false;
    }

    state = const AccountDeletionState(running: true, step: AccountDeletionStep.reauthenticating);
    try {
      await deleter.run(
        onStep: (step) => state = AccountDeletionState(running: true, step: step),
      );
      // The deleted account's documents are gone from the cache, but the
      // browser database still holds traces (deletion markers, ids). Logout
      // never clears anything (Manager's decision); only this explicit
      // deletion schedules a wipe, done at the next app start (see
      // initFirebase), when no other Firestore call has run yet.
      try {
        await ref.read(localStoreProvider).markFirestoreCachePurge();
      } catch (_) {}
      // The uid is gone for good: its "limpeza pendente" flag (docs/58) too.
      try {
        await ref.read(localStoreProvider).setSocialCleanupPending(uid, false);
        await ref.read(localStoreProvider).setSocialHint(uid, null);
      } catch (_) {}
      state = const AccountDeletionState();
      return true;
    } on AccountDeletionFailure catch (failure) {
      state = AccountDeletionState(failure: failure);
      return false;
    } catch (e) {
      state = AccountDeletionState(
        failure: AccountDeletionFailure(
          AccountDeletionFailureKind.unknown,
          code: e.runtimeType.toString(),
        ),
      );
      return false;
    }
  }

  void clearFailure() => state = const AccountDeletionState();
}

final accountControllerProvider =
    NotifierProvider<AccountController, AccountDeletionState>(AccountController.new);

/// Opens a URL outside the app. Overridden in tests.
final urlOpenerProvider = Provider<Future<bool> Function(Uri uri)>((ref) {
  return (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
});
