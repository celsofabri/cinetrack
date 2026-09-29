import '../models/discovery_category.dart';
import '../models/search_result.dart';
import '../services/local_store.dart';
import '../services/tmdb_api_client.dart';

/// Same responsibility as `FavoritesRepository` — the only layer that
/// decides network×cache — but for the discovery catalog (trending,
/// novelties, by-category). Different bounded context from favorites: this
/// one reads/writes the `discovery_cache` Hive box, never `favorites`.
///
/// Cache validity ("is this still good, or do I need to fetch again?") is
/// decided here, against a timestamp persisted in Hive, on every call —
/// never by state held in a Riverpod provider. See
/// docs/adr/adr-002-cache-descoberta-ttl.md for why (directly motivated by
/// the `seasonProvider` bug this design avoids repeating).
class DiscoveryRepository {
  final TmdbApiClient _api;
  final LocalStore _store;

  static const trendingTtl = Duration(hours: 3);
  static const noveltiesTtl = Duration(hours: 6);
  static const categoryTtl = Duration(hours: 12);

  DiscoveryRepository({required TmdbApiClient api, required LocalStore store})
      : _api = api,
        _store = store;

  Future<List<SearchResult>> getTrending() =>
      _cached('trending', trendingTtl, () => _api.getTrending());

  /// Combines now-playing movies and on-the-air TV, capped at 10 of each
  /// and interleaved so neither media type dominates the carousel. If
  /// either call fails, the whole section shows an error — deliberate:
  /// the spec asks for per-section isolation (Novidades × Em Alta ×
  /// Categoria × Favoritos), not per-sub-call granularity.
  Future<List<SearchResult>> getNovelties() =>
      _cached('novelties', noveltiesTtl, () async {
        final results = await Future.wait([
          _api.getNowPlayingMovies(),
          _api.getOnTheAirTv(),
        ]);
        return _interleave(results[0].take(10).toList(), results[1].take(10).toList());
      });

  /// `/discover/tv` is only called when the category has a TV-equivalent
  /// genre (`tvGenreId != null`) — Terror/Romance are movie-only because
  /// TV has no equivalent genre on TMDB (see DiscoveryCategory).
  Future<List<SearchResult>> getCategory(DiscoveryCategory category) =>
      _cached('category:${category.label}', categoryTtl, () async {
        final calls = [
          _api.discoverMoviesByGenre(category.movieGenreId),
          if (category.tvGenreId != null) _api.discoverTvByGenre(category.tvGenreId!),
        ];
        final results = await Future.wait(calls);
        return _interleave(
          results[0].take(10).toList(),
          results.length > 1 ? results[1].take(10).toList() : const [],
        );
      });

  static List<SearchResult> _interleave(List<SearchResult> a, List<SearchResult> b) {
    final out = <SearchResult>[];
    for (var i = 0; i < a.length || i < b.length; i++) {
      if (i < a.length) out.add(a[i]);
      if (i < b.length) out.add(b[i]);
    }
    return out;
  }

  Future<List<SearchResult>> _cached(
    String key,
    Duration ttl,
    Future<List<SearchResult>> Function() fetch,
  ) async {
    final cached = _store.readDiscoveryCache(key);
    if (cached != null && DateTime.now().difference(cached.fetchedAt) < ttl) {
      return cached.items;
    }
    final fresh = await fetch(); // error propagates — no silent fallback to stale cache
    await _store.saveDiscoveryCache(key, fresh);
    return fresh;
  }
}
