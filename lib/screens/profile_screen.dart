import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/account_providers.dart';
import '../providers/providers.dart';
import '../widgets/account_widgets.dart';
import '../widgets/delete_account_dialog.dart';
import '../widgets/nickname_dialog.dart';
import '../widgets/privacy_summary.dart';
import '../widgets/profile_stats_card.dart';

/// Profile: who is signed in, nickname, statistics, privacy, sign out and
/// account deletion.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(profileProvider).valueOrNull;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: user == null
          ? const Center(child: Text('Você não está conectado.'))
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Center(child: UserAvatar(user: user, radius: 48)),
                const SizedBox(height: 16),
                Semantics(
                  header: true,
                  child: Text(
                    ref.watch(displayLabelProvider),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                if (user.email != null && user.email != user.label) ...[
                  const SizedBox(height: 4),
                  Text(user.email!, textAlign: TextAlign.center),
                ],
                if (user.createdAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Membro desde ${_formatDate(user.createdAt!)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  child: TextButton.icon(
                    onPressed: () => showNicknameDialog(context, current: profile?.nickname),
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(profile?.nickname == null ? 'Definir apelido' : 'Editar apelido'),
                  ),
                ),
                if (profile?.deleting ?? false) ...[
                  const SizedBox(height: 8),
                  _ResumeDeletionCard(onResume: () => _deleteAccount(context, ref)),
                ],
                const SizedBox(height: 16),
                const ProfileStatsCard(),
                const SizedBox(height: 24),
                const PrivacySummary(),
                const SizedBox(height: 24),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _confirmSignOut(context, ref),
                      icon: const Icon(Icons.logout),
                      label: const Text('Sair'),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      onPressed: () => _deleteAccount(context, ref),
                      icon: const Icon(Icons.delete_forever_outlined),
                      label: const Text('Excluir minha conta e dados'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  static String _formatDate(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year}';
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final deleted = await showDeleteAccountDialog(context);
    if (deleted) messenger?.showSnackBar(const SnackBar(content: Text('Conta excluída.')));
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sair da conta?'),
        content: const Text('Seus dados continuam salvos na sua conta.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sair'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(authControllerProvider.notifier).signOut();
    if (context.mounted) context.go('/');
  }
}

class _ResumeDeletionCard extends StatelessWidget {
  final VoidCallback onResume;

  const _ResumeDeletionCard({required this.onResume});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('A exclusão da sua conta foi iniciada e não terminou.'),
            FilledButton(onPressed: onResume, child: const Text('Concluir exclusão')),
          ],
        ),
      ),
    );
  }
}
