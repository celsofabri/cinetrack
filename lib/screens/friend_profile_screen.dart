import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/sync_status.dart';
import '../providers/friend_profile_providers.dart';
import '../providers/shared_profile_providers.dart';
import '../providers/social_lists_providers.dart';
import '../providers/sync_providers.dart';
import '../shared_profile/shared_profile_texts.dart';
import '../shared_profile/shared_stats_reading.dart';
import '../social/social_models.dart';
import '../widgets/app_shell.dart';
import '../widgets/auth_gate.dart';
import '../widgets/block_dialogs.dart';
import '../widgets/person_avatar.dart';
import '../widgets/shared_profile_widgets.dart';
import '../widgets/social_gate.dart';
import 'friends_screen.dart' show kBlockedMessage, kFriendRemovedMessage;

/// A friend's profile (`/friends/u/:uid`, docs/82 §7.2, docs/81 RF-F):
/// header of the pair, what the friend shares (statistics, the 3 latest
/// activities, the recommended titles) and the Phase 1 actions.
class FriendProfileScreen extends StatelessWidget {
  final String uid;

  /// The card handed over by the friends list (0 reads for the header).
  final Friend? friend;

  const FriendProfileScreen({super.key, required this.uid, this.friend});

  @override
  Widget build(BuildContext context) {
    final inShell = MobileShellScope.active(context);
    return Scaffold(
      appBar: inShell
          ? null
          : AppBar(automaticallyImplyLeading: false, title: const Text('Perfil de amigo')),
      body: SocialGate(
        active: (context, profile) => _Body(uid: uid, handed: friend),
      ),
    );
  }
}

/// Back to the friends list (a deep link has no history to pop).
void _back(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/friends');
  }
}

class _Body extends ConsumerStatefulWidget {
  final String uid;
  final Friend? handed;

