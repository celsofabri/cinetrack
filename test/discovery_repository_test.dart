import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/discovery_cache_entry.dart';
import 'package:cinetrack/models/discovery_category.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/repositories/discovery_repository.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';

/// In-memory fake — DiscoveryRepository only depends on LocalStore's public
/// contract (readDiscoveryCache/saveDiscoveryCache), never on Hive directly.
class _FakeLocalStore extends LocalStore {
  final Map<String, DiscoveryCacheEntry> _cache = {};

  @override
  DiscoveryCacheEntry? readDiscoveryCache(String key) => _cache[key];

  @override
  Future<void> saveDiscoveryCache(String key, List<SearchResult> items) async {
    _cache[key] = DiscoveryCacheEntry(items: items, fetchedAt: DateTime.now());
  }

  void seed(String key, List<SearchResult> items, DateTime fetchedAt) {
    _cache[key] = DiscoveryCacheEntry(items: items, fetchedAt: fetchedAt);
  }
}

SearchResult _result(int id, {MediaType mediaType = MediaType.movie}) => SearchResult(
      id: id,
      mediaType: mediaType,
      title: 'Item $id',
      posterPath: null,
      overview: '',
    );

class _FakeTmdbApiClient extends TmdbApiClient {
  _FakeTmdbApiClient() : super(apiKey: 'test');

  int trendingCalls = 0;
  Object? trendingError;
  List<SearchResult> trendingResult = [_result(1)];

  int nowPlayingCalls = 0;
  int onTheAirCalls = 0;
  Object? nowPlayingError;
  Object? onTheAirError;
  List<SearchResult> nowPlayingResult = [_result(2)];
  List<SearchResult> onTheAirResult = [_result(3, mediaType: MediaType.tv)];

  int discoverMovieCalls = 0;
  int discoverTvCalls = 0;
  List<SearchResult> Function(int genreId) discoverMovieResultFn =
      (genreId) => [_result(100 + genreId)];
  List<SearchResult> Function(int genreId) discoverTvResultFn =
      (genreId) => [_result(200 + genreId, mediaType: MediaType.tv)];

  @override
  Future<List<SearchResult>> getTrending() async {
    trendingCalls++;
    final error = trendingError;
    if (error != null) throw error;
    return trendingResult;
  }

  @override
  Future<List<SearchResult>> getNowPlayingMovies() async {
    nowPlayingCalls++;
    final error = nowPlayingError;
    if (error != null) throw error;
    return nowPlayingResult;
  }

  @override
  Future<List<SearchResult>> getOnTheAirTv() async {
    onTheAirCalls++;
    final error = onTheAirError;
    if (error != null) throw error;
    return onTheAirResult;
  }

  @override
  Future<List<SearchResult>> discoverMoviesByGenre(int genreId) async {
    discoverMovieCalls++;
    return discoverMovieResultFn(genreId);
  }

  @override
  Future<List<SearchResult>> discoverTvByGenre(int genreId) async {
    discoverTvCalls++;
    return discoverTvResultFn(genreId);
  }
}

