enum AccountDeletionFailureKind {
  /// No connection: nothing was deleted (or the operation can be repeated).
  offline,

  /// The user closed the Google re-authentication window.
  cancelled,

  /// Re-authenticated with a different Google account than the signed-in one.
  wrongAccount,
  popupBlocked,
  sessionExpired,
  quotaExceeded,

  /// A write did not get confirmed in time. The SDK keeps it queued and will
  /// send it when the connection returns, so the deletion may have started
  /// (or may even finish by itself): never say "nothing was deleted".
  uncertain,
  unknown,
}

/// Why deleting the account failed. Every step of the deletion is
/// idempotent, so after any failure the user can simply try again.
class AccountDeletionFailure implements Exception {
  final AccountDeletionFailureKind kind;

  /// Provider error code (safe to log; never PII).
  final String? code;

  const AccountDeletionFailure(this.kind, {this.code});

  /// Maps a Firestore error code.
  factory AccountDeletionFailure.fromFirestoreCode(String code) => switch (code) {
        'unavailable' ||
        'deadline-exceeded' ||
        'cancelled' =>
          AccountDeletionFailure(AccountDeletionFailureKind.offline, code: code),
        'resource-exhausted' =>
          AccountDeletionFailure(AccountDeletionFailureKind.quotaExceeded, code: code),
        'unauthenticated' =>
          AccountDeletionFailure(AccountDeletionFailureKind.sessionExpired, code: code),
        _ => AccountDeletionFailure(AccountDeletionFailureKind.unknown, code: code),
      };

  String get message => switch (kind) {
        AccountDeletionFailureKind.offline =>
          'Você precisa estar online para excluir a conta. Conecte-se e tente novamente.',
        AccountDeletionFailureKind.uncertain =>
          'Não conseguimos confirmar a exclusão por falta de conexão. Ela pode ter sido iniciada '
              'e ser concluída quando a conexão voltar. Reconecte e repita a exclusão para '
              'confirmar.',
        AccountDeletionFailureKind.cancelled =>
          'A confirmação com o Google foi cancelada. Nada foi apagado.',
        AccountDeletionFailureKind.wrongAccount =>
          'Entre com a mesma conta Google que está conectada para confirmar a exclusão.',
        AccountDeletionFailureKind.popupBlocked =>
          'O navegador bloqueou a janela de confirmação. Permita pop-ups e tente novamente.',
        AccountDeletionFailureKind.sessionExpired =>
          'Sessão expirada. Entre novamente e repita a exclusão.',
        AccountDeletionFailureKind.quotaExceeded =>
          'O limite diário do serviço foi atingido. Tente novamente mais tarde.',
        AccountDeletionFailureKind.unknown => 'Não foi possível excluir. Tente novamente.',
      };

  @override
  String toString() => 'AccountDeletionFailure($kind, code: $code)';
}
