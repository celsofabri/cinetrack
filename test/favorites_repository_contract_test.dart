import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/services/tmdb_exception.dart';

import 'support/favorites_harness.dart';

/// Contract tests for the CURRENT behavior of [FavoritesRepository]
/// (favorite/unfavorite, movie watched, episode toggle, season cache,
/// `addTvShow` ordering). They were written before the cloud refactor and
/// only use the repository's public API, so the same assertions hold no
/// matter which storage sits behind it. `favorites_harness.dart` is the only
/// place that knows how to build the repository.
void main() {
  late FavoritesHarness h;

  setUp(() => h = FavoritesHarness());

  group('addMovie / addResult', () {
    test('favorites a movie with default progress fields', () async {
      await h.repo.addMovie(id: 7, title: 'Movie', posterPath: '/p.jpg', overview: 'Plot');

      final item = (await h.items()).single;
      expect(item.storageKey, '7-movie');
      expect(item.title, 'Movie');
      expect(item.posterPath, '/p.jpg');
      expect(item.overview, 'Plot');
      expect(item.watchedMovie, isFalse);
      expect(item.lastWatchedAt, isNull);
    });

    test('is idempotent: a second call keeps the original addedAt', () async {
      await h.repo.addMovie(id: 7, title: 'Movie', posterPath: null, overview: '');
      final first = (await h.items()).single;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await h.repo.addMovie(id: 7, title: 'Other title', posterPath: null, overview: '');

      final items = await h.items();
      expect(items, hasLength(1));
      expect(items.single.title, 'Movie');
      expect(items.single.addedAt, first.addedAt);
    });

    test('addResult dispatches by media type', () async {
      await h.repo.addResult(const SearchResult(
          id: 1, mediaType: MediaType.movie, title: 'M', posterPath: null, overview: ''));
      await h.repo.addResult(const SearchResult(
          id: 1, mediaType: MediaType.tv, title: 'T', posterPath: null, overview: ''));

      final keys = (await h.items()).map((i) => i.storageKey).toSet();
      // Same TMDB id, different media type: two distinct favorites.
      expect(keys, {'1-movie', '1-tv'});
    });
  });

  group('addTvShow', () {
    test('favorites the show with season summaries from /tv/{id}', () async {
      h.api.tvDetails = {
        'seasons': [
          {'season_number': 2, 'name': 'Season 2', 'episode_count': 8},
          {'season_number': 0, 'name': 'Specials', 'episode_count': 3},
          {'season_number': 1, 'name': 'Season 1', 'episode_count': 10},
          {'season_number': 3, 'name': 'Empty', 'episode_count': 0},
        ],
      };

      await h.repo.addTvShow(id: 5, title: 'Show', posterPath: null, overview: 'o');

      final item = (await h.items()).single;
      expect(item.storageKey, '5-tv');
      expect(item.seasons, isEmpty);
      // Sorted, specials last, empty seasons dropped.
      expect(item.seasonSummaries!.map((s) => s.seasonNumber), [1, 2, 0]);
      expect(item.seasonSummaries!.first.episodeCount, 10);
      expect(h.api.tvDetailsCalls, 1);
    });

    test('still favorites the show (empty summaries) when /tv/{id} fails', () async {
      h.api.tvDetailsError = TmdbException.network();

      await h.repo.addTvShow(id: 5, title: 'Show', posterPath: null, overview: '');

      final item = (await h.items()).single;
      expect(item.title, 'Show');
      expect(item.seasonSummaries, isEmpty);
    });

    test('is idempotent and does not hit the API again when already favorited', () async {
      h.api.tvDetails = {'seasons': <dynamic>[]};
      await h.repo.addTvShow(id: 5, title: 'Show', posterPath: null, overview: '');
      await h.repo.addTvShow(id: 5, title: 'Show', posterPath: null, overview: '');

      expect(await h.items(), hasLength(1));
      expect(h.api.tvDetailsCalls, 1);
    });
  });

  group('reloadSeasonSummaries / remove', () {
    test('reloads summaries for a show favorited while offline', () async {
      h.api.tvDetailsError = TmdbException.network();
      await h.repo.addTvShow(id: 5, title: 'Show', posterPath: null, overview: '');
      expect((await h.items()).single.seasonSummaries, isEmpty);

      h.api.tvDetailsError = null;
      h.api.tvDetails = {
        'seasons': [
          {'season_number': 1, 'name': 'Season 1', 'episode_count': 4},
        ],
      };
      await h.repo.reloadSeasonSummaries(5);

      expect((await h.items()).single.seasonSummaries!.single.episodeCount, 4);
    });

    test('does nothing (no API call) for a show that is not a favorite', () async {
      await h.repo.reloadSeasonSummaries(99);

      expect(h.api.tvDetailsCalls, 0);
      expect(await h.items(), isEmpty);
    });

    test('remove deletes only the targeted media type', () async {
      await h.repo.addMovie(id: 1, title: 'M', posterPath: null, overview: '');
      h.api.tvDetails = {'seasons': <dynamic>[]};
      await h.repo.addTvShow(id: 1, title: 'T', posterPath: null, overview: '');

      await h.repo.remove(1, MediaType.movie);

      expect((await h.items()).map((i) => i.storageKey), ['1-tv']);
    });
  });

  group('toggleMovieWatched', () {
    test('flips watchedMovie back and forth', () async {
      await h.repo.addMovie(id: 1, title: 'M', posterPath: null, overview: '');

      await h.repo.toggleMovieWatched(1);
      expect((await h.items()).single.watchedMovie, isTrue);

      await h.repo.toggleMovieWatched(1);
      expect((await h.items()).single.watchedMovie, isFalse);
    });

    test('is a no-op for a movie that is not a favorite', () async {
      await h.repo.toggleMovieWatched(1);

      expect(await h.items(), isEmpty);
    });
  });

  group('loadSeason', () {
    test('returns the cached season without calling the API', () async {
      await h.seedShow(seasons: [
        SeasonCache(seasonNumber: 1, episodes: [h.episode(1), h.episode(2)]),
      ]);

      final season = await h.repo.loadSeason(42, 1);

      expect(season.episodes, hasLength(2));
      expect(h.api.seasonCalls, 0);
    });

    test('fetches from TMDB and caches it for the favorited show', () async {
      await h.seedShow();
      h.api.seasonResult = SeasonCache(seasonNumber: 1, episodes: [h.episode(1)]);

      await h.repo.loadSeason(42, 1);
      await h.repo.loadSeason(42, 1);

      expect(h.api.seasonCalls, 1); // second call served from cache
      expect((await h.items()).single.seasons!.single.seasonNumber, 1);
    });

    test('propagates a fetch error without touching the saved item', () async {
      await h.seedShow();
      h.api.seasonError = TmdbException.network();

      await expectLater(() => h.repo.loadSeason(42, 1), throwsA(isA<TmdbException>()));

      expect((await h.items()).single.seasons, isEmpty);
    });
  });

  group('toggleEpisodeWatched', () {
    test('flips one episode, leaves the others and stamps lastWatchedAt', () async {
      await h.seedShow(seasons: [
        SeasonCache(seasonNumber: 1, episodes: [h.episode(1), h.episode(2)]),
        SeasonCache(seasonNumber: 2, episodes: [h.episode(1)]),
      ]);

      await h.repo.toggleEpisodeWatched(42, 1, 2);

      final item = (await h.items()).single;
      final s1 = item.seasons!.firstWhere((s) => s.seasonNumber == 1);
      expect(s1.episodes.firstWhere((e) => e.episodeNumber == 1).watched, isFalse);
      expect(s1.episodes.firstWhere((e) => e.episodeNumber == 2).watched, isTrue);
      expect(item.seasons!.firstWhere((s) => s.seasonNumber == 2).episodes.single.watched, isFalse);
      expect(item.lastWatchedAt, isNotNull);

      await h.repo.toggleEpisodeWatched(42, 1, 2);
      final again = (await h.items()).single;
      expect(
        again.seasons!.first.episodes.firstWhere((e) => e.episodeNumber == 2).watched,
        isFalse,
      );
    });

    test('is a no-op for a show that is not a favorite', () async {
      await h.repo.toggleEpisodeWatched(42, 1, 1);

      expect(await h.items(), isEmpty);
    });
  });

  group('watchAll', () {
    test('emits the current list first and again after each change', () async {
      final emissions = <int>[];
      final sub = h.repo.watchAll().listen((items) => emissions.add(items.length));
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      await h.repo.addMovie(id: 1, title: 'M', posterPath: null, overview: '');
      await Future<void>.delayed(Duration.zero);
      await h.repo.remove(1, MediaType.movie);
      await Future<void>.delayed(Duration.zero);

      expect(emissions.first, 0);
      expect(emissions, containsAllInOrder([0, 1, 0]));
    });
  });
}
