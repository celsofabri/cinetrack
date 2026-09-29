import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/catalog.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/screens/catalog_screen.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';

typedef _Call = ({MediaType type, int? genreId, int page});

class _FakeApi extends TmdbApiClient {
  _FakeApi({this.totalPages = 1}) : super(apiKey: 'test');

  final int totalPages;
  final calls = <_Call>[];

  /// Test hooks: fail the next N requests, return an empty first page, or
  /// hold the response for a given genre until the completer completes.
  int failNext = 0;
  bool emptyFirstPage = false;
  final gates = <int, Completer<void>>{};

  @override
  Future<List<Genre>> getGenres(MediaType type) async => type == MediaType.movie
      ? const [Genre(id: 28, name: 'Ação'), Genre(id: 27, name: 'Terror')]
      : const [Genre(id: 10759, name: 'Ação e Aventura')];

  @override
  Future<DiscoverPage> discoverPage(MediaType type, {int? genreId, int page = 1}) async {
    calls.add((type: type, genreId: genreId, page: page));
    final gate = gates[genreId];
    if (gate != null) await gate.future;
    if (failNext > 0) {
      failNext--;
      throw Exception('boom');
    }
    if (emptyFirstPage && page == 1) {
      return DiscoverPage(results: const [], page: 1, totalPages: totalPages);
    }
    final label = '${type.jsonValue}-${genreId ?? 'all'}-p$page';
    return DiscoverPage(
      results: [
        for (var i = 0; i < 6; i++)
          SearchResult(
            id: page * 100 + i,
            mediaType: type,
            title: '$label-$i',
            posterPath: null,
            overview: '',
          ),
      ],
      page: page,
      totalPages: totalPages,
    );
  }
}

class _FakeFavoritesRepository extends FavoritesRepository {
  _FakeFavoritesRepository()
      : super(api: TmdbApiClient(apiKey: 'test'), store: LocalStore());

  @override
  Stream<List<FavoriteItem>> watchAll() async* {
    yield const [];
  }
}

Future<_FakeApi> _pump(
  WidgetTester tester, {
  int totalPages = 1,
  void Function(_FakeApi api)? setup,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final api = _FakeApi(totalPages: totalPages);
  setup?.call(api);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      tmdbApiClientProvider.overrideWithValue(api),
      favoritesRepositoryProvider.overrideWithValue(_FakeFavoritesRepository()),
    ],
    child: const MaterialApp(home: CatalogScreen()),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('lists movies of all genres first, with genre chips', (tester) async {
    final api = await _pump(tester);

    expect(api.calls.first, (type: MediaType.movie, genreId: null, page: 1));
    expect(find.text('movie-all-p1-0'), findsOneWidget);
    expect(find.text('Todos'), findsOneWidget);
    expect(find.text('Ação'), findsOneWidget);
    expect(find.text('Terror'), findsOneWidget);
  });

  testWidgets('picking a genre reloads the list filtered by that genre',
      (tester) async {
    final api = await _pump(tester);

    await tester.tap(find.text('Terror'));
    await tester.pumpAndSettle();

    expect(api.calls.last, (type: MediaType.movie, genreId: 27, page: 1));
    expect(find.text('movie-27-p1-0'), findsOneWidget);
    expect(find.text('movie-all-p1-0'), findsNothing);
  });

  testWidgets('switching to Séries lists TV shows with the TV genres and '
      'resets the genre filter', (tester) async {
    final api = await _pump(tester);

    await tester.tap(find.text('Terror'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Séries'));
    await tester.pumpAndSettle();

    expect(api.calls.last, (type: MediaType.tv, genreId: null, page: 1));
    expect(find.text('tv-all-p1-0'), findsOneWidget);
    expect(find.text('Ação e Aventura'), findsOneWidget);
    expect(find.text('Terror'), findsNothing);
  });

  testWidgets('scrolling near the end loads the next page', (tester) async {
    final api = await _pump(tester, totalPages: 3);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(api.calls.map((c) => c.page), containsAllInOrder([1, 2]));
  });

  testWidgets('shows "Fim da lista" once the last page is loaded', (tester) async {
    await _pump(tester, totalPages: 1);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(find.text('Fim da lista'), findsOneWidget);
  });

  testWidgets('first-page error shows a retry that recovers', (tester) async {
    final api = await _pump(tester, setup: (a) => a.failNext = 1);

    expect(find.text('Tentar de novo'), findsOneWidget);

    await tester.tap(find.text('Tentar de novo'));
    await tester.pumpAndSettle();

    expect(find.text('movie-all-p1-0'), findsOneWidget);
    expect(api.calls.length, 2);
  });

  testWidgets('an empty page with more pages left keeps loading instead of '
      'spinning forever', (tester) async {
    final api = await _pump(tester, totalPages: 2, setup: (a) => a.emptyFirstPage = true);

    expect(api.calls.map((c) => c.page), containsAllInOrder([1, 2]));
    expect(find.text('movie-all-p2-0'), findsOneWidget);
  });

  testWidgets('a slow response for a previous genre never overwrites the '
      'current filter', (tester) async {
    final gate = Completer<void>();
    final api = await _pump(tester, setup: (a) => a.gates[28] = gate);

    await tester.tap(find.text('Ação')); // slow, held by the gate
    await tester.pump();
    await tester.tap(find.text('Terror')); // fast
    await tester.pumpAndSettle();
    expect(find.text('movie-27-p1-0'), findsOneWidget);

    gate.complete(); // the stale "Ação" response arrives late
    await tester.pumpAndSettle();

    expect(find.text('movie-27-p1-0'), findsOneWidget);
    expect(find.text('movie-28-p1-0'), findsNothing);
    expect(api.calls.any((c) => c.genreId == 28), isTrue);
  });
}
