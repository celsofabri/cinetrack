import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/screens/favorites_screen.dart';
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

Widget _wrap(List<FavoriteItem> favorites) {
  return ProviderScope(
    overrides: [
      favoritesRepositoryProvider.overrideWithValue(_FakeFavoritesRepository(favorites)),
    ],
    child: const MaterialApp(home: FavoritesScreen()),
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

    expect(find.text('A Show'), findsOneWidget);
    expect(find.textContaining('1/2'), findsOneWidget);
  });

  testWidgets('Todos/Filmes/Séries filter narrows the favorites list',
      (tester) async {
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

    expect(find.text('A Show'), findsOneWidget);
    expect(find.text('A Movie'), findsOneWidget);

    await tester.tap(find.text('Filmes'));
    await tester.pumpAndSettle();

    expect(find.text('A Show'), findsNothing);
    expect(find.text('A Movie'), findsOneWidget);
  });

  testWidgets('the Todos/Filmes/Séries filter is horizontally centered',
      (tester) async {
    await tester.pumpWidget(_wrap(const []));
    await tester.pumpAndSettle();

    // "Filmes" is the middle segment, so it sits at the control's center.
    final filterCenter = tester.getCenter(find.text('Filmes'));
    final screenCenter = tester.getCenter(find.byType(Scaffold));

    expect(filterCenter.dx, closeTo(screenCenter.dx, 12));
  });
}
