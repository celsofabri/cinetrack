import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/nickname.dart';
import '../providers/account_providers.dart';

/// Edits the app nickname (1-40 characters, trimmed). The Google name is
/// never changed. Saving does not wait for the server (works offline).
Future<void> showNicknameDialog(BuildContext context, {required String? current}) {
  return showDialog<void>(
    context: context,
    builder: (_) => NicknameDialog(current: current),
  );
}

class NicknameDialog extends ConsumerStatefulWidget {
  final String? current;

  const NicknameDialog({super.key, required this.current});

  @override
  ConsumerState<NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends ConsumerState<NicknameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.current);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final error = Nickname.errorFor(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final value = Nickname.normalize(_controller.text)!;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    await ref.read(profileDataSourceProvider).setNickname(value);
    navigator.pop();
    messenger?.showSnackBar(const SnackBar(content: Text('Apelido salvo.')));
  }

  Future<void> _useGoogleName() async {
    final navigator = Navigator.of(context);
    await ref.read(profileDataSourceProvider).setNickname(null);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Apelido'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: Nickname.maxLength,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(
          labelText: 'Como quer ser chamado?',
          helperText: 'Só aparece para você. O nome da sua conta Google não muda.',
          errorText: _error,
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(onPressed: _useGoogleName, child: const Text('Usar nome do Google')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _save, child: const Text('Salvar')),
      ],
    );
  }
}
