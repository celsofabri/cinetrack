import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';

/// In-memory fake — FavoritesRepository only depends on LocalStore's
/// public contract (read/save/delete/watch/readAll), never on Hive
/// directly, same pattern as discovery_repository_test.dart.
class _FakeLocalStore extends LocalStore {
  final Map<String, FavoriteItem> _items = {};
  final _controller = StreamController<void>.broadcast();

  @override
  FavoriteItem? read(String storageKey) => _items[storageKey];

  @override
  List<FavoriteItem> readAll() => _items.values.toList();

  @override
  Future<void> save(FavoriteItem item) async {
    _items[item.storageKey] = item;
    _controller.add(null);
  }

  @override
  Future<void> delete(String storageKey) async {
    _items.remove(storageKey);
    _controller.add(null);
  }

  @override
  Stream<void> watch() => _controller.stream;

  void seed(FavoriteItem item) => _items[item.storageKey] = item;
}

class _FakeTmdbApiClient extends TmdbApiClient {
  _FakeTmdbApiClient({this.error}) : super(apiKey: 'test');

  int seasonCalls = 0;
  SeasonCache? seasonResult;

  /// When set, `getSeasonEpisodes` throws this instead of returning
  /// `seasonResult` — used to simulate a network failure (no connection,
  /// 429, 401, ...) surfacing from inside `loadSeason`.
  final Object? error;

  @override
  Future<SeasonCache> getSeasonEpisodes(int tvId, int seasonNumber) async {
    seasonCalls++;
    final configuredError = error;
    if (configuredError != null) throw configuredError;
    final result = seasonResult;
    if (result == null) {
      throw StateError('no seasonResult configured for the fake API client');
    }
    return result;
  }
}

EpisodeCache _episode(int number, {bool watched = false, DateTime? airDate}) => EpisodeCache(
      episodeNumber: number,
      name: 'Episode $number',
      airDate: airDate,
      watched: watched,
    );

FavoriteItem _show({List<SeasonCache>? seasons}) => FavoriteItem(
      id: 42,
      mediaType: MediaType.tv,
      title: 'A Show',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
      seasons: seasons ?? const [],
    );

void main() {
  group('FavoritesRepository.setSeasonWatched', () {
    test('marks every already-aired episode as watched and leaves unaired ones untouched',
        () async {
      final future = DateTime.now().add(const Duration(days: 30));
      final store = _FakeLocalStore()
        ..seed(_show(seasons: [
          SeasonCache(seasonNumber: 1, episodes: [
            _episode(1, watched: false),
            _episode(2, watched: false),
            _episode(3, watched: false, airDate: future),
          ]),
        ]));
      final repo = FavoritesRepository(api: _FakeTmdbApiClient(), store: store);

      await repo.setSeasonWatched(42, 1, watched: true);

      final saved = store.read('42-tv')!;
      final season = saved.seasons!.single;
      expect(season.episodes.firstWhere((e) => e.episodeNumber == 1).watched, isTrue);
      expect(season.episodes.firstWhere((e) => e.episodeNumber == 2).watched, isTrue);
      // Unaired episode is never flipped to watched by the bulk action.
      expect(season.episodes.firstWhere((e) => e.episodeNumber == 3).watched, isFalse);
      expect(saved.lastWatchedAt, isNotNull);
    });

    test('unmarks every aired episode when called with watched: false', () async {
      final store = _FakeLocalStore()
        ..seed(_show(seasons: [
          SeasonCache(seasonNumber: 1, episodes: [
            _episode(1, watched: true),
            _episode(2, watched: true),
          ]),
        ]));
      final repo = FavoritesRepository(api: _FakeTmdbApiClient(), store: store);

      await repo.setSeasonWatched(42, 1, watched: false);

      final saved = store.read('42-tv')!;
      final season = saved.seasons!.single;
      expect(season.episodes.every((e) => !e.watched), isTrue);
    });

    test('only touches the targeted season, leaving other seasons as-is', () async {
      final store = _FakeLocalStore()
        ..seed(_show(seasons: [
          SeasonCache(seasonNumber: 1, episodes: [_episode(1, watched: false)]),
          SeasonCache(seasonNumber: 2, episodes: [_episode(1, watched: false)]),
        ]));
      final repo = FavoritesRepository(api: _FakeTmdbApiClient(), store: store);

      await repo.setSeasonWatched(42, 1, watched: true);

      final saved = store.read('42-tv')!;
      final season1 = saved.seasons!.firstWhere((s) => s.seasonNumber == 1);
      final season2 = saved.seasons!.firstWhere((s) => s.seasonNumber == 2);
      expect(season1.episodes.single.watched, isTrue);
      expect(season2.episodes.single.watched, isFalse);
    });

    test('fetches the season first when it was never opened/cached before', () async {
      final store = _FakeLocalStore()..seed(_show());
      final api = _FakeTmdbApiClient()
        ..seasonResult = SeasonCache(seasonNumber: 1, episodes: [
          _episode(1, watched: false),
          _episode(2, watched: false),
        ]);
      final repo = FavoritesRepository(api: api, store: store);

      await repo.setSeasonWatched(42, 1, watched: true);

      expect(api.seasonCalls, 1);
      final saved = store.read('42-tv')!;
      final season = saved.seasons!.single;
      expect(season.episodes.every((e) => e.watched), isTrue);
    });

    test(
        'propagates the error and leaves Hive untouched when the season was '
        'never cached and fetching it fails (e.g. no connection)', () async {
      final store = _FakeLocalStore()..seed(_show()); // seasons: [] — nothing cached yet
      final api = _FakeTmdbApiClient(error: TmdbException.network());
      final repo = FavoritesRepository(api: api, store: store);

      // Must reach the caller unchanged — never swallowed into a silent
      // no-op, which from the UI would look like the checkbox "did
      // nothing".
      await expectLater(
        () => repo.setSeasonWatched(42, 1, watched: true),
        throwsA(isA<TmdbException>()),
      );

      // No partial write: loadSeason only calls _store.save after the
      // network call succeeds, and setSeasonWatched's own save happens
      // after loadSeason returns — so a failure there must leave the
      // previously-saved item exactly as it was before the call, not a
      // half-updated one.
      final saved = store.read('42-tv')!;
      expect(saved.seasons, isEmpty);
      expect(saved.lastWatchedAt, isNull);
      expect(api.seasonCalls, 1);
    });

    test('propagates a rate-limit error the same way, without touching Hive', () async {
      final store = _FakeLocalStore()..seed(_show());
      final api = _FakeTmdbApiClient(error: TmdbException.rateLimited());
      final repo = FavoritesRepository(api: api, store: store);

      await expectLater(
        () => repo.setSeasonWatched(42, 1, watched: true),
        throwsA(isA<TmdbException>()),
      );

      final saved = store.read('42-tv')!;
      expect(saved.seasons, isEmpty);
      expect(saved.lastWatchedAt, isNull);
    });
  });
}
