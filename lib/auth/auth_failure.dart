enum AuthFailureKind {
  /// The user closed the account chooser / popup. Not an error.
  cancelled,
  network,
  popupBlocked,
  unauthorizedDomain,

  /// Firebase is not configured in this build (or cloud sync is off).
  unavailable,

  /// Re-authentication was done with a different account than the signed-in one.
  wrongAccount,

  /// The session is no longer valid (token revoked/expired, user disabled).
  sessionExpired,
  unknown,
}

/// Typed login failure. [code] is the provider's error code (safe to log:
/// never contains e-mail, name or token).
class AuthFailure implements Exception {
  final AuthFailureKind kind;
  final String? code;

  const AuthFailure(this.kind, {this.code});

  /// Maps a `FirebaseAuthException.code`.
  factory AuthFailure.fromFirebaseCode(String code) {
    switch (code) {
      case 'popup-closed-by-user':
      case 'cancelled-popup-request':
      case 'web-context-canceled':
      case 'user-cancelled':
        return AuthFailure(AuthFailureKind.cancelled, code: code);
      case 'popup-blocked':
        return AuthFailure(AuthFailureKind.popupBlocked, code: code);
      case 'network-request-failed':
        return AuthFailure(AuthFailureKind.network, code: code);
      case 'unauthorized-domain':
        return AuthFailure(AuthFailureKind.unauthorizedDomain, code: code);
      case 'user-mismatch':
      case 'wrong-account':
        return AuthFailure(AuthFailureKind.wrongAccount, code: code);
      case 'user-token-expired':
      case 'invalid-user-token':
      case 'user-disabled':
      case 'user-not-found':
      case 'requires-recent-login':
        return AuthFailure(AuthFailureKind.sessionExpired, code: code);
      default:
        return AuthFailure(AuthFailureKind.unknown, code: code);
    }
  }

  /// pt-BR text for the snackbar. `null` for [AuthFailureKind.cancelled]
  /// callers show the neutral "Login cancelado." instead (see [message]).
  String get message => switch (kind) {
        AuthFailureKind.cancelled => 'Login cancelado.',
        AuthFailureKind.network => 'Sem conexão. Conecte-se à internet para entrar.',
        AuthFailureKind.popupBlocked =>
          'O navegador bloqueou a janela de login. Permita pop-ups para este site e tente novamente.',
        AuthFailureKind.unauthorizedDomain =>
          'Este endereço não está autorizado para login. Avise quem mantém o app.',
        AuthFailureKind.unavailable => 'Login indisponível no momento.',
        AuthFailureKind.wrongAccount => 'Entre com a mesma conta Google que está conectada.',
        AuthFailureKind.sessionExpired => 'Sessão expirada. Entre novamente.',
        AuthFailureKind.unknown => 'Não foi possível entrar. Tente novamente.',
      };

  /// Whether offering "Tentar novamente" makes sense.
  bool get retryable =>
      kind == AuthFailureKind.network ||
      kind == AuthFailureKind.popupBlocked ||
      kind == AuthFailureKind.unknown;

  @override
  String toString() => 'AuthFailure($kind, code: $code)';
}
