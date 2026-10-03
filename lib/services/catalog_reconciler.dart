import 'dart:async';

import '../models/episode_cache.dart';
import '../models/favorite_doc.dart';
import '../models/media_type.dart';
import '../services/favorite_mapper.dart';
import '../models/tv_season_summary.dart';
import 'local_store.dart';
import 'tmdb_api_client.dart';
import 'tmdb_exception.dart';

/// Fills the local season catalog (`season_catalog`) of the user's favorite
/// series in the background.
///
/// Why it exists: the catalog (episodes + air dates) is per device and never
/// goes to the cloud, while the watched flags (`eps`) do. On a new device or
/// after a fresh login the catalog is empty, so progress could not be
/// computed until the user opened each series (docs/18). This downloads the
/// missing seasons from TMDB with a small concurrency limit and exponential
/// backoff, most recently active series first.
class CatalogReconciler {
  final TmdbApiClient _api;
  final LocalStore _store;
  final Future<void> Function(int tvId, List<TvSeasonSummary> summaries) _saveSummaries;
  final int concurrency;
  final int maxRetries;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;

  /// A catalog older than this is re-checked when the show is still airing
  /// (an unaired episode in the cache, or an episode that aired recently).
  final Duration airingTtl;

  /// Same re-check (new seasons only) for shows that look finished.
  final Duration idleTtl;

  CatalogReconciler({
    required TmdbApiClient api,
    required LocalStore store,
    required Future<void> Function(int tvId, List<TvSeasonSummary> summaries) saveSummaries,
    this.concurrency = 3,
    this.maxRetries = 3,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
    this.airingTtl = const Duration(hours: 24),
    this.idleTtl = const Duration(days: 7),
  })  : _now = now ?? DateTime.now,
        _api = api,
        _store = store,
        _saveSummaries = saveSummaries,
        _delay = delay ?? Future.delayed;

  /// Series whose catalog does not cover their known seasons (or that have no
  /// season list yet), most recent activity first. Movies never need it.
  List<FavoriteDoc> pending(List<FavoriteDoc> docs) {
    final todo = [
      for (final doc in docs)
        if (doc.mediaType == MediaType.tv &&
            (doc.seasonSummaries.isEmpty || _missing(doc).isNotEmpty || _refreshDue(doc)))
          doc,
    ]..sort((a, b) => _activity(b).compareTo(_activity(a)));
    return todo;
  }

  static DateTime _activity(FavoriteDoc d) {
    final w = d.lastWatchedAt;
    return w != null && w.isAfter(d.addedAt) ? w : d.addedAt;
  }

  bool _isUnaired(EpisodeCache e) => e.airDate != null && e.airDate!.isAfter(_now());

  /// Looks like a show in exibição: an episode still to air, or one aired in
  /// the last 60 days.
  bool _airing(int tvId) {
    final limit = _now().subtract(const Duration(days: 60));
    for (final season in _store.readSeasonCatalog(tvId)) {
      for (final e in season.episodes) {
        final d = e.airDate;
        if (d != null && (d.isAfter(_now()) || d.isAfter(limit))) return true;
      }
    }
    return false;
  }

  /// The downloaded catalog is stale: its stamp is older than the TTL of its
  /// kind (airing: 24 h, idle: 7 d). A cache with no stamp (older app
  /// version) counts as stale. Without any cached season there is nothing to
  /// refresh ("missing" handles it).
  bool _refreshDue(FavoriteDoc doc) {
    if (_cached(doc.id).isEmpty) return false;
    final at = _store.readCatalogFetchedAt(doc.id);
    if (at == null) return true;
    final ttl = _airing(doc.id) ? airingTtl : idleTtl;
    return _now().difference(at) > ttl;
  }

  Set<int> _cached(int tvId) => {for (final s in _store.readSeasonCatalog(tvId)) s.seasonNumber};

  List<TvSeasonSummary> _missing(FavoriteDoc doc) {
    final cached = _cached(doc.id);
    return [
      for (final s in doc.seasonSummaries)
        if (!cached.contains(s.seasonNumber)) s,
    ];
  }

