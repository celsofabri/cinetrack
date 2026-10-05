import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'app_user.dart';
import 'auth_failure.dart';
import 'auth_repository.dart';

/// Firebase Auth + Google. Web uses `signInWithPopup` (no google_sign_in);
/// Android/iOS use `google_sign_in` + `signInWithCredential`.
///
/// UNVERIFIED end to end: needs a configured Firebase project (and, on
/// Android, the SHA-1 and possibly `serverClientId`; spike S1).
class FirebaseAuthRepository implements AuthRepository {
  final FirebaseAuth _auth;
  bool _googleInitialized = false;

  FirebaseAuthRepository({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  @override
  bool get isAvailable => true;

  @override
  Stream<AppUser?> authStateChanges() => _auth.authStateChanges().map(_toAppUser);

  @override
  Future<AppUser> signInWithGoogle() async {
    try {
      final UserCredential credential;
      if (kIsWeb) {
        // First statement on purpose: the popup must open inside the tap.
        credential = await _auth.signInWithPopup(GoogleAuthProvider());
      } else {
        credential = await _auth.signInWithCredential(await _googleCredential());
      }
      final user = _toAppUser(credential.user);
      if (user == null) throw const AuthFailure(AuthFailureKind.unknown);
      return user;
    } catch (e) {
      throw _toFailure(e);
    }
  }

  @override
  Future<void> reauthenticate(String expectedUid) async {
    final current = _auth.currentUser;
    if (current == null) throw const AuthFailure(AuthFailureKind.sessionExpired);
    // Synchronous (no await yet): the popup below still opens inside the tap.
    if (current.uid != expectedUid) throw const AuthFailure(AuthFailureKind.wrongAccount);
    try {
      final UserCredential result;
      if (kIsWeb) {
        // No await before the popup (see signInWithGoogle).
        result = await current.reauthenticateWithPopup(GoogleAuthProvider());
      } else {
        result = await current.reauthenticateWithCredential(await _googleCredential());
      }
      if (result.user?.uid != current.uid) {
        throw const AuthFailure(AuthFailureKind.wrongAccount);
      }
    } catch (e) {
      throw _toFailure(e);
    }
  }

  @override
  Future<void> deleteCurrentUser(String expectedUid) async {
    final current = _auth.currentUser;
    if (current == null) throw const AuthFailure(AuthFailureKind.sessionExpired);
    // The auth session is shared between tabs: never delete somebody else.
    if (current.uid != expectedUid) throw const AuthFailure(AuthFailureKind.wrongAccount);
    try {
      await current.delete();
    } catch (e) {
      throw _toFailure(e);
    }
    if (!kIsWeb) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
  }

  @override
  Future<bool?> userStillExists(String uid) async {
    final current = _auth.currentUser;
    if (current == null || current.uid != uid) return null;
    try {
      await current.reload();
      return true;
    } on FirebaseAuthException catch (e) {
      return e.code == 'user-not-found' ? false : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<SessionCheck> verifySession({String? expectedUid}) async {
    final current = _auth.currentUser;
    if (current == null) return SessionCheck.expired;
    if (expectedUid != null && current.uid != expectedUid) return SessionCheck.unknown;
    try {
      await current.getIdToken(true);
      return SessionCheck.valid;
    } on FirebaseAuthException catch (e) {
      return AuthFailure.fromFirebaseCode(e.code).kind == AuthFailureKind.sessionExpired
          ? SessionCheck.expired
          : SessionCheck.unknown;
    } catch (_) {
      return SessionCheck.unknown;
    }
  }

  Future<AuthCredential> _googleCredential() async {
    await _ensureGoogleInitialized();
    final account = await GoogleSignIn.instance.authenticate();
    return GoogleAuthProvider.credential(idToken: account.authentication.idToken);
  }

  AuthFailure _toFailure(Object e) {
    if (e is AuthFailure) return e;
    if (e is FirebaseAuthException) return AuthFailure.fromFirebaseCode(e.code);
    if (e is GoogleSignInException) {
      return AuthFailure(
        e.code == GoogleSignInExceptionCode.canceled
            ? AuthFailureKind.cancelled
            : AuthFailureKind.unknown,
        code: e.code.name,
      );
    }
    return AuthFailure(AuthFailureKind.unknown, code: e.runtimeType.toString());
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    if (!kIsWeb) {
      try {
        // So the next login shows the account chooser again.
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
  }

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) return;
    await GoogleSignIn.instance.initialize();
    _googleInitialized = true;
  }

  AppUser? _toAppUser(User? user) {
    if (user == null) return null;
    return AppUser(
      uid: user.uid,
      displayName: user.displayName,
      email: user.email,
      photoUrl: user.photoURL,
      createdAt: user.metadata.creationTime,
      isGoogle: user.providerData.any((info) => info.providerId == 'google.com'),
    );
  }
}
