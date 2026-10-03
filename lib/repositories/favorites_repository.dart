import 'dart:async';

import '../data/favorites_data_source.dart';
import '../models/favorite_doc.dart';
import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/search_result.dart';
import '../models/season_cache.dart';
import '../models/tv_season_summary.dart';
import '../services/catalog_reconciler.dart';
import '../services/favorite_mapper.dart';
import '../services/local_store.dart';
import '../services/tmdb_api_client.dart';

/// The only layer that knows whether a piece of data comes from the
/// network (TMDB), the user's cloud space ([FavoritesDataSource]) or the
/// local catalog cache. Screens/providers depend on this, never on the
/// data source, TmdbApiClient or LocalStore directly.
///
/// It rebuilds the public [FavoriteItem] shape (cloud document + cached
/// catalog + watched overlay), so screens and `ProgressCalculator` don't
/// know the storage moved to the cloud. Writes are single-intent updates
/// (one field path), never read-modify-write of the whole object.
class FavoritesRepository {
  final TmdbApiClient _api;
  final LocalStore _store;
  final FavoritesDataSource _data;

  /// Season-catalog events inside this window collapse into one re-hydration
  /// of the whole list (leading + trailing edge): a first-login download of
  /// ~100 series would otherwise re-decode every show once per season saved.
  final Duration catalogDebounce;
  final DateTime Function()? _now;

  /// [dataSource] defaults to the signed-out source (empty reads, writes
  /// throw [AuthRequiredException]); the app wires the real one through
  /// `favoritesDataSourceProvider`.
  FavoritesRepository({
    required TmdbApiClient api,
    required LocalStore store,
    FavoritesDataSource? dataSource,
    this.catalogDebounce = const Duration(milliseconds: 300),
    DateTime Function()? now,
  })  : _now = now,
        _api = api,
        _store = store,
        _data = dataSource ?? const SignedOutFavoritesDataSource();

