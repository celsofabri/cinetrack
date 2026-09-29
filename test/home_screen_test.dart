import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/discovery_category.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/discovery_repository.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/screens/home_screen.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';

/// Fake repository so the widget test never touches Hive or the network —
/// only FavoritesRepository's public contract (watchAll) is exercised.
class _FakeFavoritesRepository extends FavoritesRepository {
  _FakeFavoritesRepository(this._items)
      : super(api: TmdbApiClient(apiKey: 'test'), store: LocalStore());

  final List<FavoriteItem> _items;

  @override
  Stream<List<FavoriteItem>> watchAll() async* {
    yield _items;
  }
}

/// Fake discovery repository so the home screen's discovery sections never
/// touch the network in these tests — empty by default so every discovery
/// section collapses to nothing, keeping the favorites-only assertions
/// below unaffected.
class _FakeDiscoveryRepository extends DiscoveryRepository {
  _FakeDiscoveryRepository() : super(api: TmdbApiClient(apiKey: 'test'), store: LocalStore());

  @override
  Future<List<SearchResult>> getTrending() async => const [];

  @override
  Future<List<SearchResult>> getNovelties() async => const [];

  @override
  Future<List<SearchResult>> getCategory(DiscoveryCategory category) async => const [];
}

Widget _wrap(List<FavoriteItem> favorites) {
  return ProviderScope(
    overrides: [
      favoritesRepositoryProvider.overrideWithValue(_FakeFavoritesRepository(favorites)),
      discoveryRepositoryProvider.overrideWithValue(_FakeDiscoveryRepository()),
    ],
    child: const MaterialApp(home: HomeScreen()),
  );
}

void main() {
  testWidgets('shows empty state when there are no favorites', (tester) async {
    await tester.pumpWidget(_wrap(const []));
    await tester.pumpAndSettle();

    expect(find.text('Nenhum favorito ainda'), findsOneWidget);
  });

  testWidgets('shows a favorite movie with its watched status', (tester) async {
    final movie = FavoriteItem(
      id: 1,
      mediaType: MediaType.movie,
      title: 'A Movie',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
      watchedMovie: false,
    );

    await tester.pumpWidget(_wrap([movie]));
    await tester.pumpAndSettle();

    expect(find.text('A Movie'), findsOneWidget);
    expect(find.text('Não assistido'), findsOneWidget);
  });

  testWidgets('shows aggregated progress for a favorite series', (tester) async {
    final show = FavoriteItem(
      id: 2,
      mediaType: MediaType.tv,
      title: 'A Show',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
      seasons: [
        const SeasonCache(seasonNumber: 1, episodes: [
          EpisodeCache(episodeNumber: 1, name: 'Ep 1', airDate: null, watched: true),
          EpisodeCache(episodeNumber: 2, name: 'Ep 2', airDate: null, watched: false),
        ]),
      ],
    );

    await tester.pumpWidget(_wrap([show]));
    await tester.pumpAndSettle();

    // A show with partial progress now renders twice: once as a highlight
    // in "Continue assistindo" and once in the regular favorites list —
    // both are expected, not a duplication bug.
    expect(find.text('A Show'), findsNWidgets(2));
    expect(find.textContaining('1/2'), findsNWidgets(2));
  });

  testWidgets(
      'Todos/Filmes/Séries filter affects only the favorites section, '
      'not Continue assistindo', (tester) async {
    final movie = FavoriteItem(
      id: 1,
      mediaType: MediaType.movie,
      title: 'A Movie',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
    );
    final show = FavoriteItem(
      id: 2,
      mediaType: MediaType.tv,
      title: 'A Show',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
      seasons: [
        const SeasonCache(seasonNumber: 1, episodes: [
          EpisodeCache(episodeNumber: 1, name: 'Ep 1', airDate: null, watched: true),
          EpisodeCache(episodeNumber: 2, name: 'Ep 2', airDate: null, watched: false),
        ]),
      ],
    );

    await tester.pumpWidget(_wrap([movie, show]));
    await tester.pumpAndSettle();

    // Before filtering: the show appears in both Continue assistindo and
    // the favorites list.
    expect(find.text('A Show'), findsNWidgets(2));
    expect(find.text('A Movie'), findsOneWidget);

    await tester.tap(find.text('Filmes'));
    await tester.pumpAndSettle();

    // After filtering to "Filmes": the favorites list drops the show, but
    // Continue assistindo (unaffected by the filter) still shows it once.
    expect(find.text('A Show'), findsOneWidget);
    expect(find.text('A Movie'), findsOneWidget);
  });
}
