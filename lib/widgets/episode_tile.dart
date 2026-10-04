import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/episode_cache.dart';
import 'poster_image.dart';

/// One episode in the season list of the show details (docs/45): still image,
/// "E3 · Name", air date and duration, a collapsible description and the
/// watched check (48 px target). Future episodes are shown but disabled.
///
/// The whole row toggles (the InkWell is left out of the semantics: assistive
/// technology uses the checkbox, whose name says what it does).
class EpisodeTile extends StatefulWidget {
  final EpisodeCache episode;

  /// A write for this episode is in flight (spinner, no second tap).
  final bool busy;

  /// Called with the episode when toggled; never called for a disabled one.
  final VoidCallback onToggle;

  const EpisodeTile({super.key, required this.episode, required this.busy, required this.onToggle});

  /// Width from which the image goes beside the text instead of above it.
  static const wideBreakpoint = 480.0;
  static const _descriptionLines = 3;

  @override
  State<EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<EpisodeTile> {
  bool _expanded = false;

  static String _date(DateTime d) => DateFormat('dd/MM/yyyy').format(d);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ep = widget.episode;
    final aired = ep.hasAired;
    final enabled = aired && !widget.busy;
    final name = ep.name.isEmpty ? 'Episódio ${ep.episodeNumber}' : ep.name;
    final title = 'E${ep.episodeNumber} · $name';
    final muted = theme.colorScheme.onSurfaceVariant;

    final meta = <String>[
      if (ep.airDate != null) aired ? _date(ep.airDate!) : 'Estreia em ${_date(ep.airDate!)}',
      if (ep.runtime != null) '${ep.runtime} min',
    ].join(' · ');

    final check = _EpisodeCheck(
      watched: ep.watched,
      busy: widget.busy,
      enabled: enabled,
      label: ep.watched
          ? 'Assistido: desmarcar episódio ${ep.episodeNumber}, $name'
          : 'Marcar episódio ${ep.episodeNumber}, $name, como assistido',
      onToggle: widget.onToggle,
    );

    Widget still(double width) => Opacity(
      opacity: aired ? 1 : 0.55,
      child: ExcludeSemantics(
        child: PosterImage(
          posterPath: ep.stillPath,
          width: width,
          height: width * 9 / 16,
          imageSize: 'w300',
          placeholderIcon: Icons.tv_outlined,
        ),
      ),
    );

    Widget text() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        if (meta.isNotEmpty || ep.watched || !aired) ...[
          const SizedBox(height: 2),
          Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (meta.isNotEmpty)
                Text(meta, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              if (ep.watched)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Assistido',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                )
              else if (!aired)
                Text(
                  'Em breve',
                  style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        _Description(
          text: ep.overview,
          episodeLabel: 'episódio ${ep.episodeNumber}, $name',
          expanded: _expanded,
          onToggle: () => setState(() => _expanded = !_expanded),
        ),
      ],
    );

    return InkWell(
      excludeFromSemantics: true,
      onTap: enabled ? widget.onToggle : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= EpisodeTile.wideBreakpoint) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  check,
                  const SizedBox(width: 4),
                  still(168),
                  const SizedBox(width: 12),
                  Expanded(child: text()),
                ],
              );
            }
            // Narrow: check beside a column that has the image on top, so a
            // large font never squeezes the text between image and check.
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                check,
                const SizedBox(width: 4),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, inner) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        still(inner.maxWidth.clamp(0.0, 320.0)),
                        const SizedBox(height: 8),
                        text(),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _EpisodeCheck extends StatelessWidget {
  final bool watched;
  final bool busy;
  final bool enabled;
  final String label;
  final VoidCallback onToggle;

  const _EpisodeCheck({
    required this.watched,
    required this.busy,
    required this.enabled,
    required this.label,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    return SizedBox(
      width: 48,
      height: 48,
      child: Checkbox(
        value: watched,
        semanticLabel: label,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onChanged: enabled ? (_) => onToggle() : null,
      ),
    );
  }
}

/// Episode description: 3 lines with "Ler mais" / "Mostrar menos" only when it
/// does not fit, so short texts have no control. No description: a muted line.
class _Description extends StatelessWidget {
  final String text;
  final String episodeLabel;
  final bool expanded;
  final VoidCallback onToggle;

  const _Description({
    required this.text,
    required this.episodeLabel,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium;
    if (text.trim().isEmpty) {
      return Text(
        'Sem descrição disponível.',
        style: body?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: body),
          maxLines: EpisodeTile._descriptionLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: body,
              maxLines: expanded ? null : EpisodeTile._descriptionLines,
              overflow: expanded ? TextOverflow.clip : TextOverflow.ellipsis,
            ),
            if (overflows)
              Semantics(
                button: true,
                expanded: expanded,
                label: '${expanded ? 'Mostrar menos' : 'Ler mais'}: descrição do $episodeLabel',
                excludeSemantics: true,
                onTap: onToggle,
                child: TextButton(
                  onPressed: onToggle,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: Text(expanded ? 'Mostrar menos' : 'Ler mais'),
                ),
              ),
          ],
        );
      },
    );
  }
}
