import 'dart:async';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/main.dart' show CineTrackApp;
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/router.dart';
import 'package:cinetrack/screens/favorites_screen.dart';
import 'package:cinetrack/screens/movie_details_screen.dart';
import 'package:cinetrack/screens/profile_screen.dart';
import 'package:cinetrack/screens/recommendations_screen.dart';
import 'package:cinetrack/screens/tv_details_screen.dart';
import 'package:cinetrack/widgets/app_shell.dart';
import 'package:cinetrack/widgets/auth_gate.dart';
import 'package:cinetrack/widgets/delete_account_dialog.dart';
import 'package:cinetrack/widgets/detail_actions.dart';
import 'package:cinetrack/widgets/poster_image.dart';
import 'package:cinetrack/widgets/privacy_summary.dart';
import 'package:cinetrack/widgets/recommendations_section.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// "Minhas recomendações": buttons, tab, navigation, states, layout,
/// accessibility (docs/35 R.7).

final _t0 = DateTime(2026, 1, 1);
final _t1 = DateTime(2026, 2, 1);
final _t2 = DateTime(2026, 3, 1);

FavoriteDoc _movie(
  int id, {
  String? title,
  bool recommended = false,
  bool watched = false,
  DateTime? addedAt,
  DateTime? lastWatchedAt,
}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.movie,
  title: title ?? 'Filme $id',
  posterPath: null,
  overview: 'Sinopse',
  addedAt: addedAt ?? _t0,
  lastWatchedAt: lastWatchedAt,
  watchedMovie: watched,
  recommended: recommended,
);

FavoriteDoc _tv(
  int id, {
  String? title,
  bool recommended = false,
  Set<String> eps = const {},
  DateTime? addedAt,
}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.tv,
  title: title ?? 'Serie $id',
  posterPath: null,
  overview: '',
  addedAt: addedAt ?? _t0,
  watchedEpisodes: eps,
  seasonSummaries: const [TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 2)],
  recommended: recommended,
);

FakeTmdbApiClient _api() => FakeTmdbApiClient()
  ..movieDetails = {
    'id': 11,
    'title': 'Filme X',
    'overview': 'Sinopse do TMDB',
    'release_date': '2019-05-01',
    'vote_average': 8.1,
    'vote_count': 10,
    'genres': [
      {'id': 1, 'name': 'Drama'},
    ],
  }
  ..tvDetails = {
    'id': 12,
    'name': 'Serie Y',
    'overview': 'Sinopse serie',
    'first_air_date': '2020-01-01',
    'vote_average': 7.0,
    'vote_count': 10,
    'genres': [],
    'seasons': [
      {'season_number': 1, 'name': 'Temporada 1', 'episode_count': 2},
    ],
  }
  ..seasonResult = const SeasonCache(
    seasonNumber: 1,
    episodes: [
      EpisodeCache(episodeNumber: 1, name: 'Piloto', airDate: null, watched: false),
      EpisodeCache(episodeNumber: 2, name: 'Segundo', airDate: null, watched: false),
    ],
  );

/// Fails the field write (what a rules refusal looks like once it reaches the UI).
class _FailingRecommend extends InMemoryFavoritesDataSource {
  _FailingRecommend(super.cloud, {required super.uid});

  @override
  Future<void> setRecommended(String key, bool recommended) =>
      Future.error(StateError('permission-denied'));
}

/// `get` says "not there" (the server lost it) while the local view still shows it.
class _GoneOnGet extends InMemoryFavoritesDataSource {
  _GoneOnGet(super.cloud, {required super.uid});

  @override
  Future<FavoriteDoc?> get(String key) async => null;
}

/// Holds the write open so a second tap can be tried while pending.
class _SlowRecommend extends InMemoryFavoritesDataSource {
  _SlowRecommend(super.cloud, {required super.uid});

  final gate = Completer<void>();
  int calls = 0;

  @override
  Future<void> setRecommended(String key, bool recommended) async {
    calls++;
    await gate.future;
    return super.setRecommended(key, recommended);
  }
}

class _Rig {
  final cloud = FakeCloud();
  final api = _api();
  final navigated = <String>[];
  FavoritesDataSourceBuilder? source;

  void put(FavoriteDoc doc, {String uid = 'uid-ana'}) => (cloud.server[uid] ??= {})[doc.key] = doc;
  FavoriteDoc? doc(String key, {String uid = 'uid-ana'}) => cloud.view(uid)[key];

