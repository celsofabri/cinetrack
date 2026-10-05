import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/social_lists_providers.dart';
import '../providers/social_providers.dart';
import '../providers/sync_providers.dart';
import '../social/social_models.dart';
import '../widgets/app_shell.dart';
import '../widgets/count_badge.dart';
import '../widgets/person_avatar.dart';
import '../widgets/social_gate.dart';

/// "Amigos" (`/friends`): two sections, Amigos | Pedidos (received and sent),
/// as tabs reachable with the arrow keys (docs/50 §13). Only the section on
/// screen is read (docs/62). Blocks arrive in a later slice and are NOT drawn
/// as a placeholder.
class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final inShell = MobileShellScope.active(context);
    final tab = GoRouterState.of(context).uri.queryParameters['tab'];
    return Scaffold(
      appBar: inShell ? null : detailAppBar(context, title: 'Amigos'),
      body: SocialGate(
        active: (context, profile) => _FriendsBody(
          showTitle: inShell,
          initialTab: tab == 'pedidos' ? FriendsTab.requests : FriendsTab.friends,
        ),
      ),
    );
  }
}

enum FriendsTab { friends, requests }

class _FriendsBody extends ConsumerStatefulWidget {
  final bool showTitle;
  final FriendsTab initialTab;

  const _FriendsBody({required this.showTitle, required this.initialTab});

  @override
  ConsumerState<_FriendsBody> createState() => _FriendsBodyState();
}

class _FriendsBodyState extends ConsumerState<_FriendsBody> {
  late FriendsTab _tab = widget.initialTab;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_FriendsBody old) {
    super.didUpdateWidget(old);
    // The badge opens `/friends?tab=pedidos` even while this screen is already open.
    if (widget.initialTab != old.initialTab) _select(widget.initialTab, syncUrl: false);
  }

  /// Reads the first page of the section on screen (served from memory while
  /// it is fresh).
  void _load() {
    Future.microtask(() {
      if (!mounted) return;
      if (_tab == FriendsTab.friends) {
        ref.read(friendsControllerProvider.notifier).ensureLoaded();
      } else {
        ref.read(receivedRequestsControllerProvider.notifier).ensureLoaded();
        ref.read(sentRequestsControllerProvider.notifier).ensureLoaded();
      }
    });
  }

  void _select(FriendsTab tab, {bool syncUrl = true}) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    _load();
    // The address follows the tab, so the badge (which opens ?tab=pedidos) can
    // bring you back to Pedidos from Amigos.
    if (syncUrl) {
      context.replace(tab == FriendsTab.requests ? '/friends?tab=pedidos' : '/friends');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offline = ref.watch(syncStatusProvider).offline;
    final pending = ref.watch(receivedBadgeProvider);
    refreshBadge(ref);
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
            const SizedBox(height: 16),
            FriendsTabs(selected: _tab, pending: pending, onSelect: _select),
            const SizedBox(height: 16),
            if (_tab == FriendsTab.friends)
              _FriendsSection(offline: offline)
            else ...[
              _ReceivedSection(offline: offline),
              const SizedBox(height: 24),
              Semantics(
                header: true,
                child: Text('Pedidos enviados', style: theme.textTheme.titleMedium),
              ),
              const SizedBox(height: 8),
              _SentSection(offline: offline),
            ],
          ],
        ),
      ),
    );
  }
}

/// The two tabs. Arrow keys (Left / Right, Home / End) move focus AND select,
/// like the ARIA tabs pattern; Tab leaves the group. Each tab is at least
/// 48 px tall, the selected one is underlined, and the screen reader hears
/// "Pedidos, 2 pedidos recebidos" when there is a number.
class FriendsTabs extends StatefulWidget {
  final FriendsTab selected;
  final int pending;
  final ValueChanged<FriendsTab> onSelect;

  const FriendsTabs({
    super.key,
    required this.selected,
    required this.pending,
    required this.onSelect,
  });

  @override
  State<FriendsTabs> createState() => _FriendsTabsState();
}

