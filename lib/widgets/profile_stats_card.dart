import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/account_providers.dart';
import '../providers/catalog_sync_providers.dart';
import '../services/watch_time.dart';

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
        const SizedBox(height: 12),
        _WatchTimeCard(
            time: stats.watchTime, calculating: ref.watch(catalogSyncProvider).isRunning),
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

/// "Tempo assistido": dynamic units plus the accumulated hours. Never a made
/// up total: titles without a known runtime are left out and the card says
/// so (docs/18).
class _WatchTimeCard extends StatelessWidget {
  final WatchTime time;
  final bool calculating;

  const _WatchTimeCard({required this.time, required this.calculating});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headline = WatchTimeFormatter.format(time.minutes);
    final accumulated = WatchTimeFormatter.accumulatedHours(time.minutes);
    final note = time.isExact
        ? null
        : calculating
            ? 'Calculando… a duração de alguns títulos ainda está sendo buscada.'
            : [
                if (time.estimated > 0)
                  'Estimado: ${time.estimated} episódio(s) usam a duração média da série.',
                if (time.unknown > 0)
                  '${time.unknown} item(ns) sem duração disponível não entraram na soma.',
              ].join(' ');
    return Semantics(
      container: true,
      label: 'Tempo assistido: $headline. $accumulated.${note == null ? '' : ' $note'}',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 150, maxWidth: 480),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Tempo assistido', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Text(
                    time.isExact || time.minutes > 0 || !calculating ? headline : 'Calculando…',
                    style: theme.textTheme.headlineSmall,
                  ),
                  Text(accumulated, style: theme.textTheme.bodyMedium),
                  if (note != null) ...[
                    const SizedBox(height: 4),
                    Text(note, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
