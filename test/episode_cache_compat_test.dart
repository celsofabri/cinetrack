import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/catalog_sync_providers.dart';
import 'package:cinetrack/screens/tv_details_screen.dart';
import 'package:cinetrack/services/favorite_mapper.dart';
import 'package:cinetrack/services/tmdb_exception.dart';
import 'package:cinetrack/widgets/episode_tile.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

// docs/45 item 2: the episode catalog gets optional fields (image, description)
// and an old cache keeps working and is enriched season by season, losing nothing.

/// What the catalog cache stored BEFORE docs/45 (exact keys, as Hive returned it).
Map<dynamic, dynamic> _oldJson(int n) => {
  'episodeNumber': n,
  'name': 'Antigo $n',
  'airDate': '2020-01-0${n}T00:00:00.000',
  'watched': false,
  'runtime': 40,
};

/// Real TMDB episode (field names/types checked against the live API, docs/45).
Map<String, dynamic> _tmdbEpisode(int n, {String? still = '/abc.jpg', String overview = 'Texto'}) =>
    {
      'air_date': '2020-01-0$n',
      'crew': [],
      'episode_number': n,
      'episode_type': 'standard',
      'guest_stars': [],
      'id': 1000 + n,
      'name': 'Novo $n',
      'overview': overview,
      'production_code': '',
      'runtime': 41,
      'season_number': 1,
      'show_id': 42,
      'still_path': still,
      'vote_average': 8.1,
      'vote_count': 10,
    };

