import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/account_providers.dart';
import '../providers/providers.dart';
import '../providers/social_providers.dart';
import '../social/social_models.dart';
import '../social/social_validation.dart';

/// Opt-in form: handle, nickname, photo and "Aparecer na busca". Nothing is
/// copied anywhere until the user taps "Ativar amizades".
Future<void> showActivateSocialDialog(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => const ActivateSocialDialog(),
  );
  if (done == true) messenger?.showSnackBar(const SnackBar(content: Text('Amizades ativadas.')));
}

Future<void> showChangeHandleDialog(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final done = await showDialog<bool>(context: context, builder: (_) => const ChangeHandleDialog());
  if (done == true) {
    messenger?.showSnackBar(const SnackBar(content: Text('Identificador alterado.')));
  }
}

Future<void> showDeactivateSocialDialog(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => const DeactivateSocialDialog(),
  );
  if (done == true) messenger?.showSnackBar(const SnackBar(content: Text('Amizades desativadas.')));
}

class _Failure extends StatelessWidget {
  final String text;

  const _Failure(this.text);

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error)),
  );
}

class ActivateSocialDialog extends ConsumerStatefulWidget {
  const ActivateSocialDialog({super.key});

  @override
  ConsumerState<ActivateSocialDialog> createState() => _ActivateSocialDialogState();
}

class _ActivateSocialDialogState extends ConsumerState<ActivateSocialDialog> {
  final _handle = TextEditingController();
  late final TextEditingController _nickname = TextEditingController(
    text: ref.read(profileProvider).valueOrNull?.nickname ?? '',
  );
  final _nicknameFocus = FocusNode();
  late bool _showPhoto = _photoAvailable;
  bool _discoverable = kDiscoverableByDefault;
  bool _busy = false;
  String? _handleError;
  String? _nicknameError;
  String? _failure;

  bool get _photoAvailable => SocialPhoto.sanitize(ref.read(currentUserProvider)?.photoUrl) != null;

  @override
  void dispose() {
    _handle.dispose();
    _nickname.dispose();
    _nicknameFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final handleError = Handle.errorFor(_handle.text);
    final nicknameError = SocialNickname.errorFor(_nickname.text);
    if (handleError != null || nicknameError != null) {
      setState(() {
        _handleError = handleError;
        _nicknameError = nicknameError;
      });
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await ref
        .read(socialControllerProvider.notifier)
        .activate(
          handle: _handle.text,
          nickname: _nickname.text,
          showPhoto: _showPhoto && _photoAvailable,
          discoverable: _discoverable,
        );
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      if (failure.kind == SocialFailureKind.handleTaken) {
        _handleError = failure.message;
      } else {
        _failure = failure.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final googleName = user?.displayName?.trim();
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Ativar amizades'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _handle,
              autofocus: true,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _nicknameFocus.requestFocus(),
              onChanged: (_) {
                if (_handleError != null) setState(() => _handleError = null);
              },
              decoration: InputDecoration(
                labelText: 'Identificador',
                prefixText: '@',
                helperText: '3 a 20 letras minúsculas, números ou _. Único no CineTrack.',
                helperMaxLines: 3,
                errorText: _handleError,
                errorMaxLines: 3,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nickname,
              focusNode: _nicknameFocus,
              enabled: !_busy,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_nicknameError != null) setState(() => _nicknameError = null);
              },
              decoration: InputDecoration(
                labelText: 'Apelido público',
                helperText: 'É o nome que outras pessoas veem (até 40 caracteres).',
                helperMaxLines: 3,
                errorText: _nicknameError,
                errorMaxLines: 3,
              ),
            ),
            if (googleName != null && googleName.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _nickname.text = SocialNickname.clean(googleName);
                          _nicknameError = null;
                        }),
                  icon: const Icon(Icons.person_outline),
                  label: const Text('Usar meu nome do Google'),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mostrar minha foto do Google'),
              subtitle: Text(
                _photoAvailable
                    ? 'Copiamos o endereço da sua foto para o seu cartão.'
                    : 'Sua conta não tem uma foto que possamos usar. Aparecem as iniciais.',
              ),
              value: _showPhoto && _photoAvailable,
              onChanged: _busy || !_photoAvailable ? null : (v) => setState(() => _showPhoto = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Aparecer na busca'),
              subtitle: const Text('Quem digitar seu identificador exato vê seu apelido e foto.'),
              value: _discoverable,
              onChanged: _busy ? null : (v) => setState(() => _discoverable = v),
            ),
            const SizedBox(height: 8),
            Text(
              'Ao ativar, copiamos seu identificador, seu apelido e (se você deixar marcado) o '
              'endereço da sua foto do Google para o banco de dados do CineTrack. Seus favoritos, '
              'recomendações e progresso continuam privados. Você pode desativar quando quiser e '
              'tudo isso é apagado.',
              style: theme.textTheme.bodySmall,
            ),
            if (_busy) ...[const SizedBox(height: 12), const LinearProgressIndicator()],
            if (_failure != null) ...[const SizedBox(height: 12), _Failure(_failure!)],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(onPressed: _busy ? null : _submit, child: const Text('Ativar amizades')),
        ],
      ),
    );
  }
}

