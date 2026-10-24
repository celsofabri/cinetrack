import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../providers/shared_profile_providers.dart';
import '../providers/sharing_providers.dart';
import '../providers/social_providers.dart';
import '../providers/sync_providers.dart';
import '../repositories/shared_profile_repository.dart';
import '../shared_profile/shared_profile_models.dart';
import '../shared_profile/shared_profile_texts.dart';
import '../shared_profile/shared_stats_reading.dart';
import '../shared_profile/sharing_texts.dart';
import '../social/social_models.dart';
import 'shared_profile_widgets.dart';

const kSharingAllOff = 'Seus amigos veem só seu cartão (apelido e foto).';
const kSharingNoActivity = 'Suas próximas atividades aparecem aqui.';
const kSharingUncertain = 'Ainda não confirmado…';

/// The last controller notice already shown as a SnackBar: the Profile and
/// the shell both listen, only one shows it.
final sharingNoticeShownProvider = StateProvider<int>((ref) => 0);

/// Shows the controller's notices (T-S SnackBars) once.
void listenSharingNotices(WidgetRef ref, BuildContext context) {
  ref.listen(sharingControllerProvider.select((s) => s.notice), (prev, next) {
    if (next == null || next.id == prev?.id) return;
    if (ref.read(sharingNoticeShownProvider) >= next.id) return;
    ref.read(sharingNoticeShownProvider.notifier).state = next.id;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(next.text)));
  });
}

/// "O que seus amigos veem" (docs/81 RF-P, docs/95 RF-SC1): only with active
/// friendships. No switches any more (one consent: "Aparecer na busca"):
/// the state text (T-V), "Atualizado há", the preview "Como seus amigos
/// veem" (statistics and recommended titles) and "Atividades recentes".
class SharingSection extends ConsumerStatefulWidget {
  const SharingSection({super.key});

  @override
  ConsumerState<SharingSection> createState() => _SharingSectionState();
}

class _SharingSectionState extends ConsumerState<SharingSection> {
  bool _previewOpen = false;

