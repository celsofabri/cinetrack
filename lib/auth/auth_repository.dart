import 'app_user.dart';
import 'auth_failure.dart';

/// Identity seam. Implementations: Firebase Auth (production),
/// [UnavailableAuthRepository] (no Firebase configured) and a fake for tests.
abstract class AuthRepository {
  /// False when login cannot work in this build (Firebase not configured or
  /// `CLOUD_SYNC=false`); the UI then hides/explains login instead of failing.
  bool get isAvailable;

  /// Emits the current user (or null) first and then every change. The
  /// first event also tells the app that the session was restored.
  Stream<AppUser?> authStateChanges();

  /// Starts Google sign-in. On web the underlying popup must be opened
  /// synchronously from the tap, so call this before any `await`.
  /// Throws [AuthFailure].
  Future<AppUser> signInWithGoogle();

  Future<void> signOut();

  /// Asks the provider whether the session is still valid (refreshes the
  /// token). Used to tell "rules refused my write" from "my session died".
  /// When [expectedUid] is given and the signed-in user is someone else, the
  /// answer is [SessionCheck.unknown]: it says nothing about that account.
  Future<SessionCheck> verifySession({String? expectedUid});

  /// Confirms the identity of the current user again (needed before
  /// deleting the account). Same web rule as [signInWithGoogle]: call it
  /// before any `await`. Throws [AuthFailure] (including
  /// [AuthFailureKind.wrongAccount] when another Google account is chosen, or
  /// when the signed-in user is no longer [expectedUid]: the session is shared
  /// between browser tabs, so it can change under the app).
  Future<void> reauthenticate(String expectedUid);

  /// Deletes the signed-in Firebase user (after [reauthenticate]) ONLY if it
  /// is still [expectedUid], else throws [AuthFailureKind.wrongAccount]
  /// without touching anything. The auth state then becomes signed out.
  /// Throws [AuthFailure].
  Future<void> deleteCurrentUser(String expectedUid);

  /// After an inconclusive [deleteCurrentUser] (network error: the server may
  /// have deleted the user and lost the answer): true = the user [uid] still
  /// exists, false = it is gone, null = could not tell.
  Future<bool?> userStillExists(String uid);
}

enum SessionCheck {
  valid,
  expired,

  /// Could not tell (offline, provider error).
  unknown,
}

/// Used when Firebase is not configured: the app runs as a free catalog
/// browser, always signed out.
class UnavailableAuthRepository implements AuthRepository {
  const UnavailableAuthRepository();

  @override
  bool get isAvailable => false;

  @override
  Stream<AppUser?> authStateChanges() => Stream.value(null);

  @override
  Future<AppUser> signInWithGoogle() =>
      Future.error(const AuthFailure(AuthFailureKind.unavailable));

  @override
  Future<void> signOut() async {}

  @override
  Future<SessionCheck> verifySession({String? expectedUid}) async => SessionCheck.expired;

  @override
  Future<void> reauthenticate(String expectedUid) =>
      Future.error(const AuthFailure(AuthFailureKind.unavailable));

  @override
  Future<void> deleteCurrentUser(String expectedUid) =>
      Future.error(const AuthFailure(AuthFailureKind.unavailable));

  @override
  Future<bool?> userStillExists(String uid) async => null;
}
