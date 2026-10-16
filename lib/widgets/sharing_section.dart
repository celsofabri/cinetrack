import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/shared_profile_providers.dart';
import '../providers/sharing_providers.dart';
import '../repositories/shared_profile_repository.dart';
import '../shared_profile/shared_profile_models.dart';
import '../shared_profile/shared_profile_texts.dart';
import 'shared_profile_widgets.dart';

/// Literal texts of the consent dialogs (docs/81, "Textos literais").
const kSharingDialogs = {
  SharedSection.stats: (
    title: 'Compartilhar estatísticas com amigos?',
    body:
        'Seus amigos mútuos vão ver seus números (favoritos, filmes e episódios assistidos, séries '
        'assistidas e concluídas e tempo assistido), os totais deste mês e deste ano e desde quando '
        'você está no CineTrack, no seu perfil e nas comparações entre amigos. Você pode desligar '
        'quando quiser: desligar apaga na hora.',
  ),
  SharedSection.activity: (
    title: 'Compartilhar atividades recentes com amigos?',
    body:
        'Seus amigos mútuos vão ver até 10 das suas atividades mais recentes (seu perfil mostra '
        'as 3 últimas): títulos que você favoritou, filmes e episódios que marcou como assistidos '
        'e séries que concluiu. Só entra o que você fizer a partir de agora. Recomendações nunca '
        'aparecem como atividade. Você pode desligar quando quiser: desligar apaga na hora.',
  ),
  SharedSection.recs: (
    title: 'Compartilhar seus recomendados com amigos?',
    body:
        'Seus amigos mútuos vão ver os títulos que você marcou com Recomendo (até 50, na ordem da '
        'sua aba) e quantos são. Para você, nada muda nas suas recomendações. Você pode desligar '
        'quando quiser: desligar apaga na hora.',
  ),
};

const kSharingAllOff = 'Seus amigos veem só seu cartão (apelido e foto).';
const kSharingNoActivity = 'Suas próximas atividades aparecem aqui.';
const kSharingUncertain = 'Ainda não confirmado…';

String _label(SharedSection s) => switch (s) {
  SharedSection.stats => 'Estatísticas',
  SharedSection.activity => 'Atividades recentes',
  SharedSection.recs => 'Recomendados',
};

/// What the screen reader announces for a toggle (with its on/off state).
String _semantic(SharedSection s) => switch (s) {
  SharedSection.stats => 'Compartilhar estatísticas com amigos',
  SharedSection.activity => 'Compartilhar atividades recentes com amigos',
  SharedSection.recs => 'Compartilhar recomendados com amigos',
};

/// "O que seus amigos veem" (docs/81 RF-P, docs/82 §7.1, §10): only with
/// active friendships. Opt-in per section (D2), consent dialog with preview,
/// turning off without confirmation, "Atualizado há", "Atividades recentes".
class SharingSection extends ConsumerStatefulWidget {
  const SharingSection({super.key});

  @override
  ConsumerState<SharingSection> createState() => _SharingSectionState();
}

