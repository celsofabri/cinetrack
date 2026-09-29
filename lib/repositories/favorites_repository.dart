import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/search_result.dart';
import '../models/season_cache.dart';
import '../models/tv_season_summary.dart';
import '../services/local_store.dart';
import '../services/tmdb_api_client.dart';

/// The only layer that knows whether a piece of data comes from the
/// network (TMDB) or from local cache (Hive). Screens/providers depend
/// on this, never on TmdbApiClient or LocalStore directly.
class FavoritesRepository {
  final TmdbApiClient _api;
  final LocalStore _store;

  FavoritesRepository({required TmdbApiClient api, required LocalStore store})
      : _api = api,
        _store = store;

  Stream<List<FavoriteItem>> watchAll() async* {
    yield _store.readAll();
    yield* _store.watch().map((_) => _store.readAll());
  }

  bool isFavorite(int id, MediaType mediaType) =>
      _store.read('$id-${mediaType.jsonValue}') != null;

  /// Favorites a catalog/search result, whichever media type it is.
  Future<void> addResult(SearchResult r) => r.mediaType == MediaType.movie
      ? addMovie(id: r.id, title: r.title, posterPath: r.posterPath, overview: r.overview)
      : addTvShow(id: r.id, title: r.title, posterPath: r.posterPath, overview: r.overview);

  Future<void> addMovie({
    required int id,
    required String title,
    required String? posterPath,
    required String overview,
  }) async {
    final key = '$id-${MediaType.movie.jsonValue}';
    if (_store.read(key) != null) return; // idempotent: already favorited
    await _store.save(FavoriteItem(
      id: id,
      mediaType: MediaType.movie,
      title: title,
      posterPath: posterPath,
      overview: overview,
      addedAt: DateTime.now(),
    ));
  }

  Future<void> addTvShow({
    required int id,
    required String title,
    required String? posterPath,
    required String overview,
  }) async {
    final key = '$id-${MediaType.tv.jsonValue}';
    if (_store.read(key) != null) return; // idempotent: already favorited

    // Best-effort: fetch season names/counts now so the season list shows
    // up offline right away. If it fails, the show is still favorited —
    // the details screen offers a retry (loadSeasonSummaries).
    List<TvSeasonSummary> summaries = const [];
    try {
      final details = await _api.getTvDetails(id);
      summaries = TvSeasonSummary.listFromTvDetails(details);
    } catch (_) {
      summaries = const [];
    }

    await _store.save(FavoriteItem(
      id: id,
      mediaType: MediaType.tv,
      title: title,
      posterPath: posterPath,
      overview: overview,
      addedAt: DateTime.now(),
      seasons: const [],
      seasonSummaries: summaries,
    ));
  }

  /// Retries fetching season names/counts for a show that was favorited
  /// while offline (or when the initial fetch failed).
  Future<void> reloadSeasonSummaries(int tvId) async {
    final key = '$tvId-${MediaType.tv.jsonValue}';
    final item = _store.read(key);
    if (item == null) return;
    final details = await _api.getTvDetails(tvId);
    final summaries = TvSeasonSummary.listFromTvDetails(details);
    await _store.save(item.copyWith(seasonSummaries: summaries));
  }

  Future<void> remove(int id, MediaType mediaType) =>
      _store.delete('$id-${mediaType.jsonValue}');

  Future<void> toggleMovieWatched(int id) async {
    final key = '$id-${MediaType.movie.jsonValue}';
    final item = _store.read(key);
    if (item == null) return;
    await _store.save(item.copyWith(watchedMovie: !item.watchedMovie));
  }

  /// Returns cached episodes for [seasonNumber] if we already have them;
  /// otherwise fetches from TMDB and caches the result. Toggling watched
  /// state never depends on this call succeeding.
  Future<SeasonCache> loadSeason(int tvId, int seasonNumber) async {
    final key = '$tvId-${MediaType.tv.jsonValue}';
    final item = _store.read(key);
    final cached = item?.seasons?.where((s) => s.seasonNumber == seasonNumber);
    if (cached != null && cached.isNotEmpty) {
      return cached.first;
    }

    final fetched = await _api.getSeasonEpisodes(tvId, seasonNumber);
    if (item != null) {
      final updatedSeasons = [
        for (final s in item.seasons ?? const <SeasonCache>[])
          if (s.seasonNumber != seasonNumber) s,
        fetched,
      ];
      await _store.save(item.copyWith(seasons: updatedSeasons));
    }
    return fetched;
  }

  Future<void> toggleEpisodeWatched(int tvId, int seasonNumber, int episodeNumber) async {
    final key = '$tvId-${MediaType.tv.jsonValue}';
    final item = _store.read(key);
    if (item == null) return;

    final seasons = item.seasons ?? const <SeasonCache>[];
    final updatedSeasons = _updateSeason(
      seasons,
      seasonNumber,
      (season) => _toggleEpisode(season, episodeNumber),
    );

    await _store.save(item.copyWith(seasons: updatedSeasons, lastWatchedAt: DateTime.now()));
  }

  /// Marks every already-aired episode of a season as watched (or
  /// unwatched), in one write. Episodes that haven't aired yet
  /// (`hasAired == false`) are left untouched either way — same rule the
  /// individual per-episode toggle already follows (its checkbox is
  /// disabled for those). If the season's episodes were never cached
  /// locally (user never expanded it), fetches them first via
  /// [loadSeason] so we know what "already aired" means for it.
  Future<void> setSeasonWatched(int tvId, int seasonNumber, {required bool watched}) async {
    await loadSeason(tvId, seasonNumber);

    final key = '$tvId-${MediaType.tv.jsonValue}';
    final item = _store.read(key);
    if (item == null) return;

    final seasons = item.seasons ?? const <SeasonCache>[];
    final updatedSeasons = _updateSeason(
      seasons,
      seasonNumber,
      (season) => _setAiredEpisodesWatched(season, watched),
    );

    await _store.save(item.copyWith(seasons: updatedSeasons, lastWatchedAt: DateTime.now()));
  }

  /// Replaces the season matching [seasonNumber] in [seasons] with the
  /// result of applying [transform] to it, leaving every other season
  /// untouched. Shared by [toggleEpisodeWatched] and [setSeasonWatched] so
  /// neither has to duplicate the "find this season in the list" scan.
  List<SeasonCache> _updateSeason(
    List<SeasonCache> seasons,
    int seasonNumber,
    SeasonCache Function(SeasonCache season) transform,
  ) =>
      [
        for (final season in seasons)
          if (season.seasonNumber == seasonNumber) transform(season) else season,
      ];

  SeasonCache _toggleEpisode(SeasonCache season, int episodeNumber) {
    final episode = season.episodes.firstWhere((ep) => ep.episodeNumber == episodeNumber);
    return season.copyWithEpisode(episode.copyWith(watched: !episode.watched));
  }

  SeasonCache _setAiredEpisodesWatched(SeasonCache season, bool watched) => SeasonCache(
        seasonNumber: season.seasonNumber,
        episodes: [
          for (final episode in season.episodes)
            episode.hasAired ? episode.copyWith(watched: watched) : episode,
        ],
      );
}
