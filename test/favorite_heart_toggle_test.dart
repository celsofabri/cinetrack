import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/models/catalog.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/screens/catalog_screen.dart';
import 'package:cinetrack/screens/search_screen.dart';
import 'package:cinetrack/widgets/discovery_section.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

const _movie = SearchResult(
    id: 11, mediaType: MediaType.movie, title: 'Filme X', posterPath: null, overview: '');
const _show =
    SearchResult(id: 12, mediaType: MediaType.tv, title: 'Serie Y', posterPath: null, overview: '');

final _list = FutureProvider<List<SearchResult>>((ref) async => [_movie, _show]);

class _Api extends FakeTmdbApiClient {
  @override
  Future<List<SearchResult>> searchMulti(String query) async => [_movie, _show];

  @override
  Future<List<Genre>> getGenres(MediaType type) async => const [];

  @override
  Future<DiscoverPage> discoverPage(MediaType type, {int? genreId, int page = 1}) async =>
      const DiscoverPage(results: [_movie], page: 1, totalPages: 1);
}

FavoriteDoc _doc(SearchResult r, {bool progress = false}) => FavoriteDoc(
      id: r.id,
      mediaType: r.mediaType,
      title: r.title,
      posterPath: null,
      overview: '',
      addedAt: DateTime(2026),
      watchedMovie: r.mediaType == MediaType.movie && progress,
      watchedEpisodes: r.mediaType == MediaType.tv && progress ? {'1_1'} : const {},
      seasonSummaries: r.mediaType == MediaType.tv
          ? const [TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 2)]
          : const [],
    );

enum _Host { discovery, catalog, search }

Future<void> _pump(WidgetTester tester, _Host host, FakeCloud cloud) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final home = switch (host) {
    _Host.discovery => Scaffold(
        body: SingleChildScrollView(child: DiscoverySection(title: 'Alta', provider: _list))),
    _Host.catalog => const CatalogScreen(),
    _Host.search => const SearchScreen(),
  };
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => home),
    GoRoute(path: '/movie/:id', builder: (_, _) => const Text('DETAIL-MOVIE')),
    GoRoute(path: '/tv/:id', builder: (_, _) => const Text('DETAIL-TV')),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides:
        cloudOverrides(auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: _Api()),
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  if (host == _Host.search) {
    await tester.enterText(find.byType(TextField), 'filme');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final host in _Host.values) {
    for (final type in [MediaType.movie, MediaType.tv]) {
      if (host == _Host.catalog && type == MediaType.tv) continue; // Explorar opens on movies
      final target = type == MediaType.movie ? _movie : _show;
      final heart = find.byTooltip('Remover ${target.title} dos favoritos');
      final key = '${target.id}-${type.jsonValue}';
      final name = '${host.name}/${type.name}';

      testWidgets('$name: heart adds, then removes directly when there is no progress',
          (tester) async {
        final cloud = FakeCloud();
        await _pump(tester, host, cloud);
        final border = host == _Host.search
            ? find.byTooltip('Favoritar ${target.title}')
            : find.byTooltip('Adicionar ${target.title} aos favoritos');
        await tester.tap(border);
        await tester.pumpAndSettle();
        expect(cloud.view('uid-ana').keys, [key]);
        expect(find.text('DETAIL-MOVIE'), findsNothing);
        expect(find.text('DETAIL-TV'), findsNothing);

        await tester.tap(heart);
        await tester.pumpAndSettle();
        expect(find.text('Remover dos favoritos?'), findsNothing);
        expect(cloud.view('uid-ana'), isEmpty);
        expect(find.text('DETAIL-MOVIE'), findsNothing);
        expect(find.text('DETAIL-TV'), findsNothing);
      });

      testWidgets('$name: with progress asks first; Cancelar keeps, Remover deletes',
          (tester) async {
        final cloud = FakeCloud();
        cloud.server['uid-ana'] = {key: _doc(target, progress: true)};
        await _pump(tester, host, cloud);

        await tester.tap(heart);
        await tester.pumpAndSettle();
        expect(find.text('Remover dos favoritos?'), findsOneWidget);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(cloud.view('uid-ana').keys, [key]);
        expect(heart, findsOneWidget);

        await tester.tap(heart);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remover'));
        await tester.pumpAndSettle();
        expect(cloud.view('uid-ana'), isEmpty);
        expect(find.text('DETAIL-MOVIE'), findsNothing);
        expect(find.text('DETAIL-TV'), findsNothing);
      });

      testWidgets('$name: favorited heart is an actionable, labelled control', (tester) async {
        final handle = tester.ensureSemantics();
        final cloud = FakeCloud();
        cloud.server['uid-ana'] = {key: _doc(target)};
        await _pump(tester, host, cloud);
        final node = tester.getSemantics(heart);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        handle.dispose();
      });
    }
  }
}
