import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/screens/search_screen.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';

class _RecordingApi extends TmdbApiClient {
  _RecordingApi() : super(apiKey: 'test');

  final queries = <String>[];

  @override
  Future<List<SearchResult>> searchMulti(String query) async {
    queries.add(query);
    return [
      SearchResult(
        id: 1,
        mediaType: MediaType.movie,
        title: 'Result for $query',
        posterPath: null,
        overview: '',
      ),
    ];
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

Future<_RecordingApi> _pump(WidgetTester tester) async {
  final api = _RecordingApi();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      tmdbApiClientProvider.overrideWithValue(api),
      favoritesRepositoryProvider.overrideWithValue(_FakeFavoritesRepository()),
    ],
    child: const MaterialApp(home: SearchScreen()),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('does not search with fewer than 2 characters', (tester) async {
    final api = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump(const Duration(seconds: 1));

    expect(api.queries, isEmpty);
    expect(find.text('Busque algo para favoritar'), findsOneWidget);
  });

  testWidgets('searches automatically from 2 characters, without Enter',
      (tester) async {
    final api = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'ma');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(api.queries, ['ma']);
    expect(find.text('Result for ma'), findsOneWidget);
  });

  testWidgets('debounces: only the last text of a typing burst is searched',
      (tester) async {
    final api = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'ma');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'mat');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'matrix');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(api.queries, ['matrix']);
    expect(find.text('Result for matrix'), findsOneWidget);
  });

  testWidgets('clearing below 2 characters returns to the initial hint',
      (tester) async {
    final api = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'matrix');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Result for matrix'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'm');
    await tester.pumpAndSettle();

    expect(find.text('Result for matrix'), findsNothing);
    expect(find.text('Busque algo para favoritar'), findsOneWidget);
    expect(api.queries, ['matrix']);
  });
}
