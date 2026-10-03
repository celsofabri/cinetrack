import '../models/episode_cache.dart';
import '../models/season_cache.dart';

class SeriesProgress {
  final int watchedCount;
  final int totalCount;
  final int? nextSeasonNumber;
  final EpisodeCache? nextEpisode;

  /// Every episode that has ALREADY aired is watched (and at least one has
  /// aired), ignoring "Specials" (season 0) as long as the show has regular
  /// seasons. Episodes that have not aired yet, or special episodes, do not
  /// block it. This is the rule behind the "Concluídos" group (docs/18);
  /// [isCompleted] is the stricter "all episodes, aired or not" used by the
  /// badge's numbers.
  final bool isCaughtUp;

  const SeriesProgress({
    required this.watchedCount,
    required this.totalCount,
    required this.nextSeasonNumber,
    required this.nextEpisode,
    this.isCaughtUp = false,
  });

  bool get isCompleted => totalCount > 0 && watchedCount == totalCount;
  bool get isStarted => watchedCount > 0;
}

/// Pure logic, kept out of widgets/providers so it can be unit tested
/// without booting Flutter.
class ProgressCalculator {
  const ProgressCalculator._();

  static SeriesProgress compute(List<SeasonCache> seasons) {
    final ordered = [...seasons]..sort((a, b) {
        // "Specials" (season 0) are ordered last.
        if (a.seasonNumber == 0) return 1;
        if (b.seasonNumber == 0) return -1;
        return a.seasonNumber.compareTo(b.seasonNumber);
      });

    var watched = 0;
    var total = 0;
    int? nextSeasonNumber;
    EpisodeCache? nextEpisode;
    var hasRegular = false;
    var regularAired = 0, regularAiredWatched = 0;
    var anyAired = 0, anyAiredWatched = 0;

    for (final season in ordered) {
      final isSpecial = season.seasonNumber == 0;
      if (!isSpecial && season.episodes.isNotEmpty) hasRegular = true;
      final episodesInOrder = [...season.episodes]
        ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));

      for (final episode in episodesInOrder) {
        total++;
        if (episode.hasAired) {
          anyAired++;
          if (episode.watched) anyAiredWatched++;
          if (!isSpecial) {
            regularAired++;
            if (episode.watched) regularAiredWatched++;
          }
        }
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
      isCaughtUp: hasRegular
          ? regularAired > 0 && regularAiredWatched == regularAired
          : anyAired > 0 && anyAiredWatched == anyAired,
    );
  }
}
