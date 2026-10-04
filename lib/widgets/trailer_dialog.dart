import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/title_video.dart';
import '../providers/account_providers.dart' show urlOpenerProvider;
import '../providers/providers.dart';
import '../services/tmdb_exception.dart';
import 'trailer_player.dart';

const kTrailerUnavailableMessage = 'Este título ainda não tem trailer disponível.';
const kTrailerErrorMessage = 'Não foi possível carregar o trailer. Verifique a conexão.';
const kTrailerPrivacyNote =
    'O vídeo é carregado do YouTube (Google), no modo de privacidade '
    'aprimorada, só depois que você abre o trailer. O CineTrack não envia nenhum dado seu.';
const kTrailerCloseHint =
    'Para fechar: botão Fechar, tecla Esc ou toque fora. Com o foco dentro '
    'do vídeo o Esc é do YouTube; use o botão Fechar.';
const kTrailerExternalNote =
    'O trailer abre no YouTube (Google), fora do CineTrack. '
    'O CineTrack não envia nenhum dado seu.';

/// "Assistir trailer" chip of the details screens. Hidden when TMDB has no
/// trailer for the title; while the list is loading (or failed) it is shown,
/// and the dialog itself handles loading / error / retry. Tapping opens
/// [showTrailerDialog]; before that, nothing from YouTube is requested.
class TrailerButton extends ConsumerWidget {
  final TitleKey titleKey;
  final String title;

  const TrailerButton({super.key, required this.titleKey, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trailer = ref.watch(titleTrailerProvider(titleKey));
    if (trailer.hasValue && trailer.value == null) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'Assistir trailer de $title',
      excludeSemantics: true,
      onTap: () => showTrailerDialog(context, titleKey: titleKey, title: title),
      child: ActionChip(
        avatar: const Icon(Icons.play_circle_outline, size: 18),
        label: const Text('Assistir trailer'),
        tooltip: 'Assistir trailer de $title',
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onPressed: () => showTrailerDialog(context, titleKey: titleKey, title: title),
      ),
    );
  }
}

Future<void> showTrailerDialog(
  BuildContext context, {
  required TitleKey titleKey,
  required String title,
}) {
  return showDialog<void>(
    context: context,
    // Esc, the close button and a tap outside all close it.
    barrierDismissible: true,
    barrierLabel: 'Fechar trailer',
    builder: (_) => TrailerDialog(titleKey: titleKey, title: title),
  );
}

class TrailerDialog extends ConsumerWidget {
  final TitleKey titleKey;
  final String title;

  const TrailerDialog({super.key, required this.titleKey, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trailer = ref.watch(titleTrailerProvider(titleKey));
    final theme = Theme.of(context);
    // The player keeps a 16:9 box that also fits short (landscape) screens.
    final height = MediaQuery.sizeOf(context).height;
    final playerWidth = ((height - 230) * 16 / 9).clamp(240.0, 860.0);

    final Widget body = trailer.when(
      loading: () => const _Status(busy: true, message: 'Carregando trailer…'),
      error: (error, _) => _Status(
        icon: Icons.error_outline,
        message: error is TmdbException ? error.message : kTrailerErrorMessage,
        action: FilledButton.tonal(
          onPressed: () => ref.invalidate(titleTrailerProvider(titleKey)),
          child: const Text('Tentar novamente'),
        ),
      ),
      data: (video) => video == null
          ? const _Status(icon: Icons.videocam_off_outlined, message: kTrailerUnavailableMessage)
          : _Ready(video: video, title: title, playerWidth: playerWidth),
    );

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Trailer de $title',
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Trailer: $title',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      autofocus: true,
                      tooltip: 'Fechar trailer',
                      icon: const Icon(Icons.close),
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loading / empty / error body: fixed minimum height so the dialog does not
/// jump between states.
class _Status extends StatelessWidget {
  final bool busy;
  final IconData? icon;
  final String message;
  final Widget? action;

  const _Status({this.busy = false, this.icon, required this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 160),
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              const SizedBox(width: 28, height: 28, child: CircularProgressIndicator())
            else if (icon != null)
              Icon(icon, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class _Ready extends ConsumerStatefulWidget {
  final TitleVideo video;
  final String title;
  final double playerWidth;

  const _Ready({required this.video, required this.title, required this.playerWidth});

  @override
  ConsumerState<_Ready> createState() => _ReadyState();
}

class _ReadyState extends ConsumerState<_Ready> {
  bool _openFailed = false;

  Future<void> _openOnYoutube() async {
    var ok = false;
    try {
      ok = await ref.read(urlOpenerProvider)(widget.video.watchUri);
    } catch (_) {}
    if (mounted) setState(() => _openFailed = !ok);
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(trailerPlayerBuilderProvider);
    final theme = Theme.of(context);
    final label = player == null ? 'Assistir no YouTube' : 'Abrir no YouTube';
    final open = player == null
        ? FilledButton.icon(
            onPressed: _openOnYoutube,
            icon: const Icon(Icons.open_in_new),
            label: Text(label),
          )
        : TextButton.icon(
            onPressed: _openOnYoutube,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(label),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (player != null)
          Center(
            child: SizedBox(
              width: widget.playerWidth,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Seen through the (transparent) frame while YouTube
                      // loads, which can take several seconds. Static on
                      // purpose: nothing animates behind the player.
                      ExcludeSemantics(
                        child: ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Center(
                            child: Text('Carregando vídeo…', style: theme.textTheme.bodyMedium),
                          ),
                        ),
                      ),
                      Semantics(
                        label: 'Player do trailer de ${widget.title}',
                        child: player(context, widget.video, widget.title),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              widget.video.name.isEmpty ? 'Trailer de ${widget.title}' : widget.video.name,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          ),
        const SizedBox(height: 8),
        Align(alignment: player == null ? Alignment.center : Alignment.centerLeft, child: open),
        if (_openFailed)
          Semantics(
            liveRegion: true,
            child: Text(
              'Não foi possível abrir o YouTube.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
        if (player != null) ...[
          Text(
            kTrailerCloseHint,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          player == null ? kTrailerExternalNote : kTrailerPrivacyNote,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
