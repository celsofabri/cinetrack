import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/auth_failure.dart';

void main() {
  test('maps Firebase auth codes to typed failures', () {
    AuthFailureKind kind(String code) => AuthFailure.fromFirebaseCode(code).kind;

    expect(kind('popup-closed-by-user'), AuthFailureKind.cancelled);
    expect(kind('cancelled-popup-request'), AuthFailureKind.cancelled);
    expect(kind('popup-blocked'), AuthFailureKind.popupBlocked);
    expect(kind('network-request-failed'), AuthFailureKind.network);
    expect(kind('unauthorized-domain'), AuthFailureKind.unauthorizedDomain);
    expect(kind('something-else'), AuthFailureKind.unknown);
  });

  test('messages are in Portuguese and only transient failures are retryable', () {
    expect(const AuthFailure(AuthFailureKind.network).message,
        'Sem conexão. Conecte-se à internet para entrar.');
    expect(const AuthFailure(AuthFailureKind.network).retryable, isTrue);
    expect(const AuthFailure(AuthFailureKind.popupBlocked).retryable, isTrue);
    expect(const AuthFailure(AuthFailureKind.cancelled).retryable, isFalse);
    expect(const AuthFailure(AuthFailureKind.unauthorizedDomain).retryable, isFalse);
  });
}
