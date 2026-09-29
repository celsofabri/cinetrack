import '../models/season_cache.dart';

/// Progress for a single season.
class SeasonProgress {
  final int watchedCount;
  final int totalCount;
  final int airedCount;
  final int airedWatchedCount;

  const SeasonProgress({
    required this.watchedCount,
    required this.totalCount,
    required this.airedCount,
    required this.airedWatchedCount,
  });

  /// Fraction of ALL episodes (aired or not) that are watched — mirrors
  /// [ProgressCalculator]'s series-wide percentage, where an episode that
  /// hasn't aired yet still counts toward the total but can never be
  /// watched. A season only reaches 100% once every episode, future ones
  /// included, has aired and been watched. Guarded against divide-by-zero
  /// for a season with no episodes.
  double get fraction => totalCount == 0 ? 0 : watchedCount / totalCount;

  int get percent => (fraction * 100).round();

  /// True once every episode that HAS aired is watched, and at least one
  /// has aired. This (not [fraction]) drives the season-level checkbox:
  /// an unaired episode can never be checked, so it shouldn't block
  /// "fully watched" for what's actually available right now. A season
  /// with nothing aired yet is "not fully watched" (there's nothing to
  /// show as done), not vacuously true.
  bool get isFullyWatched => airedCount > 0 && airedWatchedCount == airedCount;

  /// True when nothing that has aired has been watched yet — including
  /// the case where nothing has aired at all.
  bool get isNoneWatched => airedWatchedCount == 0;
}

/// Pure logic, kept out of widgets/providers so it can be unit tested
/// without booting Flutter — same rationale as [ProgressCalculator], just
/// scoped to a single season instead of the whole series.
class SeasonProgressCalculator {
  const SeasonProgressCalculator._();

  static SeasonProgress compute(SeasonCache season) {
    var watched = 0;
    var aired = 0;
    var airedWatched = 0;

    for (final episode in season.episodes) {
      if (episode.watched) watched++;
      if (episode.hasAired) {
        aired++;
        if (episode.watched) airedWatched++;
      }
    }

    return SeasonProgress(
      watchedCount: watched,
      totalCount: season.episodes.length,
      airedCount: aired,
      airedWatchedCount: airedWatched,
    );
  }
}
