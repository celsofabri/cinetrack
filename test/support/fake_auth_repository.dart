import 'dart:async';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/auth/auth_repository.dart';

/// Fictional users only (no real names/e-mails in fixtures).
const kAna = AppUser(uid: 'uid-ana', displayName: 'Ana Teste', email: 'ana@example.test');
const kBruno = AppUser(uid: 'uid-bruno', displayName: 'Bruno Teste');

/// Scriptable [AuthRepository]: no Google, no network.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({AppUser? initialUser, this.available = true}) : _user = initialUser;

  final bool available;
  AppUser? _user;

  AppUser? get currentForTest => _user;
  final _controller = StreamController<AppUser?>.broadcast();

  /// What the next `signInWithGoogle()` does: succeed as [nextUser], or
  /// throw [nextFailure].
  AppUser nextUser = kAna;
  AuthFailure? nextFailure;

  /// When set, sign-in waits for it (to observe the in-progress state).
  Completer<void>? gate;

  int signInCalls = 0;
  int signOutCalls = 0;

  /// What `verifySession()` answers.
  SessionCheck sessionCheck = SessionCheck.valid;

  /// Re-authentication: `reauthFailure` makes it throw; `reauthGate` holds it.
  AuthFailure? reauthFailure;
  Completer<void>? reauthGate;
  int reauthCalls = 0;

  /// `deleteCurrentUser()`: `deleteUserFailure` makes it throw, else the user
  /// is removed (auth state becomes signed out).
  AuthFailure? deleteUserFailure;
  int deleteUserCalls = 0;

  /// Simulates the provider revoking the session (signed out, not by us).
  void revokeSession() {
    _user = null;
    _controller.add(null);
  }

  @override
  bool get isAvailable => available;

  @override
  Stream<AppUser?> authStateChanges() {
    // Subscribes to later changes synchronously on listen (an `async*`
    // generator would subscribe a tick late and could miss an event).
    late final StreamController<AppUser?> out;
    StreamSubscription<AppUser?>? sub;
    out = StreamController<AppUser?>(
      onListen: () {
        out.add(_user);
        sub = _controller.stream.listen(out.add);
      },
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  @override
  Future<AppUser> signInWithGoogle() async {
    signInCalls++;
    final pending = gate;
    if (pending != null) await pending.future;
    final failure = nextFailure;
    if (failure != null) throw failure;
    _user = nextUser;
    _controller.add(_user);
    return nextUser;
  }

  @override
  Future<SessionCheck> verifySession({String? expectedUid}) async {
    final pending = verifyGate;
    if (pending != null) await pending.future;
    if (expectedUid != null && _user?.uid != expectedUid) return SessionCheck.unknown;
    return sessionCheck;
  }

  /// Holds `verifySession()` (to test a check that is still in flight).
  Completer<void>? verifyGate;

  /// What `userStillExists()` answers; null = derived from the signed-in user.
  bool? userExistsAnswer;
  bool useExistsAnswer = false;

  @override
  Future<bool?> userStillExists(String uid) async =>
      useExistsAnswer ? userExistsAnswer : _user?.uid == uid;

  /// Simulates another tab switching the shared session to [user].
  void switchSessionTo(AppUser user) {
    _user = user;
    _controller.add(user);
  }

  @override
  Future<void> reauthenticate(String expectedUid) async {
    reauthCalls++;
    if (_user == null) throw const AuthFailure(AuthFailureKind.sessionExpired);
    if (_user!.uid != expectedUid) {
      throw const AuthFailure(AuthFailureKind.wrongAccount);
    }
    final pending = reauthGate;
    if (pending != null) await pending.future;
    final failure = reauthFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> deleteCurrentUser(String expectedUid) async {
    deleteUserCalls++;
    if (_user == null) throw const AuthFailure(AuthFailureKind.sessionExpired);
    if (_user!.uid != expectedUid) throw const AuthFailure(AuthFailureKind.wrongAccount);
    final failure = deleteUserFailure;
    if (failure != null) throw failure;
    _user = null;
    _controller.add(null);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _user = null;
    _controller.add(null);
  }
}
