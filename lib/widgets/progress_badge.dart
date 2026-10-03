import 'package:flutter/material.dart';

import '../services/favorite_status.dart';

/// Small pill showing e.g. "Assistindo · 12/24" or "Concluído".
class ProgressBadge extends StatelessWidget {
  final int watched;
  final int total;

  /// Every episode that has aired is watched, but some have not aired yet (or
  /// are specials): shown as "Em dia" instead of "Assistindo".
  final bool caughtUp;

  /// Partial catalog: the numbers cover only the seasons downloaded so far.
  final bool approximate;

  const ProgressBadge({
    super.key,
    required this.watched,
    required this.total,
    this.caughtUp = false,
    this.approximate = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String label;
    final Color color;

    if (approximate && total > 0) {
      label = 'Parcial · $watched/$total';
      color = scheme.tertiary;
    } else if (total == 0) {
      label = 'Sem episódios ainda';
      color = scheme.outline;
    } else if (caughtUp && watched < total) {
      label = 'Em dia · $watched/$total';
      color = scheme.primary;
    } else if (watched == 0) {
      label = 'Não iniciado · 0/$total';
      color = scheme.outline;
    } else if (watched == total) {
      label = 'Concluído · $total/$total';
      color = scheme.primary;
    } else {
      label = 'Assistindo · $watched/$total';
      color = scheme.tertiary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// Badge of a favorite series from its [FavoriteStatus]: never a fake 0 while
/// the seasons of a new device are still being downloaded.
class SeriesStatusBadge extends StatelessWidget {
  final FavoriteStatus status;

  const SeriesStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = status.progress;
    if (progress != null) {
      return ProgressBadge(
        watched: progress.watchedCount,
        total: progress.totalCount,
        caughtUp: progress.isCaughtUp,
        approximate: status.approximate,
      );
    }
    final calculating = status.state == WatchState.calculating;
    final color = calculating ? scheme.outline : scheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (calculating) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              calculating ? 'Calculando progresso…' : 'Progresso indisponível',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