  @override
  Widget build(BuildContext context) {
    listenSharingNotices(ref, context);
    final state = ref.watch(sharingControllerProvider);
    if (state.phase == SharingPhase.hidden) return const SizedBox.shrink();
    final mode = ref.watch(sharingModeProvider);
    final theme = Theme.of(context);
    final now = ref.read(serverClockProvider).now();
    final doc = state.confirmed ? state.doc : null;
    // What the preview "Como seus amigos veem" shows: the sections in the
    // written document (the same components as the friend's profile).
    final sharedStats = doc != null && doc.sharing.contains(SharedSection.stats) ? doc.stats : null;
    final sharedRecs = doc != null && doc.sharing.contains(SharedSection.recs) ? doc.recs : null;
    final skeleton = !state.confirmed && state.phase == SharingPhase.loading;
    final inline = switch (state.phase) {
      SharingPhase.offline => SharedProfileFailure.offlineMessage,
      SharingPhase.unavailable => SharedProfileFailure.unavailableMessage,
      _ => null,
    };
    final statusText = switch (mode) {
      SharingMode.off => kSharingAllOff,
      SharingMode.on => SharingTexts.viewOn,
      SharingMode.review => SharingTexts.review,
      SharingMode.legacy => SharingTexts.legacy(doc?.sharing ?? const {}),
      SharingMode.uncertain => kSharingUncertain,
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
          if (skeleton) const _Skeleton(),
          if (inline != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(inline, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (statusText != null)
            Card(
              key: const Key('sharing-status'),
              margin: const EdgeInsets.only(top: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(mode == SharingMode.off ? Icons.badge_outlined : Icons.people_outline),
                    const SizedBox(width: 12),
                    Expanded(child: Text(statusText, style: theme.textTheme.bodyMedium)),
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
          if (doc != null && (sharedStats != null || sharedRecs != null)) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Semantics(
                expanded: _previewOpen,
                child: TextButton.icon(
                  onPressed: () => setState(() => _previewOpen = !_previewOpen),
                  icon: Icon(_previewOpen ? Icons.expand_less : Icons.expand_more),
                  label: const Text(SharingTexts.previewTitle),
                ),
              ),
            ),
            if (_previewOpen && sharedStats != null)
              SharedStatsView(stats: sharedStats, tz: doc.tz, now: now, updatedAt: doc.updatedAt),
            if (_previewOpen && sharedRecs != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Semantics(
                  header: true,
                  child: Text('Recomendados', style: theme.textTheme.titleSmall),
                ),
              ),
              SharedRecsView(
                reading: SharedRecsReading.of(sharedRecs),
                emptyText: SharedProfileTexts.ownNoRecs,
              ),
            ],
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
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Semantics(
      label: 'Carregando o que seus amigos veem',
      child: Container(
        height: 48,
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

/// The single switch "Aparecer na busca" (docs/95 RF-SC1, T-I) for the
/// "Amizades" card, with the E2 ("Revisar") and E3 (legacy) lines.
class SearchSharingTile extends ConsumerWidget {
  final SocialProfile profile;

  const SearchSharingTile({super.key, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(sharingModeProvider);
    final sharing = ref.watch(sharingControllerProvider);
    final offline = ref.watch(syncStatusProvider.select((s) => s.offline));
    final socialBusy = ref.watch(socialControllerProvider.select((s) => s.busy));
    final controller = ref.read(sharingControllerProvider.notifier);
    final theme = Theme.of(context);
    final value = switch (mode) {
      SharingMode.on || SharingMode.review => true,
      SharingMode.off || SharingMode.legacy => false,
      _ => profile.discoverable,
    };
    final settled = switch (mode) {
      SharingMode.on || SharingMode.review || SharingMode.off || SharingMode.legacy => true,
      _ => false,
    };
    final enabled = settled && !sharing.busy && !offline && !socialBusy;
    final waiting = sharing.busy || mode == SharingMode.uncertain || mode == SharingMode.pending;
    final tile = SwitchListTile(
      key: const Key('search-sharing-switch'),
      contentPadding: EdgeInsets.zero,
      value: value,
      title: Semantics(
        label: SharingTexts.switchSemantics,
        excludeSemantics: true,
        child: const Text(SharingTexts.switchTitle),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(SharingTexts.switchSubtitle),
          if (mode == SharingMode.uncertain) const Text(kSharingUncertain),
        ],
      ),
      secondary: waiting
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      onChanged: enabled
          ? (on) => on ? turnSearchOn(context, ref) : turnSearchOff(context, ref)
          : null,
    );
    final sections = sharing.doc?.sharing ?? const <SharedSection>{};
    final actionsEnabled = enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A disabled switch still answers a tap with the reason (offline...).
        if (enabled)
          tile
        else
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              final reason = controller.blockReason();
              if (reason != null) controller.tell(reason);
            },
            child: tile,
          ),
        if (mode == SharingMode.review)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(SharingTexts.review, style: theme.textTheme.bodyMedium),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: actionsEnabled ? () => openSharingNotice(context, ref) : null,
                child: const Text(SharingTexts.reviewButton),
              ),
            ],
          ),
        if (mode == SharingMode.legacy) ...[
          Text(SharingTexts.legacy(sections), style: theme.textTheme.bodyMedium),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: actionsEnabled ? () => controller.setSearchSharing(false) : null,
                child: const Text(SharingTexts.legacyStop),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: actionsEnabled ? () => turnSearchOn(context, ref) : null,
                child: const Text(SharingTexts.legacyAll),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// E0/E3 -> E1 (RF-SC2): T-C first; nothing is written before "Ligar".
Future<void> turnSearchOn(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(sharingControllerProvider.notifier);
  final reason = controller.blockReason();
  if (reason != null) return controller.tell(reason);
  final content = await showSearchConsentDialog(context);
  if (content != null) await controller.setSearchSharing(true, content: content);
}

/// E1/E2/E3 -> E0 (RF-SC3): T-D first.
Future<void> turnSearchOff(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(sharingControllerProvider.notifier);
  final reason = controller.blockReason();
  if (reason != null) return controller.tell(reason);
  final confirmed = await showSearchOffDialog(context);
  if (confirmed == true) await controller.setSearchSharing(false);
}

/// "Como seus amigos veem" for [content] (the 3 sections; activities start
/// empty): the same components as the friend's profile.
class SharingPreview extends StatelessWidget {
  final SharedProfileContent content;
  final DateTime now;

  const SharingPreview({super.key, required this.content, required this.now});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = content.stats;
    final recs = content.recs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(SharingTexts.previewTitle, style: theme.textTheme.titleSmall),
        ),
        const SizedBox(height: 8),
        if (stats != null)
          SharedStatsView(
            stats: stats,
            tz: content.tz,
            now: now,
            totalGridKey: const Key('sharing-preview-grid'),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Semantics(
            header: true,
            child: Text('Atividades recentes', style: theme.textTheme.titleSmall),
          ),
        ),
        Text(kSharingNoActivity, style: theme.textTheme.bodyMedium),
        if (recs != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Semantics(
              header: true,
              child: Text('Recomendados', style: theme.textTheme.titleSmall),
            ),
          ),
          SharedRecsView(
            key: const Key('sharing-preview-recs'),
            reading: SharedRecsReading.of(recs),
            emptyText: SharedProfileTexts.ownNoRecs,
          ),
        ],
      ],
    );
  }
}