void main() {
  group('EpisodeCache: compatible with the old cache', () {
    test('an old cached episode loads with defaults and loses nothing', () {
      final ep = EpisodeCache.fromJson(_oldJson(2));
      expect(ep.episodeNumber, 2);
      expect(ep.name, 'Antigo 2');
      expect(ep.airDate, DateTime(2020, 1, 2));
      expect(ep.runtime, 40);
      expect(ep.watched, isFalse);
      expect(ep.stillPath, isNull);
      expect(ep.overview, '');
      expect(ep.detailed, isFalse); // how an old season is recognized
    });

    test('a not-yet-enriched episode is stored exactly as before (no new keys)', () {
      final old = EpisodeCache.fromJson(_oldJson(1)).toJson();
      expect(old.keys.toSet(), {'episodeNumber', 'name', 'airDate', 'watched', 'runtime'});
    });

    test('survives the JSON round trip of the Hive box, enriched or not', () {
      final enriched = EpisodeCache.fromTmdb(_tmdbEpisode(1));
      final back = EpisodeCache.fromJson(
        Map<dynamic, dynamic>.from(jsonDecode(jsonEncode(enriched.toJson())) as Map),
      );
      expect(back.stillPath, '/abc.jpg');
      expect(back.overview, 'Texto');
      expect(back.detailed, isTrue);
      expect(back.runtime, 41);
      expect(back.name, 'Novo 1');
    });

    test('fromTmdb reads the real field names; no still / empty text stay absent', () {
      final ep = EpisodeCache.fromTmdb(_tmdbEpisode(3, still: null, overview: ''));
      expect(ep.stillPath, isNull);
      expect(ep.overview, '');
      expect(ep.detailed, isTrue); // TMDB answered: empty is real, no refetch loop
      expect(EpisodeCache.fromTmdb(_tmdbEpisode(1, still: '')).stillPath, isNull);
    });

    test('SeasonCache.needsDetails: any old episode; empty season never', () {
      final old = SeasonCache.fromJson({
        'seasonNumber': 1,
        'episodes': [_oldJson(1), _oldJson(2)],
      });
      expect(old.needsDetails, isTrue);
      expect(
        SeasonCache.fromTmdb({
          'season_number': 1,
          'episodes': [_tmdbEpisode(1)],
        }).needsDetails,
        isFalse,
      );
      expect(const SeasonCache(seasonNumber: 1, episodes: []).needsDetails, isFalse);
    });

    test('stripWatched / overlayWatched keep the new fields', () {
      final season = SeasonCache.fromTmdb({
        'season_number': 1,
        'episodes': [_tmdbEpisode(1)],
      });
      final stripped = FavoriteMapper.stripWatched(season).episodes.single;
      expect(stripped.stillPath, '/abc.jpg');
      expect(stripped.overview, 'Texto');
      expect(stripped.detailed, isTrue);
      final overlaid = FavoriteMapper.overlayWatched(season, {'1_1'}).episodes.single;
      expect(overlaid.watched, isTrue);
      expect(overlaid.stillPath, '/abc.jpg');
    });
  });

  group('loadSeason enriches an old cached season (docs/45)', () {
    late FavoritesHarness h;

    SeasonCache oldSeason(int number) => SeasonCache(
      seasonNumber: number,
      episodes: [
        for (final n in [1, 2]) EpisodeCache.fromJson(_oldJson(n)),
      ],
    );

    SeasonCache freshSeason(int number) => SeasonCache(
      seasonNumber: number,
      episodes: [
        for (final n in [1, 2]) EpisodeCache.fromTmdb(_tmdbEpisode(n)),
      ],
    );

    setUp(() async {
      h = FavoritesHarness();
      await h.seedShow(seasons: [oldSeason(1), oldSeason(2)]);
      // The user's progress lives in the cloud document, not in the catalog.
      h.cloud.server['user-a']!['42-tv'] = h.cloud.server['user-a']!['42-tv']!.copyWith(
        watchedEpisodes: {'1_1', '2_2'},
      );
    });

    test('downloads only the opened season, keeps what was watched, saves it', () async {
      h.api.seasonsByNumber[1] = freshSeason(1);

      final season = await h.repo.loadSeason(42, 1);

      expect(h.api.seasonCalls, 1); // one season, not the whole show
      expect(season.episodes.map((e) => e.name), ['Novo 1', 'Novo 2']);
      expect(season.episodes.first.stillPath, '/abc.jpg');
      expect(season.episodes.first.overview, 'Texto');
      expect(season.episodes.map((e) => e.watched), [true, false]); // 1_1 kept
      // Saved for next time; the other season is untouched (still old).
      final stored = h.store.readSeasonCatalog(42);
      expect(stored.firstWhere((s) => s.seasonNumber == 1).needsDetails, isFalse);
      expect(stored.firstWhere((s) => s.seasonNumber == 2).needsDetails, isTrue);
      expect(stored.every((s) => s.episodes.every((e) => !e.watched)), isTrue);
      // The document of the user is untouched.
      expect(h.cloud.view('user-a')['42-tv']!.watchedEpisodes, {'1_1', '2_2'});

      await h.repo.loadSeason(42, 1); // served from the enriched cache
      expect(h.api.seasonCalls, 1);
    });

    test('offline / failing TMDB: shows the old data, throws nothing, changes nothing', () async {
      h.api.seasonError = TmdbException.network();

      final season = await h.repo.loadSeason(42, 2);

      expect(season.episodes.map((e) => e.name), ['Antigo 1', 'Antigo 2']);
      expect(season.episodes.map((e) => e.watched), [false, true]); // 2_2 kept
      expect(
        h.store.readSeasonCatalog(42).firstWhere((s) => s.seasonNumber == 2).needsDetails,
        isTrue,
      );
      expect(h.cloud.view('user-a')['42-tv']!.watchedEpisodes, {'1_1', '2_2'});
      // Back online: the next open enriches it.
      h.api.seasonError = null;
      h.api.seasonsByNumber[2] = freshSeason(2);
      expect((await h.repo.loadSeason(42, 2)).episodes.first.stillPath, '/abc.jpg');
    });

    test('an empty answer from TMDB never replaces the cached episodes', () async {
      h.api.seasonsByNumber[1] = const SeasonCache(seasonNumber: 1, episodes: []);
      final season = await h.repo.loadSeason(42, 1);
      expect(season.episodes, hasLength(2));
      expect(
        h.store.readSeasonCatalog(42).firstWhere((s) => s.seasonNumber == 1).episodes,
        hasLength(2),
      );
    });

    test('a season already enriched makes no request', () async {
      await h.store.saveCatalogSeason(42, freshSeason(1));
      await h.repo.loadSeason(42, 1);
      expect(h.api.seasonCalls, 0);
    });

    test('NOT a favorite: nothing is cached (as before)', () async {
      h.api.seasonsByNumber[1] = freshSeason(1);
      final other = await h.repo.loadSeason(99, 1);
      expect(other.episodes.first.overview, 'Texto');
      expect(h.store.readSeasonCatalog(99), isEmpty);
    });
  });

  testWidgets('screen: opening an old-cache season shows the new layout, checks intact', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cloud = FakeCloud();
    final store = FakeLocalStore();
    final api = FakeTmdbApiClient();
    (cloud.server['uid-ana'] ??= {})['42-tv'] = FavoriteDoc(
      id: 42,
      mediaType: MediaType.tv,
      title: 'A Show',
      posterPath: null,
      overview: '',
      addedAt: DateTime(2024),
      watchedEpisodes: {'1_1'},
      seasonSummaries: const [
        TvSeasonSummary(seasonNumber: 1, name: 'Temporada 1', episodeCount: 2),
        TvSeasonSummary(seasonNumber: 2, name: 'Temporada 2', episodeCount: 2),
      ],
    );
    for (final n in [1, 2]) {
      await store.saveCatalogSeason(
        42,
        SeasonCache(
          seasonNumber: n,
          episodes: [
            for (final e in [1, 2]) EpisodeCache.fromJson(_oldJson(e)),
          ],
        ),
      );
    }
    store.fetchedAt[42] = DateTime.now();
    api.seasonsByNumber[1] = SeasonCache(
      seasonNumber: 1,
      episodes: [
        for (final n in [1, 2]) EpisodeCache.fromTmdb(_tmdbEpisode(n, overview: 'Sinopse $n')),
      ],
    );
    api.tvDetails = {'id': 42, 'name': 'A Show', 'overview': '', 'seasons': <dynamic>[]};

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...cloudOverrides(
            auth: FakeAuthRepository(initialUser: kAna),
            cloud: cloud,
            store: store,
            api: api,
          ),
          catalogSyncDelayProvider.overrideWithValue((_) async {}),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/tv/42',
            routes: [GoRoute(path: '/tv/:id', builder: (_, s) => const TvDetailsScreen(tvId: 42))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Temporada 1'));
    await tester.pumpAndSettle();

    expect(find.text('Sinopse 1'), findsOneWidget);
    expect(find.text('E1 · Novo 1'), findsOneWidget);
    final tiles = tester.widgetList<EpisodeTile>(find.byType(EpisodeTile)).toList();
    expect(tiles.map((t) => t.episode.watched), [true, false]); // progress intact
    expect(api.seasonCalls, 1); // only the season that was opened
    expect(cloud.view('uid-ana')['42-tv']!.watchedEpisodes, {'1_1'});
  });
}
