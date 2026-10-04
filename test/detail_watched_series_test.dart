import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/catalog_sync_providers.dart';
import 'package:cinetrack/services/bulk_watch.dart';
import 'package:cinetrack/widgets/poster_image.dart';
import 'package:cinetrack/widgets/detail_actions.dart';
import 'package:cinetrack/screens/movie_details_screen.dart';
import 'package:cinetrack/screens/tv_details_screen.dart';
import 'package:cinetrack/widgets/auth_gate.dart';
import 'package:cinetrack/widgets/episode_tile.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

// docs/45 item 1: "Marcar como assistido" on the details of movies AND shows.

final _past = DateTime(2020);
final _future = DateTime.now().add(const Duration(days: 90));

EpisodeCache _ep(int n, {DateTime? air}) => EpisodeCache(
  episodeNumber: n,
  name: 'Ep $n',
  airDate: air ?? _past,
  watched: false,
  detailed: true,
);

final _s1 = SeasonCache(seasonNumber: 1, episodes: [_ep(1), _ep(2), _ep(3)]);
final _s2 = SeasonCache(
  seasonNumber: 2,
  episodes: [
    _ep(1),
    _ep(2, air: _future),
  ],
);

const _summaries = [
  TvSeasonSummary(seasonNumber: 1, name: 'Temporada 1', episodeCount: 3),
  TvSeasonSummary(seasonNumber: 2, name: 'Temporada 2', episodeCount: 2),
];
const _allAired = {'1_1', '1_2', '1_3', '2_1'};

FavoriteDoc _tvDoc({Set<String> eps = const {}}) => FavoriteDoc(
  id: 12,
  mediaType: MediaType.tv,
  title: 'Serie Y',
  posterPath: null,
  overview: 'Sinopse serie',
  addedAt: DateTime(2024),
  watchedEpisodes: eps,
  seasonSummaries: _summaries,
);

FakeTmdbApiClient _api() => FakeTmdbApiClient()
  ..movieDetails = {'id': 11, 'title': 'Filme X', 'overview': 'Sinopse do filme'}
  ..tvDetails = {
    'id': 12,
    'name': 'Serie Y',
    'overview': 'Sinopse serie',
    'seasons': [
      {'season_number': 1, 'name': 'Temporada 1', 'episode_count': 3},
      {'season_number': 2, 'name': 'Temporada 2', 'episode_count': 2},
    ],
  }
  ..seasonsByNumber[1] = _s1
  ..seasonsByNumber[2] = _s2;

class _Rig {
  final cloud = FakeCloud();
  final store = FakeLocalStore();
  final api = _api();

  Set<String> eps() => cloud.view('uid-ana')['12-tv']!.watchedEpisodes;

  Future<void> seedFavorite({Set<String> eps = const {}}) async {
    (cloud.server['uid-ana'] ??= {})['12-tv'] = _tvDoc(eps: eps);
    await store.saveCatalogSeason(12, _s1);
    await store.saveCatalogSeason(12, _s2);
    store.fetchedAt[12] = DateTime.now();
  }

