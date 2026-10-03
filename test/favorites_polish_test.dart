import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/activity_overlay.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/catalog_sync_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/services/favorite_status.dart';
import 'package:cinetrack/services/progress_calculator.dart';
import 'package:cinetrack/services/tmdb_exception.dart';
import 'package:cinetrack/widgets/detail_actions.dart';
import 'package:cinetrack/widgets/favorites_section.dart';
import 'package:cinetrack/widgets/poster_image.dart';
import 'package:cinetrack/widgets/profile_stats_card.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

final _past = DateTime(2020);
final _future = DateTime.now().add(const Duration(days: 90));

EpisodeCache _ep(int n, {bool watched = false, DateTime? air}) =>
    EpisodeCache(episodeNumber: n, name: 'E$n', airDate: air ?? _past, watched: watched);

FavoriteItem _tv(String title, List<SeasonCache> seasons,
        {DateTime? added, DateTime? lastWatched, List<TvSeasonSummary>? summaries, int id = 1}) =>
    FavoriteItem(
      id: id,
      mediaType: MediaType.tv,
      title: title,
      posterPath: null,
      overview: '',
      addedAt: added ?? DateTime(2024),
      lastWatchedAt: lastWatched,
      seasons: seasons,
      seasonSummaries: summaries,
    );

FavoriteDoc _doc(int id, String title,
        {MediaType type = MediaType.tv,
        bool watchedMovie = false,
        Set<String> eps = const {},
        List<TvSeasonSummary> summaries = const [],
        DateTime? added,
        DateTime? lastWatched}) =>
    FavoriteDoc(
      id: id,
      mediaType: type,
      title: title,
      posterPath: null,
      overview: '',
      addedAt: added ?? DateTime(2024),
      lastWatchedAt: lastWatched,
      watchedMovie: watchedMovie,
      watchedEpisodes: eps,
      seasonSummaries: summaries,
    );

const _s1 = TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 2);
const _s2 = TvSeasonSummary(seasonNumber: 2, name: 'T2', episodeCount: 1);

SeasonCache _season(int n, int eps) =>
    SeasonCache(seasonNumber: n, episodes: [for (var i = 1; i <= eps; i++) _ep(i)]);

