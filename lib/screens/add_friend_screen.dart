import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/social_lists_providers.dart';
import '../providers/social_providers.dart';
import '../providers/sync_providers.dart';
import '../repositories/social_repository.dart';
import '../social/social_models.dart';
import '../social/social_validation.dart';
import '../widgets/app_shell.dart';
import '../widgets/person_avatar.dart';
import '../widgets/social_gate.dart';

/// "Adicionar amigo" (`/friends/add`): exact search by handle and "Enviar
/// pedido". Opening it reads NOTHING; one `get` happens per search (docs/59).
class AddFriendScreen extends StatelessWidget {
  const AddFriendScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final inShell = MobileShellScope.active(context);
    return Scaffold(
      appBar: inShell ? null : detailAppBar(context, title: 'Adicionar amigo'),
      body: SocialGate(
        active: (context, profile) => _AddFriendBody(profile: profile, showTitle: inShell),
      ),
    );
  }
}

enum _Phase { idle, searching, found, notFound, failed }

enum _Send { ready, sending, sent, befriended, alreadySent, alreadyFriends, failed }

class _AddFriendBody extends ConsumerStatefulWidget {
  final SocialProfile profile;
  final bool showTitle;

  const _AddFriendBody({required this.profile, required this.showTitle});

  @override
  ConsumerState<_AddFriendBody> createState() => _AddFriendBodyState();
}

class _AddFriendBodyState extends ConsumerState<_AddFriendBody> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  _Phase _phase = _Phase.idle;
  _Send _send = _Send.ready;
  FriendCard? _card;
  SocialFailure? _failure;
  SocialFailure? _sendFailure;

  /// Normalized handle of the search that produced the current result.
  String? _searched;
  int _generation = 0;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _text => _controller.text;
  String? get _error => _text.trim().isEmpty ? null : Handle.searchErrorFor(_text);
  bool get _valid => _text.trim().isNotEmpty && Handle.searchErrorFor(_text) == null;

  void _onChanged(String _) {
    // A result belongs to what was typed when it was searched.
    final changed = _phase != _Phase.searching && Handle.normalize(_text) != _searched;
    setState(() {
      if (changed && _phase != _Phase.idle) {
        _phase = _Phase.idle;
        _card = null;
        _failure = null;
        _sendFailure = null;
        _send = _Send.ready;
      }
    });
  }

  Future<void> _search() async {
    final offline = ref.read(syncStatusProvider).offline;
    if (!_valid || _phase == _Phase.searching || offline) return;
    final generation = ++_generation;
    final handle = Handle.normalize(_text);
    setState(() {
      _phase = _Phase.searching;
      _card = null;
      _failure = null;
      _sendFailure = null;
      _send = _Send.ready;
      _searched = handle;
    });
    try {
      final outcome = await ref
          .read(socialRepositoryProvider)
          .search(handle, ownHandle: widget.profile.handle);
      if (!mounted || generation != _generation) return;
      setState(() {
        switch (outcome) {
          case SearchFound(:final card):
            _card = card;
            _phase = _Phase.found;
            // Free: the list may already be in memory; if not, the send
            // transaction detects it.
            _send = ref.read(friendsControllerProvider.notifier).contains(card.uid)
                ? _Send.alreadyFriends
                : ref.read(sentRequestsControllerProvider).contains(card.uid)
                ? _Send.alreadySent
                : _Send.ready;
          case SearchNotFound():
            _phase = _Phase.notFound;
        }
      });
    } on SocialFailure catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failure = e;
        _phase = _Phase.failed;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failure = const SocialFailure(SocialFailureKind.unknown);
        _phase = _Phase.failed;
      });
    }
  }

  Future<void> _sendRequest() async {
    final card = _card;
    if (card == null || _send == _Send.sending) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _send = _Send.sending;
      _sendFailure = null;
    });
    final result = await ref.read(sentRequestsControllerProvider.notifier).send(card);
    final failure = result.failure;
    if (!mounted) return;
    final friends = result.outcome == SendOutcome.becameFriends;
    setState(() {
      if (failure == null) {
        _send = friends ? _Send.befriended : _Send.sent;
      } else if (failure.kind == SocialFailureKind.alreadySent) {
        _send = _Send.alreadySent;
      } else {
        _send = _Send.failed;
        _sendFailure = failure;
      }
    });
    if (failure == null) {
      messenger?.showSnackBar(
        SnackBar(content: Text(friends ? 'Amizade aceita.' : 'Pedido enviado.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offline = ref.watch(syncStatusProvider).offline;
    final canSearch = _valid && _phase != _Phase.searching && !offline;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kFriendsMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.showTitle)
              Row(
                children: [
                  IconButton(
                    tooltip: 'Voltar para Amigos',
                    style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => context.canPop() ? context.pop() : context.go('/friends'),
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text('Adicionar amigo', style: theme.textTheme.headlineSmall),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            const Text(
              'Digite o identificador exato da pessoa. Só aparece quem escolheu aparecer na busca.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.search,
              keyboardType: TextInputType.text,
              inputFormatters: [LengthLimitingTextInputFormatter(64)],
              decoration: InputDecoration(
                labelText: 'Identificador',
                prefixText: '@',
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 3,
              ),
              onChanged: _onChanged,
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: canSearch ? _search : null,
              icon: const Icon(Icons.search),
              label: const Text('Buscar'),
            ),
            if (offline) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  'Sem conexão. Tente de novo quando estiver online.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Fixed minimum height: the result area does not push the page around.
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 180),
              child: _result(context, offline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _result(BuildContext context, bool offline) {
    final theme = Theme.of(context);
    switch (_phase) {
      case _Phase.idle:
        return Text(
          'O resultado aparece aqui. O identificador tem de 3 a 20 letras minúsculas, '
          'números ou _.',
          style: theme.textTheme.bodySmall,
        );
      case _Phase.searching:
        return Semantics(
          liveRegion: true,
          label: 'Buscando',
          child: const Row(
            children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 16),
              Expanded(child: Text('Buscando...')),
            ],
          ),
        );
      case _Phase.notFound:
        return Semantics(liveRegion: true, child: const Text(kSearchNotFoundMessage));
      case _Phase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                _failure?.message ?? const SocialFailure(SocialFailureKind.unknown).message,
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: offline ? null : _search,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar de novo'),
            ),
          ],
        );
      case _Phase.found:
        return _FoundCard(
          card: _card!,
          send: _send,
          failure: _sendFailure,
          offline: offline,
          onSend: _sendRequest,
        );
    }
  }
}

