import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/favorite_doc.dart';
import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/search_result.dart';
import '../models/title_details.dart';
import '../models/tv_season_summary.dart';
import '../providers/catalog_sync_providers.dart';
import '../providers/providers.dart';
import '../services/favorite_status.dart';
import '../services/progress_calculator.dart';
import '../services/season_progress_calculator.dart';
import '../services/tmdb_exception.dart';
import '../widgets/error_state.dart';
import '../widgets/poster_image.dart';
import '../widgets/progress_badge.dart';
import '../widgets/app_shell.dart';
import '../widgets/auth_gate.dart';
import '../widgets/cast_widgets.dart';
import '../widgets/detail_actions.dart';
import '../widgets/episode_tile.dart';
import '../widgets/series_bulk_flow.dart';
import '../widgets/trailer_dialog.dart';
import 'movie_details_screen.dart' show detailsErrorMessage;

/// Details of a TV show. Works for any TMDB show: a favorite shows its saved
/// data and progress; otherwise the show and its seasons come from TMDB (the
/// episodes of a season are fetched when it is expanded), so the user can look
/// before favoriting, and favorite / mark episodes watched from here.
class TvDetailsScreen extends ConsumerStatefulWidget {
  final int tvId;

  const TvDetailsScreen({super.key, required this.tvId});

  @override
  ConsumerState<TvDetailsScreen> createState() => _TvDetailsScreenState();
}

