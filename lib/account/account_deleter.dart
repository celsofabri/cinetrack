import '../auth/auth_failure.dart';
import '../auth/auth_repository.dart';
import '../data/profile_data_source.dart';
import '../repositories/social_repository.dart';
import 'account_deletion_failure.dart';

enum AccountDeletionStep { reauthenticating, deletingData, deletingAccount }

/// Orchestrates account deletion on the client (no Cloud Functions on the
/// free plan). Every step is idempotent, so a failure at any point leaves a
/// consistent state and the whole operation can simply be run again:
///
/// 1. re-authenticate the SAME account (also proves we are online);
/// 2. confirm the server is reachable (nothing is written while offline);
/// 3. mark `users/{uid}.deleting = true` (so the app can offer to resume);
/// 4. delete the social data (handle, card, friends, requests, blocks; a
///    no-op for accounts that never turned friendships on), so the user
///    disappears from other people's friend lists and nothing is orphaned;
/// 5. delete the favorites in batches, then the profile document;
/// 6. delete the Firebase user. If that fails, the marker is written again,
///    since the profile document is gone and a resume must stay possible
///    (but ONLY when the user is known to still exist: writing under a uid
///    whose account is already gone would create data nobody owns).
///
/// Everything is bound to [uid]: the auth session is shared between browser
/// tabs, so the signed-in user can change mid-way; the auth steps then refuse
/// to act on anybody else.
class AccountDeleter {
  final AuthRepository _auth;
  final ProfileDataSource _profile;
  final SocialRepository _social;
  final String uid;

  /// Called right before the Firebase user is deleted, and [onDeleteAborted]
  /// when that fails: lets the app tell "I deleted the account" (expected
  /// sign-out) from "the session died" (shows the expired banner).
  final void Function() onBeforeUserDelete;
  final void Function() onDeleteAborted;

  AccountDeleter({
    required this.uid,
    required this._auth,
    required this._profile,
    required this._social,
    void Function()? onBeforeUserDelete,
    void Function()? onDeleteAborted,
  })  : onBeforeUserDelete = onBeforeUserDelete ?? _noop,
        onDeleteAborted = onDeleteAborted ?? _noop;

  static void _noop() {}

  /// Throws [AccountDeletionFailure]. NOTE: the first thing it does is
  /// call [AuthRepository.reauthenticate] synchronously (web popups must open
  /// inside the user's tap), so call it straight from the button handler.
  Future<void> run({void Function(AccountDeletionStep step)? onStep}) async {
    onStep?.call(AccountDeletionStep.reauthenticating);
    try {
      await _auth.reauthenticate(uid);
    } on AuthFailure catch (e) {
      throw _fromAuth(e);
    }

    onStep?.call(AccountDeletionStep.deletingData);
    await _profile.ensureOnline();
    await _profile.markDeleting();
    await _social.wipeForAccountDeletion();
    await _profile.deleteAllFavorites();
    await _profile.deleteProfile();

    onStep?.call(AccountDeletionStep.deletingAccount);
    onBeforeUserDelete();
    try {
      await _auth.deleteCurrentUser(uid);
    } on AuthFailure catch (e) {
      onDeleteAborted();
      if (e.kind == AuthFailureKind.wrongAccount) {
        // The session now belongs to someone else (other tab): nothing of
        // theirs was touched, and this tab can no longer write under [uid].
        throw _fromAuth(e);
      }
      if (e.kind == AuthFailureKind.network) {
        // The server may have deleted the user and lost the answer.
        final exists = await _userStillExists();
        if (exists == false) {
          onBeforeUserDelete();
          await _signOutQuietly();
          return;
        }
        if (exists == null) {
          // Uncertain: do NOT write under a uid that may not exist anymore.
          throw const AccountDeletionFailure(
            AccountDeletionFailureKind.uncertain,
            code: 'delete-user-unconfirmed',
          );
        }
      }
      try {
        await _profile.markDeleting();
      } catch (_) {
        // Best effort: without the marker the user just sees an empty
        // account and can repeat the deletion.
      }
      throw _fromAuth(e);
    }
  }

  Future<bool?> _userStillExists() async {
    try {
      return await _auth.userStillExists(uid);
    } catch (_) {
      return null;
    }
  }

  Future<void> _signOutQuietly() async {
    try {
      await _auth.signOut();
    } catch (_) {}
  }

  AccountDeletionFailure _fromAuth(AuthFailure e) => AccountDeletionFailure(
        switch (e.kind) {
          AuthFailureKind.cancelled => AccountDeletionFailureKind.cancelled,
          AuthFailureKind.network => AccountDeletionFailureKind.offline,
          AuthFailureKind.popupBlocked => AccountDeletionFailureKind.popupBlocked,
          AuthFailureKind.wrongAccount => AccountDeletionFailureKind.wrongAccount,
          AuthFailureKind.sessionExpired => AccountDeletionFailureKind.sessionExpired,
          _ => AccountDeletionFailureKind.unknown,
        },
        code: e.code,
      );
}
