import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/app_user.dart';
import '../providers/account_providers.dart';
import '../providers/providers.dart';
import 'auth_gate.dart';
import 'privacy_summary.dart';
import 'sync_widgets.dart';

/// Round avatar: Google photo, or initials when there is no photo / it
/// fails to load. Decorative for screen readers (the name is read next to it).
class UserAvatar extends StatelessWidget {
  final AppUser user;
  final double radius;

  const UserAvatar({super.key, required this.user, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    final initials = Text(user.initials, style: TextStyle(fontSize: radius * 0.8));
    final photo = user.photoUrl;
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: radius,
        foregroundImage: photo == null || photo.isEmpty ? null : NetworkImage(photo),
        onForegroundImageError: photo == null || photo.isEmpty ? null : (_, _) {},
        child: initials,
      ),
    );
  }
}

/// Top-bar account entry: avatar -> profile when signed in, "Entrar" when
/// signed out. Hidden while the session is loading or when login is
/// unavailable in this build.
class AccountAction extends ConsumerWidget {
  const AccountAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    if (authState.isLoading) return const SizedBox.shrink();

    final user = authState.valueOrNull;
    if (user != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SyncIndicator(),
          IconButton(
            tooltip: 'Perfil de ${ref.watch(displayLabelProvider)}',
            onPressed: () => context.push('/profile'),
            icon: UserAvatar(user: user),
          ),
        ],
      );
    }
    if (!ref.watch(authRepositoryProvider).isAvailable) return const SizedBox.shrink();

    final signingIn = ref.watch(authControllerProvider).signingIn;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton.filledTonal(
        tooltip: 'Entrar com Google',
        onPressed: signingIn ? null : () => _signIn(context),
        icon: const Icon(Icons.login),
      ),
    );
  }
}

void _signIn(BuildContext context) => signInWithFeedback(
      ProviderScope.containerOf(context),
      ScaffoldMessenger.maybeOf(context),
    );

/// Home banner inviting the signed-out visitor to log in. Renders nothing
/// when signed in, while loading, or when login is unavailable.
class SignInInvite extends ConsumerWidget {
  const SignInInvite({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    if (authState.isLoading || authState.valueOrNull != null) {
      return const SizedBox.shrink();
    }
    if (!ref.watch(authRepositoryProvider).isAvailable) return const SizedBox.shrink();

    final signingIn = ref.watch(authControllerProvider).signingIn;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Entre para salvar seus favoritos e seu progresso em qualquer aparelho.'),
            const PrivacyPolicyLink(),
            FilledButton.icon(
              onPressed: signingIn ? null : () => _signIn(context),
              icon: signingIn
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(signingIn ? 'Entrando...' : 'Entrar com Google'),
            ),
          ],
        ),
      ),
    );
  }
}