  const _Body({required this.uid, required this.handed});

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  @override
  void initState() {
    super.initState();
    final handed = widget.handed;
    if (handed != null && handed.uid == widget.uid && isValidFriendUid(widget.uid)) {
      ref.read(friendProfileCacheProvider).rememberHeader(handed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(friendProfileControllerProvider(widget.uid));
    final controller = ref.read(friendProfileControllerProvider(widget.uid).notifier);
    final offline = ref.watch(syncStatusProvider).offline;
    final list = ref.watch(friendsControllerProvider);
    final friend = state.friend;
    final removing =
        friend != null && list.busy.contains(friend.uid) && !list.blocking.contains(friend.uid);
    final blocking = friend != null && list.blocking.contains(friend.uid);
    final now = ref.read(sharedProfileClockProvider)();
    final unavailable = state.phase == FriendProfilePhase.unavailable;

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _back(context)},
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kFriendsMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  // Focus starts here: Tab goes on to "Atualizar", the
                  // activities and the actions (docs/81 order).
                  autofocus: true,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _back(context),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Voltar', semanticsLabel: 'Voltar para Amigos'),
                ),
              ),
              const SizedBox(height: 8),
              if (unavailable)
                _Unavailable()
              else ...[
                _Header(
                  friend: friend,
                  memberSince: state.view?.stats?.memberSince,
                  tz: state.view?.tz ?? 0,
                ),
                const SizedBox(height: 8),
                _RefreshRow(
                  state: state,
                  now: now,
                  offline: offline,
                  onRefresh: controller.refresh,
                ),
                const SizedBox(height: 8),
                _content(context, state, now),
                if (friend != null) ...[
                  const SizedBox(height: 24),
                  _Actions(
                    friend: friend,
                    removing: removing,
                    blocking: blocking,
                    offline: offline,
                    onRemove: () => _remove(context, friend),
                    onBlock: () => _block(context, friend),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, FriendProfileState state, DateTime now) {
    final controller = ref.read(friendProfileControllerProvider(widget.uid).notifier);
    final name = state.friend?.name;
    switch (state.phase) {
      case FriendProfilePhase.loading:
        return const _Skeleton();
      case FriendProfilePhase.notShared:
        return _Line(SharedProfileTexts.sharesNothing(name ?? ''), live: true);
      case FriendProfilePhase.offline:
        return _Problem(
          message: SharedProfileTexts.offline(name),
          action: SharedProfileTexts.retry,
          onAction: controller.refresh,
        );
      case FriendProfilePhase.error:
        return _Problem(
          message: SharedProfileTexts.loadFailed,
          action: SharedProfileTexts.retry,
          onAction: controller.refresh,
        );
      case FriendProfilePhase.quota:
        return _Problem(
          message: const SocialFailure(SocialFailureKind.quotaExceeded).message,
          action: SharedProfileTexts.retry,
          onAction: controller.refresh,
        );
      case FriendProfilePhase.sessionExpired:
        return _Problem(
          message: SyncFailure.fromCode('unauthenticated').message,
          action: 'Entrar',
          icon: Icons.login,
          onAction: () => signInWithFeedback(
            ProviderScope.containerOf(context),
            ScaffoldMessenger.maybeOf(context),
          ),
        );
      case FriendProfilePhase.unavailable:
        return const SizedBox.shrink();
      case FriendProfilePhase.content:
        return _Shared(view: state.view!, name: name ?? '', now: now);
    }
  }

  Future<void> _remove(BuildContext context, Friend friend) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final router = GoRouter.of(context);
    if (!await confirmRemoveFriend(context, friend.name)) return;
    final failure = await ref.read(friendProfileControllerProvider(widget.uid).notifier).remove();
    messenger?.showSnackBar(SnackBar(content: Text(failure?.message ?? kFriendRemovedMessage)));
    if (failure == null) router.go('/friends');
  }

  Future<void> _block(BuildContext context, Friend friend) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final router = GoRouter.of(context);
    if (!await confirmBlock(context, friend.name)) return;
    final failure = await ref.read(friendProfileControllerProvider(widget.uid).notifier).block();
    messenger?.showSnackBar(SnackBar(content: Text(failure?.message ?? kBlockedMessage)));
    if (failure == null) router.go('/friends');
  }
}

class _Unavailable extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Line(SharedProfileTexts.unavailable, live: true),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => context.go('/friends'),
          icon: const Icon(Icons.people_outline),
          label: const Text(SharedProfileTexts.backToFriends),
        ),
      ],
    );
  }
}

/// Name, photo, "Amigos desde" (the pair's card, RF-F3) and "No CineTrack
/// desde" only when the friend shares statistics (D8).
class _Header extends StatelessWidget {
  final Friend? friend;
  final DateTime? memberSince;
  final int tz;

