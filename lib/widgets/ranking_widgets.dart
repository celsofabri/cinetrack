import 'package:flutter/material.dart';

import '../ranking/ranking_models.dart';
import '../ranking/ranking_table.dart';
import '../ranking/ranking_texts.dart';
import 'person_avatar.dart';

/// Pieces of the ranking screen (docs/90 RF-R7, T1, T3). Each row is ONE
/// focus and ONE Semantics node (a button) with the literal label of T1.

/// Rows narrower than this (× text scale) put the value under the name.
const double kRankingWideRow = 480;

class RankingRowTile extends StatelessWidget {
  final RankingRow row;
  final RankingMetric metric;
  final VoidCallback onOpen;

  const RankingRowTile({
    super.key,
    required this.row,
    required this.metric,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final me = row.who.isMe;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final position = row.position;
    final stale = RankingTexts.stale(row);
    final value = Text(
      RankingTexts.value(metric, row.value),
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final markers = <Widget>[
      if (me)
        _Tag(
          text: RankingTexts.you,
          color: scheme.primary,
          onColor: scheme.onPrimary,
        ),
      if (row.tied) Text('empatado', style: theme.textTheme.bodySmall),
      if (stale != null)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                stale,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
    ];
    return Semantics(
      button: true,
      label: RankingTexts.rowSemantics(row, metric),
      excludeSemantics: true,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        color: me ? scheme.primaryContainer : null,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= kRankingWideRow * scale;
                  final name = Text(
                    row.who.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  );
                  final details = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      name,
                      if (!wide) value,
                      if (markers.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: markers,
                        ),
                    ],
                  );
                  return Row(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(minWidth: 36 * scale),
                        child: Text(
                          position == null
                              ? ''
                              : RankingTexts.position(position),
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      PersonAvatar(
                        photoUrl: row.who.photoUrl,
                        nickname: row.who.name,
                        radius: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: details),
                      if (wide) ...[const SizedBox(width: 12), value],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  final Color onColor;

  const _Tag({required this.text, required this.color, required this.onColor});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: onColor),
        ),
      ),
    );
  }
}

/// Placeholder rows while loading (not focusable, hidden from the reader).
class RankingSkeleton extends StatelessWidget {
  final int rows;

  const RankingSkeleton({super.key, this.rows = 4});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ExcludeSemantics(
      child: Column(
        key: const Key('ranking-skeleton'),
        children: [
          for (var i = 0; i < rows; i++)
            Container(
              height: 56,
              margin: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
        ],
      ),
    );
  }
}

/// A notice block (banner D9, partial failure): text and an optional button.
class RankingNotice extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final IconData icon;
  final Key? actionKey;

  const RankingNotice({
    super.key,
    required this.text,
    this.action,
    this.onAction,
    this.icon = Icons.info_outline,
    this.actionKey,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(icon, color: scheme.onSecondaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: scheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            if (action != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: actionKey,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: onAction,
                  child: Text(action!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
