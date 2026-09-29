import '../models/episode_cache.dart';
import '../models/season_cache.dart';

class SeriesProgress {
  final int watchedCount;
  final int totalCount;
  final int? nextSeasonNumber;
  final EpisodeCache? nextEpisode;

  const SeriesProgress({
    required this.watchedCount,
    required this.totalCount,
    required this.nextSeasonNumber,
    required this.nextEpisode,
  });

  bool get isCompleted => totalCount > 0 && watchedCount == totalCount;
  bool get isStarted => watchedCount > 0;
}

/// Pure logic, kept out of widgets/providers so it can be unit tested
/// without booting Flutter.
class ProgressCalculator {
  const ProgressCalculator._();

  static SeriesProgress compute(List<SeasonCache> seasons) {
    final ordered = [...seasons]
      ..sort((a, b) {
        // "Specials" (season 0) are ordered last.
        if (a.seasonNumber == 0) return 1;
        if (b.seasonNumber == 0) return -1;
        return a.seasonNumber.compareTo(b.seasonNumber);
      });

    var watched = 0;
    var total = 0;
    int? nextSeasonNumber;
    EpisodeCache? nextEpisode;

    for (final season in ordered) {
      final episodesInOrder = [...season.episodes]
        ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));

      for (final episode in episodesInOrder) {
        total++;
        if (episode.watched) {
          watched++;
        } else if (nextEpisode == null && episode.hasAired) {
          nextEpisode = episode;
          nextSeasonNumber = season.seasonNumber;
        }
      }
    }

    return SeriesProgress(
      watchedCount: watched,
      totalCount: total,
      nextSeasonNumber: nextSeasonNumber,
      nextEpisode: nextEpisode,
    );
  }
}