class _TvDetailsScreenState extends ConsumerState<TvDetailsScreen>
    with SeriesBulkFlow<TvDetailsScreen> {
  /// Last favorite seen: keeps the content if the user removes it while TMDB
  /// is unreachable (otherwise the screen would turn into an error page).
  FavoriteItem? _last;

  /// The whole-series action is running / its confirmation is open (the
  /// spinner of the chip is hidden while the modal is on screen).
  bool _seriesBusy = false;
  bool _dialogOpen = false;

  @override
  void dispose() {
    disposeBulkFlow();
    super.dispose();
  }

  /// "Marcar como assistido" of the whole series: the same flow as the quick
  /// button of Favoritos (docs/30). Signed out: login first and the SAME flow
  /// (confirmation included) resumes afterwards, always as a mark (never a
  /// toggle), whatever the account being signed into already has.
  Future<void> _toggleSeriesWatched(SearchResult result, {required bool completed}) async {
    final key = '${result.id}-${MediaType.tv.jsonValue}';
    if (bulkBusy.contains(key)) return;
    bulkBusy.add(key);
    setState(() => _seriesBusy = true);
    try {
      if (ref.read(currentUidProvider) == null) {
        // Straight from the tap (no await before): the Google popup is still
        // opened by the user gesture.
        await signInWithFeedback(
          ProviderScope.containerOf(context),
          ScaffoldMessenger.maybeOf(context),
          intent: PendingIntent((_) async {
            if (mounted) await _runSeriesBulk(result, markAll: true);
          }),
        );
        return;
      }
      await _runSeriesBulk(result, markAll: !completed);
    } finally {
      bulkBusy.remove(key);
      if (mounted) setState(() => _seriesBusy = false);
    }
  }

  Future<void> _runSeriesBulk(SearchResult result, {required bool markAll}) {
    final favorites = ref.read(favoritesListProvider).value ?? const <FavoriteItem>[];
    final isFavorite = favorites.any((f) => f.id == result.id && f.mediaType == MediaType.tv);
    return toggleSeriesBulk(
      series: result,
      isFavorite: isFavorite,
      markAll: markAll,
      onDialog: (open) {
        if (mounted) setState(() => _dialogOpen = open);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // A different account never sees (or undoes) the previous one's action.
    ref.listen(currentUidProvider, (_, _) => discardBulkUndo());
    final tvId = widget.tvId;
    final favorites = ref.watch(favoritesListProvider).value ?? [];
    final matches = favorites.where((f) => f.id == tvId && f.mediaType == MediaType.tv);
    final FavoriteItem? item = matches.isEmpty ? null : matches.first;

    final key = (id: tvId, type: MediaType.tv);
    // Favorites also use it as a fallback for missing season names and for
    // year/genres; its failure is ignored (saved data is enough, e.g. offline).
    final detailsAsync = ref.watch(titleDetailsProvider(key));
    final details = detailsAsync.valueOrNull;
    _last = item ?? _last;
    final base = item ?? (details == null ? _last : null);

    if (base == null && details == null) {
      return Scaffold(
        appBar: detailAppBar(context, title: 'Detalhes'),
        bottomNavigationBar: const DetailBottomBanner(),
        body: detailsAsync.hasError
            ? ErrorState(
                message: detailsErrorMessage(detailsAsync.error),
                retryLabel: 'Tentar novamente',
                onRetry: () => ref.invalidate(titleDetailsProvider(key)),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }

    final title = base?.title ?? details!.title;
    final result = base == null
        ? details!.toSearchResult()
        : SearchResult(
            id: base.id,
            mediaType: MediaType.tv,
            title: base.title,
            posterPath: base.posterPath,
            overview: base.overview,
          );
    final progress = item == null ? null : ProgressCalculator.compute(item.seasons ?? const []);
    // Progress lives in the favorite document (episodes of seasons not cached
    // on this device are not in `progress`). While the documents are loading
    // or failed we cannot rule progress out, so removing must ask.
    final docsAsync = ref.watch(favoriteDocsProvider);
    final hasProgress = (progress?.isStarted ?? false) ||
        (item != null &&
            (!docsAsync.hasValue ||
                docsAsync.requireValue.any((d) =>
                    d.id == tvId && d.mediaType == MediaType.tv && d.watchedEpisodes.isNotEmpty)));

    // Derived (not stored): the show is "concluída" when every episode already
    // aired is watched, so it follows the per-episode and per-season checks.
    final sync = ref.watch(catalogSyncProvider);
    final completed =
        item != null &&
        FavoriteStatus.of(
          item,
          settled: sync.settled.contains(item.id),
          failed: sync.failed.contains(item.id),
        ).isCompleted;

    final savedSummaries = base?.seasonSummaries;
    final summaries = (savedSummaries != null && savedSummaries.isNotEmpty)
        ? savedSummaries
        : (details?.seasonSummaries ?? const <TvSeasonSummary>[]);

    return Scaffold(
      bottomNavigationBar: const DetailBottomBanner(),
      appBar: detailAppBar(context, title: title),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _Header(
              result: result,
              details: details,
              progress: progress,
              isFavorite: item != null,
              hasProgress: hasProgress,
              recommended: item?.recommended ?? false,
              completed: completed,
              watchedPending: _seriesBusy && !_dialogOpen,
              onToggleWatched: () => _toggleSeriesWatched(result, completed: completed),
              titleKey: key,
            ),
          ),
          SliverToBoxAdapter(child: CastSection(titleKey: key)),
          if (summaries.isEmpty)
            SliverToBoxAdapter(
              child: item == null
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('Nenhuma temporada disponível.')),
                    )
                  : ErrorState(
                      message: 'Não foi possível carregar as temporadas ainda.',
                      onRetry: () =>
                          ref.read(favoritesRepositoryProvider).reloadSeasonSummaries(item.id),
                    ),
            )
          else
            SliverList.builder(
              itemCount: summaries.length,
              itemBuilder: (context, index) =>
                  _SeasonTile(result: result, summary: summaries[index]),
            ),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  final SearchResult result;
  final TitleDetails? details;
  final SeriesProgress? progress;
  final bool isFavorite;
  final bool hasProgress;
  final bool recommended;
  final bool completed;
  final bool watchedPending;
  final Future<void> Function() onToggleWatched;
  final TitleKey titleKey;

  const _Header({
    required this.result,
    required this.details,
    required this.progress,
    required this.isFavorite,
    required this.hasProgress,
    required this.recommended,
    required this.completed,
    required this.watchedPending,
    required this.onToggleWatched,
    required this.titleKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = this.progress;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PosterImage(posterPath: result.posterPath, width: 120, height: 180),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(result.title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    TitleMeta(details: details),
                    if (progress != null) ...[
                      const SizedBox(height: 8),
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
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FavoriteToggleButton(
                isFavorite: isFavorite,
                hasProgress: hasProgress,
                recommended: recommended,
                title: result.title,
                onAdd: () => runDetailWrite(context, (repo) => repo.addResult(result)),
                onRemove: () =>
                    runDetailWrite(context, (repo) => repo.remove(result.id, MediaType.tv)),
              ),
              RecommendToggleChip(
                recommended: recommended,
                title: result.title,
                onSet: (target) => setRecommendedFromUi(
                  context,
                  result,
                  inFavorites: isFavorite,
                  recommended: target,
                ),
              ),
              WatchedToggleChip(
                watched: completed,
                title: result.title,
                wholeSeries: true,
                pending: watchedPending,
                onToggle: onToggleWatched,
              ),
              TrailerButton(titleKey: titleKey, title: result.title),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            result.overview.isEmpty ? 'Sem sinopse disponível.' : result.overview,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// How many episodes a season list builds at a time (docs/45).
const kEpisodePage = 25;

class _SeasonTile extends ConsumerStatefulWidget {
  final SearchResult result;
  final TvSeasonSummary summary;

  const _SeasonTile({required this.result, required this.summary});

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

  /// Episodes whose write is in flight (a quick second tap must not repeat the
  /// same target state before the stream catches up).
  final Set<int> _busyEpisodes = {};

  /// Episodes built so far: a long season (100+) shows [kEpisodePage] at a time,
  /// so its images are only requested as the user asks for more.
  int _shown = kEpisodePage;

  @override
  Widget build(BuildContext context) {
    final tvId = widget.result.id;
    final summary = widget.summary;

    // seasonProvider caches the season (with the watched overlay) and does not
    // watch the favorites. Re-read it whenever this show's document appears,
    // disappears or its watched episodes change, whatever caused it: a login
    // replay, a removal, another device. Without it the checks go stale.
    ref.listen(favoriteDocsProvider, (previous, next) {
      FavoriteDoc? docOf(AsyncValue<List<FavoriteDoc>>? v) {
        for (final d in v?.valueOrNull ?? const <FavoriteDoc>[]) {
          if (d.id == tvId && d.mediaType == MediaType.tv) return d;
        }
        return null;
      }

      final before = docOf(previous);
      final after = docOf(next);
      if ((before == null) != (after == null) ||
          !setEquals(before?.watchedEpisodes, after?.watchedEpisodes)) {
        ref.invalidate(seasonProvider((tvId: tvId, seasonNumber: summary.seasonNumber)));
      }
    });

    // Read from favoritesListProvider (not seasonProvider, which only
    // populates once the tile is expanded) so the season's progress shows
    // up in the collapsed header too, and updates reactively — this
    // StreamProvider is already wired to Hive, no manual invalidate
    // needed for it to pick up a watched-state change.
    final favorites = ref.watch(favoritesListProvider).value ?? const [];
    final matches = favorites.where((f) => f.id == tvId && f.mediaType == MediaType.tv);
    final item = matches.isEmpty ? null : matches.first;

    final cachedSeasons = item?.seasons?.where((s) => s.seasonNumber == summary.seasonNumber);
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
            await runWrite(context, (repo) async {
              // Not a favorite yet: progress lives in the favorite, so favorite
              // it first (see docs/15). Decided at tap time, so a replay after
              // login does the same.
              await favoriteThen(
                repo,
                widget.result,
                item != null,
                () => repo.setSeasonWatched(tvId, summary.seasonNumber, watched: markAllWatched),
              );
            });
            // Same class of bug the individual-episode toggle fix already
            // addresses: seasonProvider caches the season and doesn't watch
            // the favorites list, so once the tile is expanded it needs an
            // explicit invalidate to reflect this batch update too.
            ref.invalidate(
              seasonProvider((tvId: tvId, seasonNumber: summary.seasonNumber)),
            );
          } catch (error) {
            if (!context.mounted) return;
            final message = error is TmdbException || error is PartialWriteException
                ? writeErrorMessage(error)
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
                  for (final episode in season.episodes.take(_shown))
                    EpisodeTile(
                      key: ValueKey('episode-${summary.seasonNumber}-${episode.episodeNumber}'),
                      episode: episode,
                      busy: _busyEpisodes.contains(episode.episodeNumber),
                      onToggle: () async {
                        final number = episode.episodeNumber;
                        setState(() => _busyEpisodes.add(number));
                        try {
                          await runDetailWrite(context, (repo) async {
                            if (item == null) {
                              await favoriteThen(
                                repo,
                                widget.result,
                                false,
                                () => repo.setEpisodeWatched(
                                  tvId,
                                  summary.seasonNumber,
                                  number,
                                  watched: !episode.watched,
                                ),
                              );
                            } else {
                              await repo.toggleEpisodeWatched(tvId, summary.seasonNumber, number);
                            }
                          });
                          ref.invalidate(
                            seasonProvider((tvId: tvId, seasonNumber: summary.seasonNumber)),
                          );
                        } finally {
                          if (mounted) setState(() => _busyEpisodes.remove(number));
                        }
                      },
                    ),
                  if (season.episodes.length > _shown)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => setState(() => _shown += kEpisodePage),
                        child: Text(
                          'Mostrar mais episódios (${season.episodes.length - _shown} restantes)',
                          textAlign: TextAlign.center,
                        ),
                      ),
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
      message:
          value == true ? 'Desmarcar temporada inteira' : 'Marcar temporada inteira como assistida',
      child: Checkbox(
        tristate: true,
        value: value,
        onChanged: (_) => onPressed(),
      ),
    );
  }
}
