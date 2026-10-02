import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/services/tmdb_exception.dart';

import 'support/favorites_harness.dart';

/// `setSeasonWatched` behavior. Originally written against the Hive-backed
/// LocalStore fake; the assertions are unchanged, only the storage wiring
/// moved to the shared harness (cloud data source + season catalog).
void main() {
  late FavoritesHarness h;

  setUp(() => h = FavoritesHarness());

  group('FavoritesRepository.setSeasonWatched', () {
    test('marks every already-aired episode as watched and leaves unaired ones untouched',
        () async {
      final future = DateTime.now().add(const Duration(days: 30));
      await h.seedShow(seasons: [
        SeasonCache(seasonNumber: 1, episodes: [
          h.episode(1),
          h.episode(2),
          h.episode(3, airDate: future),
        ]),
      ]);

      await h.repo.setSeasonWatched(42, 1, watched: true);

      final saved = (await h.items()).single;
      final season = saved.seasons!.single;
      expect(season.episodes.firstWhere((e) => e.episodeNumber == 1).watched, isTrue);
      expect(season.episodes.firstWhere((e) => e.episodeNumber == 2).watched, isTrue);
      // Unaired episode is never flipped to watched by the bulk action.
      expect(season.episodes.firstWhere((e) => e.episodeNumber == 3).watched, isFalse);
      expect(saved.lastWatchedAt, isNotNull);
    });

    test('unmarks every aired episode when called with watched: false', () async {
      await h.seedShow(seasons: [
        SeasonCache(seasonNumber: 1, episodes: [
          h.episode(1, watched: true),
          h.episode(2, watched: true),
        ]),
      ]);

      await h.repo.setSeasonWatched(42, 1, watched: false);

      final season = (await h.items()).single.seasons!.single;
      expect(season.episodes.every((e) => !e.watched), isTrue);
    });

    test('only touches the targeted season, leaving other seasons as-is', () async {
      await h.seedShow(seasons: [
        SeasonCache(seasonNumber: 1, episodes: [h.episode(1)]),
        SeasonCache(seasonNumber: 2, episodes: [h.episode(1)]),
      ]);

      await h.repo.setSeasonWatched(42, 1, watched: true);

      final saved = (await h.items()).single;
      final season1 = saved.seasons!.firstWhere((s) => s.seasonNumber == 1);
      final season2 = saved.seasons!.firstWhere((s) => s.seasonNumber == 2);
      expect(season1.episodes.single.watched, isTrue);
      expect(season2.episodes.single.watched, isFalse);
    });

    test('fetches the season first when it was never opened/cached before', () async {
      await h.seedShow();
      h.api.seasonResult = SeasonCache(seasonNumber: 1, episodes: [h.episode(1), h.episode(2)]);

      await h.repo.setSeasonWatched(42, 1, watched: true);

      expect(h.api.seasonCalls, 1);
      final season = (await h.items()).single.seasons!.single;
      expect(season.episodes.every((e) => e.watched), isTrue);
    });

    test(
        'propagates the error and writes nothing when the season was '
        'never cached and fetching it fails (e.g. no connection)', () async {
      await h.seedShow(); // seasons: [] — nothing cached yet
      h.api.seasonError = TmdbException.network();

      // Must reach the caller unchanged — never swallowed into a silent
      // no-op, which from the UI would look like the checkbox "did nothing".
      await expectLater(
        () => h.repo.setSeasonWatched(42, 1, watched: true),
        throwsA(isA<TmdbException>()),
      );

      // No partial write: the bulk write only happens after loadSeason
      // returned, so a failure must leave the item exactly as it was.
      final saved = (await h.items()).single;
      expect(saved.seasons, isEmpty);
      expect(saved.lastWatchedAt, isNull);
      expect(h.api.seasonCalls, 1);
    });

    test('propagates a rate-limit error the same way, without writing', () async {
      await h.seedShow();
      h.api.seasonError = TmdbException.rateLimited();

      await expectLater(
        () => h.repo.setSeasonWatched(42, 1, watched: true),
        throwsA(isA<TmdbException>()),
      );

      final saved = (await h.items()).single;
      expect(saved.seasons, isEmpty);
      expect(saved.lastWatchedAt, isNull);
    });
  });
}
