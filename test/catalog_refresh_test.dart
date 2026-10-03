import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/activity_overlay.dart';
import 'package:cinetrack/data/firestore_favorites_data_source.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/catalog_sync_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/services/watch_time.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';

const _s1 = TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 2);

FavoriteDoc _tvDoc(int id,
        {Set<String> eps = const {}, List<TvSeasonSummary> summaries = const [_s1]}) =>
    FavoriteDoc(
      id: id,
      mediaType: MediaType.tv,
      title: 'S$id',
      posterPath: null,
      overview: '',
      addedAt: DateTime(2024),
      seasonSummaries: summaries,
      watchedEpisodes: eps,
    );

SeasonCache _season(int n, List<DateTime?> air, {int? runtime}) => SeasonCache(
      seasonNumber: n,
      episodes: [
        for (var i = 0; i < air.length; i++)
          EpisodeCache(
              episodeNumber: i + 1, name: 'E', airDate: air[i], watched: false, runtime: runtime),
      ],
    );

void main() {
  final clock = DateTime(2026, 10, 3, 12);
  late FavoritesHarness h;
  late FavoritesRepository repo;
  late DateTime now;

  setUp(() {
    h = FavoritesHarness();
    now = clock;
    repo =
        FavoritesRepository(api: h.api, store: h.store, dataSource: h.dataSource, now: () => now);
    h.api.tvDetails = {
      'seasons': [
        {'season_number': 1, 'name': 'T1', 'episode_count': 3},
        {'season_number': 2, 'name': 'T2', 'episode_count': 1},
      ]
    };
  });

  group('TTL refresh of the season catalog (fake clock)', () {
    test('airing show older than 24 h: newest season and new seasons are re-downloaded', () async {
      final future = now.add(const Duration(days: 10));
      await h.store.saveCatalogSeason(1, _season(1, [DateTime(2026, 9, 1), future]));
      h.store.fetchedAt[1] = now.subtract(const Duration(hours: 25));
      h.api.seasonsByNumber[1] = _season(1, [DateTime(2026, 9, 1), DateTime(2026, 9, 8)]);
      h.api.seasonsByNumber[2] = _season(2, [DateTime(2026, 9, 20)]);
      h.cloud.server['user-a'] = {
        '1-tv': _tvDoc(1, eps: {'1_1', '1_2'})
      };
      final docs = h.cloud.view('user-a').values.toList();

      expect(repo.docsNeedingCatalog(docs), hasLength(1));
      await repo.reconcileCatalog(repo.docsNeedingCatalog(docs));

      // the episode that was "to air" is now aired, and season 2 exists
      expect(h.store.readSeasonCatalog(1).map((s) => s.seasonNumber).toSet(), {1, 2});
      expect(
          h.store
              .readSeasonCatalog(1)
              .firstWhere((s) => s.seasonNumber == 1)
              .episodes
              .every((e) => !e.airDate!.isAfter(now)),
          isTrue);
      expect(h.cloud.view('user-a')['1-tv']!.seasonSummaries.map((s) => s.seasonNumber), [1, 2]);
      expect(h.store.fetchedAt[1], now);
      expect(repo.docsNeedingCatalog(h.cloud.view('user-a').values.toList()), isEmpty);
    });

    test('fresh catalog (< 24 h) is left alone; stale only after the TTL passes', () async {
      await h.store.saveCatalogSeason(1, _season(1, [now.add(const Duration(days: 3))]));
      h.store.fetchedAt[1] = now.subtract(const Duration(hours: 1));
      final docs = [_tvDoc(1)];
      expect(repo.docsNeedingCatalog(docs), isEmpty);
      now = now.add(const Duration(hours: 24));
      expect(repo.docsNeedingCatalog(docs), hasLength(1));
    });

    test('cache without a stamp (older app version) of an airing show is refreshed once', () async {
      await h.store.saveCatalogSeason(1, _season(1, [now.add(const Duration(days: 3))]));
      expect(repo.docsNeedingCatalog([_tvDoc(1)]), hasLength(1));
    });

    test('finished show: weekly check of the season list only, no season re-download', () async {
      await h.store.saveCatalogSeason(1, _season(1, [DateTime(2019), DateTime(2019)]));
      h.api.tvDetails = {
        'seasons': [
          {'season_number': 1, 'name': 'T1', 'episode_count': 2}
        ]
      };
      h.store.fetchedAt[1] = now.subtract(const Duration(days: 3));
      expect(repo.docsNeedingCatalog([_tvDoc(1)]), isEmpty);
      h.store.fetchedAt[1] = now.subtract(const Duration(days: 8));
      final docs = [_tvDoc(1)];
      expect(repo.docsNeedingCatalog(docs), hasLength(1));
      h.cloud.server['user-a'] = {'1-tv': docs.single};
      await repo.reconcileCatalog(docs);
      expect(h.api.tvDetailsCalls, 1);
      expect(h.api.seasonCalls, 0);
      expect(h.store.fetchedAt[1], now);
    });
  });

  group('no write for a stale run', () {
    test('account switched / run cancelled before the summaries are saved: nothing written',
        () async {
      await h.seedShow();
      var cancelled = false;
      h.api.onTvDetails = () => cancelled = true;
      h.api.seasonsByNumber[1] = _season(1, [DateTime(2020)]);
      await repo.reconcileCatalog([_tvDoc(42, summaries: const [])], isCancelled: () => cancelled);
      expect(h.cloud.view('user-a')['42-tv']!.seasonSummaries, isEmpty);
      expect(h.store.readSeasonCatalog(42), isEmpty);
    });

    test('unfavorited while running: nothing written', () async {
      await h.seedShow();
      var stale = false;
      h.api.onTvDetails = () => stale = true;
      await repo.reconcileCatalog([_tvDoc(42, summaries: const [])], isStale: (_) => stale);
      expect(h.cloud.view('user-a')['42-tv']!.seasonSummaries, isEmpty);
    });
  });

  test('partial offline catalog keeps its progress and stays in "Continue assistindo"', () async {
    await h.store.saveCatalogSeason(7, _season(1, [DateTime(2020), DateTime(2020)]));
    h.cloud.server['uid-ana'] = {
      '7-tv': _tvDoc(7, eps: {
        '1_1'
      }, summaries: const [
        _s1,
        TvSeasonSummary(seasonNumber: 2, name: 'T2', episodeCount: 5),
      ]),
    };
    h.api.seasonError = Exception('offline');
    final c = ProviderContainer(overrides: [
      ...cloudOverrides(
          auth: FakeAuthRepository(initialUser: kAna), cloud: h.cloud, store: h.store, api: h.api),
      catalogSyncDelayProvider.overrideWithValue((_) async {}),
    ]);
    addTearDown(c.dispose);
    c.listen(catalogSyncProvider, (_, __) {});
    c.listen(continueWatchingProvider, (_, __) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.read(catalogSyncProvider).failed, {7});
    expect(c.read(continueWatchingProvider).map((e) => e.id), [7]);
  });

  test('debounce: a burst of season saves re-hydrates the list a handful of times, not once each',
      () async {
    h.cloud.server['user-a'] = {
      for (var i = 1; i <= 100; i++) '$i-tv': _tvDoc(i),
    };
    Future<int> emissions(Duration debounce) async {
      final r = FavoritesRepository(
          api: h.api, store: h.store, dataSource: h.dataSource, catalogDebounce: debounce);
      var n = 0;
      final sub = r.watchAll().listen((_) => n++);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      n = 0;
      for (var i = 1; i <= 100; i++) {
        await h.store.saveCatalogSeason(i, _season(1, [DateTime(2020)]));
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await sub.cancel();
      return n;
    }

    final without = await emissions(Duration.zero);
    final with_ = await emissions(const Duration(milliseconds: 100));
    expect(without, 100);
    expect(with_, lessThan(10), reason: '100 saves -> $with_ re-hydrations (vs $without)');
    expect(with_, greaterThanOrEqualTo(2), reason: 'leading + trailing edge');
  });

  group('account switch resets the runtime bookkeeping', () {
    test('a title tried for account A is tried again for account B', () async {
      h.cloud.server['uid-ana'] = {
        '3-movie': FavoriteDoc(
            id: 3,
            mediaType: MediaType.movie,
            title: 'M',
            posterPath: null,
            overview: '',
            addedAt: DateTime(2024),
            watchedMovie: true),
      };
      h.cloud.server['uid-bruno'] = {...h.cloud.server['uid-ana']!};
      h.api.movieDetails = {}; // no runtime: stays pending, tried once per account
      final auth = FakeAuthRepository(initialUser: kAna);
      final c = ProviderContainer(overrides: [
        ...cloudOverrides(auth: auth, cloud: h.cloud, store: h.store, api: h.api),
        catalogSyncDelayProvider.overrideWithValue((_) async {}),
      ]);
      addTearDown(c.dispose);
      c.listen(catalogSyncProvider, (_, __) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.api.movieDetailsCalls, 1);

      auth.nextUser = kBruno;
      await auth.signInWithGoogle();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.api.movieDetailsCalls, 2);
      expect(c.read(catalogSyncProvider).runtimesLoading, isFalse);
    });
  });

  group('runtimes missing in catalogs saved by an older version', () {
    test('only seasons with watched episodes and no runtime are downloaded again', () async {
      await h.store.saveCatalogSeason(7, _season(1, [DateTime(2020), DateTime(2020)]));
      await h.store.saveCatalogSeason(7, _season(2, [DateTime(2020)]));
      final docs = [
        _tvDoc(7, eps: {'1_1', '1_2'})
      ];
      h.api.tvDetails = {'episode_run_time': <dynamic>[], 'seasons': <dynamic>[]};
      h.api.seasonsByNumber[1] = _season(1, [DateTime(2020), DateTime(2020)], runtime: 42);

      final before = WatchTimeCalculator.compute(docs,
          catalog: h.store.readSeasonCatalog,
          movieRuntime: h.store.readMovieRuntime,
          tvFallbackRuntime: h.store.readTvFallbackRuntime);
      expect(before.minutes, 0);
      expect(before.unknown, 2); // the card keeps warning

      final keys = repo.pendingRuntimes(docs);
      expect(keys, ['tv:7']);
      await repo.reconcileRuntimes(keys, docs: docs);

      expect(h.api.seasonCalls, 1, reason: 'season 2 has no watched episode: untouched');
      final after = WatchTimeCalculator.compute(docs,
          catalog: h.store.readSeasonCatalog,
          movieRuntime: h.store.readMovieRuntime,
          tvFallbackRuntime: h.store.readTvFallbackRuntime);
      expect(after.minutes, 84);
      expect(after.isExact, isTrue);
    });
  });

  group('Firestore data source overlay (pure part)', () {
    FavoriteDoc doc(DateTime? last) => FavoriteDoc(
        id: 1,
        mediaType: MediaType.tv,
        title: 'S',
        posterPath: null,
        overview: '',
        addedAt: DateTime(2024),
        lastWatchedAt: last);

    test('pending snapshot with a null server timestamp shows the local mark time', () {
      final overlay = ActivityOverlay()..stamp('1-tv', DateTime(2026, 10, 3));
      final shown = FirestoreFavoritesDataSource.withActivity(overlay, doc(null), pending: true);
      expect(shown.lastWatchedAt, DateTime(2026, 10, 3));
    });

    test('after the server acknowledges, its value is used and the stamp is gone', () {
      final overlay = ActivityOverlay()..stamp('1-tv', DateTime(2026, 10, 3));
      final acked = FirestoreFavoritesDataSource.withActivity(
          overlay, doc(DateTime(2026, 10, 3, 0, 0, 2)),
          pending: false);
      expect(acked.lastWatchedAt, DateTime(2026, 10, 3, 0, 0, 2));
      final later = FirestoreFavoritesDataSource.withActivity(overlay, doc(null), pending: true);
      expect(later.lastWatchedAt, isNull);
    });

    test('no stamp: the document is returned untouched', () {
      final d = doc(DateTime(2025));
      expect(
          identical(
              FirestoreFavoritesDataSource.withActivity(ActivityOverlay(), d, pending: true), d),
          isTrue);
    });
  });
}