  /// Watched titles whose runtime is still unknown locally: watched movies
  /// without a cached runtime, and shows with watched episodes that have no
  /// own runtime in the catalog and no cached typical runtime. Keys are
  /// `movie:<id>` / `tv:<id>`.
  List<String> pendingRuntimes(List<FavoriteDoc> docs) {
    final keys = <String>[];
    for (final doc in docs) {
      if (doc.mediaType == MediaType.movie) {
        if (doc.watchedMovie && _store.readMovieRuntime(doc.id) == null) {
          keys.add('movie:${doc.id}');
        }
        continue;
      }
      if (doc.watchedEpisodes.isEmpty) continue;
      final own = {
        for (final season in _store.readSeasonCatalog(doc.id))
          for (final ep in season.episodes)
            if (ep.runtime != null)
              FavoriteMapper.episodeKey(season.seasonNumber, ep.episodeNumber),
      };
      if (doc.watchedEpisodes.any((k) => !own.contains(k))) keys.add('tv:${doc.id}');
    }
    return keys;
  }

  /// Fetches the runtimes listed by [pendingRuntimes] (movie `runtime`, show
  /// `episode_run_time`) with the same concurrency/backoff. [onDone] reports
  /// each key; a title TMDB has no runtime for reports `false`.
  Future<void> runRuntimes(
    List<String> keys, {
    List<FavoriteDoc> docs = const [],
    bool Function()? isCancelled,
    void Function(String key, bool ok)? onDone,
  }) async {
    var next = 0;
    Future<void> worker() async {
      while (next < keys.length) {
        if (isCancelled?.call() ?? false) return;
        final key = keys[next++];
        var ok = false;
        try {
          ok = await _fetchRuntime(key, docs);
        } catch (_) {}
        if (isCancelled?.call() ?? false) return;
        onDone?.call(key, ok);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  }

  Future<bool> _fetchRuntime(String key, List<FavoriteDoc> docs) async {
    final parts = key.split(':');
    final id = int.parse(parts[1]);
    if (parts[0] == 'movie') {
      final json = await _withRetry(() => _api.getMovieDetails(id));
      final runtime = json['runtime'];
      if (runtime is! int || runtime <= 0) return false;
      await _store.saveMovieRuntime(id, runtime);
      return true;
    }
    var ok = true;
    // Typical runtime of the show (fallback for episodes with none).
    if (_store.readTvFallbackRuntime(id) == null) {
      final json = await _withRetry(() => _api.getTvDetails(id));
      final list = [
        for (final r in (json['episode_run_time'] as List? ?? const []))
          if (r is int && r > 0) r,
      ];
      if (list.isNotEmpty) {
        await _store.saveTvFallbackRuntime(
            id, (list.reduce((a, b) => a + b) / list.length).round());
      } else {
        ok = false;
      }
    }
    // Catalogs downloaded before runtimes were stored: download again only
    // the seasons that hold watched episodes and have no runtime at all.
    final watched = {
      for (final d in docs)
        if (d.id == id && d.mediaType == MediaType.tv) ...d.watchedEpisodes,
    };
    for (final season in _store.readSeasonCatalog(id)) {
      final hasWatched = watched.any((k) => k.startsWith('${season.seasonNumber}_'));
      if (!hasWatched || season.episodes.any((e) => e.runtime != null)) continue;
      try {
        final fresh = await _withRetry(() => _api.getSeasonEpisodes(id, season.seasonNumber));
        await _store.saveCatalogSeason(id, fresh);
        if (!fresh.episodes.any((e) => e.runtime != null)) ok = false;
      } catch (_) {
        ok = false;
      }
    }
    return ok;
  }

  /// Reconciles [targets] (see [pending]) with at most [concurrency] shows in
  /// flight (one request each). [onDone] reports each show: `true` when its
  /// catalog now covers every season. [isCancelled] is polled between
  /// requests (account switch / provider disposed).
  Future<void> run(
    List<FavoriteDoc> targets, {
    bool Function()? isCancelled,
    bool Function(int tvId)? isStale,
    void Function(int tvId, bool ok)? onDone,
  }) async {
    var next = 0;
    Future<void> worker() async {
      while (next < targets.length) {
        if (isCancelled?.call() ?? false) return;
        final doc = targets[next++];
        if (isStale?.call(doc.id) ?? false) continue;
        bool ok;
        try {
          ok = await _reconcile(
              doc, () => (isCancelled?.call() ?? false) || (isStale?.call(doc.id) ?? false));
        } catch (_) {
          ok = false;
        }
        if (isCancelled?.call() ?? false) return;
        onDone?.call(doc.id, ok);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  }

  Future<bool> _reconcile(FavoriteDoc doc, bool Function() isCancelled) async {
    var summaries = doc.seasonSummaries;
    final due = _refreshDue(doc);
    final airing = due && _airing(doc.id);
    // Seasons to download again: the newest one and any with an unaired
    // episode (only for shows that look airing).
    final stale = <int>{};
    if (airing) {
      final cachedSeasons = _store.readSeasonCatalog(doc.id);
      final regular = [
        for (final s in cachedSeasons)
          if (s.seasonNumber > 0) s.seasonNumber
      ];
      if (regular.isNotEmpty) stale.add(regular.reduce((a, b) => a > b ? a : b));
      for (final s in cachedSeasons) {
        if (s.episodes.any(_isUnaired)) stale.add(s.seasonNumber);
      }
    }
    if (summaries.isEmpty || due) {
      final details = await _withRetry(() => _api.getTvDetails(doc.id));
      final fresh = TvSeasonSummary.listFromTvDetails(details);
      if (fresh.isNotEmpty) {
        final changed = fresh.length != summaries.length ||
            [
              for (var i = 0; i < fresh.length; i++)
                fresh[i].seasonNumber != summaries[i].seasonNumber ||
                    fresh[i].episodeCount != summaries[i].episodeCount
            ].any((c) => c);
        if (changed) {
          // Never write for a cancelled run (account switched) or a show that
          // is no longer a favorite.
          if (isCancelled()) return false;
          try {
            await _saveSummaries(doc.id, fresh);
          } catch (_) {
            // Best effort: the seasons below are still downloaded.
          }
        }
        summaries = fresh;
      }
    }
    for (final number in stale) {
      if (isCancelled()) return false;
      final season = await _withRetry(() => _api.getSeasonEpisodes(doc.id, number));
      await _store.saveCatalogSeason(doc.id, season);
    }
    // Two passes: a concurrent save of the same show (details screen) can
    // overwrite the box entry, so verify once after the first sweep.
    for (var pass = 0; pass < 2; pass++) {
      final cached = _cached(doc.id);
      final missing = [
        for (final s in summaries)
          if (!cached.contains(s.seasonNumber)) s,
      ];
      if (missing.isEmpty) {
        await _store.saveCatalogFetchedAt(doc.id, _now());
        return true;
      }
      for (final summary in missing) {
        if (isCancelled()) return false;
        final season = await _withRetry(
          () => _api.getSeasonEpisodes(doc.id, summary.seasonNumber),
        );
        await _store.saveCatalogSeason(doc.id, season);
      }
    }
    final cached = _cached(doc.id);
    final ok = summaries.every((s) => cached.contains(s.seasonNumber));
    if (ok) await _store.saveCatalogFetchedAt(doc.id, _now());
    return ok;
  }

  /// Retries transient failures (network, 429, 5xx) with 1 s, 2 s, 4 s
  /// backoff. Auth/not-found and programming errors are not retried.
  Future<T> _withRetry<T>(Future<T> Function() request) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await request();
      } on TmdbException catch (e) {
        final transient = e.type == TmdbErrorType.network ||
            e.type == TmdbErrorType.rateLimited ||
            e.type == TmdbErrorType.unknown;
        if (!transient || attempt >= maxRetries) rethrow;
        await _delay(Duration(seconds: 1 << attempt));
      }
    }
  }
}