/// T-C (RF-SC2, RF-SC5): returns the previewed content when the user taps
/// "Ligar" (null: "Cancelar"/"Agora não", Esc or outside). While the data is
/// not trustworthy the button reads "Calculando…" and is disabled.
/// [fromForm] = the activation form ("Agora não"); there [notNowResult] tells
/// "Agora não" (true) from Esc/outside (null).
Future<SharedProfileContent?> showSearchConsentDialog(
  BuildContext context, {
  bool fromForm = false,
  void Function()? onNotNow,
}) {
  return showDialog<SharedProfileContent>(
    context: context,
    builder: (dialogContext) => Consumer(
      builder: (context, ref, _) {
        final preview = ref.watch(sharedPreviewProvider);
        return AlertDialog(
          // The whole dialog scrolls: 320 px at 3x font still fits.
          scrollable: true,
          title: const Text(SharingTexts.consentTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(SharingTexts.consentBody),
              const SizedBox(height: 8),
              for (final item in SharingTexts.consentItems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ExcludeSemantics(child: Text('•  ')),
                      Expanded(child: Text(item)),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              const Text(SharingTexts.consentClosing),
              if (preview != null) ...[
                const SizedBox(height: 16),
                SharingPreview(content: preview, now: ref.read(serverClockProvider).now()),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                onNotNow?.call();
                Navigator.of(dialogContext).pop();
              },
              child: Text(fromForm ? SharingTexts.notNow : SharingTexts.cancel),
            ),
            FilledButton(
              onPressed: preview == null ? null : () => Navigator.of(dialogContext).pop(preview),
              child: Text(preview == null ? SharingTexts.calculating : SharingTexts.turnOn),
            ),
          ],
        );
      },
    ),
  );
}

/// T-D (RF-SC3): true = "Desligar".
Future<bool?> showSearchOffDialog(BuildContext context) => showDialog<bool>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    scrollable: true,
    title: const Text(SharingTexts.offTitle),
    content: const Text(SharingTexts.offBody),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(false),
        child: const Text(SharingTexts.cancel),
      ),
      FilledButton(
        onPressed: () => Navigator.of(dialogContext).pop(true),
        child: const Text(SharingTexts.turnOff),
      ),
    ],
  ),
);

/// What the person chose in notice A or B (null = closed without choosing).
sealed class SharingNoticeChoice {
  const SharingNoticeChoice();
}

/// "OK" (A) with the previewed content.
class NoticeAccepted extends SharingNoticeChoice {
  final SharedProfileContent content;

  const NoticeAccepted(this.content);
}

/// "Desligar" (A) / "Parar de compartilhar" (B).
class NoticeStop extends SharingNoticeChoice {
  const NoticeStop();
}

/// "Aparecer na busca e compartilhar tudo" (B): goes through T-C.
class NoticeShareAll extends SharingNoticeChoice {
  const NoticeShareAll();
}

