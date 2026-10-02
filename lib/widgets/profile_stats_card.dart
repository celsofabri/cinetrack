import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/account_providers.dart';

/// Profile statistics (derived from the user's data, see `ProfileStats`).
class ProfileStatsCard extends ConsumerWidget {
  const ProfileStatsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(profileStatsProvider);
    final items = <(String, int)>[
      ('Favoritos', stats.favorites),
      ('Filmes favoritos', stats.movies),
      ('Séries favoritas', stats.series),
      ('Filmes assistidos', stats.watchedMovies),
      ('Episódios assistidos', stats.watchedEpisodes),
      ('Séries concluídas', stats.completedSeries),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text('Suas estatísticas', style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final (label, value) in items) _StatTile(label: label, value: value)],
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final int value;

  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '$label: $value',
      child: ExcludeSemantics(
        child: SizedBox(
          width: 150,
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$value', style: theme.textTheme.headlineSmall),
                  Text(label, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
