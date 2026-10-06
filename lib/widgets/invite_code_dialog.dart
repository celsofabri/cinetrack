import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../social/invite_code.dart';

/// "Tenho um convite": paste a link or the bare code and open `/invite/:code`.
/// Nothing is read here; the screen it opens does the one `get`.
Future<void> showUseInviteDialog(BuildContext context) {
  return showDialog<void>(context: context, builder: (_) => const UseInviteDialog());
}

class UseInviteDialog extends StatefulWidget {
  const UseInviteDialog({super.key});

  @override
  State<UseInviteDialog> createState() => _UseInviteDialogState();
}

class _UseInviteDialogState extends State<UseInviteDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    final code = InviteCode.parse(_controller.text);
    if (code == null) {
      setState(() => _error = 'Cole o link ou o código do convite.');
      return;
    }
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.push('/invite/$code');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Usar um convite'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Link ou código do convite',
          border: const OutlineInputBorder(),
          errorText: _error,
          errorMaxLines: 3,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _open(),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _open,
          child: const Text('Abrir convite'),
        ),
      ],
    );
  }
}