  Future<void> pump(
    WidgetTester tester, {
    required String location,
    FakeAuthRepository? auth,
    Size size = const Size(390, 2400),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/movie/:id',
          builder: (_, s) => MovieDetailsScreen(movieId: int.parse(s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/tv/:id',
          builder: (_, s) => TvDetailsScreen(tvId: int.parse(s.pathParameters['id']!)),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...cloudOverrides(
            auth: auth ?? FakeAuthRepository(initialUser: kAna),
            cloud: cloud,
            store: store,
            api: api,
          ),
          catalogSyncDelayProvider.overrideWithValue((_) async {}),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(brightness: brightness, useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: PendingIntentRunner(child: child!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

/// Lets the "salvando…" / undo acknowledgement timers finish.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 12));
  await tester.pumpAndSettle();
}

Finder _markSeries() => find.byTooltip('Marcar como assistido: todos os episódios de Serie Y');
Finder _unmarkSeries() => find.byTooltip('Assistido: desmarcar todos os episódios de Serie Y');

void main() {
  group('the chip is on every details screen', () {
    testWidgets('show that is NOT a favorite: Favoritar, Recomendo and Marcar como assistido', (
      tester,
    ) async {
      final r = _Rig();
      await r.pump(tester, location: '/tv/12');
      expect(find.text('Favoritar'), findsOneWidget);
      expect(find.text('Recomendo'), findsOneWidget);
      expect(find.text('Marcar como assistido'), findsOneWidget);
    });

    testWidgets('show that is a favorite: same chip, "Assistido" only when concluded', (
      tester,
    ) async {
      final r = _Rig();
      await r.seedFavorite();
      await r.pump(tester, location: '/tv/12');
      expect(find.text('Marcar como assistido'), findsOneWidget);
      expect(find.text('Assistido'), findsNothing);
    });

    testWidgets('movie (favorite or not): chip is there', (tester) async {
      final r = _Rig();
      await r.pump(tester, location: '/movie/11');
      expect(find.text('Marcar como assistido'), findsOneWidget);
      expect(find.text('Favoritar'), findsOneWidget);
      expect(find.text('Recomendo'), findsOneWidget);
    });

    testWidgets('accessible names start with the visible text, 48 px target', (tester) async {
      final handle = tester.ensureSemantics();
      final r = _Rig();
      await r.seedFavorite();
      await r.pump(tester, location: '/tv/12');
      final node = tester.getSemantics(_markSeries()).getSemanticsData();
      expect(node.label, startsWith('Marcar como assistido'));
      expect(node.hasAction(SemanticsAction.tap), isTrue);
      expect(node.flagsCollection.isSelected, Tristate.isFalse);
      final chip = find.ancestor(of: _markSeries(), matching: find.byType(FilterChip));
      expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
      handle.dispose();
    });
  });

  group('show: whole series from the details', () {
    testWidgets('not a favorite: cancelling leaves NO trace; confirming favorites + marks', (
      tester,
    ) async {
      final r = _Rig();
      await r.pump(tester, location: '/tv/12');

      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      expect(find.text('Marcar a série inteira como assistida?'), findsOneWidget);
      // 3 + 1 aired (the future episode is left out), 2 seasons.
      expect(find.textContaining('Isso vai marcar 4 episódios de 2 temporadas'), findsOneWidget);
      expect(find.textContaining('desfazer por 30 segundos'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(r.cloud.view('uid-ana'), isEmpty); // not even favorited
      expect(r.store.readSeasonCatalog(12), isEmpty); // nothing cached either

      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps(), _allAired);
      expect(find.text('Remover dos favoritos'), findsOneWidget);
      expect(find.text('Assistido'), findsOneWidget);
      expect(find.text('Desfazer'), findsOneWidget);
    });

    testWidgets('favorite: marks, chip follows; undo restores', (tester) async {
      final r = _Rig();
      await r.seedFavorite();
      await r.pump(tester, location: '/tv/12');

      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps(), _allAired);
      expect(find.text('Assistido'), findsOneWidget);

      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      expect(r.eps(), isEmpty);
      expect(find.text('Marcar como assistido'), findsOneWidget);
      await _drain(tester);
    });

    testWidgets('unmark asks first, clears the progress, undo brings it back', (tester) async {
      final r = _Rig();
      await r.seedFavorite(eps: _allAired);
      await r.pump(tester, location: '/tv/12');
      expect(find.text('Assistido'), findsOneWidget);

      await tester.tap(_unmarkSeries());
      await tester.pumpAndSettle();
      expect(find.text('Desmarcar a série inteira?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(r.eps(), _allAired); // cancel changes nothing

      await tester.tap(_unmarkSeries());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desmarcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps(), isEmpty);
      expect(find.text('Marcar como assistido'), findsOneWidget);

      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      expect(r.eps(), _allAired);
      await _drain(tester);
    });

    testWidgets('NO DATA LOSS: existing watched episodes stay, undo only reverts the new ones', (
      tester,
    ) async {
      final r = _Rig();
      await r.seedFavorite(eps: {'1_1', '9_9'}); // 9_9: an episode the catalog does not know
      await r.pump(tester, location: '/tv/12');
      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      expect(find.textContaining('Isso vai marcar 3 episódios'), findsOneWidget);
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps(), {..._allAired, '9_9'});

      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      expect(r.eps(), {'1_1', '9_9'});
      await _drain(tester);
    });

    testWidgets('derived state: follows the per-episode checks, no divergence', (tester) async {
      final r = _Rig();
      await r.seedFavorite(eps: {'1_1', '1_2', '1_3'}); // only season 2 is missing
      await r.pump(tester, location: '/tv/12');
      expect(find.text('Marcar como assistido'), findsOneWidget);

      await tester.tap(find.text('Temporada 2'));
      await tester.pumpAndSettle();
      final check = find.descendant(
        of: find.byKey(const ValueKey('episode-2-1')),
        matching: find.byType(Checkbox),
      );
      await tester.tap(check); // last aired episode -> concluded
      await tester.pumpAndSettle();
      expect(find.text('Assistido'), findsAtLeastNWidgets(1));
      expect(_unmarkSeries(), findsOneWidget);

      await tester.tap(check); // unchecking one -> not concluded anymore
      await tester.pumpAndSettle();
      expect(_markSeries(), findsOneWidget);
      expect(_unmarkSeries(), findsNothing);

      // And the other direction: the chip ticks the episode checks of the open season.
      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EpisodeTile>(find.byKey(const ValueKey('episode-2-1'))).episode.watched,
        isTrue,
      );
    });

    testWidgets('offline catalog: loads the seasons first, a failure changes nothing', (
      tester,
    ) async {
      final r = _Rig();
      (r.cloud.server['uid-ana'] ??= {})['12-tv'] = _tvDoc(); // no catalog on this device
      r.api.seasonError = StateError('x');
      await r.pump(tester, location: '/tv/12');
      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      expect(find.text('Não foi possível preparar'), findsOneWidget);
      expect(find.textContaining('Nada foi alterado'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(r.eps(), isEmpty);
    });

    testWidgets('signed out: login first, then the same confirmation, then it is saved', (
      tester,
    ) async {
      final r = _Rig();
      final auth = FakeAuthRepository()..nextUser = kAna;
      await r.pump(tester, location: '/tv/12', auth: auth);
      expect(find.text('Marcar como assistido'), findsOneWidget); // visible when signed out

      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      expect(auth.signInCalls, 1);
      expect(find.text('Marcar a série inteira como assistida?'), findsOneWidget);
      expect(r.cloud.view('uid-ana'), isEmpty); // nothing written before the confirmation

      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps(), _allAired);
    });

    testWidgets('signed out and login cancelled: nothing is saved', (tester) async {
      final r = _Rig();
      final auth = FakeAuthRepository()..nextFailure = const AuthFailure(AuthFailureKind.cancelled);
      await r.pump(tester, location: '/tv/12', auth: auth);
      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      expect(auth.signInCalls, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(r.cloud.view('uid-ana'), isEmpty);
    });

    testWidgets('signing into an account that already finished the show never unmarks it', (
      tester,
    ) async {
      final r = _Rig();
      await r.seedFavorite(eps: _allAired); // the account being signed into
      final auth = FakeAuthRepository()..nextUser = kAna;
      await r.pump(tester, location: '/tv/12', auth: auth);
      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      expect(find.text('Nada para marcar'), findsOneWidget); // a mark, never a toggle
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(r.eps(), _allAired);
    });
  });

  group('movie: chip works signed out and signed in', () {
    testWidgets('signed out: login resumes the intent (favorite + watched)', (tester) async {
      final r = _Rig();
      final auth = FakeAuthRepository()..nextUser = kAna;
      await r.pump(tester, location: '/movie/11', auth: auth);
      await tester.tap(find.text('Marcar como assistido'));
      await tester.pumpAndSettle();
      expect(auth.signInCalls, 1);
      expect(r.cloud.view('uid-ana')['11-movie']!.watchedMovie, isTrue);
      expect(find.text('Assistido'), findsOneWidget);
    });

    testWidgets('signed in: toggles on and off', (tester) async {
      final r = _Rig();
      await r.pump(tester, location: '/movie/11');
      await tester.tap(find.text('Marcar como assistido'));
      await tester.pumpAndSettle();
      expect(r.cloud.view('uid-ana')['11-movie']!.watchedMovie, isTrue);
      await tester.tap(find.text('Assistido'));
      await tester.pumpAndSettle();
      expect(r.cloud.view('uid-ana')['11-movie']!.watchedMovie, isFalse);
    });
  });

  group('layout: chips row never overflows', () {
    for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 3.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('show $width px, font ${scale}x, ${brightness.name}', (tester) async {
            final r = _Rig();
            await r.seedFavorite();
            r.api.videos = const [];
            await r.pump(
              tester,
              location: '/tv/12',
              size: Size(width, 1800),
              textScale: scale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('Temporada 1'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.byType(EpisodeTile), findsNWidgets(3));
          });
        }
      }
    }
  });

  group('hardening (docs/45 review)', () {
    testWidgets('account switch with the detail dialog open: nothing is written to the new one', (
      tester,
    ) async {
      final r = _Rig();
      await r.seedFavorite();
      final auth = FakeAuthRepository(initialUser: kAna)..nextUser = kBruno;
      await r.pump(tester, location: '/tv/12', auth: auth);
      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      expect(find.text('Marcar tudo'), findsOneWidget);

      await auth.signOut();
      await tester.pumpAndSettle();
      await auth.signInWithGoogle(); // now Bruno
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();

      expect(find.text('A conta mudou. Nada foi alterado.'), findsOneWidget);
      expect(find.text('Desfazer'), findsNothing);
      expect(r.cloud.view('uid-bruno'), isEmpty);
      expect(r.eps(), isEmpty); // Ana's document untouched too
    });

    testWidgets('over the 5000 episode cap: refused with a message, progress untouched', (
      tester,
    ) async {
      final r = _Rig();
      await r.seedFavorite(eps: {for (var i = 0; i < kMaxBulkEpisodes; i++) '9_$i'});
      await r.pump(tester, location: '/tv/12');
      await tester.tap(_markSeries());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(find.text(kTooLargeMessage), findsOneWidget);
      expect(r.eps().length, kMaxBulkEpisodes);
      expect(r.eps(), isNot(contains('1_1')));
      await _drain(tester);
    });

    testWidgets('a season with 150 episodes builds and requests images in pages only', (
      tester,
    ) async {
      final r = _Rig();
      final big = SeasonCache(
        seasonNumber: 1,
        episodes: [
          for (var n = 1; n <= 150; n++)
            EpisodeCache(
              episodeNumber: n,
              name: 'Ep $n',
              airDate: _past,
              watched: false,
              stillPath: '/s$n.jpg',
              detailed: true,
            ),
        ],
      );
      r.api.seasonsByNumber[1] = big;
      (r.cloud.server['uid-ana'] ??= {})['12-tv'] = _tvDoc(eps: {'1_2'});
      await r.store.saveCatalogSeason(12, big);
      r.store.fetchedAt[12] = DateTime.now();
      await r.pump(tester, location: '/tv/12', size: const Size(390, 6000));

      await tester.tap(find.text('Temporada 1'));
      await tester.pumpAndSettle();
      expect(find.byType(EpisodeTile), findsNWidgets(kEpisodePage));
      final images = tester
          .widgetList<PosterImage>(find.byType(PosterImage))
          .where((p) => p.posterPath?.startsWith('/s') ?? false);
      expect(images.length, kEpisodePage); // 25 images asked, not 150
      expect(find.textContaining('125 restantes'), findsOneWidget);

      await tester.ensureVisible(find.textContaining('Mostrar mais episódios'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Mostrar mais episódios'));
      await tester.pumpAndSettle();
      expect(find.byType(EpisodeTile), findsNWidgets(kEpisodePage * 2));
      // Watched state is untouched by paging.
      expect(
        tester.widget<EpisodeTile>(find.byKey(const ValueKey('episode-1-2'))).episode.watched,
        isTrue,
      );
      expect(r.eps(), {'1_2'});
    });

    test('stale list says "not a favorite" but the document exists: progress is kept', () async {
      final h = FavoritesHarness();
      await h.seedShow(
        seasons: [
          SeasonCache(seasonNumber: 1, episodes: [h.episode(1), h.episode(2), h.episode(3)]),
        ],
      );
      h.cloud.server['user-a']!['42-tv'] = h.cloud.server['user-a']!['42-tv']!.copyWith(
        watchedEpisodes: {'1_1', '7_7'},
      );
      final before = h.cloud.view('user-a')['42-tv']!;
      h.api.tvDetails = {
        'seasons': [
          {'season_number': 1, 'name': 'T1', 'episode_count': 3},
        ],
      };
      h.api.seasonsByNumber[1] = SeasonCache(
        seasonNumber: 1,
        episodes: [h.episode(1), h.episode(2), h.episode(3)],
      );

      final plan = await h.repo.planNewSeriesBulk(42);
      expect(plan.keys, {'1_2', '1_3'}); // counts only what is missing
      // The screen still thinks it is not a favorite: add + apply.
      const result = SearchResult(
        id: 42,
        mediaType: MediaType.tv,
        title: 'Outro titulo',
        posterPath: null,
        overview: '',
      );
      await favoriteThen(h.repo, result, false, () => h.repo.applySeriesBulk(plan, uid: 'user-a'));

      final after = h.cloud.view('user-a')['42-tv']!;
      expect(after.watchedEpisodes, {'1_1', '1_2', '1_3', '7_7'});
      expect(after.title, before.title); // the existing document was not rewritten
      expect(after.addedAt, before.addedAt);
    });
  });
}
