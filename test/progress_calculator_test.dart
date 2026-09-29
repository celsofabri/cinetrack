import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/services/progress_calculator.dart';

void main() {
  EpisodeCache episode(int number, {bool watched = false, DateTime? airDate}) => EpisodeCache(
        episodeNumber: number,
        name: 'Episode $number',
        airDate: airDate,
        watched: watched,
      );

  group('ProgressCalculator.compute', () {
    test('counts watched/total across seasons', () {
      final seasons = [
        SeasonCache(seasonNumber: 1, episodes: [
          episode(1, watched: true),
          episode(2, watched: true),
          episode(3, watched: true),
        ]),
        SeasonCache(seasonNumber: 2, episodes: [
          episode(1, watched: false),
        ]),
      ];

      final progress = ProgressCalculator.compute(seasons);

      expect(progress.watchedCount, 3);
      expect(progress.totalCount, 4);
      expect(progress.isStarted, isTrue);
      expect(progress.isCompleted, isFalse);
    });

    test('finds the next unwatched aired episode, in season/episode order', () {
      final seasons = [
        SeasonCache(seasonNumber: 1, episodes: [
          episode(1, watched: true),
          episode(2, watched: true),
        ]),
        SeasonCache(seasonNumber: 2, episodes: [
          episode(1, watched: false),
          episode(2, watched: false),
        ]),
      ];

      final progress = ProgressCalculator.compute(seasons);

      expect(progress.nextSeasonNumber, 2);
      expect(progress.nextEpisode?.episodeNumber, 1);
    });

    test('skips unaired episodes when picking the next episode', () {
      final future = DateTime.now().add(const Duration(days: 30));
      final seasons = [
        SeasonCache(seasonNumber: 1, episodes: [
          episode(1, watched: false, airDate: future),
          episode(2, watched: false),
        ]),
      ];

      final progress = ProgressCalculator.compute(seasons);

      expect(progress.nextEpisode?.episodeNumber, 2);
    });

    test('orders "specials" (season 0) last', () {
      final seasons = [
        SeasonCache(seasonNumber: 0, episodes: [episode(1, watched: false)]),
        SeasonCache(seasonNumber: 1, episodes: [episode(1, watched: false)]),
      ];

      final progress = ProgressCalculator.compute(seasons);

      expect(progress.nextSeasonNumber, 1);
    });

    test('reports completed when every episode is watched', () {
      final seasons = [
        SeasonCache(seasonNumber: 1, episodes: [episode(1, watched: true)]),
      ];

      final progress = ProgressCalculator.compute(seasons);

      expect(progress.isCompleted, isTrue);
      expect(progress.nextEpisode, isNull);
    });

    test('empty seasons list yields zeroed progress, not an error', () {
      final progress = ProgressCalculator.compute(const []);

      expect(progress.watchedCount, 0);
      expect(progress.totalCount, 0);
      expect(progress.isStarted, isFalse);
      expect(progress.isCompleted, isFalse);
    });
  });
}