/// T-A (RF-SC4). [sections] = what the person already shares.
Future<SharingNoticeChoice?> showReviewNotice(BuildContext context, Set<SharedSection> sections) {
  return showDialog<SharingNoticeChoice>(
    context: context,
    builder: (dialogContext) => Consumer(
      builder: (context, ref, _) {
        final preview = ref.watch(sharedPreviewProvider);
        final controller = ref.read(sharingControllerProvider.notifier);
        ref.watch(sharingControllerProvider.select((s) => (s.busy, s.uncertain, s.confirmed)));
        ref.watch(syncStatusProvider.select((s) => s.offline));
        final blocked = controller.blockReason() != null;
        return AlertDialog(
          scrollable: true,
          title: const Text(SharingTexts.noticeTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(SharingTexts.noticeBody),
              if (sections.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(SharingTexts.noticeAlready(sections)),
              ],
              const SizedBox(height: 8),
              Text(
                sections.isEmpty ? SharingTexts.noticeClosing : SharingTexts.noticeClosingAlready,
              ),
              if (preview != null) ...[
                const SizedBox(height: 16),
                SharingPreview(content: preview, now: ref.read(serverClockProvider).now()),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: blocked ? null : () => Navigator.of(dialogContext).pop(const NoticeStop()),
              child: const Text(SharingTexts.turnOff),
            ),
            FilledButton(
              onPressed: preview == null || blocked
                  ? null
                  : () => Navigator.of(dialogContext).pop(NoticeAccepted(preview)),
              child: Text(preview == null ? SharingTexts.calculating : SharingTexts.ok),
            ),
          ],
        );
      },
    ),
  );
}

/// T-B (legacy, E3): nothing is deleted without a choice.
Future<SharingNoticeChoice?> showLegacyNotice(BuildContext context, Set<SharedSection> sections) {
  return showDialog<SharingNoticeChoice>(
    context: context,
    builder: (dialogContext) => Consumer(
      builder: (context, ref, _) {
        final controller = ref.read(sharingControllerProvider.notifier);
        ref.watch(sharingControllerProvider.select((s) => (s.busy, s.uncertain, s.confirmed)));
        ref.watch(syncStatusProvider.select((s) => s.offline));
        final blocked = controller.blockReason() != null;
        return AlertDialog(
          scrollable: true,
          title: const Text(SharingTexts.legacyTitle),
          content: Text(SharingTexts.legacyBody(sections)),
          actions: [
            TextButton(
              onPressed: blocked ? null : () => Navigator.of(dialogContext).pop(const NoticeStop()),
              child: const Text(SharingTexts.legacyStop),
            ),
            FilledButton(
              onPressed: blocked
                  ? null
                  : () => Navigator.of(dialogContext).pop(const NoticeShareAll()),
              child: const Text(SharingTexts.legacyAll),
            ),
          ],
        );
      },
    ),
  );
}

/// Opens the notice that fits the confirmed state (A for E2, B for E3),
/// marks it seen for this session and runs the choice. "Desligar" in A and
/// "Parar de compartilhar" in B need no T-D (the notice explains it);
/// closing without a choice writes nothing.
Future<void> openSharingNotice(BuildContext context, WidgetRef ref) async {
  final uid = ref.read(currentUidProvider);
  final mode = ref.read(sharingModeProvider);
  if (uid == null || (mode != SharingMode.review && mode != SharingMode.legacy)) return;
  ref.read(sharingNoticeSeenProvider.notifier).update((seen) => {...seen, uid});
  final sections = ref.read(sharingControllerProvider).doc?.sharing ?? const <SharedSection>{};
  final choice = mode == SharingMode.review
      ? await showReviewNotice(context, sections)
      : await showLegacyNotice(context, sections);
  if (!context.mounted) return;
  final controller = ref.read(sharingControllerProvider.notifier);
  switch (choice) {
    case NoticeAccepted(:final content):
      await controller.setSearchSharing(true, content: content);
    case NoticeStop():
      await controller.setSearchSharing(false);
    case NoticeShareAll():
      await turnSearchOn(context, ref);
    case null:
      break;
  }
}

/// Opens notice A/B once per session when the confirmed state asks for it
/// (RF-SC4, ❓1), with the shell visible; shows the T-S SnackBars anywhere.
class SharingNoticeHost extends ConsumerStatefulWidget {
  final Widget child;

  const SharingNoticeHost({super.key, required this.child});

  @override
  ConsumerState<SharingNoticeHost> createState() => _SharingNoticeHostState();
}

class _SharingNoticeHostState extends ConsumerState<SharingNoticeHost> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sharingNoticeDueProvider, (_, due) => _maybeOpen(due), fireImmediately: true);
  }

  void _maybeOpen(SharingNoticeKind? due) {
    if (due == null || _open) return;
    _open = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        // Still due once the frame is done (nothing changed meanwhile).
        if (mounted && ref.read(sharingNoticeDueProvider) != null) {
          await openSharingNotice(context, ref);
        }
      } finally {
        _open = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    listenSharingNotices(ref, context);
    return widget.child;
  }
}
