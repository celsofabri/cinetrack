import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/services/season_progress_calculator.dart';

void main() {
  EpisodeCache episode(int number, {bool watched = false, DateTime? airDate}) => EpisodeCache(
        episodeNumber: number,
        name: 'Episode $number',
        airDate: airDate,
        watched: watched,
      );

  group('SeasonProgressCalculator.compute', () {
    test('no episodes watched yields 0% and no crash', () {
      final season = SeasonCache(seasonNumber: 1, episodes: [
        episode(1),
        episode(2),
      ]);

      final progress = SeasonProgressCalculator.compute(season);

      expect(progress.watchedCount, 0);
      expect(progress.totalCount, 2);
      expect(progress.percent, 0);
      expect(progress.isNoneWatched, isTrue);
      expect(progress.isFullyWatched, isFalse);
    });

    test('partially watched season reports the right fraction and neither tristate extreme', () {
      final season = SeasonCache(seasonNumber: 1, episodes: [
        episode(1, watched: true),
        episode(2, watched: false),
        episode(3, watched: false),
        episode(4, watched: false),
      ]);

      final progress = SeasonProgressCalculator.compute(season);

      expect(progress.watchedCount, 1);
      expect(progress.totalCount, 4);
      expect(progress.percent, 25);
      expect(progress.isNoneWatched, isFalse);
      expect(progress.isFullyWatched, isFalse);
    });

    test('every episode watched yields 100% and isFullyWatched', () {
      final season = SeasonCache(seasonNumber: 1, episodes: [
        episode(1, watched: true),
        episode(2, watched: true),
      ]);

      final progress = SeasonProgressCalculator.compute(season);

      expect(progress.watchedCount, 2);
      expect(progress.totalCount, 2);
      expect(progress.percent, 100);
      expect(progress.isFullyWatched, isTrue);
      expect(progress.isNoneWatched, isFalse);
    });

    test('a season with zero episodes does not divide by zero', () {
      const season = SeasonCache(seasonNumber: 1, episodes: []);

      final progress = SeasonProgressCalculator.compute(season);

      expect(progress.totalCount, 0);
      expect(progress.watchedCount, 0);
      expect(progress.percent, 0);
      expect(progress.fraction, 0);
      // Nothing has aired, so it's "not fully watched" (vacuous truth would
      // be misleading here), and also "none watched".
      expect(progress.isFullyWatched, isFalse);
      expect(progress.isNoneWatched, isTrue);
    });

    test(
        'unaired episodes count toward the total (matches series-wide ProgressCalculator) '
        'but do not block isFullyWatched, since they can never be checked', () {
      final future = DateTime.now().add(const Duration(days: 30));
      final season = SeasonCache(seasonNumber: 1, episodes: [
        episode(1, watched: true),
        episode(2, watched: true),
        episode(3, watched: false, airDate: future), // not aired yet
      ]);

      final progress = SeasonProgressCalculator.compute(season);

      // Total includes the unaired episode, so percent isn't 100 yet...
      expect(progress.totalCount, 3);
      expect(progress.watchedCount, 2);
      expect(progress.percent, 67);
      // ...but the checkbox-driving flag only cares about what's aired.
      expect(progress.airedCount, 2);
      expect(progress.airedWatchedCount, 2);
      expect(progress.isFullyWatched, isTrue);
    });

    test('a season where nothing has aired yet is neither fully watched nor "started"', () {
      final future = DateTime.now().add(const Duration(days: 10));
      final season = SeasonCache(seasonNumber: 1, episodes: [
        episode(1, watched: false, airDate: future),
        episode(2, watched: false, airDate: future),
      ]);

      final progress = SeasonProgressCalculator.compute(season);

      expect(progress.airedCount, 0);
      expect(progress.isFullyWatched, isFalse);
      expect(progress.isNoneWatched, isTrue);
    });
  });
}
