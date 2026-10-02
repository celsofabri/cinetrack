import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/tv_season_summary.dart';
import '../providers/providers.dart';
import '../services/progress_calculator.dart';
import '../services/season_progress_calculator.dart';
import '../services/tmdb_exception.dart';
import '../widgets/error_state.dart';
import '../widgets/poster_image.dart';
import '../widgets/progress_badge.dart';
import '../widgets/auth_gate.dart';

class TvDetailsScreen extends ConsumerWidget {
  final int tvId;

  const TvDetailsScreen({super.key, required this.tvId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesListProvider).value ?? [];
    final matches = favorites.where((f) => f.id == tvId && f.mediaType == MediaType.tv);
    final item = matches.isEmpty ? null : matches.first;

    if (item == null) {
      return const Scaffold(
        body: Center(child: Text('Esta série não está mais nos seus favoritos.')),
      );
    }

    final progress = ProgressCalculator.compute(item.seasons ?? const []);

    return Scaffold(
      appBar: AppBar(
        title: Text(item.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remover dos favoritos',
            onPressed: () {
              ref.read(favoritesRepositoryProvider).remove(item.id, MediaType.tv);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _Header(item: item, progress: progress)),
          if (item.seasonSummaries == null || item.seasonSummaries!.isEmpty)
            SliverToBoxAdapter(
              child: ErrorState(
                message: 'Não foi possível carregar as temporadas ainda.',
                onRetry: () =>
                    ref.read(favoritesRepositoryProvider).reloadSeasonSummaries(item.id),
              ),
            )
          else
            SliverList.builder(
              itemCount: item.seasonSummaries!.length,
              itemBuilder: (context, index) {
                final summary = item.seasonSummaries![index];
                return _SeasonTile(tvId: item.id, summary: summary);
              },
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final FavoriteItem item;
  final SeriesProgress progress;

  const _Header({required this.item, required this.progress});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PosterImage(posterPath: item.posterPath, width: 120, height: 180),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ProgressBadge(watched: progress.watchedCount, total: progress.totalCount),
                    const SizedBox(height: 8),
                    if (progress.nextEpisode != null)
                      Text(
                        'Próximo: T${progress.nextSeasonNumber} '
                        'E${progress.nextEpisode!.episodeNumber} · '
                        '${progress.nextEpisode!.name}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            item.overview.isEmpty ? 'Sem sinopse disponível.' : item.overview,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SeasonTile extends ConsumerStatefulWidget {
  final int tvId;
  final TvSeasonSummary summary;

  const _SeasonTile({required this.tvId, required this.summary});

  @override
  ConsumerState<_SeasonTile> createState() => _SeasonTileState();
}

class _SeasonTileState extends ConsumerState<_SeasonTile> {
  // True while the season-level check is mid-flight (only relevant the
  // first time it's tapped for a season that was never opened before,
  // since setSeasonWatched then has to fetch it over the network first).
  // Same _pendingKeys-style local UI state as DiscoverySection's favorite
  // button, just scoped to this single tile instead of a set of keys.
  bool _isPending = false;

  @override
  Widget build(BuildContext context) {
    final tvId = widget.tvId;
    final summary = widget.summary;

    // Read from favoritesListProvider (not seasonProvider, which only
    // populates once the tile is expanded) so the season's progress shows
    // up in the collapsed header too, and updates reactively — this
    // StreamProvider is already wired to Hive, no manual invalidate
    // needed for it to pick up a watched-state change.
    final favorites = ref.watch(favoritesListProvider).value ?? const [];
    final matches = favorites.where((f) => f.id == tvId && f.mediaType == MediaType.tv);
    final item = matches.isEmpty ? null : matches.first;

    final cachedSeasons =
        item?.seasons?.where((s) => s.seasonNumber == summary.seasonNumber);
    final cachedSeason =
        (cachedSeasons != null && cachedSeasons.isNotEmpty) ? cachedSeasons.first : null;
    // Null until the season has been opened at least once (nothing cached
    // locally yet) — the header then falls back to the static episode
    // count from TvSeasonSummary, with no percentage.
    final progress = cachedSeason == null ? null : SeasonProgressCalculator.compute(cachedSeason);

    return ExpansionTile(
      leading: _SeasonWatchedCheckbox(
        progress: progress,
        isPending: _isPending,
        onPressed: () async {
          final markAllWatched = !(progress?.isFullyWatched ?? false);
          setState(() => _isPending = true);
          try {
            await runWrite(
              context,
              (repo) => repo.setSeasonWatched(tvId, summary.seasonNumber, watched: markAllWatched),
            );
            // Same class of bug the individual-episode toggle fix already
            // addresses: seasonProvider caches the season and doesn't watch
            // the favorites list, so once the tile is expanded it needs an
            // explicit invalidate to reflect this batch update too.
            ref.invalidate(
              seasonProvider((tvId: tvId, seasonNumber: summary.seasonNumber)),
            );
          } catch (error) {
            if (!context.mounted) return;
            final message = error is TmdbException
                ? error.message
                : 'Não foi possível atualizar esta temporada. Tente novamente.';
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
          } finally {
            if (mounted) setState(() => _isPending = false);
          }
        },
      ),
      title: Text(summary.name),
      subtitle: Text(
        progress == null
            ? '${summary.episodeCount} episódios'
            : '${progress.watchedCount}/${progress.totalCount} episódios · ${progress.percent}%',
      ),
      children: [
        Consumer(
          builder: (context, ref, _) {
            final seasonAsync = ref.watch(
              seasonProvider((tvId: tvId, seasonNumber: summary.seasonNumber)),
            );
            return seasonAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => ErrorState(
                message: error is TmdbException
                    ? error.message
                    : 'Erro ao carregar episódios desta temporada.',
                onRetry: () => ref.invalidate(
                  seasonProvider((tvId: tvId, seasonNumber: summary.seasonNumber)),
                ),
              ),
              data: (season) => Column(
                children: [
                  for (final episode in season.episodes)
                    CheckboxListTile(
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('E${episode.episodeNumber} · ${episode.name}'),
                      subtitle: episode.airDate == null
                          ? null
                          : Text(DateFormat('dd/MM/yyyy').format(episode.airDate!)),
                      value: episode.watched,
                      onChanged: episode.hasAired
                          ? (_) async {
                              await runWrite(
                                context,
                                (repo) => repo.toggleEpisodeWatched(
                                  tvId,
                                  summary.seasonNumber,
                                  episode.episodeNumber,
                                ),
                              );
                              // seasonProvider caches the season in Riverpod
                              // and doesn't watch the favorites list, so it
                              // won't pick up the toggle on its own —
                              // invalidate it to reflect the new watched
                              // state (favoritesRepository already cached
                              // the season in Hive, so this re-read is
                              // local, no network call).
                              ref.invalidate(
                                seasonProvider(
                                  (tvId: tvId, seasonNumber: summary.seasonNumber),
                                ),
                              );
                            }
                          : null,
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Tristate control in the season header that marks/unmarks the whole
/// season's already-aired episodes at once. Deliberately controlled (the
/// value tapped by the user is ignored) rather than left to Checkbox's own
/// null → false → true cycling, since the desired behavior is binary:
/// "not fully watched yet" → mark everything aired as watched;
/// "fully watched" → clear it all. The indeterminate (null) visual state
/// is only ever shown, never landed on by tapping.
class _SeasonWatchedCheckbox extends StatelessWidget {
  final SeasonProgress? progress;
  final bool isPending;
  final VoidCallback onPressed;

  const _SeasonWatchedCheckbox({
    required this.progress,
    required this.isPending,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // First tap on a season that was never opened before has to fetch it
    // over the network inside setSeasonWatched — swap the checkbox for a
    // spinner for that stretch so the tap doesn't look like it did
    // nothing. Same tap-target size as the Checkbox it replaces (48x48)
    // so nothing shifts in the row.
    if (isPending) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final bool? value = progress == null
        ? false
        : progress!.isFullyWatched
            ? true
            : progress!.isNoneWatched
                ? false
                : null;

    return Tooltip(
      message: value == true
          ? 'Desmarcar temporada inteira'
          : 'Marcar temporada inteira como assistida',
      child: Checkbox(
        tristate: true,
        value: value,
        onChanged: (_) => onPressed(),
      ),
    );
  }
}
