import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';

class _FakeFavoritesRepository extends FavoritesRepository {
  _FakeFavoritesRepository(this._items)
      : super(api: TmdbApiClient(apiKey: 'test'), store: LocalStore());

  final List<FavoriteItem> _items;

  @override
  Stream<List<FavoriteItem>> watchAll() async* {
    yield _items;
  }
}

FavoriteItem _movie({bool watched = false}) => FavoriteItem(
      id: 1,
      mediaType: MediaType.movie,
      title: 'Movie',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
      watchedMovie: watched,
    );

FavoriteItem _show(
  int id, {
  required List<SeasonCache> seasons,
  DateTime? addedAt,
  DateTime? lastWatchedAt,
}) =>
    FavoriteItem(
      id: id,
      mediaType: MediaType.tv,
      title: 'Show $id',
      posterPath: null,
      overview: '',
      addedAt: addedAt ?? DateTime.now(),
      seasons: seasons,
      lastWatchedAt: lastWatchedAt,
    );

SeasonCache _season(List<EpisodeCache> episodes) =>
    SeasonCache(seasonNumber: 1, episodes: episodes);

EpisodeCache _episode(int number, {bool watched = false}) => EpisodeCache(
      episodeNumber: number,
      name: 'Ep $number',
      airDate: null,
      watched: watched,
    );

ProviderContainer _containerFor(List<FavoriteItem> favorites) {
  final container = ProviderContainer(overrides: [
    favoritesRepositoryProvider.overrideWithValue(_FakeFavoritesRepository(favorites)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('continueWatchingProvider', () {
    test('a movie never enters, regardless of watched status', () async {
      final container = _containerFor([_movie(watched: true), _movie(watched: false)]);
      await container.read(favoritesListProvider.future);

      expect(container.read(continueWatchingProvider), isEmpty);
    });

    test('a tv show with partial progress enters', () async {
      final show = _show(1, seasons: [
        _season([_episode(1, watched: true), _episode(2)]),
      ]);
      final container = _containerFor([show]);
      await container.read(favoritesListProvider.future);

      final result = container.read(continueWatchingProvider);
      expect(result.map((s) => s.id), [1]);
    });

    test('a tv show with zero watched episodes does not enter (not started)', () async {
      final show = _show(1, seasons: [
        _season([_episode(1), _episode(2)]),
      ]);
      final container = _containerFor([show]);
      await container.read(favoritesListProvider.future);

      expect(container.read(continueWatchingProvider), isEmpty);
    });

    test('a fully watched tv show does not enter (nothing left to continue)', () async {
      final show = _show(1, seasons: [
        _season([_episode(1, watched: true), _episode(2, watched: true)]),
      ]);
      final container = _containerFor([show]);
      await container.read(favoritesListProvider.future);

      expect(container.read(continueWatchingProvider), isEmpty);
    });

    test('orders by lastWatchedAt, falling back to addedAt when null (pre-migration items)',
        () async {
      final now = DateTime.now();
      final partial = [_episode(1, watched: true), _episode(2)];

      final showA = _show(
        1,
        seasons: [_season(partial)],
        addedAt: now.subtract(const Duration(days: 5)),
        lastWatchedAt: now.subtract(const Duration(hours: 1)),
      );
      final showB = _show(
        2,
        seasons: [_season(partial)],
        addedAt: now.subtract(const Duration(days: 1)),
        lastWatchedAt: null, // pre-migration item: falls back to addedAt
      );
      final showC = _show(
        3,
        seasons: [_season(partial)],
        addedAt: now.subtract(const Duration(days: 10)),
        lastWatchedAt: now, // most recent activity
      );

      final container = _containerFor([showA, showB, showC]);
      await container.read(favoritesListProvider.future);

      final result = container.read(continueWatchingProvider);
      expect(result.map((s) => s.id).toList(), [3, 1, 2]);
    });
  });
}