void main() {
  group('item 3: ordering by recent activity', () {
    test('lastWatchedAt wins over addedAt; null (pending server timestamp) falls back', () {
      final oldWatchedToday =
          _tv('Velha', [], added: DateTime(2020), lastWatched: DateTime(2026, 10, 3), id: 1);
      final newNeverWatched = _tv('Nova', [], added: DateTime(2026, 1, 1), id: 2);
      final nullStamp = _tv('Sem carimbo', [], added: DateTime(2025), id: 3);
      final sorted = [nullStamp, newNeverWatched, oldWatchedToday]
        ..sort(FavoriteItem.byRecentActivity);
      expect(sorted.map((e) => e.title), ['Velha', 'Nova', 'Sem carimbo']);
    });

    test('ties are broken by newest favorite, then title (stable)', () {
      final a = _tv('B', [], added: DateTime(2024), id: 1);
      final b = _tv('A', [], added: DateTime(2024), id: 2);
      expect([a, b]..sort(FavoriteItem.byRecentActivity), [b, a]);
    });

    test('ActivityOverlay: local stamp stands in for a pending (null) server timestamp', () {
      final overlay = ActivityOverlay()..stamp('1-tv', DateTime(2026, 10, 3));
      expect(overlay.resolve('1-tv', null, pending: true), DateTime(2026, 10, 3));
      expect(overlay.resolve('1-tv', DateTime(2026, 1, 1), pending: true), DateTime(2026, 10, 3));
      // acknowledged: the server value wins and the stamp is dropped
      expect(overlay.resolve('1-tv', DateTime(2026, 10, 4), pending: false), DateTime(2026, 10, 4));
      expect(overlay.resolve('1-tv', null, pending: true), isNull);
    });

    test('every watch action stamps lastWatchedAt: episode, season and movie', () async {
      final h = FavoritesHarness();
      await h.seedShow(seasons: [
        SeasonCache(seasonNumber: 1, episodes: [h.episode(1), h.episode(2)])
      ]);
      DateTime? stamp() => h.cloud.view('user-a')['42-tv']!.lastWatchedAt;
      expect(stamp(), isNull);
      await h.repo.toggleEpisodeWatched(42, 1, 1);
      final first = stamp();
      expect(first, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await h.repo.setSeasonWatched(42, 1, watched: true);
      expect(stamp()!.isAfter(first!), isTrue);

      await h.repo.addMovie(id: 5, title: 'F', posterPath: null, overview: '');
      expect(h.cloud.view('user-a')['5-movie']!.lastWatchedAt, isNull);
      await h.repo.markMovieWatched(5);
      final marked = h.cloud.view('user-a')['5-movie']!.lastWatchedAt;
      expect(marked, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await h.repo.toggleMovieWatched(5);
      expect(h.cloud.view('user-a')['5-movie']!.watchedMovie, isFalse);
      expect(h.cloud.view('user-a')['5-movie']!.lastWatchedAt!.isAfter(marked!), isTrue,
          reason: 'unmarking is an interaction too');
    });
  });

  group('item 4: rule of "concluído"', () {
    test('movie: watched = completed', () {
      FavoriteItem m(bool w) => FavoriteItem(
          id: 1,
          mediaType: MediaType.movie,
          title: 'M',
          posterPath: null,
          overview: '',
          addedAt: DateTime(2024),
          watchedMovie: w);
      expect(FavoriteStatus.of(m(true)).state, WatchState.completed);
      expect(FavoriteStatus.of(m(false)).state, WatchState.notStarted);
    });

    test('series: all aired watched = completed even with unaired episodes left', () {
      final item = _tv('S', [
        SeasonCache(seasonNumber: 1, episodes: [
          _ep(1, watched: true),
          _ep(2, watched: true),
          _ep(3, air: _future),
        ])
      ]);
      expect(ProgressCalculator.compute(item.seasons!).isCompleted, isFalse);
      expect(FavoriteStatus.of(item).state, WatchState.completed);
    });

    test('series: one aired episode missing = in progress; nothing watched = not started', () {
      final partial = _tv('S', [
        SeasonCache(seasonNumber: 1, episodes: [_ep(1, watched: true), _ep(2)])
      ]);
      final none = _tv('S', [_season(1, 2)]);
      expect(FavoriteStatus.of(partial).state, WatchState.inProgress);
      expect(FavoriteStatus.of(none).state, WatchState.notStarted);
    });

    test('series: only unaired episodes (nothing aired) is never completed', () {
      final item = _tv('S', [
        SeasonCache(seasonNumber: 1, episodes: [_ep(1, air: _future)])
      ]);
      expect(FavoriteStatus.of(item).state, WatchState.notStarted);
    });

    test('series: unwatched specials (season 0) do not block completion', () {
      final item = _tv('S', [
        SeasonCache(seasonNumber: 1, episodes: [_ep(1, watched: true)]),
        SeasonCache(seasonNumber: 0, episodes: [_ep(1)]),
      ]);
      expect(FavoriteStatus.of(item).state, WatchState.completed);
    });

    test('series: a season not downloaded yet = partial, approximate, never completed', () {
      final item = _tv(
        'S',
        [
          SeasonCache(seasonNumber: 1, episodes: [_ep(1, watched: true), _ep(2, watched: true)])
        ],
        summaries: const [_s1, _s2],
      );
      for (final failed in [false, true]) {
        final status = FavoriteStatus.of(item, failed: failed);
        expect(status.state, WatchState.inProgress);
        expect(status.approximate, isTrue);
      }
    });

    test('series with nothing cached is calculating, or unavailable after a failure', () {
      final item = _tv('S', [], summaries: const [_s1]);
      expect(FavoriteStatus.of(item).state, WatchState.calculating);
      expect(FavoriteStatus.of(item, failed: true).state, WatchState.unavailable);
    });

    test('empty summary list with cached seasons is partial, not complete', () {
      final item = _tv('S', [_season(1, 1)], summaries: const []);
      expect(FavoriteStatus.of(item).approximate, isTrue);
    });
  });

  group('item 5: reconciliation of the season catalog', () {
    test('empty catalog + docs: downloads every missing season, newest activity first', () async {
      final h = FavoritesHarness();
      h.api.seasonsByNumber[1] = _season(1, 2);
      h.api.seasonsByNumber[2] = _season(2, 1);
      final docs = [
        _doc(1, 'Old', summaries: const [_s1, _s2], lastWatched: DateTime(2021)),
        _doc(2, 'Recent', summaries: const [_s1], lastWatched: DateTime(2026)),
        _doc(3, 'Filme', type: MediaType.movie),
      ];
      final order = <int>[];
      expect(h.repo.docsNeedingCatalog(docs).map((d) => d.id), [2, 1]);
      await h.repo.reconcileCatalog(h.repo.docsNeedingCatalog(docs),
          onDone: (id, ok) => order.add(ok ? id : -id));
      expect(order.toSet(), {1, 2});
      expect(h.store.readSeasonCatalog(1).map((s) => s.seasonNumber), [1, 2]);
      expect(h.store.readSeasonCatalog(2).map((s) => s.seasonNumber), [1]);
      expect(h.repo.docsNeedingCatalog(docs), isEmpty, reason: 'cache hit: nothing left to fetch');
      expect(h.api.seasonCalls, 3);
    });

    test('a show with no season list gets it from TMDB and the summaries are saved', () async {
      final h = FavoritesHarness();
      h.api.tvDetails = {
        'seasons': [
          {'season_number': 1, 'name': 'T1', 'episode_count': 2},
        ]
      };
      h.api.seasonsByNumber[1] = _season(1, 2);
      await h.seedShow();
      await h.repo
          .reconcileCatalog(h.repo.docsNeedingCatalog(h.cloud.view('user-a').values.toList()));
      expect(h.cloud.view('user-a')['42-tv']!.seasonSummaries.single.seasonNumber, 1);
      expect(h.store.readSeasonCatalog(42), hasLength(1));
    });

    test('limits concurrency to 3 requests in flight', () async {
      final h = FavoritesHarness();
      h.api.seasonsByNumber[1] = _season(1, 1);
      final gate = h.api.seasonGate = Completer<void>();
      final docs = [
        for (var i = 1; i <= 8; i++) _doc(i, 'S$i', summaries: const [_s1])
      ];
      final run = h.repo.reconcileCatalog(docs);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.api.inFlight, 3);
      gate.complete();
      await run;
      expect(h.api.maxInFlight, 3);
      expect(h.api.seasonCalls, 8);
    });

    test('retries 429/network with 1 s, 2 s backoff, then succeeds', () async {
      final h = FavoritesHarness();
      h.api.seasonsByNumber[1] = _season(1, 1);
      h.api.seasonErrorQueue
        ..add(TmdbException.rateLimited())
        ..add(TmdbException.network());
      final waits = <Duration>[];
      bool? ok;
      await h.repo.reconcileCatalog([
        _doc(1, 'S', summaries: const [_s1])
      ], delay: (d) async => waits.add(d), onDone: (_, r) => ok = r);
      expect(waits, [const Duration(seconds: 1), const Duration(seconds: 2)]);
      expect(ok, isTrue);
    });

    test('gives up after the retry budget and does not retry auth errors', () async {
      final h = FavoritesHarness();
      h.api.seasonError = TmdbException.rateLimited();
      final waits = <Duration>[];
      bool? ok;
      await h.repo.reconcileCatalog([
        _doc(1, 'S', summaries: const [_s1])
      ], delay: (d) async => waits.add(d), onDone: (_, r) => ok = r);
      expect(ok, isFalse);
      expect(waits, hasLength(3));

      h.api.seasonError = TmdbException.unauthorized();
      waits.clear();
      await h.repo.reconcileCatalog([
        _doc(1, 'S', summaries: const [_s1])
      ], delay: (d) async => waits.add(d), onDone: (_, r) => ok = r);
      expect(waits, isEmpty);
    });

    group('after login, no interaction (widgets)', () {
      Future<FakeCloud> cloudWithHistory() async {
        final cloud = FakeCloud();
        cloud.server['uid-ana'] = {
          '1-tv': _doc(1, 'Serie Completa',
              summaries: const [_s1, _s2],
              eps: {'1_1', '1_2', '2_1'},
              lastWatched: DateTime(2026, 5)),
          '2-tv': _doc(2, 'Serie Parcial',
              summaries: const [_s1], eps: {'1_1'}, lastWatched: DateTime(2026, 6)),
          '3-movie': _doc(3, 'Filme Visto',
              type: MediaType.movie, watchedMovie: true, lastWatched: DateTime(2026, 4)),
          '4-movie': _doc(4, 'Filme Novo', type: MediaType.movie),
        };
        return cloud;
      }

      Widget app(FakeCloud cloud, FakeTmdbApiClient api, {Size? size}) => ProviderScope(
            overrides: [
              ...cloudOverrides(
                  auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, api: api),
              catalogSyncDelayProvider.overrideWithValue((_) async {}),
            ],
            child: const MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: FavoritesSection())),
            ),
          );

      testWidgets('empty catalog: "Calculando progresso…" (no false 0), then correct groups',
          (tester) async {
        final api = FakeTmdbApiClient()
          ..seasonsByNumber[1] = _season(1, 2)
          ..seasonsByNumber[2] = _season(2, 1);
        final gate = api.seasonGate = Completer<void>();
        await tester.pumpWidget(app(await cloudWithHistory(), api));
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(find.text('Calculando progresso…'), findsNWidgets(2));
        expect(find.textContaining('0/'), findsNothing);
        expect(find.textContaining('Sem episódios'), findsNothing);
        // movies are right immediately (watchedMovie lives in the document)
        expect(find.text('Em andamento (3)'), findsOneWidget); // 2 shows calculating + new movie
        expect(find.text('Concluídos (1)'), findsOneWidget);

        gate.complete();
        await tester.pumpAndSettle();

        expect(find.text('Calculando progresso…'), findsNothing);
        expect(find.text('Em andamento (2)'), findsOneWidget);
        expect(find.text('Concluídos (2)'), findsOneWidget);
        expect(find.text('Assistindo · 1/2'), findsOneWidget);
        await tester.tap(find.text('Concluídos (2)'));
        await tester.pumpAndSettle();
        expect(find.text('Concluído · 3/3'), findsOneWidget);
        expect(find.text('Filme Visto'), findsOneWidget);
        expect(api.seasonCalls, 3);
      });

      testWidgets('TMDB failing: "Progresso indisponível" with retry that recovers',
          (tester) async {
        final api = FakeTmdbApiClient()
          ..seasonsByNumber[1] = _season(1, 2)
          ..seasonsByNumber[2] = _season(2, 1)
          ..seasonError = Exception('offline');
        await tester.pumpWidget(app(await cloudWithHistory(), api));
        await tester.pumpAndSettle();

        expect(find.text('Progresso indisponível'), findsNWidgets(2));
        expect(find.textContaining('Não foi possível calcular o progresso de 2 séries'),
            findsOneWidget);

        api.seasonError = null;
        await tester.tap(find.text('Tentar de novo'));
        await tester.pumpAndSettle();
        expect(find.text('Progresso indisponível'), findsNothing);
        expect(find.text('Concluídos (2)'), findsOneWidget);
      });
    });
  });

  group('items 2 and 4: layout, groups and counters (widgets)', () {
    Future<void> pumpList(WidgetTester tester, List<FavoriteDoc> docs,
        {Size size = const Size(400, 900), double textScale = 1}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cloud = FakeCloud()..server['uid-ana'] = {for (final d in docs) d.key: d};
      final store = FakeLocalStore();
      for (final d in docs) {
        if (d.mediaType == MediaType.tv) {
          for (final s in d.seasonSummaries) {
            await store.saveCatalogSeason(d.id, _season(s.seasonNumber, s.episodeCount));
          }
        }
      }
      await tester.pumpWidget(ProviderScope(
        overrides:
            cloudOverrides(auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, store: store),
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: SingleChildScrollView(child: FavoritesSection())),
        ),
      ));
      await tester.pumpAndSettle();
    }

    final docs = [
      _doc(1, 'Serie A', summaries: const [_s1], eps: {'1_1'}, lastWatched: DateTime(2026, 3)),
      _doc(2, 'Serie B',
          summaries: const [_s1], eps: {'1_1', '1_2'}, lastWatched: DateTime(2026, 5)),
      _doc(3, 'Filme C', type: MediaType.movie, watchedMovie: true, lastWatched: DateTime(2026, 4)),
      _doc(4, 'Filme D', type: MediaType.movie, added: DateTime(2026, 6)),
    ];

    testWidgets('groups with counters, combined with the Filmes/Séries filter', (tester) async {
      await pumpList(tester, docs);
      expect(find.text('Em andamento (2)'), findsOneWidget);
      expect(find.text('Concluídos (2)'), findsOneWidget);
      expect(find.text('Serie A'), findsOneWidget);
      expect(find.text('Filme D'), findsOneWidget);
      expect(find.text('Serie B'), findsNothing);

      await tester.tap(find.text('Concluídos (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Serie B'), findsOneWidget);
      expect(find.text('Filme C'), findsOneWidget);

      await tester.tap(find.text('Filmes'));
      await tester.pumpAndSettle();
      expect(find.text('Em andamento (1)'), findsOneWidget);
      expect(find.text('Concluídos (1)'), findsOneWidget);
      expect(find.text('Serie B'), findsNothing);
    });

    testWidgets('a list is ordered by recent activity inside each group', (tester) async {
      await pumpList(tester, docs);
      await tester.tap(find.text('Concluídos (2)'));
      await tester.pumpAndSettle();
      // Serie B (May) is more recent than Filme C (April)
      expect(
          tester.getTopLeft(find.text('Serie B')).dy < tester.getTopLeft(find.text('Filme C')).dy,
          isTrue);
    });

    testWidgets('marking an episode moves the series to the top immediately', (tester) async {
      const three = TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 3);
      final two = [
        _doc(1, 'Primeira', summaries: const [three], eps: {'1_1'}, lastWatched: DateTime(2026, 3)),
        _doc(2, 'Segunda', summaries: const [three], eps: {'1_1'}, lastWatched: DateTime(2026, 5)),
      ];
      await pumpList(tester, two);
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Segunda') < y('Primeira'), isTrue);

      final container = ProviderScope.containerOf(tester.element(find.byType(FavoritesSection)));
      await container.read(favoritesRepositoryProvider).setEpisodeWatched(1, 1, 2, watched: true);
      await tester.pumpAndSettle();
      expect(y('Primeira') < y('Segunda'), isTrue);
    });

    for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
      testWidgets('poster keeps 2:3 and nothing overflows at ${width.toInt()} px', (tester) async {
        final long = _doc(9, 'Um título extremamente longo para testar a quebra de linha na lista',
            summaries: const [_s1], eps: {'1_1'});
        await pumpList(tester, [...docs, long], size: Size(width, 900), textScale: 1.5);
        expect(tester.takeException(), isNull);
        final size = tester.getSize(find.byType(PosterImage).first);
        expect(size.width / size.height, closeTo(2 / 3, 0.01));
        final poster = tester.widget<PosterImage>(find.byType(PosterImage).first);
        expect(poster.fit, BoxFit.contain, reason: 'whole poster, never cropped');
        // every tile at least 48 px tall (touch target)
        expect(tester.getSize(find.byType(Card).first).height, greaterThanOrEqualTo(48));
      });
    }

    testWidgets('empty group explains itself', (tester) async {
      await pumpList(tester, [docs[2]]);
      expect(find.text('Nada em andamento'), findsOneWidget);
      await tester.tap(find.text('Concluídos (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Filme C'), findsOneWidget);
    });
  });

  group('item 1: favorite button follows the app button pattern', () {
    Future<void> pumpButton(WidgetTester tester, {required bool fav, double width = 400}) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
        home: Scaffold(
          body: Center(
            child: FavoriteToggleButton(
              isFavorite: fav,
              hasProgress: false,
              title: 'X',
              onAdd: () async {},
              onRemove: () async {},
            ),
          ),
        ),
      ));
    }

    testWidgets('Favoritar is the filled purple M3 button, 48 px on mobile, default shape',
        (tester) async {
      await pumpButton(tester, fav: false);
      expect(find.byType(OutlinedButton), findsNothing);
      final button = find.byType(FilledButton);
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      final style = tester.widget<FilledButton>(button).style!;
      expect(style.shape, isNull, reason: 'theme (stadium) shape, no custom radius');
      expect(style.backgroundColor, isNull, reason: 'theme primary (purple), no hard-coded color');
    });

    testWidgets('Remover is the tonal variant of the same family (not outlined)', (tester) async {
      await pumpButton(tester, fav: true);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.text('Remover dos favoritos'), findsOneWidget);
      expect(find.bySemanticsLabel('Remover X dos favoritos'), findsOneWidget);
    });

    testWidgets('desktop keeps the 40 px M3 height', (tester) async {
      await pumpButton(tester, fav: false, width: 1200);
      final style = tester.widget<FilledButton>(find.byType(FilledButton)).style!;
      expect(style.minimumSize!.resolve({})!.height, 40);
    });

    testWidgets('pending spinner uses the button foreground color and the 18 px icon size',
        (tester) async {
      final done = Completer<void>();
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FavoriteToggleButton(
            isFavorite: false,
            hasProgress: false,
            title: 'X',
            onAdd: () => done.future,
            onRemove: () async {},
          ),
        ),
      ));
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      final spinner =
          tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
      expect(spinner.color, isNotNull);
      expect(tester.getSize(find.byType(CircularProgressIndicator)), const Size(18, 18));
      done.complete();
      await tester.pumpAndSettle();
    });
  });

  group('item 6: Tempo assistido (profile)', () {
    test('profile stats sum movie + episode runtimes from the local cache', () async {
      final h = FavoritesHarness();
      await h.store.saveMovieRuntime(3, 100);
      await h.store.saveCatalogSeason(
          1,
          const SeasonCache(seasonNumber: 1, episodes: [
            EpisodeCache(episodeNumber: 1, name: '', airDate: null, watched: false, runtime: 30),
          ]));
      final container = ProviderContainer(overrides: [
        ...cloudOverrides(
            auth: FakeAuthRepository(initialUser: kAna), cloud: h.cloud, store: h.store),
      ]);
      addTearDown(container.dispose);
      h.cloud.server['uid-ana'] = {
        '1-tv': _doc(1, 'S', summaries: const [_s1], eps: {'1_1'}),
        '3-movie': _doc(3, 'M', type: MediaType.movie, watchedMovie: true),
      };
      container.listen(favoriteDocsProvider, (_, _) {});
      await container.read(authStateProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final stats = container.read(profileStatsProvider);
      expect(stats.watchTime.minutes, 130);
    });

    test('reconciliation fetches movie runtime and show typical runtime', () async {
      final h = FavoritesHarness();
      h.api.movieDetails = {'runtime': 120};
      h.api.tvDetails = {
        'episode_run_time': [40, 50],
        'seasons': <dynamic>[],
      };
      final docs = [
        _doc(3, 'M', type: MediaType.movie, watchedMovie: true),
        _doc(1, 'S', summaries: const [_s1], eps: {'1_1'}),
        _doc(4, 'Nao visto', type: MediaType.movie),
      ];
      final keys = h.repo.pendingRuntimes(docs);
      expect(keys.toSet(), {'movie:3', 'tv:1'});
      await h.repo.reconcileRuntimes(keys);
      expect(h.store.readMovieRuntime(3), 120);
      expect(h.store.readTvFallbackRuntime(1), 45);
      expect(h.repo.pendingRuntimes(docs), ['tv:1'], reason: 'no catalog for it yet');
    });

    testWidgets('profile card shows dynamic units + accumulated hours, and flags estimates',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = FakeLocalStore()..movieRuntimes[3] = 150;
      final cloud = FakeCloud()
        ..server['uid-ana'] = {
          '3-movie': _doc(3, 'M', type: MediaType.movie, watchedMovie: true),
          '4-movie': _doc(4, 'N', type: MediaType.movie, watchedMovie: true),
        };
      await tester.pumpWidget(ProviderScope(
        overrides: [
          ...cloudOverrides(
              auth: FakeAuthRepository(initialUser: kAna), cloud: cloud, store: store),
          catalogSyncDelayProvider.overrideWithValue((_) async {}),
        ],
        child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: ProfileStatsCard()))),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('2 horas e 30 min'), findsOneWidget);
      expect(find.text('2 h no total'), findsOneWidget);
      // movie 4 has no runtime (TMDB fake returns none): left out and said so
      expect(find.textContaining('sem duração disponível'), findsOneWidget);
    });
  });
}