  /// Emits the hydrated list now and whenever the user's favorites OR the
  /// season catalog change (e.g. a season finishing its first download).
  Stream<List<FavoriteItem>> watchAll() {
    late final StreamController<List<FavoriteItem>> controller;
    StreamSubscription<List<FavoriteDoc>>? docsSub;
    StreamSubscription<void>? catalogSub;
    List<FavoriteDoc>? latest;
    Timer? window;
    var dirty = false;

    void emit() {
      final docs = latest;
      if (docs == null || controller.isClosed) return;
      controller.add([
        for (final doc in docs)
          FavoriteMapper.hydrate(
            doc,
            doc.mediaType == MediaType.tv ? _store.readSeasonCatalog(doc.id) : const [],
          ),
      ]);
    }

    controller = StreamController<List<FavoriteItem>>(
      onListen: () {
        docsSub = _data.watchAll().listen(
          (docs) {
            latest = docs;
            emit();
          },
          onError: controller.addError,
        );
        catalogSub = _store.watchSeasonCatalog().listen((_) {
          if (catalogDebounce == Duration.zero) return emit();
          if (window != null) {
            dirty = true; // inside the window: emitted once when it closes
            return;
          }
          emit();
          void close() {
            window = null;
            if (dirty) {
              dirty = false;
              emit();
              window = Timer(catalogDebounce, close);
            }
          }

          window = Timer(catalogDebounce, close);
        });
      },
      onCancel: () async {
        window?.cancel();
        await docsSub?.cancel();
        await catalogSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// Series whose local season catalog is incomplete for [docs] (new
  /// device / fresh login), most recent first. See [reconcileCatalog].
  List<FavoriteDoc> docsNeedingCatalog(List<FavoriteDoc> docs) => _reconciler().pending(docs);

  /// Downloads the missing seasons of [targets] in the background (limited
  /// concurrency, backoff on 429/5xx/network). Each saved season re-emits
  /// [watchAll], so progress appears without any interaction.
  Future<void> reconcileCatalog(
    List<FavoriteDoc> targets, {
    bool Function()? isCancelled,
    bool Function(int tvId)? isStale,
    void Function(int tvId, bool ok)? onDone,
    Future<void> Function(Duration)? delay,
  }) =>
      _reconciler(delay: delay)
          .run(targets, isCancelled: isCancelled, isStale: isStale, onDone: onDone);

  List<String> pendingRuntimes(List<FavoriteDoc> docs) => _reconciler().pendingRuntimes(docs);

  Future<void> reconcileRuntimes(
    List<String> keys, {
    List<FavoriteDoc> docs = const [],
    bool Function()? isCancelled,
    void Function(String key, bool ok)? onDone,
    Future<void> Function(Duration)? delay,
  }) =>
      _reconciler(delay: delay)
          .runRuntimes(keys, docs: docs, isCancelled: isCancelled, onDone: onDone);

  CatalogReconciler _reconciler({Future<void> Function(Duration)? delay}) => CatalogReconciler(
        api: _api,
        store: _store,
        delay: delay,
        now: _now,
        saveSummaries: (tvId, summaries) =>
            _data.setSeasonSummaries('$tvId-${MediaType.tv.jsonValue}', summaries),
      );

  /// The raw cloud documents (no catalog hydration), for statistics.
  Stream<List<FavoriteDoc>> watchDocs() => _data.watchAll();

  /// Idempotency check for adds. If the read is unavailable (cold cache while
  /// offline) we proceed as "not favorited": the add is a `set` whose rules
  /// forbid moving `addedAt` forward, so it cannot clobber an existing doc,
  /// and the user's action is not lost. Toggles do NOT do this: they need the
  /// current state, so they let [FavoritesUnavailableException] propagate.
  Future<bool> _exists(String key) async {
    try {
      return await _data.get(key) != null;
    } on FavoritesUnavailableException {
      return false;
    }
  }

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
    if (await _exists(key)) return; // idempotent: already favorited
    await _data.add(FavoriteDoc(
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
    if (await _exists(key)) return; // idempotent: already favorited

    // Favorite first (so it is saved even if TMDB is slow/unreachable and
    // signed-out callers fail before any network call)...
    await _data.add(FavoriteDoc(
      id: id,
      mediaType: MediaType.tv,
      title: title,
      posterPath: posterPath,
      overview: overview,
      addedAt: DateTime.now(),
    ));

    // ...then best-effort: fetch season names/counts so the season list
    // shows up offline right away. If it fails, the show is still
    // favorited — the details screen offers a retry (reloadSeasonSummaries).
    try {
      final details = await _api.getTvDetails(id);
      await _data.setSeasonSummaries(key, TvSeasonSummary.listFromTvDetails(details));
    } catch (_) {
      // Keep the favorite with empty summaries.
    }
  }

  /// Retries fetching season names/counts for a show that was favorited
  /// while offline (or when the initial fetch failed).
  Future<void> reloadSeasonSummaries(int tvId) async {
    final key = '$tvId-${MediaType.tv.jsonValue}';
    if (await _data.get(key) == null) return;
    final details = await _api.getTvDetails(tvId);
    await _data.setSeasonSummaries(key, TvSeasonSummary.listFromTvDetails(details));
  }

  Future<void> remove(int id, MediaType mediaType) => _data.remove('$id-${mediaType.jsonValue}');

  Future<void> toggleMovieWatched(int id) async {
    final key = '$id-${MediaType.movie.jsonValue}';
    final doc = await _data.get(key);
    if (doc == null) return;
    await _data.setWatchedMovie(key, !doc.watchedMovie);
  }

  /// Marks a movie as watched (explicit, not a toggle). Progress lives inside
  /// the favorite document, so for a title that is not a favorite yet callers
  /// run [addResult] first (see `favoriteThen`).
  Future<void> markMovieWatched(int id) =>
      _data.setWatchedMovie('$id-${MediaType.movie.jsonValue}', true);

  /// Explicit (not toggle) episode state. Used for a title that was not a
  /// favorite when the user acted, after [addResult].
  Future<void> setEpisodeWatched(
    int tvId,
    int seasonNumber,
    int episodeNumber, {
    required bool watched,
  }) async {
    final key = '$tvId-${MediaType.tv.jsonValue}';
    await _data.setEpisodes(key, {FavoriteMapper.episodeKey(seasonNumber, episodeNumber): watched});
  }

  /// Returns cached episodes for [seasonNumber] if we already have them;
  /// otherwise fetches from TMDB and caches the result (only for shows the
  /// user favorited). The returned season carries the user's `watched`
  /// flags. Toggling watched state never depends on this call succeeding.
  Future<SeasonCache> loadSeason(int tvId, int seasonNumber) async {
    final key = '$tvId-${MediaType.tv.jsonValue}';
    final doc = await _data.get(key);
    final watched = doc?.watchedEpisodes ?? const <String>{};

    final cached = _store.readSeasonCatalog(tvId).where((s) => s.seasonNumber == seasonNumber);
    if (cached.isNotEmpty) {
      return FavoriteMapper.overlayWatched(cached.first, watched);
    }

    final fetched = await _api.getSeasonEpisodes(tvId, seasonNumber);
    if (doc != null) {
      await _store.saveCatalogSeason(tvId, fetched);
    }
    return FavoriteMapper.overlayWatched(fetched, watched);
  }

  Future<void> toggleEpisodeWatched(int tvId, int seasonNumber, int episodeNumber) async {
    final key = '$tvId-${MediaType.tv.jsonValue}';
    final doc = await _data.get(key);
    if (doc == null) return;

    final episodeKey = FavoriteMapper.episodeKey(seasonNumber, episodeNumber);
    await _data.setEpisodes(key, {episodeKey: !doc.watchedEpisodes.contains(episodeKey)});
  }

  /// Marks every already-aired episode of a season as watched (or
  /// unwatched), in one write. Episodes that haven't aired yet
  /// (`hasAired == false`) are left untouched either way — same rule the
  /// individual per-episode toggle already follows (its checkbox is
  /// disabled for those). If the season's episodes were never cached
  /// locally (user never expanded it), fetches them first via
  /// [loadSeason] so we know what "already aired" means for it.
  Future<void> setSeasonWatched(int tvId, int seasonNumber, {required bool watched}) async {
    final season = await loadSeason(tvId, seasonNumber);

    final key = '$tvId-${MediaType.tv.jsonValue}';
    if (await _data.get(key) == null) return;

    await _data.setEpisodes(key, {
      for (final episode in season.episodes)
        if (episode.hasAired)
          FavoriteMapper.episodeKey(seasonNumber, episode.episodeNumber): watched,
    });
  }
}
