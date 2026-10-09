import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/social_lists_providers.dart';
import '../providers/social_providers.dart';
import '../social/social_models.dart';

/// Where "Enviar pedido" stands for one card (search result or invite).
/// [blocking] / [blocked] are only used by the search ("Bloquear" on the card).
enum SendStatus {
  ready,
  sending,
  sent,
  befriended,
  alreadySent,
  alreadyFriends,
  failed,
  blocking,
  blocked,
}

/// What the lists already in memory say about [uid]: free, nothing is read
/// (the send transaction still detects what they do not know).
SendStatus knownSendStatus(WidgetRef ref, String uid) =>
    ref.read(friendsControllerProvider.notifier).contains(uid)
    ? SendStatus.alreadyFriends
    : ref.read(sentRequestsControllerProvider).contains(uid)
    ? SendStatus.alreadySent
    : SendStatus.ready;

/// Sends a request to [card] (search and invite share it, docs/71 G8) and
/// shows the success SnackBar. Returns where the card stands now and the
/// failure to show (null on success).
Future<({SendStatus status, SocialFailure? failure})> sendFriendRequest(
  WidgetRef ref,
  FriendCard card,
  ScaffoldMessengerState? messenger,
) async {
  final result = await ref.read(sentRequestsControllerProvider.notifier).send(card);
  final failure = result.failure;
  if (failure == null) {
    final friends = result.outcome == SendOutcome.becameFriends;
    messenger?.showSnackBar(
      SnackBar(content: Text(friends ? 'Amizade aceita.' : 'Pedido enviado.')),
    );
    return (status: friends ? SendStatus.befriended : SendStatus.sent, failure: null);
  }
  if (failure.kind == SocialFailureKind.alreadySent) {
    return (status: SendStatus.alreadySent, failure: null);
  }
  return (status: SendStatus.failed, failure: failure);
}

/// "Enviar pedido" and what follows it (sent, became friends, already
/// friends / sent, failure, offline), identical on the search result and on
/// the invite card. [target] names the person for screen readers ("@bruno"
/// or the nickname); [sentText] is the confirmation shown after sending.
class SendRequestControls extends StatelessWidget {
  final SendStatus status;
  final SocialFailure? failure;
  final bool offline;
  final VoidCallback onSend;
  final String target;
  final String sentText;

  const SendRequestControls({
    super.key,
    required this.status,
    required this.failure,
    required this.offline,
    required this.onSend,
    required this.target,
    required this.sentText,
  });

  /// The button shows while sending is (still) possible.
  static bool showsButton(SendStatus status, SocialFailure? failure) =>
      status == SendStatus.ready ||
      status == SendStatus.sending ||
      status == SendStatus.blocking ||
      (status == SendStatus.failed && failure?.kind != SocialFailureKind.limitReached);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showButton = showsButton(status, failure);
    final sending = status == SendStatus.sending;

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

    Widget link(String label, String location) => Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => context.go(location),
        child: Text(label),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showButton)
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: sending || status == SendStatus.blocking || offline ? null : onSend,
            icon: sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.person_add_alt_1_outlined),
            label: Text(
              sending ? 'Enviando...' : 'Enviar pedido',
              semanticsLabel: sending ? 'Enviando pedido para $target' : 'Enviar pedido para $target',
            ),
          ),
        if (status == SendStatus.sent) ...[
          done(sentText),
          link('Ver pedidos enviados', '/friends?tab=pedidos'),
        ],
        if (status == SendStatus.befriended) ...[
          done('Essa pessoa já tinha pedido a sua amizade. Vocês agora são amigos.'),
          link('Ver amigos', '/friends'),
        ],
        if (status == SendStatus.alreadyFriends)
          Semantics(liveRegion: true, child: const Text('Vocês já são amigos.')),
        if (status == SendStatus.alreadySent)
          Semantics(
            liveRegion: true,
            child: Text(const SocialFailure(SocialFailureKind.alreadySent).message),
          ),
        if (status == SendStatus.failed && failure != null) ...[
          if (showButton) const SizedBox(height: 8),
          Semantics(liveRegion: true, child: Text(failure!.message)),
        ],
        if (offline && showButton) ...[
          const SizedBox(height: 8),
          const Text('Sem conexão. Tente de novo quando estiver online.'),
        ],
      ],
    );
  }
}