  const _Header({required this.friend, required this.memberSince, required this.tz});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = friend;
    if (f == null) {
      return Semantics(
        label: 'Carregando o perfil',
        child: ExcludeSemantics(
          child: Row(
            children: [
              CircleAvatar(radius: 28, backgroundColor: theme.colorScheme.surfaceContainerHighest),
              const SizedBox(width: 16),
              Expanded(
                child: Container(
                  height: 20,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final since = f.since;
    return Row(
      children: [
        PersonAvatar(photoUrl: f.photoUrl, nickname: f.name),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: Text(f.name, style: theme.textTheme.headlineSmall)),
              if (since != null)
                Text('Amigos desde ${formatSocialDate(since)}', style: theme.textTheme.bodyMedium),
              if (memberSince != null)
                Text(
                  'No CineTrack desde ${SharedProfileTexts.date(memberSince!, tz)}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Atualizado há X" (neutral, never an alarm) and "Atualizar" (ignores the TTL).
class _RefreshRow extends StatelessWidget {
  final FriendProfileState state;
  final DateTime now;
  final bool offline;
  final VoidCallback onRefresh;

  const _RefreshRow({
    required this.state,
    required this.now,
    required this.offline,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final updated = state.hasContent ? state.view?.updatedAt : null;
    final loading = state.phase == FriendProfilePhase.loading;
    final name = state.friend?.name;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        if (updated != null)
          Text(
            SharedProfileTexts.updated(updated, now),
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          const SizedBox.shrink(),
        TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: loading || offline ? null : onRefresh,
          icon: const Icon(Icons.refresh),
          label: Text(
            'Atualizar',
            semanticsLabel: name == null ? 'Atualizar o perfil' : 'Atualizar o perfil de $name',
          ),
        ),
      ],
    );
  }
}

/// The sections the friend shares; an absent one says so.
class _Shared extends StatelessWidget {
  final FriendSharedView view;
  final String name;
  final DateTime now;

  const _Shared({required this.view, required this.name, required this.now});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = view.stats;
    final activity = view.activity;
    final recs = view.recs;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Semantics(header: true, child: Text(text, style: theme.textTheme.titleMedium)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading('Estatísticas'),
        if (stats != null)
          SharedStatsView.reading(
            reading: stats,
            tz: view.tz,
            now: now,
            updatedAt: view.updatedAt,
            showMemberSince: false,
          )
        else
          _Line(SharedProfileTexts.noStats(name)),
        heading('Atividades recentes'),
        if (activity == null)
          _Line(SharedProfileTexts.noActivity(name))
        else if (activity.isEmpty)
          _Line(SharedProfileTexts.noActivityYet(name))
        else
          // Up to 10 are stored; the profile shows the 3 latest (D1).
          for (final a in activity.take(3)) SharedActivityTile(item: a, now: now),
        heading('Recomendados'),
        if (recs == null)
          _Line(SharedProfileTexts.noRecs(name))
        else
          SharedRecsView(reading: recs, emptyText: SharedProfileTexts.noRecsYet(name)),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  final Friend friend;
  final bool removing;
  final bool blocking;
  final bool offline;
  final VoidCallback onRemove;
  final VoidCallback onBlock;

  const _Actions({
    required this.friend,
    required this.removing,
    required this.blocking,
    required this.offline,
    required this.onRemove,
    required this.onBlock,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = removing || blocking;
    final style = TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: theme.colorScheme.error,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (offline)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
                'Sem conexão. Remover amigos exige internet.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              style: style,
              onPressed: busy || offline ? null : onRemove,
              icon: removing ? const _Saving() : const Icon(Icons.person_remove_outlined),
              label: Text(
                removing ? 'Removendo...' : 'Remover amizade',
                semanticsLabel: removing
                    ? 'Removendo a amizade com ${friend.name}'
                    : 'Remover amizade com ${friend.name}',
              ),
            ),
            TextButton.icon(
              style: style,
              onPressed: busy || offline ? null : onBlock,
              icon: blocking ? const _Saving() : const Icon(Icons.block),
              label: Text(
                blocking ? 'Bloqueando...' : 'Bloquear',
                semanticsLabel: blocking ? 'Bloqueando ${friend.name}' : 'Bloquear ${friend.name}',
              ),
            ),
          ],
        ),
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

class _Line extends StatelessWidget {
  final String text;
  final bool live;

  const _Line(this.text, {this.live = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Semantics(liveRegion: live, child: Text(text)),
  );
}

class _Problem extends StatelessWidget {
  final String message;
  final String action;
  final IconData icon;
  final VoidCallback onAction;

  const _Problem({
    required this.message,
    required this.action,
    required this.onAction,
    this.icon = Icons.refresh,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Line(message, live: true),
        const SizedBox(height: 4),
        TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onAction,
          icon: Icon(icon),
          label: Text(action),
        ),
      ],
    );
  }
}

/// Section placeholders while the shared profile is read (the header is
/// already there when it came from the list, RF-F3).
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Carregando o perfil',
      child: ExcludeSemantics(
        child: Column(
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                height: 56,
                margin: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
              ),
          ],
        ),
      ),
    );
  }
}
