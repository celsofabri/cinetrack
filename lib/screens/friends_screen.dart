import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/social_providers.dart';
import '../providers/sync_providers.dart';
import '../social/social_models.dart';
import '../widgets/app_shell.dart';
import '../widgets/person_avatar.dart';
import '../widgets/social_gate.dart';

/// "Amigos" (`/friends`). Slice 2 only has what exists: add a friend and the
/// requests this user sent (docs/59). Received requests, the friends list and
/// blocks arrive in later slices and are NOT drawn as placeholders.
class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final inShell = MobileShellScope.active(context);
    return Scaffold(
      appBar: inShell ? null : detailAppBar(context, title: 'Amigos'),
      body: SocialGate(active: (context, profile) => _FriendsBody(showTitle: inShell)),
    );
  }
}

class _FriendsBody extends ConsumerStatefulWidget {
  final bool showTitle;

  const _FriendsBody({required this.showTitle});

  @override
  ConsumerState<_FriendsBody> createState() => _FriendsBodyState();
}

class _FriendsBodyState extends ConsumerState<_FriendsBody> {
  @override
  void initState() {
    super.initState();
    // One read of the first page (served from memory while it is fresh).
    Future.microtask(() {
      if (mounted) ref.read(sentRequestsControllerProvider.notifier).ensureLoaded();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offline = ref.watch(syncStatusProvider).offline;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kFriendsMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.showTitle) ...[
              Semantics(header: true, child: Text('Amigos', style: theme.textTheme.headlineSmall)),
              const SizedBox(height: 12),
            ],
            const Text(
              'Procure uma pessoa pelo identificador exato (@usuario) e envie um pedido de amizade.',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => context.push('/friends/add'),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Adicionar amigo'),
              ),
            ),
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text('Pedidos enviados', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 8),
            _SentSection(offline: offline),
          ],
        ),
      ),
    );
  }
}

class _SentSection extends ConsumerWidget {
  final bool offline;

  const _SentSection({required this.offline});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sentRequestsControllerProvider);
    final controller = ref.read(sentRequestsControllerProvider.notifier);
    final theme = Theme.of(context);

    switch (state.phase) {
      case SentPhase.idle || SentPhase.loading:
        return const _SentSkeleton();
      case SentPhase.error:
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  state.failure?.message ?? const SocialFailure(SocialFailureKind.unknown).message,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: controller.reload,
                icon: const Icon(Icons.refresh),
                label: const Text('Tentar de novo'),
              ),
            ],
          ),
        );
      case SentPhase.loaded:
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.fromCache || offline) ...[
          Semantics(
            liveRegion: true,
            child: Text(
              state.fromCache
                  ? 'Sem conexão. Mostrando a última lista salva neste aparelho.'
                  : 'Sem conexão. Cancelar pedidos exige internet.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (state.items.isEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120),
            child: const Text(
              'Você não tem pedidos pendentes. Quando você pedir amizade a alguém, o pedido '
              'fica aqui até a pessoa responder ou você cancelar. Se a pessoa recusar, o '
              'pedido some daqui sem aviso.',
            ),
          )
        else
          for (final request in state.items)
            _SentTile(
              key: ValueKey(request.toUid),
              request: request,
              cancelling: state.cancelling.contains(request.toUid),
              disabled: offline,
            ),
        if (state.moreFailure != null) ...[
          const SizedBox(height: 8),
          Semantics(liveRegion: true, child: Text(state.moreFailure!.message)),
        ],
        if (state.hasMore) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: state.loadingMore || offline ? null : controller.loadMore,
              child: Text(state.loadingMore ? 'Carregando...' : 'Ver mais'),
            ),
          ),
        ],
      ],
    );
  }
}

/// Three rows with the height of real rows: nothing jumps when the list
/// arrives, and "empty" is never shown before the answer.
class _SentSkeleton extends StatelessWidget {
  const _SentSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Semantics(
      liveRegion: true,
      label: 'Carregando pedidos enviados',
      child: ExcludeSemantics(
        child: Column(
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    CircleAvatar(radius: 24, backgroundColor: color),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Container(
                        height: 16,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SentTile extends ConsumerWidget {
  final SentRequest request;
  final bool cancelling;
  final bool disabled;

  const _SentTile({
    super.key,
    required this.request,
    required this.cancelling,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final at = request.createdAt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PersonAvatar(photoUrl: request.toPhoto, nickname: request.toName),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(request.toName, style: theme.textTheme.titleMedium),
                Text(
                  at == null ? 'Aguardando resposta' : 'Enviado em ${formatSocialDate(at)}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: cancelling || disabled ? null : () => _confirmCancel(context, ref),
                  icon: cancelling
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.close),
                  label: Text(
                    cancelling ? 'Cancelando...' : 'Cancelar pedido',
                    semanticsLabel: cancelling
                        ? 'Cancelando o pedido para ${request.toName}'
                        : 'Cancelar pedido para ${request.toName}',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCancel(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Cancelar o pedido para ${request.toName}?'),
        content: const Text('Você pode enviar outro pedido depois.'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Manter pedido'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cancelar pedido'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final failure = await ref.read(sentRequestsControllerProvider.notifier).cancel(request.toUid);
    messenger?.showSnackBar(SnackBar(content: Text(failure?.message ?? 'Pedido cancelado.')));
  }
}
