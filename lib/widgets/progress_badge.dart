import 'package:flutter/material.dart';

/// Small pill showing e.g. "Assistindo · 12/24" or "Concluído".
class ProgressBadge extends StatelessWidget {
  final int watched;
  final int total;

  const ProgressBadge({super.key, required this.watched, required this.total});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String label;
    final Color color;

    if (total == 0) {
      label = 'Sem episódios ainda';
      color = scheme.outline;
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
