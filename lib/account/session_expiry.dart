import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';

/// True when the user was signed out WITHOUT asking for it (token revoked or
/// expired): the app then says "Sessão expirada, entre novamente". Pending
/// changes stay in the local database and are sent after signing in again
/// with the same account.
///
/// Explicit sign-outs (button, account deletion) call [expectSignOut] first.
/// Must stay watched (the banner at the app root does it).
class SessionExpiryNotifier extends Notifier<bool> {
  bool _expected = false;

  @override
  bool build() {
    ref.listen<String?>(currentUidProvider, (previous, next) {
      if (next != null) {
        _expected = false;
        state = false;
      } else if (previous != null) {
        state = !_expected;
        _expected = false;
      }
    });
    return false;
  }

  /// The next transition to signed-out is on purpose.
  void expectSignOut() => _expected = true;

  /// Undo [expectSignOut] (the sign-out did not happen).
  void cancelExpectedSignOut() => _expected = false;
}

final sessionExpiryProvider =
    NotifierProvider<SessionExpiryNotifier, bool>(SessionExpiryNotifier.new);
