import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_deleter.dart';
import '../providers/account_providers.dart';

/// Confirmation + progress for deleting the account and all data.
/// Pops with `true` once the account is gone.
///
/// Accessibility: focus starts on the SAFE button ("Cancelar"), Esc closes
/// the dialog (unless a deletion is running), Tab/Enter/Space work as on any
/// dialog; status and errors are announced as live regions.
Future<bool> showDeleteAccountDialog(BuildContext context) async {
  final deleted = await showDialog<bool>(
    context: context,
    builder: (_) => const DeleteAccountDialog(),
  );
  return deleted ?? false;
}

class DeleteAccountDialog extends ConsumerWidget {
  const DeleteAccountDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accountControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    Future<void> confirm() async {
      final navigator = Navigator.of(context);
      // Straight from the tap: the controller opens the Google
      // re-authentication synchronously (web popup rule).
      final deleted = await ref.read(accountControllerProvider.notifier).deleteAccount();
      if (deleted) navigator.pop(true);
    }

    return PopScope(
      canPop: !state.running,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(accountControllerProvider.notifier).clearFailure();
      },
      child: AlertDialog(
        title: const Text('Excluir conta e dados?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Isso apaga para sempre seus favoritos, suas recomendações, seu progresso e seu '
                'apelido, e exclui sua conta do CineTrack. Não dá para desfazer.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Por segurança, vamos pedir para você entrar com o Google de novo. Você precisa '
                'estar online.',
              ),
              if (state.running) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Semantics(liveRegion: true, child: Text(_stepLabel(state.step))),
              ],
              if (state.failure != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(state.failure!.message, style: TextStyle(color: scheme.error)),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: state.running ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: state.running ? null : confirm,
            child: Text(state.failure == null ? 'Excluir minha conta e dados' : 'Tentar novamente'),
          ),
        ],
      ),
    );
  }

  String _stepLabel(AccountDeletionStep? step) => switch (step) {
        AccountDeletionStep.reauthenticating => 'Confirmando sua identidade com o Google...',
        AccountDeletionStep.deletingData => 'Apagando seus dados...',
        AccountDeletionStep.deletingAccount => 'Excluindo a conta...',
        null => 'Excluindo...',
      };
}