class _FriendsTabsState extends State<FriendsTabs> {
  final _nodes = [FocusNode(debugLabel: 'tab-amigos'), FocusNode(debugLabel: 'tab-pedidos')];

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _go(int index) {
    final tab = FriendsTab.values[index.clamp(0, FriendsTab.values.length - 1)];
    _nodes[tab.index].requestFocus();
    widget.onSelect(tab);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, int index) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == (rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight)) {
      _go((index + 1) % _nodes.length);
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == (rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft)) {
      _go((index - 1 + _nodes.length) % _nodes.length);
    } else if (key == LogicalKeyboardKey.home) {
      _go(0);
    } else if (key == LogicalKeyboardKey.end) {
      _go(_nodes.length - 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttons = [
      for (final tab in FriendsTab.values)
        _TabButton(
          focusNode: _nodes[tab.index],
          selected: widget.selected == tab,
          label: tab == FriendsTab.friends ? 'Amigos' : 'Pedidos',
          semanticLabel: tab == FriendsTab.requests && widget.pending > 0
              ? 'Pedidos, ${widget.pending == 1 ? '1 pedido recebido' : '${widget.pending >= kMaxReceivedListed ? '$kMaxReceivedListed ou mais' : widget.pending} pedidos recebidos'}'
              : null,
          badge: tab == FriendsTab.requests ? widget.pending : 0,
          onTap: () => widget.onSelect(tab),
          onKey: (node, event) => _onKey(node, event, tab.index),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Side by side while both labels fit; stacked (full width each) with
        // very large fonts on narrow screens, so nothing is cut or overflows.
        final style = theme.textTheme.titleSmall;
        var widest = 0.0;
        for (final label in const ['Amigos', 'Pedidos']) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          if (painter.width > widest) widest = painter.width;
          painter.dispose();
        }
        // padding 16 + room for the badge (12 + dot) on the second tab
        final sideBySide = (widest + 16 + 28) * 2 <= constraints.maxWidth;
        return Semantics(
          role: SemanticsRole.tabBar,
          container: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
            ),
            child: sideBySide
                ? Row(children: [for (final button in buttons) Expanded(child: button)])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons),
          ),
        );
      },
    );
  }
}

class _TabButton extends StatelessWidget {
  final FocusNode focusNode;
  final bool selected;
  final String label;
  final String? semanticLabel;
  final int badge;
  final VoidCallback onTap;
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKey;

