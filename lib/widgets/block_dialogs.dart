import 'package:flutter/material.dart';

/// Confirmation before blocking (docs/50 §12, docs/65). Says plainly what
/// happens, including what does NOT: the person is not told, and unblocking
/// does not bring the friendship back. The initial focus is on "Cancelar"
/// and Esc closes (both are the Material defaults of `showDialog`).
Future<bool> confirmBlock(BuildContext context, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text('Bloquear $name?'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('O que acontece:'),
              SizedBox(height: 8),
              Text('• Vocês deixam de ser amigos, se eram.'),
              Text('• Os pedidos pendentes entre vocês, nos dois sentidos, são cancelados.'),
              Text('• A pessoa não é avisada.'),
              Text('• Ela não encontra mais você na busca e não consegue enviar pedidos.'),
              SizedBox(height: 8),
              Text(
                'Você pode desbloquear depois em Amigos > Bloqueados, mas a amizade não volta: '
                'seria preciso enviar e aceitar um novo pedido.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Bloquear'),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

/// Light confirmation before unblocking: nothing is restored and nobody is told.
Future<bool> confirmUnblock(BuildContext context, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Desbloquear $name?'),
      content: const Text(
        'A pessoa poderá encontrar você na busca e enviar um novo pedido. '
        'A amizade e os pedidos de antes não voltam. Ela não será avisada.',
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Desbloquear'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