void main() {
  group('DiscoveryRepository._cached (exercised via getTrending)', () {
    test('cache-hit within the TTL returns cached items without calling the API', () async {
      final store = _FakeLocalStore()
        ..seed('trending', [_result(9)], DateTime.now().subtract(const Duration(minutes: 5)));
      final api = _FakeTmdbApiClient();
      final repo = DiscoveryRepository(api: api, store: store);

      final result = await repo.getTrending();

      expect(result.single.id, 9);
      expect(api.trendingCalls, 0);
    });

    test('missing cache calls the API and persists the fresh result', () async {
      final store = _FakeLocalStore();
      final api = _FakeTmdbApiClient()..trendingResult = [_result(1)];
      final repo = DiscoveryRepository(api: api, store: store);

      final result = await repo.getTrending();

      expect(result.single.id, 1);
      expect(api.trendingCalls, 1);
      expect(store.readDiscoveryCache('trending')?.items.single.id, 1);
    });

    test('expired cache calls the API and persists the fresh result', () async {
      final store = _FakeLocalStore()
        ..seed(
          'trending',
          [_result(9)],
          DateTime.now().subtract(DiscoveryRepository.trendingTtl + const Duration(minutes: 1)),
        );
      final api = _FakeTmdbApiClient()..trendingResult = [_result(1)];
      final repo = DiscoveryRepository(api: api, store: store);

      final result = await repo.getTrending();

      expect(result.single.id, 1);
      expect(api.trendingCalls, 1);
      expect(store.readDiscoveryCache('trending')?.items.single.id, 1);
    });

    test('API error propagates and does not fall back to the stale cache', () async {
      final store = _FakeLocalStore()
        ..seed(
          'trending',
          [_result(9)],
          DateTime.now().subtract(DiscoveryRepository.trendingTtl + const Duration(minutes: 1)),
        );
      final api = _FakeTmdbApiClient()..trendingError = TmdbException.rateLimited();
      final repo = DiscoveryRepository(api: api, store: store);

      await expectLater(repo.getTrending(), throwsA(isA<TmdbException>()));
      // stale entry stays untouched — no silent fallback, no overwrite with bad data.
      expect(store.readDiscoveryCache('trending')?.items.single.id, 9);
    });
  });

  group('DiscoveryRepository.getNovelties', () {
    test('cache-hit within the TTL returns cached items without calling the API', () async {
      final store = _FakeLocalStore()
        ..seed('novelties', [_result(9)], DateTime.now().subtract(const Duration(hours: 1)));
      final api = _FakeTmdbApiClient();
      final repo = DiscoveryRepository(api: api, store: store);

      final result = await repo.getNovelties();

      expect(result.single.id, 9);
      expect(api.nowPlayingCalls, 0);
      expect(api.onTheAirCalls, 0);
    });

    test('expired cache calls both endpoints again', () async {
      final store = _FakeLocalStore()
        ..seed(
          'novelties',
          [_result(9)],
          DateTime.now().subtract(DiscoveryRepository.noveltiesTtl + const Duration(minutes: 1)),
        );
      final api = _FakeTmdbApiClient();
      final repo = DiscoveryRepository(api: api, store: store);

      await repo.getNovelties();

      expect(api.nowPlayingCalls, 1);
      expect(api.onTheAirCalls, 1);
    });

    test('interleaves now-playing movies and on-the-air tv results', () async {
      final store = _FakeLocalStore();
      final api = _FakeTmdbApiClient()
        ..nowPlayingResult = [_result(1), _result(2)]
        ..onTheAirResult = [
          _result(11, mediaType: MediaType.tv),
          _result(12, mediaType: MediaType.tv),
        ];
      final repo = DiscoveryRepository(api: api, store: store);

      final result = await repo.getNovelties();

      expect(result.map((r) => r.id).toList(), [1, 11, 2, 12]);
    });

    test('propagates the error when one of the two calls fails, without caching a partial result',
        () async {
      final store = _FakeLocalStore();
      final api = _FakeTmdbApiClient()..onTheAirError = TmdbException.network();
      final repo = DiscoveryRepository(api: api, store: store);

      await expectLater(repo.getNovelties(), throwsA(isA<TmdbException>()));
      expect(store.readDiscoveryCache('novelties'), isNull);
    });

    test('a failing Novidades call does not affect a separate getTrending call', () async {
      final store = _FakeLocalStore();
      final api = _FakeTmdbApiClient()
        ..onTheAirError = TmdbException.rateLimited()
        ..trendingResult = [_result(5)];
      final repo = DiscoveryRepository(api: api, store: store);

      await expectLater(repo.getNovelties(), throwsA(isA<TmdbException>()));
      final trending = await repo.getTrending();

      expect(trending.single.id, 5);
    });
  });

  group('DiscoveryRepository.getCategory', () {
    const DiscoveryCategory horror = (label: 'Terror', movieGenreId: 27, tvGenreId: null);
    const DiscoveryCategory action = (label: 'Ação', movieGenreId: 28, tvGenreId: 10759);

    test('a movie-only category (no tvGenreId) never calls /discover/tv', () async {
      final store = _FakeLocalStore();
      final api = _FakeTmdbApiClient();
      final repo = DiscoveryRepository(api: api, store: store);

      final result = await repo.getCategory(horror);

      expect(api.discoverMovieCalls, 1);
      expect(api.discoverTvCalls, 0);
      expect(result, isNotEmpty);
    });

    test('a category with a tvGenreId calls both endpoints and interleaves', () async {
      final store = _FakeLocalStore();
      final api = _FakeTmdbApiClient();
      api.discoverMovieResultFn = (genreId) => [_result(1), _result(2)];
      api.discoverTvResultFn = (genreId) =>
          [_result(11, mediaType: MediaType.tv), _result(12, mediaType: MediaType.tv)];
      final repo = DiscoveryRepository(api: api, store: store);

      final result = await repo.getCategory(action);

      expect(api.discoverMovieCalls, 1);
      expect(api.discoverTvCalls, 1);
      expect(result.map((r) => r.id).toList(), [1, 11, 2, 12]);
    });

    test('cache-hit within the TTL returns cached items without calling the API', () async {
      final store = _FakeLocalStore()
        ..seed('category:Terror', [_result(9)], DateTime.now().subtract(const Duration(hours: 1)));
      final api = _FakeTmdbApiClient();
      final repo = DiscoveryRepository(api: api, store: store);

      final result = await repo.getCategory(horror);

      expect(result.single.id, 9);
      expect(api.discoverMovieCalls, 0);
    });

    test('expired cache calls the API again, respecting the 12h category TTL', () async {
      final store = _FakeLocalStore()
        ..seed(
          'category:Terror',
          [_result(9)],
          DateTime.now().subtract(DiscoveryRepository.categoryTtl + const Duration(minutes: 1)),
        );
      final api = _FakeTmdbApiClient();
      final repo = DiscoveryRepository(api: api, store: store);

      await repo.getCategory(horror);

      expect(api.discoverMovieCalls, 1);
    });

    test('different categories are cached under different keys', () async {
      final store = _FakeLocalStore();
      final api = _FakeTmdbApiClient();
      final repo = DiscoveryRepository(api: api, store: store);

      await repo.getCategory(horror);
      await repo.getCategory(action);

      expect(store.readDiscoveryCache('category:Terror'), isNotNull);
      expect(store.readDiscoveryCache('category:Ação'), isNotNull);
    });
  });
}
