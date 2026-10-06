import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/providers.dart';
import '../providers/social_lists_providers.dart';
import '../providers/social_providers.dart';
import '../providers/sync_providers.dart';
import '../repositories/social_repository.dart';
import '../social/social_models.dart';
import '../widgets/app_shell.dart';
import '../widgets/auth_gate.dart';
import '../widgets/person_avatar.dart';
import '../widgets/social_dialogs.dart';
import '../widgets/social_gate.dart' show kFriendsMaxWidth;

/// `/invite/:code`: somebody's invite link (docs/68). Public route: signed out
/// the code stays in the address (the login popup keeps the page), so after
/// signing in, and after turning friendships on if needed, the same screen
/// continues. Opening it costs ONE `get` of `invites/{code}`, only for someone
/// signed in with friendships on. It shows the card and "Enviar pedido": a
/// NORMAL request, never a friendship. Anything that prevents it (bad code,
/// revoked, expired, blocked, your own...) is the same single message.
class InviteScreen extends StatelessWidget {
  final String code;

  const InviteScreen({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    final inShell = MobileShellScope.active(context);
    return Scaffold(
      appBar: inShell ? null : detailAppBar(context, title: 'Convite'),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kFriendsMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (inShell)
                Semantics(
                  header: true,
                  child: Text('Convite', style: Theme.of(context).textTheme.headlineSmall),
                ),
              if (inShell) const SizedBox(height: 8),
              _Gate(code: code),
            ],
          ),
        ),
      ),
    );
  }
}

class _Gate extends ConsumerWidget {
  final String code;

  const _Gate({required this.code});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(socialControllerProvider);
    ref.read(socialControllerProvider.notifier).confirm();
    final profile = state.profile;
    switch (state.phase) {
      case SocialPhase.active when profile != null:
        return _Opened(key: ValueKey('${profile.handle}:$code'), code: code);
      case SocialPhase.loading:
        return const _Note(message: 'Carregando...', busy: true);
      case SocialPhase.signedOut:
        return _Note(
          icon: Icons.mail_outline,
          message:
              'Você recebeu um convite de amizade no CineTrack. Entre com sua conta Google para vê-lo.',
          action: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: ref.watch(authControllerProvider).signingIn
                ? null
                : () => signInWithFeedback(
                    ProviderScope.containerOf(context),
                    ScaffoldMessenger.maybeOf(context),
                  ),
            icon: const Icon(Icons.login),
            label: const Text('Entrar com o Google'),
          ),
        );
      case SocialPhase.notGoogle:
        return const _Note(
          icon: Icons.info_outline,
          message: 'Amizades só estão disponíveis para contas que entraram com o Google.',
        );
      case SocialPhase.unavailable || SocialPhase.loadFailed || SocialPhase.active:
        return _Note(
          icon: Icons.cloud_off_outlined,
          live: true,
          message: state.failure?.message ?? const SocialFailure(SocialFailureKind.unknown).message,
          action: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => ref.read(socialControllerProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar de novo'),
          ),
        );
      case SocialPhase.inactive:
        final offline = ref.watch(syncStatusProvider).offline;
        return _Note(
          icon: Icons.people_outline,
          message:
              'Para usar este convite, ative as amizades. Só então seu apelido e sua foto ficam '
              'visíveis, e apenas para quem você aceitar. O convite continua aqui depois.',
          action: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: state.busy || offline ? null : () => showActivateSocialDialog(context),
            icon: const Icon(Icons.people_outline),
            label: const Text('Ativar amizades'),
          ),
        );
    }
  }
}

class _Note extends StatelessWidget {
  final IconData? icon;
  final String message;
  final Widget? action;
  final bool live;
  final bool busy;

  const _Note({
    this.icon,
    required this.message,
    this.action,
    this.live = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          if (busy)
            const SizedBox(width: 32, height: 32, child: CircularProgressIndicator())
          else if (icon != null)
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: live || busy,
            child: Text(message, textAlign: TextAlign.center),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

enum _Phase { loading, found, unavailable, failed }

enum _Send { ready, sending, sent, befriended, alreadySent, alreadyFriends, failed }

/// Signed in with friendships on: opens the invite (one `get`) and offers the request.
class _Opened extends ConsumerStatefulWidget {
  final String code;

  const _Opened({super.key, required this.code});

  @override
  ConsumerState<_Opened> createState() => _OpenedState();
}

class _OpenedState extends ConsumerState<_Opened> {
  _Phase _phase = _Phase.loading;
  _Send _send = _Send.ready;
  FriendCard? _card;
  SocialFailure? _failure;
  SocialFailure? _sendFailure;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_open);
  }

  Future<void> _open() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _phase = _Phase.loading;
        _failure = null;
      });
    }
    try {
      final outcome = await ref.read(socialRepositoryProvider).openInvite(widget.code);
      if (!mounted || generation != _generation) return;
      setState(() {
        switch (outcome) {
          case InviteFound(:final card):
            _card = card;
            _phase = _Phase.found;
            // Free: only what the lists already hold in memory (nothing is read for it).
            _send = ref.read(friendsControllerProvider.notifier).contains(card.uid)
                ? _Send.alreadyFriends
                : ref.read(sentRequestsControllerProvider).contains(card.uid)
                ? _Send.alreadySent
                : _Send.ready;
          case InviteUnavailable():
            _phase = _Phase.unavailable;
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
    final offline = ref.watch(syncStatusProvider).offline;
    // Fixed minimum height: the result does not push the page around.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 200),
      child: switch (_phase) {
        _Phase.loading => const _Note(message: 'Abrindo o convite...', busy: true),
        _Phase.unavailable => _Note(
          icon: Icons.link_off,
          live: true,
          message: kInviteUnavailableMessage,
          action: TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => context.go('/friends'),
            child: const Text('Ir para Amigos'),
          ),
        ),
        _Phase.failed => _Note(
          icon: Icons.cloud_off_outlined,
          live: true,
          message: _failure?.message ?? const SocialFailure(SocialFailureKind.unknown).message,
          action: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: offline ? null : _open,
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar de novo'),
          ),
        ),
        _Phase.found => _InviteCard(
          card: _card!,
          send: _send,
          failure: _sendFailure,
          offline: offline,
          onSend: _sendRequest,
        ),
      },
    );
  }
}

class _InviteCard extends StatelessWidget {
  final FriendCard card;
  final _Send send;
  final SocialFailure? failure;
  final bool offline;
  final VoidCallback onSend;

  const _InviteCard({
    required this.card,
    required this.send,
    required this.failure,
    required this.offline,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stopped = failure?.kind == SocialFailureKind.limitReached;
    final showButton =
        send == _Send.ready || send == _Send.sending || (send == _Send.failed && !stopped);

    Widget done(String text) => Semantics(
      liveRegion: true,
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );

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
                        Text('convidou você para ser amigo', style: theme.textTheme.bodySmall),
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
                      ? 'Enviando pedido para ${card.nickname}'
                      : 'Enviar pedido para ${card.nickname}',
                ),
              ),
            if (send == _Send.sent) ...[
              done('Pedido enviado. ${card.nickname} decide se aceita.'),
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
              done('Essa pessoa já tinha pedido a sua amizade. Vocês agora são amigos.'),
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