  const _TabButton({
    required this.focusNode,
    required this.selected,
    required this.label,
    required this.semanticLabel,
    required this.badge,
    required this.onTap,
    required this.onKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      role: SemanticsRole.tab,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: Focus(
        focusNode: focusNode,
        // Roving focus: Tab reaches only the selected tab, the arrows move
        // between tabs (ARIA tabs pattern).
        skipTraversal: !selected,
        onKeyEvent: (node, event) {
          final key = event.logicalKey;
          if (event is KeyDownEvent &&
              (key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.numpadEnter ||
                  key == LogicalKeyboardKey.space)) {
            onTap();
            return KeyEventResult.handled;
          }
          return onKey(node, event);
        },
        child: ListenableBuilder(
          listenable: focusNode,
          builder: (context, child) => DecoratedBox(
            decoration: BoxDecoration(
              border: focusNode.hasFocus
                  ? Border.all(color: theme.colorScheme.primary, width: 2)
                  : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: child,
          ),
          child: InkWell(
            canRequestFocus: false,
            onTap: () {
              focusNode.requestFocus();
              onTap();
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected ? theme.colorScheme.primary : Colors.transparent,
                      width: 3,
                    ),
                  ),
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    child: CountBadge(
                      count: badge,
                      child: Padding(
                        padding: EdgeInsets.only(right: badge > 0 ? 12 : 0),
                        child: Text(
                          label,
                          style: theme.textTheme.titleSmall?.copyWith(color: color),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

/// Three rows with the height of real rows: nothing jumps when the list
/// arrives, and "empty" is never shown before the answer.
class _Skeleton extends StatelessWidget {
  final String label;

  const _Skeleton({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Semantics(
      liveRegion: true,
      label: label,
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

class _ListError extends StatelessWidget {
  final SocialFailure? failure;
  final VoidCallback onRetry;

  const _ListError({required this.failure, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(failure?.message ?? const SocialFailure(SocialFailureKind.unknown).message),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar de novo'),
          ),
        ],
      ),
    );
  }
}

class _OfflineStrip extends StatelessWidget {
  final String text;

  const _OfflineStrip(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        liveRegion: true,
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  final PagedState<Object?> state;
  final bool offline;
  final VoidCallback onMore;

  const _MoreButton({required this.state, required this.offline, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              onPressed: state.loadingMore || offline ? null : onMore,
              child: Text(state.loadingMore ? 'Carregando...' : 'Ver mais'),
            ),
          ),
        ],
      ],
    );
  }
}

class _Saving extends StatelessWidget {
  const _Saving();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
}

// ---------------------------------------------------------------------------
// Amigos
// ---------------------------------------------------------------------------

class _FriendsSection extends ConsumerWidget {
  final bool offline;

  const _FriendsSection({required this.offline});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(friendsControllerProvider);
    final controller = ref.read(friendsControllerProvider.notifier);
    switch (state.phase) {
      case SentPhase.idle || SentPhase.loading:
        return const _Skeleton(label: 'Carregando amigos');
      case SentPhase.error:
        return _ListError(failure: state.failure, onRetry: controller.reload);
      case SentPhase.loaded:
        break;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: offline || state.loadingMore ? null : controller.refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Atualizar'),
          ),
        ),
        if (state.fromCache || offline)
          _OfflineStrip(
            state.fromCache
                ? 'Sem conexão. Mostrando a última lista salva neste aparelho.'
                : 'Sem conexão. Remover amigos exige internet.',
          ),
        if (state.items.isEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120),
            child: const Text(
              'Você ainda não tem amigos. Use "Adicionar amigo" para pedir amizade a alguém. '
              'Quem é seu amigo vê só o seu cartão (apelido e foto).',
            ),
          )
        else
          for (final friend in state.items)
            _FriendTile(
              key: ValueKey(friend.uid),
              friend: friend,
              removing: state.busy.contains(friend.uid),
              disabled: offline,
            ),
        _MoreButton(state: state, offline: offline, onMore: controller.loadMore),
      ],
    );
  }
}

class _FriendTile extends ConsumerWidget {
  final Friend friend;
  final bool removing;
  final bool disabled;

  const _FriendTile({
    super.key,
    required this.friend,
    required this.removing,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final since = friend.since;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PersonAvatar(photoUrl: friend.photoUrl, nickname: friend.name),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(friend.name, style: theme.textTheme.titleMedium),
                if (since != null)
                  Text('Amigos desde ${formatSocialDate(since)}', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: removing || disabled ? null : () => _confirmRemove(context, ref),
                  icon: removing ? const _Saving() : const Icon(Icons.person_remove_outlined),
                  label: Text(
                    removing ? 'Removendo...' : 'Remover amizade',
                    semanticsLabel: removing
                        ? 'Removendo a amizade com ${friend.name}'
                        : 'Remover amizade com ${friend.name}',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remover ${friend.name}?'),
        content: const Text(
          'A pessoa não será avisada. Vocês deixam de ser amigos nos dois lados. '
          'Para voltar a ser amigos, é preciso enviar e aceitar um novo pedido.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remover amizade'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final failure = await ref.read(friendsControllerProvider.notifier).remove(friend);
    messenger?.showSnackBar(SnackBar(content: Text(failure?.message ?? 'Amizade removida.')));
  }
}

// ---------------------------------------------------------------------------
// Pedidos recebidos
// ---------------------------------------------------------------------------

class _ReceivedSection extends ConsumerWidget {
  final bool offline;

  const _ReceivedSection({required this.offline});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(receivedRequestsControllerProvider);
    final controller = ref.read(receivedRequestsControllerProvider.notifier);
    final theme = Theme.of(context);
    final loading = state.phase == SentPhase.loading;

    Widget body;
    switch (state.phase) {
      case SentPhase.idle || SentPhase.loading:
        body = const _Skeleton(label: 'Carregando pedidos recebidos');
      case SentPhase.error:
        body = _ListError(failure: state.failure, onRetry: controller.reload);
      case SentPhase.loaded:
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.fromCache || offline)
              _OfflineStrip(
                state.fromCache
                    ? 'Sem conexão. Mostrando a última lista salva neste aparelho.'
                    : 'Sem conexão. Aceitar e recusar exigem internet.',
              ),
            if (state.items.isEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 96),
                child: const Text(
                  'Nenhum pedido recebido. Quando alguém pedir a sua amizade, o pedido '
                  'aparece aqui. Se você recusar, a pessoa não é avisada.',
                ),
              )
            else
              for (final request in state.items)
                _ReceivedTile(
                  key: ValueKey(request.fromUid),
                  request: request,
                  saving: state.busy.contains(request.fromUid),
                  disabled: offline,
                ),
            _MoreButton(state: state, offline: offline, onMore: controller.loadMore),
            if (!state.hasMore && state.items.length >= kMaxReceivedListed) ...[
              const SizedBox(height: 8),
              Text(
                'Mostrando os $kMaxReceivedListed pedidos mais recentes. Responda alguns para '
                'ver os outros.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A Wrap, not a Row: with a huge font the button drops below the title.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              header: true,
              child: Text('Pedidos recebidos', style: theme.textTheme.titleMedium),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: loading || offline ? null : controller.refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Atualizar'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        body,
      ],
    );
  }
}

class _ReceivedTile extends ConsumerWidget {
  final ReceivedRequest request;
  final bool saving;
  final bool disabled;

  const _ReceivedTile({
    super.key,
    required this.request,
    required this.saving,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final at = request.createdAt;
    final locked = saving || disabled;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PersonAvatar(photoUrl: request.fromPhoto, nickname: request.fromName),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(request.fromName, style: theme.textTheme.titleMedium),
                Text(
                  at == null ? 'Quer ser seu amigo' : 'Pedido de ${formatSocialDate(at)}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: locked ? null : () => _accept(context, ref),
                      icon: saving ? const _Saving() : const Icon(Icons.check),
                      label: Text(
                        saving ? 'Salvando...' : 'Aceitar',
                        semanticsLabel: saving
                            ? 'Salvando a resposta ao pedido de ${request.fromName}'
                            : 'Aceitar pedido de ${request.fromName}',
                      ),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: locked ? null : () => _decline(context, ref),
                      icon: const Icon(Icons.close),
                      label: Text(
                        'Recusar',
                        semanticsLabel: 'Recusar pedido de ${request.fromName}',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _accept(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failure = await ref.read(receivedRequestsControllerProvider.notifier).accept(request);
    messenger?.showSnackBar(
      SnackBar(content: Text(failure?.message ?? 'Amizade aceita: ${request.fromName}.')),
    );
  }

  Future<void> _decline(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failure = await ref.read(receivedRequestsControllerProvider.notifier).decline(request);
    messenger?.showSnackBar(
      SnackBar(content: Text(failure?.message ?? 'Pedido recusado. A pessoa não foi avisada.')),
    );
  }
}

// ---------------------------------------------------------------------------
// Pedidos enviados (slice 2)
// ---------------------------------------------------------------------------

class _SentSection extends ConsumerWidget {
  final bool offline;

  const _SentSection({required this.offline});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sentRequestsControllerProvider);
    final controller = ref.read(sentRequestsControllerProvider.notifier);

    switch (state.phase) {
      case SentPhase.idle || SentPhase.loading:
        return const _Skeleton(label: 'Carregando pedidos enviados');
      case SentPhase.error:
        return _ListError(failure: state.failure, onRetry: controller.reload);
      case SentPhase.loaded:
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.fromCache || offline)
          _OfflineStrip(
            state.fromCache
                ? 'Sem conexão. Mostrando a última lista salva neste aparelho.'
                : 'Sem conexão. Cancelar pedidos exige internet.',
          ),
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
                  icon: cancelling ? const _Saving() : const Icon(Icons.close),
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
