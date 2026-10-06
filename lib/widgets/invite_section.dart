import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/social_providers.dart';
import '../social/invite_code.dart';
import '../social/social_models.dart';
import 'share_link.dart';

/// "Convite por link" inside the active social card (docs/68): create one link
/// (the code is the secret id of `invites/{code}`), copy or share it, see when
/// it expires, revoke it. One active invite per user. Creating, replacing and
/// revoking need the server, so they are disabled with the reason while offline;
/// copying works offline (it is local).
class InviteSection extends ConsumerStatefulWidget {
  final SocialProfile profile;
  final bool offline;

  /// Another social action is running (all buttons wait).
  final bool busy;

  const InviteSection({
    super.key,
    required this.profile,
    required this.offline,
    required this.busy,
  });

  @override
  ConsumerState<InviteSection> createState() => _InviteSectionState();
}

class _InviteSectionState extends ConsumerState<InviteSection> {
  int _days = InviteValidity.defaultDays;
  bool _working = false;

  bool get _locked => widget.busy || _working || widget.offline;

  void _say(String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _create({required bool replace}) async {
    if (replace && !await _confirmReplace()) return;
    if (!mounted) return;
    setState(() => _working = true);
    final failure = await ref
        .read(socialControllerProvider.notifier)
        .createInvite(days: replace ? InviteValidity.defaultDays : _days);
    if (!mounted) return;
    setState(() => _working = false);
    _say(
      failure?.message ??
          (replace ? 'Novo link criado. O anterior parou de funcionar.' : 'Link criado.'),
    );
  }

  Future<void> _revoke() async {
    if (!await _confirmRevoke()) return;
    if (!mounted) return;
    setState(() => _working = true);
    final failure = await ref.read(socialControllerProvider.notifier).revokeInvite();
    if (!mounted) return;
    setState(() => _working = false);
    _say(failure?.message ?? 'Convite revogado. O link parou de funcionar.');
  }

  Future<bool> _confirmRevoke() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Revogar o convite?'),
          content: const Text(
            'O link e o código deixam de funcionar na hora. Quem já pediu amizade por ele '
            'continua com o pedido. Ninguém é avisado.',
          ),
          actions: [
            TextButton(
              autofocus: true,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Revogar'),
            ),
          ],
        ),
      ) ??
      false;

  Future<bool> _confirmReplace() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Criar um novo link?'),
          content: const Text(
            'O link atual deixa de funcionar na hora e um novo é criado '
            '(válido por ${InviteValidity.defaultDays} dias).',
          ),
          actions: [
            TextButton(
              autofocus: true,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Criar novo link'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _copy(String text, String done) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _say(done);
    } catch (_) {
      if (mounted) _say('Não foi possível copiar. Selecione o texto e copie manualmente.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invite = widget.profile.invite;
    final now = DateTime.now();
    final expired = invite?.isExpired(now) ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text('Convite por link', style: theme.textTheme.titleSmall)),
        const SizedBox(height: 4),
        Text(
          'Quem abrir o link vê seu apelido e sua foto e pode pedir amizade; você decide se aceita. '
          'Funciona mesmo com "Aparecer na busca" desligado. Você pode revogar quando quiser.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (invite != null && invite.unreadable)
          _Unreadable(onRetry: () => ref.read(socialControllerProvider.notifier).refresh())
        else if (invite == null || invite.missing)
          _Create(
            days: _days,
            onDays: (v) => setState(() => _days = v),
            onCreate: _locked ? null : () => _create(replace: false),
            working: _working,
          )
        else
          _Active(
            invite: invite,
            expired: expired,
            link: InviteLink.build(ref.watch(inviteLinkBaseProvider), invite.code),
            onCopyLink: (link) => _copy(link, 'Link copiado.'),
            onCopyCode: () => _copy(invite.code, 'Código copiado.'),
            onNew: _locked ? null : () => _create(replace: true),
            onRevoke: _locked ? null : _revoke,
            working: _working,
          ),
        if (widget.offline) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              'Sem conexão. Criar e revogar convites exige internet.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ],
    );
  }
}

/// The invite could not be read: never "create" here (it would replace an active invite).
class _Unreadable extends StatelessWidget {
  final VoidCallback onRetry;

  const _Unreadable({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(liveRegion: true, child: const Text('Não foi possível ler o seu convite agora.')),
        TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Tentar de novo'),
        ),
      ],
    );
  }
}

class _Create extends StatelessWidget {
  final int days;
  final ValueChanged<int> onDays;
  final VoidCallback? onCreate;
  final bool working;

  const _Create({
    required this.days,
    required this.onDays,
    required this.onCreate,
    required this.working,
  });

  static String label(int d) => d == 1 ? '1 dia' : '$d dias';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: DropdownButtonFormField<int>(
            initialValue: days,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Validade do link',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final d in InviteValidity.options)
                DropdownMenuItem(value: d, child: Text(label(d))),
            ],
            onChanged: onCreate == null ? null : (v) => onDays(v ?? days),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onCreate,
          icon: working
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: Text(working ? 'Criando...' : 'Criar link de convite'),
        ),
      ],
    );
  }
}

class _Active extends ConsumerWidget {
  final InviteInfo invite;
  final bool expired;
  final String link;
  final ValueChanged<String> onCopyLink;
  final VoidCallback onCopyCode;
  final VoidCallback? onNew;
  final VoidCallback? onRevoke;
  final bool working;

  const _Active({
    required this.invite,
    required this.expired,
    required this.link,
    required this.onCopyLink,
    required this.onCopyCode,
    required this.onNew,
    required this.onRevoke,
    required this.working,
  });

  String _validity(DateTime now) {
    final end = invite.expiresAt;
    if (expired) return 'Este convite expirou. Crie um novo link ou remova este.';
    if (end == null) return 'Convite ativo.';
    final days = invite.daysLeft(now);
    final when = formatSocialDate(end);
    return days <= 1 ? 'Expira hoje ou amanhã ($when).' : 'Válido até $when (faltam $days dias).';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final share = ref.watch(shareLinkProvider);
    final now = DateTime.now();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: expired,
          child: Text(
            _validity(now),
            style: expired ? TextStyle(color: theme.colorScheme.error) : null,
          ),
        ),
        if (!expired) ...[
          const SizedBox(height: 8),
          Text('Link', style: theme.textTheme.labelMedium),
          SelectableText(link, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Text('Código', style: theme.textTheme.labelMedium),
          SelectableText(
            invite.code,
            style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            if (!expired) ...[
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => onCopyLink(link),
                icon: const Icon(Icons.copy),
                label: const Text('Copiar link'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onCopyCode,
                icon: const Icon(Icons.tag),
                label: const Text('Copiar código'),
              ),
              if (share != null)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => share(
                    title: 'Convite do CineTrack',
                    text: 'Vamos ser amigos no CineTrack? Abra o convite:',
                    url: link,
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Compartilhar'),
                ),
            ],
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onNew,
              icon: const Icon(Icons.autorenew),
              label: const Text('Novo link'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: onRevoke,
              icon: const Icon(Icons.link_off),
              label: Text(expired ? 'Remover convite' : 'Revogar convite'),
            ),
          ],
        ),
        if (working)
          Semantics(
            liveRegion: true,
            child: const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Atualizando o convite...'),
            ),
          ),
      ],
    );
  }
}