class ChangeHandleDialog extends ConsumerStatefulWidget {
  const ChangeHandleDialog({super.key});

  @override
  ConsumerState<ChangeHandleDialog> createState() => _ChangeHandleDialogState();
}

class _ChangeHandleDialogState extends ConsumerState<ChangeHandleDialog> {
  final _handle = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _failure;

  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final error = Handle.errorFor(_handle.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await ref.read(socialControllerProvider.notifier).changeHandle(_handle.text);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      if (failure.kind == SocialFailureKind.handleTaken ||
          failure.kind == SocialFailureKind.invalid) {
        _error = failure.message;
      } else {
        _failure = failure.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(socialControllerProvider).profile?.handle;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Trocar identificador'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (current != null) Text('Atual: @$current'),
            const SizedBox(height: 8),
            TextField(
              controller: _handle,
              autofocus: true,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                labelText: 'Novo identificador',
                prefixText: '@',
                helperText: '3 a 20 letras minúsculas, números ou _.',
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Você só pode trocar o identificador uma vez a cada $kHandleChangeIntervalDays '
              'dias. O identificador antigo fica livre para outras pessoas. Seus amigos '
              'continuam amigos.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_busy) ...[const SizedBox(height: 12), const LinearProgressIndicator()],
            if (_failure != null) ...[const SizedBox(height: 12), _Failure(_failure!)],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(onPressed: _busy ? null : _submit, child: const Text('Trocar')),
        ],
      ),
    );
  }
}

/// Confirmation that says exactly what is erased. Focus starts on the SAFE
/// button ("Cancelar"); Esc closes unless the work is running.
class DeactivateSocialDialog extends ConsumerStatefulWidget {
  const DeactivateSocialDialog({super.key});

  @override
  ConsumerState<DeactivateSocialDialog> createState() => _DeactivateSocialDialogState();
}

class _DeactivateSocialDialogState extends ConsumerState<DeactivateSocialDialog> {
  bool _busy = false;
  String? _failure;

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await ref.read(socialControllerProvider.notifier).deactivate();
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Desativar amizades?'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Vamos apagar para sempre: seu identificador, seu cartão de busca (apelido e foto), '
              'todos os seus amigos, os pedidos de amizade enviados e recebidos, seus bloqueios e '
              'seu convite. Seus amigos deixam de ver você, sem aviso.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Seus favoritos, recomendações e progresso não mudam. Você precisa estar online. '
              'Se ativar de novo depois, terá de refazer as amizades.',
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Semantics(liveRegion: true, child: const Text('Apagando seus dados sociais...')),
            ],
            if (_failure != null) ...[const SizedBox(height: 12), _Failure(_failure!)],
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: _busy ? null : _confirm,
            child: Text(_failure == null ? 'Desativar amizades' : 'Tentar de novo'),
          ),
        ],
      ),
    );
  }
}
