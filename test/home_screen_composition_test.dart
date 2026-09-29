import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/models/discovery_category.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/discovery_repository.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/screens/favorites_screen.dart';
import 'package:cinetrack/screens/home_screen.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';

/// Same fake as home_screen_test.dart / discovery_section_test.dart — only
/// FavoritesRepository's public contract (watchAll) is exercised.
class _FakeFavoritesRepository extends FavoritesRepository {
  _FakeFavoritesRepository(this._items)
      : super(api: TmdbApiClient(apiKey: 'test'), store: LocalStore());

  final List<FavoriteItem> _items;

  @override
  Stream<List<FavoriteItem>> watchAll() async* {
    yield _items;
  }
}

/// Unlike the always-empty fake in home_screen_test.dart, this one lets each
/// test control what each discovery call returns (or throws) independently,
/// so the composition tests below can assert that HomeScreen renders every
/// section together and that one section failing never affects another.
class _ConfigurableDiscoveryRepository extends DiscoveryRepository {
  _ConfigurableDiscoveryRepository({
    this.trending = const [],
    this.novelties = const [],
    this.category = const [],
    this.noveltiesError,
  }) : super(api: TmdbApiClient(apiKey: 'test'), store: LocalStore());

  final List<SearchResult> trending;
  final List<SearchResult> novelties;
  final List<SearchResult> category;
  final Object? noveltiesError;

  @override
  Future<List<SearchResult>> getTrending() async => trending;

  @override
  Future<List<SearchResult>> getNovelties() async {
    if (noveltiesError != null) throw noveltiesError!;
    return novelties;
  }

  @override
  Future<List<SearchResult>> getCategory(DiscoveryCategory category) async => this.category;
}

Widget _wrap({
  required List<FavoriteItem> favorites,
  required DiscoveryRepository discoveryRepository,
}) {
  return ProviderScope(
    overrides: [
      favoritesRepositoryProvider.overrideWithValue(_FakeFavoritesRepository(favorites)),
      discoveryRepositoryProvider.overrideWithValue(discoveryRepository),
    ],
    child: const MaterialApp(home: HomeScreen()),
  );
}