class _SharingSectionState extends ConsumerState<SharingSection> {
  bool _previewOpen = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(sharingControllerProvider.select((s) => s.notice), (prev, next) {
      if (next == null || next.id == prev?.id) return;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(next.text)));
    });
    final state = ref.watch(sharingControllerProvider);
    if (state.phase == SharingPhase.hidden) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final now = ref.read(serverClockProvider).now();
    final doc = state.confirmed ? state.doc : null;
    final sections = state.sections;
    final skeleton = !state.confirmed && state.hint == null && state.phase == SharingPhase.loading;
    final inline = switch (state.phase) {
      SharingPhase.offline => SharedProfileFailure.offlineMessage,
      SharingPhase.unavailable => SharedProfileFailure.unavailableMessage,
      _ => null,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text('O que seus amigos veem', style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 4),
          if (skeleton)
            const _Skeleton()
          else
            for (final s in kSharingSections) _toggle(s, state, sections.contains(s)),
          if (inline != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(inline, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (state.confirmed && sections.isEmpty)
            Card(
              margin: const EdgeInsets.only(top: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.badge_outlined),
                    const SizedBox(width: 12),
                    Expanded(child: Text(kSharingAllOff, style: theme.textTheme.bodyMedium)),
                  ],
                ),
              ),
            ),
          if (doc != null && doc.sharing.isNotEmpty && doc.updatedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                SharedProfileTexts.updated(doc.updatedAt!, now),
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (doc != null && doc.sharing.contains(SharedSection.stats) && doc.stats != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Semantics(
                expanded: _previewOpen,
                child: TextButton.icon(
                  onPressed: () => setState(() => _previewOpen = !_previewOpen),
                  icon: Icon(_previewOpen ? Icons.expand_less : Icons.expand_more),
                  label: const Text('Como seus amigos veem'),
                ),
              ),
            ),
            if (_previewOpen)
              SharedStatsView(stats: doc.stats!, tz: doc.tz, now: now, updatedAt: doc.updatedAt),
          ],
          if (doc != null && doc.sharing.contains(SharedSection.activity)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                header: true,
                child: Text('Atividades recentes', style: theme.textTheme.titleSmall),
              ),
            ),
            if ((doc.activity ?? const []).isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(kSharingNoActivity, style: theme.textTheme.bodyMedium),
              )
            else
              for (final a in doc.activity!.take(3)) SharedActivityTile(item: a, now: now),
          ],
        ],
      ),
    );
  }

  Widget _toggle(SharedSection s, SharingState state, bool on) {
    final uncertain = state.uncertain.containsKey(s);
    final running = state.busy == s;
    final enabled = state.confirmed && state.phase == SharingPhase.ready && !uncertain;
    final waiting =
        running || uncertain || (!state.confirmed && state.phase == SharingPhase.loading);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: on,
      title: Semantics(label: _semantic(s), excludeSemantics: true, child: Text(_label(s))),
      subtitle: uncertain ? const Text(kSharingUncertain) : null,
      secondary: waiting
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      onChanged: enabled ? (value) => _onChanged(s, value) : null,
    );
  }

  Future<void> _onChanged(SharedSection s, bool value) async {
    final controller = ref.read(sharingControllerProvider.notifier);
    final reason = controller.blockReason();
    if (reason != null) return controller.tell(reason);
    if (!value) return controller.turnOff(s);
    final content = await showSharingConsentDialog(context, s);
    if (content != null && mounted) await controller.turnOn(s, content);
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Semantics(
      label: 'Carregando o que seus amigos veem',
      child: Column(
        children: [
          for (var i = 0; i < kSharingSections.length; i++)
            Container(
              height: 40,
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
            ),
        ],
      ),
    );
  }
}

/// The consent dialog of [section] with the literal texts and the preview
/// (RF-P4). Returns the previewed content when the user taps "Compartilhar"
/// (null: "Cancelar", Esc or outside). While the data is not trustworthy
/// the button reads "Calculando…" and is disabled.
Future<SharedProfileContent?> showSharingConsentDialog(
  BuildContext context,
  SharedSection section,
) {
  final texts = kSharingDialogs[section]!;
  return showDialog<SharedProfileContent>(
    context: context,
    builder: (dialogContext) => Consumer(
      builder: (context, ref, _) {
        final preview = ref.watch(sharedPreviewProvider(section));
        final stats = preview?.stats;
        return AlertDialog(
          // The whole dialog scrolls: 320 px at 3x font still fits (RNF7).
          scrollable: true,
          title: Text(texts.title),
          content: SizedBox(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(texts.body),
                if (section == SharedSection.stats && stats != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: Text('Prévia', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  const SizedBox(height: 8),
                  // Everything the dialog promises: totals, this month and
                  // year (owner's zone), time watched, "No CineTrack desde".
                  SharedStatsView(
                    stats: stats,
                    tz: preview!.tz,
                    now: ref.read(serverClockProvider).now(),
                    totalGridKey: const Key('sharing-preview-grid'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: preview == null ? null : () => Navigator.of(dialogContext).pop(preview),
              child: Text(preview == null ? 'Calculando…' : 'Compartilhar'),
            ),
          ],
        );
      },
    ),
  );
}
