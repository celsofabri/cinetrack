import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/models/catalog.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/screens/catalog_screen.dart';
import 'package:cinetrack/screens/movie_details_screen.dart';
import 'package:cinetrack/screens/search_screen.dart';
import 'package:cinetrack/screens/tv_details_screen.dart';
import 'package:cinetrack/services/tmdb_exception.dart';
import 'package:cinetrack/widgets/auth_gate.dart';
import 'package:cinetrack/widgets/detail_actions.dart';
import 'package:cinetrack/widgets/discovery_section.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

const _movie = SearchResult(
    id: 11, mediaType: MediaType.movie, title: 'Filme X', posterPath: null, overview: 'Sinopse');
const _show =
    SearchResult(id: 12, mediaType: MediaType.tv, title: 'Serie Y', posterPath: null, overview: '');

final _list = FutureProvider<List<SearchResult>>((ref) async => [_movie, _show]);

FakeTmdbApiClient _api() => FakeTmdbApiClient()
  ..movieDetails = {
    'id': 11,
    'title': 'Filme X',
    'overview': 'Sinopse do TMDB',
    'release_date': '2019-05-01',
    'vote_average': 8.14,
    'vote_count': 100,
    'genres': [
      {'id': 1, 'name': 'Drama'}
    ],
  }
  ..tvDetails = {
    'id': 12,
    'name': 'Serie Y',
    'overview': 'Sinopse serie',
    'first_air_date': '2020-01-01',
    'vote_average': 7.0,
    'vote_count': 10,
    'genres': [
      {'id': 2, 'name': 'Comédia'}
    ],
    'seasons': [
      {'season_number': 1, 'name': 'Temporada 1', 'episode_count': 2},
    ],
  }
  ..seasonResult = const SeasonCache(seasonNumber: 1, episodes: [
    EpisodeCache(episodeNumber: 1, name: 'Piloto', airDate: null, watched: false),
    EpisodeCache(episodeNumber: 2, name: 'Segundo', airDate: null, watched: false),
  ]);