class _FoundCard extends StatelessWidget {
  final FriendCard card;
  final _Send send;
  final SocialFailure? failure;
  final bool offline;
  final VoidCallback onSend;

  const _FoundCard({
    required this.card,
    required this.send,
    required this.failure,
    required this.offline,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = 'Enviar pedido para @${card.handle}';
    final stopped = failure?.kind == SocialFailureKind.limitReached;
    final showButton =
        send == _Send.ready || send == _Send.sending || (send == _Send.failed && !stopped);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PersonAvatar(photoUrl: card.photoUrl, nickname: card.nickname),
                const SizedBox(width: 16),
                Expanded(
                  child: MergeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(card.nickname, style: theme.textTheme.titleMedium),
                        Text('@${card.handle}'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (showButton)
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: send == _Send.sending || offline ? null : onSend,
                icon: send == _Send.sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.person_add_alt_1_outlined),
                label: Text(
                  send == _Send.sending ? 'Enviando...' : 'Enviar pedido',
                  semanticsLabel: send == _Send.sending
                      ? 'Enviando pedido para @${card.handle}'
                      : label,
                ),
              ),
            if (send == _Send.sent) ...[
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Pedido enviado')),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => context.go('/friends?tab=pedidos'),
                  child: const Text('Ver pedidos enviados'),
                ),
              ),
            ],
            if (send == _Send.befriended) ...[
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Essa pessoa já tinha pedido a sua amizade. Vocês agora são amigos.',
                      ),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => context.go('/friends'),
                  child: const Text('Ver amigos'),
                ),
              ),
            ],
            if (send == _Send.alreadyFriends)
              Semantics(liveRegion: true, child: const Text('Vocês já são amigos.')),
            if (send == _Send.alreadySent)
              Semantics(
                liveRegion: true,
                child: Text(const SocialFailure(SocialFailureKind.alreadySent).message),
              ),
            if (send == _Send.failed && failure != null) ...[
              if (showButton) const SizedBox(height: 8),
              Semantics(liveRegion: true, child: Text(failure!.message)),
            ],
            if (offline && showButton) ...[
              const SizedBox(height: 8),
              const Text('Sem conexão. Tente de novo quando estiver online.'),
            ],
          ],
        ),
      ),
    );
  }
}
