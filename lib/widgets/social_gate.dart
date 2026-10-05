import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/social_providers.dart';
import '../social/social_models.dart';

/// Widest content column of the friends screens (readable on 1440 px).
const double kFriendsMaxWidth = 640;

/// Decides what the friends screens show before anything social can happen:
/// loading, signed out, not a Google account, rules not published / load
/// failed (with retry), friendships off (an invitation to turn them on in the
/// Profile), and finally [active] with the user's own profile.
class SocialGate extends ConsumerWidget {
  final Widget Function(BuildContext context, SocialProfile profile) active;

  const SocialGate({super.key, required this.active});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(socialControllerProvider);
    ref.read(socialControllerProvider.notifier).confirm();
    final profile = state.profile;
    switch (state.phase) {
      case SocialPhase.active when profile != null:
        return active(context, profile);
      case SocialPhase.loading:
        return const _Message(
          icon: null,
          message: 'Carregando amizades...',
          live: true,
          busy: true,
        );
      case SocialPhase.signedOut:
        return const _Message(icon: Icons.lock_outline, message: 'Você não está conectado.');
      case SocialPhase.notGoogle:
        return const _Message(
          icon: Icons.info_outline,
          message: 'Amizades só estão disponíveis para contas que entraram com o Google.',
        );
      case SocialPhase.unavailable || SocialPhase.loadFailed || SocialPhase.active:
        return _Message(
          icon: Icons.cloud_off_outlined,
          message: state.failure?.message ?? const SocialFailure(SocialFailureKind.unknown).message,
          live: true,
          action: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => ref.read(socialControllerProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar de novo'),
          ),
        );
      case SocialPhase.inactive:
        return _Message(
          icon: Icons.people_outline,
          message:
              'Para adicionar amigos, ative as amizades no seu Perfil. '
              'Enquanto estiverem desativadas, nada seu fica visível para outras pessoas.',
          action: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => context.go('/profile'),
            icon: const Icon(Icons.person_outline),
            label: const Text('Ir para o Perfil'),
          ),
        );
    }
  }
}

class _Message extends StatelessWidget {
  final IconData? icon;
  final String message;
  final Widget? action;
  final bool live;
  final bool busy;

  const _Message({
    required this.icon,
    required this.message,
    this.action,
    this.live = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kFriendsMaxWidth),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (busy)
                const SizedBox(width: 32, height: 32, child: CircularProgressIndicator())
              else if (icon != null)
                Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              Semantics(
                liveRegion: live,
                child: Text(message, textAlign: TextAlign.center),
              ),
              if (action != null) ...[const SizedBox(height: 12), action!],
            ],
          ),
        ),
      ),
    );
  }
}