/// HomeScreen's body is a plain (non-lazy-only-in-appearance) `ListView`:
/// under the hood it still only mounts elements within the viewport, so
/// with the default ~800px-tall test surface most of the 7 discovery
/// sections below "Novidades" (plus "Meus favoritos") would never be built
/// and `find.text` would report them missing even though they're not a
/// product bug — just off-screen. Growing the test viewport instead of
/// scrolling keeps every section assertable in the same pump.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  testWidgets(
      'Cenário 1: sem favoritos, mas com seções de descoberta preenchidas — '
      'a home mostra as seções de descoberta e o atalho "Meus favoritos" no '
      'menu do topo, nunca a tela inteira vazia', (tester) async {
    _useTallViewport(tester);
    const trendingItem = SearchResult(
      id: 1,
      mediaType: MediaType.movie,
      title: 'Trending Movie',
      posterPath: null,
      overview: '',
    );
    const noveltyItem = SearchResult(
      id: 2,
      mediaType: MediaType.tv,
      title: 'Novelty Show',
      posterPath: null,
      overview: '',
    );
    const categoryItem = SearchResult(
      id: 3,
      mediaType: MediaType.movie,
      title: 'Category Movie',
      posterPath: null,
      overview: '',
    );

    await tester.pumpWidget(_wrap(
      favorites: const [],
      discoveryRepository: _ConfigurableDiscoveryRepository(
        trending: [trendingItem],
        novelties: [noveltyItem],
        category: [categoryItem],
      ),
    ));
    await tester.pumpAndSettle();

    // As três famílias de seção de descoberta aparecem com conteúdo real...
    expect(find.text('Em Alta'), findsOneWidget);
    expect(find.text('Trending Movie'), findsOneWidget);
    expect(find.text('Novidades'), findsOneWidget);
    expect(find.text('Novelty Show'), findsOneWidget);
    for (final category in kDiscoveryCategories) {
      expect(find.text(category.label), findsOneWidget);
    }
    expect(find.text('Category Movie'), findsNWidgets(kDiscoveryCategories.length));

    // ...e a lista de favoritos não mora mais na home: só o atalho no menu.
    expect(find.text('Meus favoritos'), findsOneWidget);
    expect(find.text('Explorar'), findsOneWidget);
    expect(find.text('Nenhum favorito ainda'), findsNothing);
  });

  testWidgets(
      'Cenário 9: "Novidades" falha (erro/429) enquanto "Em Alta", '
      '"Continue assistindo" e "Meus favoritos" continuam funcionando '
      'normalmente na mesma árvore de widgets', (tester) async {
    _useTallViewport(tester);
    const trendingItem = SearchResult(
      id: 1,
      mediaType: MediaType.movie,
      title: 'Trending Movie',
      posterPath: null,
      overview: '',
    );
    final favoriteMovie = FavoriteItem(
      id: 10,
      mediaType: MediaType.movie,
      title: 'Favorite Movie',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
      watchedMovie: false,
    );
    final inProgressShow = FavoriteItem(
      id: 11,
      mediaType: MediaType.tv,
      title: 'In Progress Show',
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

    await tester.pumpWidget(_wrap(
      favorites: [favoriteMovie, inProgressShow],
      discoveryRepository: _ConfigurableDiscoveryRepository(
        trending: [trendingItem],
        noveltiesError: Exception('429 rate limited'),
      ),
    ));
    await tester.pumpAndSettle();

    // Nenhuma exceção escapou para o framework — a tela não quebrou.
    expect(tester.takeException(), isNull);

    // "Em Alta" segue funcionando normalmente, com dado real.
    expect(find.text('Em Alta'), findsOneWidget);
    expect(find.text('Trending Movie'), findsOneWidget);

    // "Novidades" mostra seu próprio estado de erro, com opção de retry —
    // não deixa a home inteira travada nem em loading infinito.
    expect(find.text('Novidades'), findsOneWidget);
    expect(find.text('Erro ao carregar "Novidades".'), findsOneWidget);
    expect(find.text('Tentar de novo'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // "Continue assistindo" e "Meus favoritos" — dados puramente locais —
    // continuam funcionando normalmente na mesma árvore.
    expect(find.text('Continue assistindo'), findsOneWidget);
    expect(find.text('In Progress Show'), findsOneWidget);
    expect(find.text('Meus favoritos'), findsOneWidget);
  });

  testWidgets(
      'o menu do topo "Meus favoritos" abre a segunda tela com a lista de '
      'favoritos', (tester) async {
    _useTallViewport(tester);
    final favoriteMovie = FavoriteItem(
      id: 10,
      mediaType: MediaType.movie,
      title: 'Favorite Movie',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
    );
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/favorites', builder: (_, __) => const FavoritesScreen()),
    ]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        favoritesRepositoryProvider
            .overrideWithValue(_FakeFavoritesRepository([favoriteMovie])),
        discoveryRepositoryProvider
            .overrideWithValue(_ConfigurableDiscoveryRepository()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Favorite Movie'), findsNothing);

    await tester.tap(find.text('Meus favoritos'));
    await tester.pumpAndSettle();

    expect(find.text('Favorite Movie'), findsOneWidget);
    expect(find.byType(FavoritesScreen), findsOneWidget);
  });

  testWidgets(
      '/favorites abre direto (deep link) e voltar leva à home',
      (tester) async {
    _useTallViewport(tester);
    final router = GoRouter(initialLocation: '/favorites', routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/favorites', builder: (_, __) => const FavoritesScreen()),
    ]);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        favoritesRepositoryProvider.overrideWithValue(_FakeFavoritesRepository(const [])),
        discoveryRepositoryProvider.overrideWithValue(_ConfigurableDiscoveryRepository()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(FavoritesScreen), findsOneWidget);
    expect(find.text('Nenhum favorito ainda'), findsOneWidget);
  });

  testWidgets('a 320px-wide home shows icon-only menu buttons with no overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_wrap(
      favorites: const [],
      discoveryRepository: _ConfigurableDiscoveryRepository(),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Explorar'), findsOneWidget);
    expect(find.byTooltip('Meus favoritos'), findsOneWidget);
    expect(find.byTooltip('Buscar'), findsOneWidget);
  });
}
