import 'dart:async';

import '../data/favorites_data_source.dart';
import '../models/favorite_doc.dart';
import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/search_result.dart';
import '../models/season_cache.dart';
import '../models/tv_season_summary.dart';
import '../services/bulk_watch.dart';
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
    required this._api,
    required this._store,
    FavoritesDataSource? dataSource,
    this.catalogDebounce = const Duration(milliseconds: 300),
    this._now,
  })  : _data = dataSource ?? const SignedOutFavoritesDataSource();

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
  }) => _reconciler(
    delay: delay,
  ).run(targets, isCancelled: isCancelled, isStale: isStale, onDone: onDone);

  List<String> pendingRuntimes(List<FavoriteDoc> docs) => _reconciler().pendingRuntimes(docs);

  Future<void> reconcileRuntimes(
    List<String> keys, {
    List<FavoriteDoc> docs = const [],
    bool Function()? isCancelled,
    void Function(String key, bool ok)? onDone,
    Future<void> Function(Duration)? delay,
  }) => _reconciler(
    delay: delay,
  ).runRuntimes(keys, docs: docs, isCancelled: isCancelled, onDone: onDone);

  CatalogReconciler _reconciler({Future<void> Function(Duration)? delay, int maxRetries = 3}) =>
      CatalogReconciler(
        api: _api,
        store: _store,
        delay: delay,
        maxRetries: maxRetries,
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

  /// "Recomendo" on a title that is NOT in Favoritos yet: adds it and
  /// recommends it in ONE write (a single `set` with `recommended: true`), so
  /// a failure leaves it in neither list. If it turns out to exist already
  /// (stale screen), it only marks the field by field path, never rewriting
  /// the document. Used by the login replay too (explicit intent, not a toggle).
  Future<void> addAndRecommend(SearchResult r) async {
    final key = '${r.id}-${r.mediaType.jsonValue}';
    if (await _exists(key)) return setRecommended(r.id, r.mediaType, true);
    if (r.mediaType == MediaType.movie) {
      return _addMovie(
        id: r.id,
        title: r.title,
        posterPath: r.posterPath,
        overview: r.overview,
        recommended: true,
      );
    }
    return _addTvShow(
      id: r.id,
      title: r.title,
      posterPath: r.posterPath,
      overview: r.overview,
      recommended: true,
    );
  }

  /// Explicit (not toggle) "Recomendo" state of a title that is in Favoritos.
  /// One field-level update (`true` / field deleted); never touches progress,
  /// `addedAt` or `lastWatchedAt`. A title that is gone (removed on another
  /// device) throws [FavoriteGoneException] and nothing is recreated.
  /// [FavoritesUnavailableException] propagates (the state cannot be known).
  Future<void> setRecommended(int id, MediaType mediaType, bool recommended) async {
    final key = '$id-${mediaType.jsonValue}';
    if (await _data.get(key) == null) throw const FavoriteGoneException();
    await _data.setRecommended(key, recommended);
  }

  Future<void> addMovie({
    required int id,
    required String title,
    required String? posterPath,
    required String overview,
  }) =>
      _addMovie(id: id, title: title, posterPath: posterPath, overview: overview);

  Future<void> _addMovie({
    required int id,
    required String title,
    required String? posterPath,
    required String overview,
    bool recommended = false,
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
      recommended: recommended,
    ));
  }

  Future<void> addTvShow({
    required int id,
    required String title,
    required String? posterPath,
    required String overview,
  }) =>
      _addTvShow(id: id, title: title, posterPath: posterPath, overview: overview);

  Future<void> _addTvShow({
    required int id,
    required String title,
    required String? posterPath,
    required String overview,
    bool recommended = false,
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
      recommended: recommended,
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

  /// Explicit (not toggle) movie state, for the quick control of the favorites
  /// list. Does nothing when the favorite no longer exists.
  Future<void> setMovieWatched(int id, bool watched) async {
    final key = '$id-${MediaType.movie.jsonValue}';
    if (await _data.get(key) == null) return;
    await _data.setWatchedMovie(key, watched);
  }

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
      final season = cached.first;
      if (!season.needsDetails) return FavoriteMapper.overlayWatched(season, watched);
      // Catalog cached before the episode image/description fields (docs/45):
      // download THIS season once and keep it. The watched state is not part
      // of the catalog (it comes from the user's document), so nothing the
      // user marked is touched. Offline or failing: keep showing what we have.
      try {
        final fresh = await _api.getSeasonEpisodes(tvId, seasonNumber);
        if (fresh.episodes.isNotEmpty) {
          if (doc != null) await _store.saveCatalogSeason(tvId, fresh);
          return FavoriteMapper.overlayWatched(fresh, watched);
        }
      } catch (_) {
        // Fall through to the cached copy.
      }
      return FavoriteMapper.overlayWatched(season, watched);
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

  // --- whole-series mark / unmark (docs/30) ---

  /// What marking ([watched] true) or clearing the whole series would change.
  /// Marking needs every season in the local catalog: the missing ones (and the
  /// season list itself, for a show favorited offline) are downloaded first
  /// with the reconciler's backoff, and any failure is thrown, so the caller
  /// never marks from a partial catalog.
  Future<SeriesBulkPlan> planSeriesBulk(
    int tvId, {
    required bool watched,
    Future<void> Function(Duration)? delay,
    bool Function()? isCancelled,
  }) async {
    final key = '$tvId-${MediaType.tv.jsonValue}';
    var doc = await _data.get(key);
    if (doc == null) throw const FavoriteGoneException();
    if (!watched) return _checked(BulkWatchRules.unmarkAll(key, doc.watchedEpisodes));

    final reconciler = _reconciler(delay: delay, maxRetries: 2);
    var summaries = doc.seasonSummaries;
    if (summaries.isEmpty) {
      summaries = await reconciler.fetchSummaries(tvId);
      if (summaries.isNotEmpty && !(isCancelled?.call() ?? false)) {
        try {
          await _data.setSeasonSummaries(key, summaries);
        } catch (_) {
          // Best effort: the plan below does not depend on the saved copy.
        }
      }
    }
    final cached = {for (final s in _store.readSeasonCatalog(tvId)) s.seasonNumber};
    final missing = [
      for (final s in summaries)
        if (!cached.contains(s.seasonNumber)) s.seasonNumber,
    ];
    if (missing.isNotEmpty) {
      await reconciler.downloadSeasons(tvId, missing, isCancelled: isCancelled);
    }
    // A catalog past its TTL (airing shows: newest season, seasons with unaired
    // episodes, new seasons) is refreshed first: the plan must not be built on
    // an outdated episode list. A refresh that fails fails the plan.
    final current = doc.copyWith(seasonSummaries: summaries);
    if (reconciler.refreshDue(current)) {
      await reconciler.refresh(current, isCancelled: isCancelled);
    }
    if (isCancelled?.call() ?? false) throw StateError('cancelled');
    doc = await _data.get(key);
    if (doc == null) throw const FavoriteGoneException();
    return _checked(
      BulkWatchRules.markAll(key, _store.readSeasonCatalog(tvId), doc.watchedEpisodes),
    );
  }

  /// [planSeriesBulk] (marking) for a show that is NOT in Favoritos yet
  /// (docs/45): everything comes from TMDB and stays in memory, so cancelling
  /// the confirmation leaves no trace (no favorite, no local catalog). The
  /// caller favorites the show together with the write.
  Future<SeriesBulkPlan> planNewSeriesBulk(
    int tvId, {
    Future<void> Function(Duration)? delay,
    bool Function()? isCancelled,
  }) async {
    // It may be a favorite after all (stale screen, or a login replay into an
    // account that has it): then the normal plan counts only what is missing.
    if (await _exists('$tvId-${MediaType.tv.jsonValue}')) {
      return planSeriesBulk(tvId, watched: true, delay: delay, isCancelled: isCancelled);
    }
    final reconciler = _reconciler(delay: delay, maxRetries: 2);
    final summaries = await reconciler.fetchSummaries(tvId);
    final seasons = await reconciler.fetchSeasons(tvId, [
      for (final s in summaries) s.seasonNumber,
    ], isCancelled: isCancelled);
    if (isCancelled?.call() ?? false) throw StateError('cancelled');
    return _checked(BulkWatchRules.markAll('$tvId-${MediaType.tv.jsonValue}', seasons, const {}));
  }

  SeriesBulkPlan _checked(SeriesBulkPlan plan) {
    if (plan.episodeCount > kMaxBulkEpisodes) throw const BulkTooLargeException();
    return plan;
  }

  /// Applies [plan] in ONE atomic update (per-episode field paths, so it merges
  /// with edits from other devices). The state is re-read right before, so
  /// what is written is the effective difference. Returns the exact inverse
  /// (for "Desfazer"), or null when nothing needed to change.
  Future<SeriesBulkUndo?> applySeriesBulk(SeriesBulkPlan plan, {required String uid}) async {
    final doc = await _data.get(plan.docKey);
    if (doc == null) throw const FavoriteGoneException();
    final before = doc.watchedEpisodes;
    final changes = plan.watched
        ? {
            for (final k in plan.keys)
              if (!before.contains(k)) k: true,
          }
        : {for (final k in before) k: false};
    if (changes.isEmpty) return null;
    final after = FavoriteMapper.applyEpisodeChanges(before, changes);
    // The rules cap the whole `eps` map: validate the final size, not the diff.
    if (after.length > kMaxBulkEpisodes) throw const BulkTooLargeException();
    await _data.setEpisodes(plan.docKey, changes);
    return SeriesBulkUndo(
      docKey: plan.docKey,
      uid: uid,
      inverse: {for (final e in changes.entries) e.key: !e.value},
      expected: after,
    );
  }

  /// Restores the episodes as they were before [undo]'s change, only if the
  /// document still holds exactly what that change produced.
  Future<UndoOutcome> undoSeriesBulk(SeriesBulkUndo undo) async {
    final doc = await _data.get(undo.docKey);
    if (doc == null) return UndoOutcome.gone;
    if (doc.watchedEpisodes.length != undo.expected.length ||
        !doc.watchedEpisodes.containsAll(undo.expected)) {
      return UndoOutcome.changed;
    }
    await _data.setEpisodes(undo.docKey, undo.inverse);
    return UndoOutcome.restored;
  }
}