  Future<void> pump(
    WidgetTester tester, {
    String initial = '/',
    Size size = const Size(390, 900),
    double textScale = 1,
    Brightness brightness = Brightness.light,
    FakeAuthRepository? auth,
    Duration grace = Duration.zero,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('HOME')),
        ),
        GoRoute(
          path: '/search',
          builder: (_, _) => const Scaffold(body: Text('SEARCH')),
        ),
        GoRoute(path: '/favorites', builder: (_, _) => const FavoritesScreen()),
        GoRoute(path: '/recommendations', builder: (_, _) => const RecommendationsScreen()),
        GoRoute(
          path: '/movie/:id',
          builder: (_, s) {
            navigated.add('movie');
            return MovieDetailsScreen(movieId: int.parse(s.pathParameters['id']!));
          },
        ),
        GoRoute(
          path: '/tv/:id',
          builder: (_, s) {
            navigated.add('tv');
            return TvDetailsScreen(tvId: int.parse(s.pathParameters['id']!));
          },
        ),
      ],
    );
    final overrides = cloudOverrides(
      auth: auth ?? FakeAuthRepository(initialUser: kAna),
      cloud: cloud,
      api: api,
      grace: grace,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          if (source != null)
            favoritesDataSourceFactoryProvider.overrideWithValue((uid) => source!(cloud, uid)),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(brightness: brightness, useMaterial3: true),
          builder: (context, child) => PendingIntentRunner(child: child!),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

typedef FavoritesDataSourceBuilder = InMemoryFavoritesDataSource Function(FakeCloud, String);

Finder _chip(String label) => find.widgetWithText(FilterChip, label);

void main() {
  group('movie details', () {
    testWidgets('title outside Favoritos: Recomendo adds + recommends in one go, then unmarks', (
      tester,
    ) async {
      final r = _Rig();
      await r.pump(tester, initial: '/movie/11');
      expect(_chip('Favoritar'), findsOneWidget);
      expect(_chip('Recomendo'), findsOneWidget);

      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(r.doc('11-movie')!.recommended, isTrue);
      expect(find.text(kRecommendAddedMessage), findsOneWidget);
      expect(_chip('Recomendado'), findsOneWidget);
      expect(_chip('Remover dos favoritos'), findsOneWidget);
      expect(r.doc('11-movie')!.watchedMovie, isFalse, reason: 'recommending is not watching');

      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      expect(r.doc('11-movie')!.recommended, isFalse);
      expect(r.doc('11-movie'), isNotNull, reason: 'unmarking keeps it in Favoritos');
      expect(find.text(kUnrecommendedMessage), findsOneWidget);
      expect(_chip('Recomendo'), findsOneWidget);
    });

    testWidgets('favorite with progress: mark and unmark keep every field', (tester) async {
      final r = _Rig()
        ..put(_movie(11, title: 'Filme X', watched: true, lastWatchedAt: _t2, addedAt: _t1));
      await r.pump(tester, initial: '/movie/11');
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(find.text(kRecommendedMessage), findsOneWidget);
      var d = r.doc('11-movie')!;
      expect((d.recommended, d.watchedMovie, d.addedAt, d.lastWatchedAt), (true, true, _t1, _t2));
      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      d = r.doc('11-movie')!;
      expect((d.recommended, d.watchedMovie, d.addedAt, d.lastWatchedAt), (false, true, _t1, _t2));
    });

    testWidgets('removing a recommended favorite asks first, Cancelar has the focus', (
      tester,
    ) async {
      final r = _Rig()..put(_movie(11, title: 'Filme X', recommended: true));
      await r.pump(tester, initial: '/movie/11');
      await tester.tap(_chip('Remover dos favoritos'));
      await tester.pumpAndSettle();
      expect(find.text('Remover dos favoritos?'), findsOneWidget);
      expect(find.textContaining('deixa de estar nas suas recomendações'), findsOneWidget);
      // Initial focus on the safe button.
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancelar')).autofocus,
        isTrue,
      );

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(r.doc('11-movie')!.recommended, isTrue);

      await tester.tap(_chip('Remover dos favoritos'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remover'));
      await tester.pumpAndSettle();
      expect(r.doc('11-movie'), isNull, reason: 'the mark leaves with the document');
    });

    testWidgets('Esc and outside tap cancel the removal', (tester) async {
      final r = _Rig()..put(_movie(11, title: 'Filme X', recommended: true));
      await r.pump(tester, initial: '/movie/11');
      await tester.tap(_chip('Remover dos favoritos'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Remover dos favoritos?'), findsNothing);
      expect(r.doc('11-movie')!.recommended, isTrue);
    });

    testWidgets('removing a favorite that is NOT recommended and has no progress: no dialog', (
      tester,
    ) async {
      final r = _Rig()..put(_movie(11, title: 'Filme X'));
      await r.pump(tester, initial: '/movie/11');
      await tester.tap(_chip('Remover dos favoritos'));
      await tester.pumpAndSettle();
      expect(find.text('Remover dos favoritos?'), findsNothing);
      expect(r.doc('11-movie'), isNull);
    });

    testWidgets('title removed on another device: message, nothing is recreated', (tester) async {
      final r = _Rig()
        ..put(_movie(11, title: 'Filme X'))
        ..source = (cloud, uid) => _GoneOnGet(cloud, uid: uid);
      await r.pump(tester, initial: '/movie/11');
      // The screen still shows it as a favorite (stale), the server no longer has it.
      expect(_chip('Remover dos favoritos'), findsOneWidget);
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(find.text(kGoneMessage), findsOneWidget);
      expect(_chip('Recomendo'), findsOneWidget);
      expect(r.doc('11-movie')!.recommended, isFalse, reason: 'no write happened');
    });

    testWidgets('rejected write: visible message and the button goes back', (tester) async {
      final r = _Rig()
        ..put(_movie(11, title: 'Filme X'))
        ..source = (cloud, uid) => _FailingRecommend(cloud, uid: uid);
      await r.pump(tester, initial: '/movie/11');
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(find.text(kGenericWriteMessage), findsOneWidget);
      expect(_chip('Recomendo'), findsOneWidget);
      expect(r.doc('11-movie')!.recommended, isFalse);
      expect(r.doc('11-movie')!.title, 'Filme X');
    });

    testWidgets('double tap: ONE write, spinner while pending', (tester) async {
      late _SlowRecommend slow;
      final r = _Rig()
        ..put(_movie(11, title: 'Filme X'))
        ..source = (cloud, uid) => slow = _SlowRecommend(cloud, uid: uid);
      await r.pump(tester, initial: '/movie/11');
      await tester.tap(_chip('Recomendo'));
      await tester.pump();
      await tester.tap(_chip('Recomendo'), warnIfMissed: false);
      await tester.pump();
      expect(slow.calls, 1);
      expect(
        find.descendant(
          of: find.byType(RecommendToggleChip),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      slow.gate.complete();
      await tester.pumpAndSettle();
      expect(slow.calls, 1);
      expect(r.doc('11-movie')!.recommended, isTrue);
    });

    testWidgets('signed out: Recomendo starts login from the tap; after login adds + recommends', (
      tester,
    ) async {
      final auth = FakeAuthRepository()..nextUser = kAna;
      final r = _Rig();
      await r.pump(tester, initial: '/movie/11', auth: auth);
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(auth.signInCalls, 1);
      expect(r.doc('11-movie')!.recommended, isTrue);
      expect(_chip('Recomendado'), findsOneWidget);
    });

    testWidgets('signed out: cancelled login saves nothing', (tester) async {
      final auth = FakeAuthRepository()..nextFailure = const AuthFailure(AuthFailureKind.cancelled);
      final r = _Rig();
      await r.pump(tester, initial: '/movie/11', auth: auth);
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(auth.signInCalls, 1);
      expect(r.cloud.view('uid-ana'), isEmpty);
      expect(_chip('Recomendo'), findsOneWidget);
    });

    testWidgets('offline: the mark shows at once and survives the reconnection', (tester) async {
      final r = _Rig()..put(_movie(11, title: 'Filme X', watched: true));
      await r.pump(tester, initial: '/movie/11');
      r.cloud.offline = true;
      await tester.pumpAndSettle();
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(_chip('Recomendado'), findsOneWidget);
      expect(r.cloud.server['uid-ana']!['11-movie']!.recommended, isFalse);
      r.cloud.offline = false;
      r.cloud.flush('uid-ana');
      await tester.pumpAndSettle();
      expect(r.cloud.server['uid-ana']!['11-movie']!.recommended, isTrue);
      expect(r.cloud.server['uid-ana']!['11-movie']!.watchedMovie, isTrue);
    });
  });

  group('series details', () {
    testWidgets('Recomendo next to Favoritar; progress untouched', (tester) async {
      final r = _Rig()..put(_tv(12, title: 'Serie Y', eps: {'1_1'}, addedAt: _t1));
      await r.pump(tester, initial: '/tv/12');
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(r.doc('12-tv')!.recommended, isTrue);
      expect(r.doc('12-tv')!.watchedEpisodes, {'1_1'});
      expect(r.doc('12-tv')!.addedAt, _t1);
      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      expect(r.doc('12-tv')!.recommended, isFalse);
      expect(r.doc('12-tv')!.watchedEpisodes, {'1_1'});
    });

    testWidgets('not in Favoritos: one write adds the series recommended', (tester) async {
      final r = _Rig();
      await r.pump(tester, initial: '/tv/12');
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(r.doc('12-tv')!.recommended, isTrue);
      expect(r.doc('12-tv')!.watchedEpisodes, isEmpty);
    });

    testWidgets('marking an episode on a recommended series keeps it recommended', (tester) async {
      final r = _Rig()..put(_tv(12, title: 'Serie Y', recommended: true));
      await r.pump(tester, initial: '/tv/12');
      final c = ProviderScope.containerOf(tester.element(find.byType(TvDetailsScreen)));
      await c.read(favoritesRepositoryProvider).toggleEpisodeWatched(12, 1, 1);
      await tester.pumpAndSettle();
      expect(r.doc('12-tv')!.recommended, isTrue);
      expect(r.doc('12-tv')!.watchedEpisodes, {'1_1'});
    });

    testWidgets('removing a recommended series with progress: one dialog naming both', (
      tester,
    ) async {
      final r = _Rig()..put(_tv(12, title: 'Serie Y', recommended: true, eps: {'1_1'}));
      await r.pump(tester, initial: '/tv/12');
      await tester.tap(_chip('Remover dos favoritos'));
      await tester.pumpAndSettle();
      expect(find.textContaining('progresso'), findsOneWidget);
      expect(find.textContaining('recomendações'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(r.doc('12-tv'), isNotNull);
    });
  });

  group('Favoritos cards', () {
    testWidgets('Recomendo sits beside the watched chip, does not open the details', (
      tester,
    ) async {
      final r = _Rig()..put(_movie(1, title: 'Alpha'));
      await r.pump(tester, initial: '/favorites', size: const Size(1024, 900));
      expect(_chip('Marcar como assistido'), findsOneWidget);
      expect(_chip('Recomendo'), findsOneWidget);
      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      expect(r.navigated, isEmpty);
      expect(r.doc('1-movie')!.recommended, isTrue);
      expect(r.doc('1-movie')!.watchedMovie, isFalse);
      expect(_chip('Recomendado'), findsOneWidget);
      // The watched chip still works on its own.
      await tester.tap(_chip('Marcar como assistido'));
      await tester.pumpAndSettle();
      expect(r.doc('1-movie')!.watchedMovie, isTrue);
      expect(r.doc('1-movie')!.recommended, isTrue);
    });

    for (final scale in [1.0, 2.0, 3.0]) {
      for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
        for (final dark in [false, true]) {
          testWidgets(
            'cards ${width.toInt()} px, ${dark ? 'dark' : 'light'}, font ${scale.toInt()}x: '
            'no overflow, targets >= 48',
            (tester) async {
              final r = _Rig()
                ..put(_tv(1, title: 'Uma série com um título bastante longo para quebrar linhas'))
                ..put(
                  _movie(
                    2,
                    title: 'Um filme com um título igualmente longo e cheio',
                    recommended: true,
                  ),
                );
              await r.pump(
                tester,
                initial: '/favorites',
                size: Size(width, 900),
                textScale: scale,
                brightness: dark ? Brightness.dark : Brightness.light,
              );
              expect(tester.takeException(), isNull);
              for (final chip in find.byType(FilterChip).evaluate()) {
                final size = tester.getSize(find.byWidget(chip.widget));
                expect(size.height, greaterThanOrEqualTo(48));
                expect(size.width, greaterThanOrEqualTo(48));
              }
              expect(find.byType(RecommendToggleChip), findsNWidgets(2));
            },
          );
        }
      }
    }
  });

  group('Minhas recomendações screen', () {
    testWidgets('empty with no favorites: teaches, says private, offers search', (tester) async {
      final r = _Rig();
      await r.pump(tester, initial: '/recommendations');
      expect(find.text('Você ainda não recomendou nada'), findsOneWidget);
      expect(find.textContaining('toque em Recomendo'), findsOneWidget);
      expect(find.textContaining(kRecommendationsPrivacyNote), findsWidgets);
      expect(find.text('Buscar um título'), findsOneWidget);
      await tester.tap(find.text('Buscar um título'));
      await tester.pumpAndSettle();
      expect(find.text('SEARCH'), findsOneWidget);
    });

    testWidgets('empty with favorites: offers "Ver meus favoritos"', (tester) async {
      final r = _Rig()..put(_movie(1));
      await r.pump(tester, initial: '/recommendations');
      expect(find.text('Você ainda não recomendou nada'), findsOneWidget);
      expect(find.text('Ver meus favoritos'), findsOneWidget);
      await tester.tap(find.text('Ver meus favoritos'));
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesScreen), findsOneWidget);
    });

    testWidgets('lists only recommended titles, ordered like Favoritos, with filters and count', (
      tester,
    ) async {
      final r = _Rig()
        ..put(_movie(1, title: 'Velho', recommended: true, addedAt: _t0))
        ..put(_movie(2, title: 'Novo', recommended: true, addedAt: _t2))
        ..put(_tv(3, title: 'Serie Meio', recommended: true, addedAt: _t1))
        ..put(_movie(4, title: 'Nao recomendado', addedAt: _t2));
      await r.pump(tester, initial: '/recommendations');
      expect(find.text('Minhas recomendações (3)'), findsOneWidget);
      expect(find.text('Nao recomendado'), findsNothing);
      final ys = [
        for (final t in ['Novo', 'Serie Meio', 'Velho']) tester.getTopLeft(find.text(t)).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()), reason: 'recent activity first');

      await tester.tap(find.text('Filmes'));
      await tester.pumpAndSettle();
      expect(find.text('Minhas recomendações (2)'), findsOneWidget);
      expect(find.text('Serie Meio'), findsNothing);
      await tester.tap(find.text('Séries'));
      await tester.pumpAndSettle();
      expect(find.text('Minhas recomendações (1)'), findsOneWidget);
      expect(find.text('Serie Meio'), findsOneWidget);
    });

    testWidgets('cards show the WHOLE poster in a 2:3 box', (tester) async {
      final r = _Rig()..put(_movie(1, recommended: true));
      await r.pump(tester, initial: '/recommendations');
      final poster = tester.widget<PosterImage>(find.byType(PosterImage));
      expect(poster.fit, BoxFit.contain);
      expect(poster.width / poster.height, closeTo(2 / 3, 0.001));
    });

    testWidgets('tapping a card opens the details; the chip unmarks without opening', (
      tester,
    ) async {
      final r = _Rig()
        ..put(_movie(1, title: 'Alpha', recommended: true, watched: true, lastWatchedAt: _t2));
      await r.pump(tester, initial: '/recommendations');
      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      expect(r.navigated, isEmpty);
      expect(find.text(kUnrecommendedMessage), findsOneWidget);
      expect(find.text('Alpha'), findsNothing, reason: 'it leaves the tab');
      expect(find.text('Você ainda não recomendou nada'), findsOneWidget);
      final d = r.doc('1-movie')!;
      expect((d.recommended, d.watchedMovie, d.lastWatchedAt), (false, true, _t2));

      r.put(_movie(2, title: 'Beta', recommended: true));
      r.cloud.flush('uid-ana'); // notifies the listeners
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(r.navigated, ['movie']);
    });

    testWidgets('unmark offers Desfazer, which sets the mark back without touching the rest', (
      tester,
    ) async {
      final r = _Rig()..put(_tv(1, title: 'Alpha', recommended: true, eps: {'1_1'}, addedAt: _t1));
      await r.pump(tester, initial: '/recommendations');
      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      expect(r.doc('1-tv')!.recommended, isFalse);
      expect(find.text('Desfazer'), findsOneWidget);
      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      final d = r.doc('1-tv')!;
      expect(d.recommended, isTrue);
      expect(d.watchedEpisodes, {'1_1'});
      expect(d.addedAt, _t1);
      expect(find.text('Recomendação restaurada.'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('Desfazer after the title left Favoritos: message, nothing recreated', (
      tester,
    ) async {
      final r = _Rig()..put(_movie(1, title: 'Alpha', recommended: true));
      await r.pump(tester, initial: '/recommendations');
      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      r.cloud.server['uid-ana']!.remove('1-movie'); // removed on another device
      r.cloud.flush('uid-ana');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      expect(find.text(kGoneMessage), findsOneWidget);
      expect(r.doc('1-movie'), isNull);
    });

    testWidgets('Desfazer is dropped when the account changes (no write for the new one)', (
      tester,
    ) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      final r = _Rig()..put(_movie(1, title: 'Alpha', recommended: true));
      await r.pump(tester, initial: '/recommendations', auth: auth);
      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsOneWidget);
      auth.revokeSession();
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsNothing);
      expect(r.doc('1-movie')!.recommended, isFalse);
    });

    testWidgets('leaving the screen discards the Desfazer snackbar', (tester) async {
      final r = _Rig()..put(_movie(1, title: 'Alpha', recommended: true));
      await r.pump(tester, initial: '/recommendations');
      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsOneWidget);
      GoRouter.of(tester.element(find.byType(RecommendationsScreen))).go('/');
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('marking from other screens has no Desfazer', (tester) async {
      final r = _Rig()..put(_movie(11, title: 'Filme X', recommended: true));
      await r.pump(tester, initial: '/movie/11');
      await tester.tap(_chip('Recomendado'));
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('never the empty state while Favoritos is unconfirmed; error afterwards', (
      tester,
    ) async {
      final r = _Rig();
      r.cloud.offline = true; // empty and not confirmed by the server
      await r.pump(
        tester,
        initial: '/recommendations',
        grace: const Duration(seconds: 5),
        settle: false,
      );
      expect(find.text('Você ainda não recomendou nada'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Você ainda não recomendou nada'), findsNothing);
      expect(find.textContaining('Não foi possível carregar seus favoritos'), findsOneWidget);
    });

    testWidgets('signed out: invite to log in, starts from the tap', (tester) async {
      final auth = FakeAuthRepository()..nextUser = kAna;
      final r = _Rig()..put(_movie(1, recommended: true));
      await r.pump(tester, initial: '/recommendations', auth: auth);
      expect(find.text('Entre para guardar suas recomendações'), findsOneWidget);
      expect(find.text('Você ainda não recomendou nada'), findsNothing);
      await tester.tap(find.text('Entrar com Google'));
      await tester.pumpAndSettle();
      expect(auth.signInCalls, 1);
      expect(find.text('Minhas recomendações (1)'), findsOneWidget);
    });

    testWidgets('account switch: the list follows the account', (tester) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      final r = _Rig()
        ..put(_movie(1, title: 'Da Ana', recommended: true))
        ..put(_movie(2, title: 'Do Bruno', recommended: true), uid: 'uid-bruno');
      await r.pump(tester, initial: '/recommendations', auth: auth);
      expect(find.text('Da Ana'), findsOneWidget);
      auth.revokeSession();
      await tester.pumpAndSettle();
      expect(find.text('Da Ana'), findsNothing);
      auth.nextUser = kBruno;
      await auth.signInWithGoogle();
      await tester.pumpAndSettle();
      expect(find.text('Do Bruno'), findsOneWidget);
      expect(find.text('Da Ana'), findsNothing);
    });

    for (final scale in [1.0, 2.0, 3.0]) {
      for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
        for (final dark in [false, true]) {
          testWidgets(
            'screen ${width.toInt()} px, ${dark ? 'dark' : 'light'}, font ${scale.toInt()}x: '
            'no overflow',
            (tester) async {
              final r = _Rig()
                ..put(
                  _tv(
                    1,
                    title: 'Uma série com um título bastante longo para quebrar',
                    recommended: true,
                  ),
                )
                ..put(
                  _movie(
                    2,
                    title: 'Um filme com um título igualmente longo e cheio',
                    recommended: true,
                  ),
                );
              await r.pump(
                tester,
                initial: '/recommendations',
                size: Size(width, 900),
                textScale: scale,
                brightness: dark ? Brightness.dark : Brightness.light,
              );
              expect(tester.takeException(), isNull);
              for (final chip in find.byType(FilterChip).evaluate()) {
                expect(tester.getSize(find.byWidget(chip.widget)).height, greaterThanOrEqualTo(48));
              }
            },
          );
        }
      }
    }
  });

  group('accessibility', () {
    testWidgets('name starts with the visible text; selected/button semantics; targets', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final r = _Rig()..put(_movie(11, title: 'Filme X'));
      await r.pump(tester, initial: '/movie/11');
      var node = tester.getSemantics(find.byType(RecommendToggleChip));
      expect(node.label, startsWith('Recomendo'));
      expect(node.label, contains('Filme X'));
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(node.getSemanticsData().flagsCollection.isSelected, Tristate.isFalse);

      await tester.tap(_chip('Recomendo'));
      await tester.pumpAndSettle();
      node = tester.getSemantics(find.byType(RecommendToggleChip));
      expect(node.label, startsWith('Recomendado'));
      expect(node.getSemanticsData().flagsCollection.isSelected, Tristate.isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      final size = tester.getSize(find.byType(FilterChip).at(1));
      expect(size.height, greaterThanOrEqualTo(48));
      handle.dispose();
    });

    testWidgets('keyboard: Tab reaches the chip and Enter toggles it', (tester) async {
      final r = _Rig()..put(_movie(11, title: 'Filme X'));
      await r.pump(tester, initial: '/movie/11', size: const Size(1024, 900));
      var guard = 0;
      while (guard++ < 30) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused != null &&
            find
                .descendant(
                  of: find.byType(RecommendToggleChip),
                  matching: find.byWidget(focused.widget),
                )
                .evaluate()
                .isNotEmpty) {
          break;
        }
        if (focused?.findAncestorWidgetOfExactType<RecommendToggleChip>() != null) break;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(r.doc('11-movie')?.recommended, isTrue);
    });
  });

  group('texts', () {
    testWidgets('delete dialog and privacy summary mention recommendations (private for now)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: cloudOverrides(
            auth: FakeAuthRepository(initialUser: kAna),
            cloud: FakeCloud(),
          ),
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: PrivacySummary())),
          ),
        ),
      );
      expect(find.textContaining('recomendações são privadas'), findsOneWidget);
      expect(find.textContaining('por enquanto'), findsOneWidget);

      await tester.pumpWidget(
        ProviderScope(
          overrides: cloudOverrides(
            auth: FakeAuthRepository(initialUser: kAna),
            cloud: FakeCloud(),
          ),
          child: const MaterialApp(home: Scaffold(body: DeleteAccountDialog())),
        ),
      );
      expect(find.textContaining('suas recomendações'), findsOneWidget);
    });

    testWidgets('Profile shows the "Recomendações" counter next to the old numbers', (
      tester,
    ) async {
      final cloud = FakeCloud()
        ..server['uid-ana'] = {
          '1-movie': _movie(1, recommended: true),
          '2-movie': _movie(2),
          '3-tv': _tv(3, recommended: true),
        };
      await tester.pumpWidget(
        ProviderScope(
          overrides: cloudOverrides(
            auth: FakeAuthRepository(initialUser: kAna),
            cloud: cloud,
          ),
          child: const MaterialApp(home: ProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Recomendações'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final tile = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Recomendações: 2',
      );
      expect(tile, findsOneWidget);
      expect(find.text('Favoritos'), findsOneWidget);
    });
  });

  group('navigation (full app)', () {
    Future<(ProviderContainer, FakeAuthRepository)> pumpApp(
      WidgetTester tester, {
      required Size size,
      FakeAuthRepository? auth,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fake = auth ?? FakeAuthRepository(initialUser: kAna);
      final container = ProviderContainer(
        overrides: cloudOverrides(auth: fake, cloud: FakeCloud(), api: _api()),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const CineTrackApp()),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      return (container, fake);
    }

    String location(ProviderContainer c) =>
        c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;
    NavigationBar bar(WidgetTester t) => t.widget(find.byType(NavigationBar));
    Finder inBar(String text) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(text));

    testWidgets('tab bar: Início, Explorar, Recomendo, Favoritos, Perfil (5 items)', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(390, 800));
      expect(bar(tester).destinations, hasLength(5));
      final xs = [
        for (final l in ['Início', 'Explorar', 'Recomendo', 'Favoritos', 'Perfil'])
          tester.getCenter(inBar(l)).dx,
      ];
      expect(xs, orderedEquals([...xs]..sort()), reason: 'declared order, Perfil last');
      expect(find.byTooltip('Minhas recomendações'), findsOneWidget);
    });

    testWidgets('Recomendo tab opens /recommendations and is the selected item', (tester) async {
      final (c, _) = await pumpApp(tester, size: const Size(390, 800));
      await tester.tap(inBar('Recomendo'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(location(c), '/recommendations');
      expect(bar(tester).selectedIndex, 2);
      expect(find.text('Você ainda não recomendou nada'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('Perfil stays a tab (index 4); Favoritos stays index 3', (tester) async {
      final (c, _) = await pumpApp(tester, size: const Size(390, 800));
      await tester.tap(inBar('Favoritos'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect((location(c), bar(tester).selectedIndex), ('/favorites', 3));
      await tester.tap(inBar('Perfil'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect((location(c), bar(tester).selectedIndex), ('/profile', 4));
    });

    testWidgets('magnifier in the top bar opens /search; Explorar is the selected tab there', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final (c, _) = await pumpApp(tester, size: const Size(390, 800));
      final lupa = find.descendant(
        of: find.byType(MobileTopBar),
        matching: find.byTooltip('Buscar'),
      );
      expect(lupa, findsOneWidget);
      final size = tester.getSize(lupa);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      await tester.tap(lupa);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(location(c), '/search');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(bar(tester).selectedIndex, 1);
      // Screen readers: exactly one destination is announced as selected, and it
      // is Explorar (never Início).
      final selected = <String>[];
      for (final l in ['Início', 'Explorar', 'Recomendo', 'Favoritos', 'Perfil']) {
        final node = tester.getSemantics(inBar(l));
        if (node.getSemanticsData().flagsCollection.isSelected == Tristate.isTrue) {
          selected.add(l);
        }
      }
      expect(selected, ['Explorar']);
      // The magnifier is available on every main tab.
      await tester.tap(inBar('Recomendo'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(
        find.descendant(of: find.byType(MobileTopBar), matching: find.byTooltip('Buscar')),
        findsOneWidget,
      );
      expect(bar(tester).selectedIndex, 2);
      handle.dispose();
    });

    testWidgets('signed out: Entrar is still the last tab and starts login from the tap', (
      tester,
    ) async {
      final (c, auth) = await pumpApp(
        tester,
        size: const Size(390, 800),
        auth: FakeAuthRepository(),
      );
      await tester.tap(inBar('Entrar'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(auth.signInCalls, 1);
      expect(location(c), '/');
    });

    for (final scale in [1.0, 2.0, 3.0]) {
      for (final w in [320.0, 360.0, 390.0, 768.0]) {
        testWidgets('mobile ${w.toInt()} px font ${scale.toInt()}x: top bar and tab bar fit', (
          tester,
        ) async {
          final (c, _) = await pumpApp(tester, size: Size(w, 700), textScale: scale);
          for (final p in ['/', '/recommendations', '/favorites', '/search']) {
            c.read(routerProvider).go(p);
            await tester.pumpAndSettle(const Duration(seconds: 1));
            expect(tester.takeException(), isNull, reason: '$p at $w x$scale');
          }
        });
      }
    }

    for (final scale in [2.0, 3.0]) {
      for (final w in [769.0, 1024.0, 1440.0]) {
        testWidgets('real /search and /catalog at ${w.toInt()} px font ${scale.toInt()}x fit', (
          tester,
        ) async {
          final (c, _) = await pumpApp(tester, size: Size(w, 700), textScale: scale);
          for (final p in ['/search', '/catalog']) {
            c.read(routerProvider).go(p);
            await tester.pumpAndSettle(const Duration(seconds: 1));
            expect(tester.takeException(), isNull, reason: p);
          }
        });
      }
    }

    testWidgets('desktop top menu has "Minhas recomendações"; Busca stays in it', (tester) async {
      final (_, _) = await pumpApp(tester, size: const Size(1280, 800));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Minhas recomendações'), findsOneWidget);
      expect(find.byTooltip('Buscar'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Minhas recomendações'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.byType(RecommendationsScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Minhas recomendações'), findsOneWidget);
    });

    for (final scale in [1.0, 2.0]) {
      for (final w in [769.0, 800.0, 900.0, 959.0, 960.0, 1024.0, 1440.0]) {
        testWidgets('desktop ${w.toInt()} px font ${scale.toInt()}x: top menu has no overflow', (
          tester,
        ) async {
          final (c, _) = await pumpApp(tester, size: Size(w, 800), textScale: scale);
          expect(tester.takeException(), isNull);
          for (final p in ['/recommendations', '/favorites']) {
            c.read(routerProvider).go(p);
            await tester.pumpAndSettle(const Duration(seconds: 1));
            expect(tester.takeException(), isNull, reason: p);
          }
        });
      }
    }

    for (final size in [const Size(390, 800), const Size(1280, 800)]) {
      testWidgets('every existing deep link still opens at ${size.width.toInt()} px', (
        tester,
      ) async {
        final (c, _) = await pumpApp(tester, size: size);
        for (final p in [
          '/',
          '/favorites',
          '/search',
          '/catalog',
          '/profile',
          '/recommendations',
          '/movie/603',
          '/tv/1396',
          '/person/1',
        ]) {
          c.read(routerProvider).go(p);
          await tester.pumpAndSettle(const Duration(seconds: 1));
          expect(location(c), p, reason: p);
          expect(tester.takeException(), isNull, reason: p);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  });

  group('EmptyState and /search at large fonts', () {
    for (final scale in [1.0, 2.0, 3.0]) {
      for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
        for (final dark in [false, true]) {
          testWidgets('${width.toInt()} px, ${dark ? 'dark' : 'light'}, font ${scale.toInt()}x: '
              'empty Favoritos and empty Minhas recomendações fit', (tester) async {
            for (final path in ['/favorites', '/recommendations']) {
              final r = _Rig();
              await r.pump(
                tester,
                initial: path,
                size: Size(width, 700),
                textScale: scale,
                brightness: dark ? Brightness.dark : Brightness.light,
              );
              expect(tester.takeException(), isNull, reason: path);
              await tester.pumpWidget(const SizedBox());
              await tester.pump(const Duration(seconds: 1));
            }
          });
        }
      }
    }
  });
}
