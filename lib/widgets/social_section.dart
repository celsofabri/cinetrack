import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/social_providers.dart';
import '../providers/sync_providers.dart';
import '../social/social_models.dart';
import '../social/social_validation.dart';
import 'nickname_dialog.dart';
import 'social_dialogs.dart';

/// Profile section "Amizades": opt-in, off by default. Nothing is written
/// (and nobody is exposed) until the user turns it on; turning it off
/// removes everything social. Writes need the server, so they are disabled
/// with the reason while offline.
class SocialSection extends ConsumerWidget {
  const SocialSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(socialControllerProvider);
    final offline = ref.watch(syncStatusProvider).offline;
    final theme = Theme.of(context);
    if (state.phase == SocialPhase.signedOut) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text('Amizades', style: theme.textTheme.titleMedium)),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: switch (state.phase) {
              SocialPhase.loading => const _Loading(),
              SocialPhase.notGoogle => const Text(
                'Amizades só estão disponíveis para contas que entraram com o Google.',
              ),
              SocialPhase.unavailable || SocialPhase.loadFailed => _LoadError(state: state),
              SocialPhase.inactive => _Inactive(
                busy: state.busy,
                offline: offline,
                cleanupPending: state.cleanupPending,
              ),
              SocialPhase.active => _Active(state: state, offline: offline),
              SocialPhase.signedOut => const SizedBox.shrink(),
            },
          ),
        ),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    // Same minimum height as the inactive card: no jump when it loads.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 120),
      child: Semantics(
        liveRegion: true,
        child: const Row(
          children: [
            SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 16),
            Expanded(child: Text('Carregando amizades...')),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends ConsumerWidget {
  final SocialState state;

  const _LoadError({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message =
        state.failure?.message ?? const SocialFailure(SocialFailureKind.unknown).message;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(liveRegion: true, child: Text(message)),
          const SizedBox(height: 8),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => ref.read(socialControllerProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar de novo'),
          ),
        ],
      ),
    );
  }
}

class _OfflineNote extends StatelessWidget {
  const _OfflineNote();

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      'Sem conexão. Tente de novo quando estiver online.',
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

class _Inactive extends ConsumerWidget {
  final bool busy;
  final bool offline;
  final bool cleanupPending;

  const _Inactive({required this.busy, required this.offline, required this.cleanupPending});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ative para ter um identificador (@usuario) e, em breve, adicionar amigos. '
            'Enquanto estiver desativado, nada seu fica visível para outras pessoas.',
          ),
          const SizedBox(height: 12),
          if (cleanupPending) ...[
            Semantics(
              liveRegion: true,
              child: const Text(
                'As amizades foram desativadas, mas a limpeza de amigos e pedidos não terminou.',
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: busy || offline
                  ? null
                  : () => ref.read(socialControllerProvider.notifier).finishCleanup(),
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('Concluir limpeza'),
            ),
            const SizedBox(height: 8),
          ],
          if (offline) ...[const _OfflineNote(), const SizedBox(height: 8)],
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: busy || offline ? null : () => showActivateSocialDialog(context),
            icon: const Icon(Icons.people_outline),
            label: const Text('Ativar amizades'),
          ),
        ],
      ),
    );
  }
}

class _Active extends ConsumerWidget {
  final SocialState state;
  final bool offline;

  const _Active({required this.state, required this.offline});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = state.profile!;
    final busy = state.busy;
    final locked = busy || offline;
    final theme = Theme.of(context);
    final controller = ref.read(socialControllerProvider.notifier);
    final canChange = profile.canChangeHandle(DateTime.now());

    Future<void> toggle(Future<SocialFailure?> Function() action, String done) async {
      final messenger = ScaffoldMessenger.maybeOf(context);
      final failure = await action();
      messenger?.showSnackBar(SnackBar(content: Text(failure?.message ?? done)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _CardAvatar(photoUrl: profile.photoUrl, nickname: profile.nickname),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('@${profile.handle}', style: theme.textTheme.titleMedium),
                  if (profile.nickname.isNotEmpty) Text(profile.nickname),
                ],
              ),
            ),
          ],
        ),
        if (state.fromCache) ...[const SizedBox(height: 8), const _OfflineNote()],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Aparecer na busca'),
          subtitle: const Text(
            'Ligado: quem digitar seu identificador exato vê seu apelido e sua foto. '
            'Desligado: só quem você aceitar ou convidar.',
          ),
          value: profile.discoverable,
          onChanged: locked
              ? null
              : (value) => toggle(
                  () => controller.setDiscoverable(value),
                  value ? 'Você aparece na busca.' : 'Você não aparece mais na busca.',
                ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Mostrar minha foto'),
          subtitle: const Text('Usa a foto da sua conta Google no seu cartão.'),
          value: profile.photoVisible,
          onChanged: locked
              ? null
              : (value) => toggle(
                  () => controller.setPhotoVisible(value),
                  value ? 'Sua foto está visível.' : 'Sua foto foi ocultada.',
                ),
        ),
        const SizedBox(height: 8),
        Text(
          canChange
              ? 'Você pode trocar o identificador uma vez a cada $kHandleChangeIntervalDays dias.'
              : 'Você poderá trocar o identificador de novo em '
                    '${formatSocialDate(profile.nextHandleChange!)}.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (offline) ...[const _OfflineNote(), const SizedBox(height: 8)],
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: locked || !canChange ? null : () => showChangeHandleDialog(context),
              icon: const Icon(Icons.alternate_email),
              label: const Text('Trocar identificador'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: locked
                  ? null
                  : () => showNicknameDialog(context, current: profile.nickname),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Editar apelido'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: locked ? null : () => showDeactivateSocialDialog(context),
              icon: const Icon(Icons.person_off_outlined),
              label: const Text('Desativar amizades'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Round avatar of the public card: Google photo, or the nickname's initial.
/// Decorative for screen readers (the handle and nickname are read next to it).
class _CardAvatar extends StatelessWidget {
  final String? photoUrl;
  final String nickname;

  const _CardAvatar({required this.photoUrl, required this.nickname});

  @override
  Widget build(BuildContext context) {
    final photo = photoUrl;
    final initial = nickname.isEmpty
        ? '@'
        : String.fromCharCode(nickname.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: 24,
        foregroundImage: photo == null ? null : NetworkImage(photo),
        onForegroundImageError: photo == null ? null : (_, _) {},
        child: Text(initial),
      ),
    );
  }
}
