import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';
import 'package:cinetrack/widgets/discovery_section.dart';
import 'package:cinetrack/widgets/poster_image.dart';

/// Fake repository that reacts like the real one: watchAll() streams the
/// current in-memory list, and addMovie is idempotent (mirrors the
/// `if (_store.read(key) != null) return;` guard in FavoritesRepository).
class _FakeFavoritesRepository extends FavoritesRepository {
  _FakeFavoritesRepository(List<FavoriteItem> items)
      : _items = items,
        super(api: TmdbApiClient(apiKey: 'test'), store: LocalStore());

  List<FavoriteItem> _items;
  int addMovieCalls = 0;
  final _controller = StreamController<List<FavoriteItem>>.broadcast();

  @override
  Stream<List<FavoriteItem>> watchAll() async* {
    yield _items;
    yield* _controller.stream;
  }

  @override
  Future<void> addMovie({
    required int id,
    required String title,
    required String? posterPath,
    required String overview,
  }) async {
    addMovieCalls++;
    if (_items.any((i) => i.id == id && i.mediaType == MediaType.movie)) return;
    _items = [
      ..._items,
      FavoriteItem(
        id: id,
        mediaType: MediaType.movie,
        title: title,
        posterPath: posterPath,
        overview: overview,
        addedAt: DateTime.now(),
      ),
    ];
    _controller.add(_items);
  }
}

Widget _wrap({
  required FutureProvider<List<SearchResult>> provider,
  List<FavoriteItem> favorites = const [],
  FavoritesRepository? repository,
}) {
  // A real (minimal) GoRouter — tapping a card (or a disabled overlay
  // button that lets the tap fall through to the card underneath) calls
  // context.push, which needs a GoRouter ancestor even in tests.
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: DiscoverySection(title: 'Em Alta', provider: provider),
        ),
      ),
      // Renders the matched id so navigation tests can assert *which*
      // details route was pushed, instead of just that push() was called.
      GoRoute(
        path: '/movie/:id',
        builder: (context, state) => Text('movie-details-${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/tv/:id',
        builder: (context, state) => Text('tv-details-${state.pathParameters['id']}'),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      favoritesRepositoryProvider.overrideWithValue(
        repository ?? _FakeFavoritesRepository(favorites),
      ),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('loading state shows a progress indicator', (tester) async {
    final provider = FutureProvider<List<SearchResult>>(
      (ref) => Completer<List<SearchResult>>().future,
    );

    await tester.pumpWidget(_wrap(provider: provider));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('error state shows the message and a retry button', (tester) async {
    final provider = FutureProvider<List<SearchResult>>(
      (ref) => Future<List<SearchResult>>.error(TmdbException.rateLimited()),
    );

    await tester.pumpWidget(_wrap(provider: provider));
    await tester.pump();

    expect(find.text(TmdbException.rateLimited().message), findsOneWidget);
    expect(find.text('Tentar de novo'), findsOneWidget);
  });

  testWidgets('empty data hides the section entirely', (tester) async {
    final provider = FutureProvider<List<SearchResult>>((ref) async => <SearchResult>[]);

    await tester.pumpWidget(_wrap(provider: provider));
    await tester.pump();
    await tester.pump();

    expect(find.text('Em Alta'), findsNothing);
  });

  testWidgets('data shows the title and a card per item', (tester) async {
    final items = [
      const SearchResult(
        id: 1,
        mediaType: MediaType.movie,
        title: 'Movie A',
        posterPath: null,
        overview: '',
      ),
      const SearchResult(
        id: 2,
        mediaType: MediaType.tv,
        title: 'Show B',
        posterPath: null,
        overview: '',
      ),
    ];
    final provider = FutureProvider<List<SearchResult>>((ref) async => items);

    await tester.pumpWidget(_wrap(provider: provider));
    await tester.pump();
    await tester.pump();

    expect(find.text('Em Alta'), findsOneWidget);
    expect(find.text('Movie A'), findsOneWidget);
    expect(find.text('Show B'), findsOneWidget);
  });

  testWidgets('item already favorited shows a filled heart from the start', (tester) async {
    final favorite = FavoriteItem(
      id: 1,
      mediaType: MediaType.movie,
      title: 'Movie A',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
    );
    final items = [
      const SearchResult(
        id: 1,
        mediaType: MediaType.movie,
        title: 'Movie A',
        posterPath: null,
        overview: '',
      ),
    ];
    final provider = FutureProvider<List<SearchResult>>((ref) async => items);

    await tester.pumpWidget(_wrap(provider: provider, favorites: [favorite]));
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsNothing);
  });

  testWidgets('favoriting from a card updates the icon and does not duplicate on a second tap',
      (tester) async {
    final items = [
      const SearchResult(
        id: 1,
        mediaType: MediaType.movie,
        title: 'Movie A',
        posterPath: null,
        overview: '',
      ),
    ];
    final provider = FutureProvider<List<SearchResult>>((ref) async => items);
    final repo = _FakeFavoritesRepository(const []);

    await tester.pumpWidget(_wrap(provider: provider, repository: repo));
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.favorite_border), findsOneWidget);

    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pump();
    await tester.pump();

    expect(repo.addMovieCalls, 1);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsNothing);

    // Once favorited, the icon reflects favoritesListProvider (source of
    // truth); a second tap toggles (removes) and never calls addMovie again.
    await tester.tap(find.byIcon(Icons.favorite), warnIfMissed: false);
    await tester.pump();

    expect(repo.addMovieCalls, 1);
  });

  testWidgets('tapping the poster of a movie card navigates to /movie/:id', (tester) async {
    final items = [
      const SearchResult(
        id: 42,
        mediaType: MediaType.movie,
        title: 'Poster Movie',
        posterPath: null,
        overview: '',
      ),
    ];
    final provider = FutureProvider<List<SearchResult>>((ref) async => items);

    await tester.pumpWidget(_wrap(provider: provider));
    await tester.pump();
    await tester.pump();

    // Taps the poster itself, not the favorite icon in the corner.
    await tester.tap(find.byType(PosterImage));
    await tester.pumpAndSettle();

    expect(find.text('movie-details-42'), findsOneWidget);
  });

  testWidgets('tapping the poster of a TV card navigates to /tv/:id', (tester) async {
    final items = [
      const SearchResult(
        id: 99,
        mediaType: MediaType.tv,
        title: 'Poster Show',
        posterPath: null,
        overview: '',
      ),
    ];
    final provider = FutureProvider<List<SearchResult>>((ref) async => items);

    await tester.pumpWidget(_wrap(provider: provider));
    await tester.pump();
    await tester.pump();

    // Taps the poster itself, not the favorite icon in the corner.
    await tester.tap(find.byType(PosterImage));
    await tester.pumpAndSettle();

    expect(find.text('tv-details-99'), findsOneWidget);
  });
}