Future<void> _pump(
  WidgetTester tester, {
  required FakeAuthRepository auth,
  required FakeCloud cloud,
  required FakeTmdbApiClient api,
  Widget? home,
  Size size = const Size(390, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (_, _) =>
          home ??
          Scaffold(
              body: SingleChildScrollView(child: DiscoverySection(title: 'Alta', provider: _list))),
    ),
    GoRoute(
        path: '/movie/:id',
        builder: (_, s) => MovieDetailsScreen(movieId: int.parse(s.pathParameters['id']!))),
    GoRoute(
        path: '/tv/:id',
        builder: (_, s) => TvDetailsScreen(tvId: int.parse(s.pathParameters['id']!))),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides: cloudOverrides(auth: auth, cloud: cloud, api: api),
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => PendingIntentRunner(child: child!),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tapping a non-favorited movie card opens details from TMDB; heart does not navigate',
      (tester) async {
    final cloud = FakeCloud();
    final api = _api();
    await _pump(tester, auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: api);

    // Heart: favorites, does not navigate.
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pumpAndSettle();
    expect(find.byType(MovieDetailsScreen), findsNothing);
    expect(cloud.view('uid-ana').keys, ['11-movie']);
    // A tap on the filled heart un-favorites (no progress: no dialog) and must not navigate.
    await tester.tap(find.byIcon(Icons.favorite), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(MovieDetailsScreen), findsNothing);
    expect(cloud.view('uid-ana'), isEmpty); // the second tap really removed it

    // Poster of the NON favorited show opens its details.
    await tester.tap(find.text('Serie Y'));
    await tester.pumpAndSettle();
    expect(find.byType(TvDetailsScreen), findsOneWidget);
    expect(find.text('Sinopse serie'), findsOneWidget);
    expect(find.text('Comédia'), findsOneWidget);
    expect(find.text('Temporada 1'), findsOneWidget);
    expect(find.text('Favoritar'), findsOneWidget);
  });

  testWidgets('movie details of a non-favorite: favorite and unfavorite inside', (tester) async {
    final cloud = FakeCloud();
    final api = _api();
    await _pump(tester, auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: api);

    await tester.tap(find.text('Filme X'));
    await tester.pumpAndSettle();
    expect(find.text('Sinopse do TMDB'), findsOneWidget);
    expect(find.text('2019 · ★ 8.1'), findsOneWidget);
    expect(find.text('Drama'), findsOneWidget);
    expect(find.text('Marcar como assistido'), findsOneWidget);

    await tester.tap(find.text('Favoritar'));
    await tester.pumpAndSettle();
    expect(cloud.view('uid-ana').keys, ['11-movie']);
    expect(find.text('Remover dos favoritos'), findsOneWidget);

    // No progress: removes without asking.
    await tester.tap(find.text('Remover dos favoritos'));
    await tester.pumpAndSettle();
    expect(cloud.view('uid-ana'), isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Favoritar'), findsOneWidget);
  });

  testWidgets('marking a non-favorited movie watched favorites it first', (tester) async {
    final cloud = FakeCloud();
    await _pump(tester, auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: _api());
    await tester.tap(find.text('Filme X'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Marcar como assistido'));
    await tester.pumpAndSettle();

    final doc = cloud.view('uid-ana')['11-movie']!;
    expect(doc.watchedMovie, isTrue);
    expect(find.text('Assistido'), findsOneWidget);
    expect(find.text('Remover dos favoritos'), findsOneWidget);

    // With progress, removing asks for confirmation; cancel keeps everything.
    await tester.tap(find.text('Remover dos favoritos'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(cloud.view('uid-ana').keys, ['11-movie']);

    await tester.tap(find.text('Remover dos favoritos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remover'));
    await tester.pumpAndSettle();
    expect(cloud.view('uid-ana'), isEmpty);
  });

  testWidgets('marking an episode of a non-favorited show favorites it and marks the episode',
      (tester) async {
    final cloud = FakeCloud();
    await _pump(tester, auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: _api());
    await tester.tap(find.text('Serie Y'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Temporada 1'));
    await tester.pumpAndSettle();
    expect(find.text('E1 · Piloto'), findsOneWidget); // fetched on demand

    await tester.tap(find.text('E1 · Piloto'));
    await tester.pumpAndSettle();

    final doc = cloud.view('uid-ana')['12-tv']!;
    expect(doc.watchedEpisodes, {'1_1'});
    expect(find.text('Remover dos favoritos'), findsOneWidget);
  });

  testWidgets('signed out: watched -> login -> favorite + watched are saved (intent replayed)',
      (tester) async {
    final cloud = FakeCloud();
    final auth = FakeAuthRepository()..nextUser = kAna;
    await _pump(tester, auth: auth, cloud: cloud, api: _api());
    await tester.tap(find.text('Filme X'));
    await tester.pumpAndSettle();
    expect(find.text('Favoritar'), findsOneWidget); // catalog is free without login

    await tester.tap(find.text('Marcar como assistido'));
    await tester.pumpAndSettle();

    expect(auth.signInCalls, 1);
    expect(cloud.view('uid-ana')['11-movie']!.watchedMovie, isTrue);
  });

  testWidgets('signed out: favorite -> login cancelled saves nothing', (tester) async {
    final cloud = FakeCloud();
    final auth = FakeAuthRepository()..nextFailure = const AuthFailure(AuthFailureKind.cancelled);
    await _pump(tester, auth: auth, cloud: cloud, api: _api());
    await tester.tap(find.text('Filme X'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favoritar'));
    await tester.pumpAndSettle();
    expect(auth.signInCalls, 1);
    expect(cloud.view('uid-ana'), isEmpty);
    expect(find.text('Favoritar'), findsOneWidget);
  });

  testWidgets('TMDB error shows a message and "Tentar novamente" recovers', (tester) async {
    final api = _api()..movieDetailsError = TmdbException.network();
    await _pump(tester, auth: FakeAuthRepository(initialUser: kAna), cloud: FakeCloud(), api: api);
    await tester.tap(find.text('Filme X'));
    await tester.pumpAndSettle();

    expect(find.text('Sem conexão com a internet.'), findsOneWidget);
    expect(find.text('Favoritar'), findsNothing);

    api.movieDetailsError = null;
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    expect(find.text('Sinopse do TMDB'), findsOneWidget);
    expect(find.text('Favoritar'), findsOneWidget);
  });

  testWidgets('search: tapping a row opens details instead of favoriting', (tester) async {
    final cloud = FakeCloud();
    final api = _api();
    await _pump(
      tester,
      auth: FakeAuthRepository(initialUser: kAna),
      cloud: cloud,
      api: _SearchApi(api),
      home: const SearchScreen(),
    );
    await tester.enterText(find.byType(TextField), 'filme');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Filme X'));
    await tester.pumpAndSettle();

    expect(find.byType(MovieDetailsScreen), findsOneWidget);
    expect(cloud.view('uid-ana'), isEmpty);
  });

  Future<void> openShowSeason(WidgetTester tester) async {
    await tester.tap(find.text('Serie Y'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Temporada 1'));
    await tester.pumpAndSettle();
  }

  bool episodeChecked(WidgetTester tester, String title) =>
      tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, title)).value!;

  testWidgets('removing a show clears the episode checks; marking again works', (tester) async {
    final cloud = FakeCloud();
    await _pump(tester, auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: _api());
    await openShowSeason(tester);
    await tester.tap(find.text('E1 · Piloto'));
    await tester.pumpAndSettle();
    expect(episodeChecked(tester, 'E1 · Piloto'), isTrue);

    // Progress exists: confirmation appears; confirm.
    await tester.scrollUntilVisible(find.text('Remover dos favoritos'), -200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Remover dos favoritos'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(cloud.view('uid-ana').keys, ['12-tv']);
    expect(episodeChecked(tester, 'E1 · Piloto'), isTrue);

    await tester.tap(find.text('Remover dos favoritos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remover'));
    await tester.pumpAndSettle();
    expect(cloud.view('uid-ana'), isEmpty);
    expect(episodeChecked(tester, 'E1 · Piloto'), isFalse);

    await tester.tap(find.text('E1 · Piloto'));
    await tester.pumpAndSettle();
    expect(cloud.view('uid-ana')['12-tv']!.watchedEpisodes, {'1_1'});
    expect(episodeChecked(tester, 'E1 · Piloto'), isTrue);
  });

  testWidgets('signed out: episode -> login -> the check shows as watched', (tester) async {
    final cloud = FakeCloud();
    final auth = FakeAuthRepository()..nextUser = kAna;
    await _pump(tester, auth: auth, cloud: cloud, api: _api());
    await openShowSeason(tester);
    await tester.tap(find.text('E2 · Segundo'));
    await tester.pumpAndSettle();

    expect(cloud.view('uid-ana')['12-tv']!.watchedEpisodes, {'1_2'});
    expect(episodeChecked(tester, 'E2 · Segundo'), isTrue);
  });

  testWidgets('signed out: whole season -> login -> checks show as watched', (tester) async {
    final cloud = FakeCloud();
    final auth = FakeAuthRepository()..nextUser = kAna;
    await _pump(tester, auth: auth, cloud: cloud, api: _api());
    await openShowSeason(tester);
    await tester.tap(find.byTooltip('Marcar temporada inteira como assistida'));
    await tester.pumpAndSettle();

    expect(cloud.view('uid-ana')['12-tv']!.watchedEpisodes, {'1_1', '1_2'});
    expect(episodeChecked(tester, 'E1 · Piloto'), isTrue);
    expect(episodeChecked(tester, 'E2 · Segundo'), isTrue);
  });

  testWidgets('favorited heart is announced as actionable ("Remover ... dos favoritos")',
      (tester) async {
    final handle = tester.ensureSemantics();
    final cloud = FakeCloud();
    await _pump(tester, auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: _api());
    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.byTooltip('Remover Filme X dos favoritos'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    handle.dispose();
  });

  testWidgets('removing a favorite while TMDB is unreachable keeps the content', (tester) async {
    final cloud = FakeCloud();
    cloud.server['uid-ana'] = {
      '11-movie': FavoriteDoc(
        id: 11,
        mediaType: MediaType.movie,
        title: 'Filme X',
        posterPath: null,
        overview: 'Sinopse salva',
        addedAt: DateTime(2024),
      ),
    };
    final api = _api()..movieDetailsError = TmdbException.network();
    await _pump(tester, auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: api);
    await tester.tap(find.text('Filme X'));
    await tester.pumpAndSettle();
    expect(find.text('Sinopse salva'), findsOneWidget);

    await tester.tap(find.text('Remover dos favoritos'));
    await tester.pumpAndSettle();

    expect(cloud.view('uid-ana'), isEmpty);
    expect(find.text('Sinopse salva'), findsOneWidget);
    expect(find.text('Sem conexão com a internet.'), findsNothing);
    expect(find.text('Favoritar'), findsOneWidget);
  });

  test('favoriteThen: a failure after favoriting becomes a PartialWriteException', () async {
    final h = FavoritesHarness();
    await expectLater(
      favoriteThen(h.repo, _movie, false, () async => throw StateError('boom')),
      throwsA(isA<PartialWriteException>()),
    );
    // The favorite was saved (the user is told through the partial message).
    expect(h.cloud.view('user-a').keys, ['11-movie']);
    expect(writeErrorMessage(const PartialWriteException()), kPartialWriteMessage);
  });

  testWidgets('Explorar: tapping a non-favorited title opens its details; heart does not',
      (tester) async {
    final cloud = FakeCloud();
    final api = _CatalogApi(_api());
    await _pump(tester,
        auth: FakeAuthRepository(initialUser: kAna),
        cloud: cloud,
        api: api,
        home: const CatalogScreen());

    await tester.tap(find.byIcon(Icons.favorite_border).first);
    await tester.pumpAndSettle();
    expect(find.byType(MovieDetailsScreen), findsNothing);
    expect(cloud.view('uid-ana').keys, ['11-movie']);

    await tester.tap(find.text('Filme X'));
    await tester.pumpAndSettle();
    expect(find.byType(MovieDetailsScreen), findsOneWidget);
  });

  testWidgets('320px: details of a show have no overflow and targets >= 48px', (tester) async {
    await _pump(tester,
        auth: FakeAuthRepository(initialUser: kAna),
        cloud: FakeCloud(),
        api: _api(),
        size: const Size(320, 640));
    await tester.tap(find.text('Serie Y'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.widgetWithText(FilterChip, 'Favoritar')).height,
        greaterThanOrEqualTo(48));
  });
}

/// Same fake, plus a search answer.
class _SearchApi extends FakeTmdbApiClient {
  _SearchApi(FakeTmdbApiClient base) {
    movieDetails = base.movieDetails;
  }

  @override
  Future<List<SearchResult>> searchMulti(String query) async => [_movie];
}

class _CatalogApi extends FakeTmdbApiClient {
  _CatalogApi(FakeTmdbApiClient base) {
    movieDetails = base.movieDetails;
  }

  @override
  Future<List<Genre>> getGenres(MediaType type) async => const [];

  @override
  Future<DiscoverPage> discoverPage(MediaType type, {int? genreId, int page = 1}) async =>
      const DiscoverPage(results: [_movie], page: 1, totalPages: 1);
}
