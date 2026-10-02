import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/favorites_data_source.dart';
import '../providers/providers.dart';
import '../repositories/favorites_repository.dart';

const kFavoriteUnavailableMessage =
    'Não foi possível acessar seus favoritos agora. Verifique a conexão e tente novamente.';

const kLoginUnavailableMessage =
    'Login indisponível no momento. Você pode continuar explorando o catálogo.';

/// Runs a write ([action]) on the favorites repository. If nobody is signed
/// in (the repository throws [AuthRequiredException]) the action becomes the
/// pending intent and the login flow starts; after a successful login
/// [PendingIntentRunner] replays it, on cancel/failure nothing is saved.
///
/// Uses the provider container and messenger captured up front, so it stays
/// safe if the calling widget is disposed while the login popup is open.
Future<void> runWrite(
  BuildContext context,
  Future<void> Function(FavoritesRepository repo) action,
) async {
  final container = ProviderScope.containerOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await action(container.read(favoritesRepositoryProvider));
  } on AuthRequiredException {
    final intent = PendingIntent(action);
    await signInWithFeedback(container, messenger, intent: intent);
  } on FavoritesUnavailableException {
    // Never a silent no-op: tell the user the action did not happen.
    messenger?.showSnackBar(const SnackBar(content: Text(kFavoriteUnavailableMessage)));
  }
}

/// Starts login and reports failures with a snackbar (neutral for
/// "cancelled", with "Tentar novamente" when retrying makes sense). If login
/// is unavailable in this build, explains it instead of failing.
Future<void> signInWithFeedback(
  ProviderContainer container,
  ScaffoldMessengerState? messenger, {
  PendingIntent? intent,
}) async {
  if (!container.read(authRepositoryProvider).isAvailable) {
    messenger?.showSnackBar(const SnackBar(content: Text(kLoginUnavailableMessage)));
    return;
  }
  container.read(pendingIntentProvider.notifier).state = intent;
  final failure = await container.read(authControllerProvider.notifier).signIn();
  if (failure == null) return;
  messenger?.showSnackBar(
    SnackBar(
      content: Text(failure.message),
      action: failure.retryable
          ? SnackBarAction(
              label: 'Tentar novamente',
              onPressed: () => signInWithFeedback(container, messenger, intent: intent),
            )
          : null,
    ),
  );
}

/// Replays the pending intent when a user becomes signed in. Place once
/// above the screens (MaterialApp `builder`).
class PendingIntentRunner extends ConsumerWidget {
  final Widget child;

  const PendingIntentRunner({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<String?>(currentUidProvider, (previous, next) {
      if (next == null) return;
      final intent = ref.read(pendingIntentProvider);
      if (intent == null) return;
      ref.read(pendingIntentProvider.notifier).state = null;
      // Defer one microtask: while this listener runs, providers that depend
      // on the uid may not have been rebuilt yet, and the replay must hit the
      // NEW account's repository (not the signed-out one).
      Future.microtask(() {
        intent.run(ref.read(favoritesRepositoryProvider)).catchError((Object _) {
          // A failed replay must not crash the app; the user can tap again.
        });
      });
    });
    return child;
  }
}
