import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/session_expiry.dart';
import '../data/sync_status.dart';
import '../providers/account_providers.dart';
import '../providers/providers.dart';
import '../providers/sync_providers.dart';
import 'auth_gate.dart';

/// Small cloud icon in the top bar: synced / syncing / offline / problem.
/// Discreet on purpose (the details live in the banner); the tooltip doubles
/// as the screen-reader label.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    if (!status.signedIn) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (status.phase) {
      SyncPhase.failed => (Icons.sync_problem, 'Problema ao sincronizar', scheme.error),
      SyncPhase.offline => (
          Icons.cloud_off_outlined,
          status.hasPendingWrites
              ? 'Sem conexão. Alterações pendentes serão enviadas ao reconectar.'
              : 'Sem conexão. Mostrando dados deste aparelho.',
          scheme.outline,
        ),
      SyncPhase.pending => (
          Icons.cloud_upload_outlined,
          'Sincronizando alterações',
          scheme.primary
        ),
      SyncPhase.stalled => (
          Icons.sync_problem,
          'Não conseguimos confirmar suas alterações',
          scheme.tertiary,
        ),
      SyncPhase.connecting => (Icons.sync, 'Conectando', scheme.outline),
      SyncPhase.synced => (Icons.cloud_done_outlined, 'Sincronizado', scheme.outline),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(icon, size: 20, color: color),
          ),
        ),
      ),
    );
  }
}

/// Bottom strip for things the user must know: expired session, a write the
/// server refused, an account deletion left half-done. One message at a time
/// (the most urgent). Placed once above the screens (MaterialApp `builder`).
class SyncBanner extends ConsumerWidget {
  /// Opens the profile (where an interrupted deletion is resumed).
  final VoidCallback? onOpenProfile;

  const SyncBanner({super.key, this.onOpenProfile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    final expiredSignOut = ref.watch(sessionExpiryProvider);
    final user = ref.watch(currentUserProvider);
    final deleting = ref.watch(profileProvider).valueOrNull?.deleting ?? false;
    final running = ref.watch(accountControllerProvider).running;

    final failure = status.failure;
    final sessionExpired =
        expiredSignOut || (failure != null && failure.kind == SyncFailureKind.sessionExpired);

    _Banner? banner;
    if (sessionExpired) {
      banner = _Banner(
        message: SyncFailure.fromCode('unauthenticated').message,
        action: 'Entrar',
        onAction: () async {
          await signInWithFeedback(
            ProviderScope.containerOf(context),
            ScaffoldMessenger.maybeOf(context),
          );
          if (ref.read(currentUserProvider) != null) {
            ref.read(syncStatusProvider.notifier).dismissFailure();
          }
        },
      );
    } else if (user != null && deleting && !running) {
      banner = _Banner(
        message: 'A exclusão da sua conta ficou pela metade. Conclua para apagar tudo.',
        action: 'Concluir',
        onAction: onOpenProfile,
      );
    } else if (failure != null) {
      banner = _Banner(
        message: failure.message,
        action: 'Entendi',
        onAction: () => ref.read(syncStatusProvider.notifier).dismissFailure(),
      );
    } else if (status.phase == SyncPhase.stalled) {
      // Goes away by itself when the server finally acknowledges.
      banner = const _Banner(message: SyncStatus.stalledMessage, action: '', onAction: null);
    }
    if (banner == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        top: false,
        child: Semantics(
          liveRegion: true,
          container: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: scheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(banner.message, style: TextStyle(color: scheme.onErrorContainer)),
                ),
                if (banner.onAction != null)
                  TextButton(onPressed: banner.onAction, child: Text(banner.action)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner {
  final String message;
  final String action;
  final VoidCallback? onAction;

  const _Banner({required this.message, required this.action, required this.onAction});
}

/// Shown instead of the favorites list/empty state when the first load did
/// not get a server answer ("could not load" is not "no favorites").
class FavoritesLoadError extends ConsumerWidget {
  /// Compact card (home) instead of the full-screen state.
  final bool compact;

  const FavoritesLoadError({super.key, this.compact = false});

  static const message =
      'Não foi possível carregar seus favoritos agora. Verifique a conexão e tente novamente.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void retry() => retrySync(ref);
    if (!compact) {
      return Semantics(
        liveRegion: true,
        child: _FullError(onRetry: retry),
      );
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(message),
            FilledButton.tonal(onPressed: retry, child: const Text('Tentar novamente')),
          ],
        ),
      ),
    );
  }
}

class _FullError extends StatelessWidget {
  final VoidCallback onRetry;

  const _FullError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            const Text(FavoritesLoadError.message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Tentar novamente')),
          ],
        ),
      ),
    );
  }
}
