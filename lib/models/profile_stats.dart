import 'favorite_doc.dart';
import 'media_type.dart';
import 'season_cache.dart';
import '../services/favorite_mapper.dart';
import '../services/progress_calculator.dart';

/// Numbers shown on the profile. Always derived from the user's documents
/// (never stored as counters, so they cannot drift).
class ProfileStats {
  final int favorites;
  final int movies;
  final int series;
  final int watchedMovies;
  final int watchedEpisodes;
  final int completedSeries;

  const ProfileStats({
    this.favorites = 0,
    this.movies = 0,
    this.series = 0,
    this.watchedMovies = 0,
    this.watchedEpisodes = 0,
    this.completedSeries = 0,
  });

  /// [catalog] returns the cached seasons of a show (may be empty on a new
  /// device). A series is "completed" when every episode is watched: counted
  /// against the cached catalog when it covers all known seasons (same
  /// numbers as the progress badge), else against the season summaries
  /// stored with the favorite.
  factory ProfileStats.fromDocs(
    List<FavoriteDoc> docs, {
    required List<SeasonCache> Function(int tvId) catalog,
  }) {
    var movies = 0, series = 0, watchedMovies = 0, watchedEpisodes = 0, completed = 0;
    for (final doc in docs) {
      if (doc.mediaType == MediaType.movie) {
        movies++;
        if (doc.watchedMovie) watchedMovies++;
        continue;
      }
      series++;
      watchedEpisodes += doc.watchedEpisodes.length;
      if (_isCompleted(doc, catalog(doc.id))) completed++;
    }
    return ProfileStats(
      favorites: docs.length,
      movies: movies,
      series: series,
      watchedMovies: watchedMovies,
      watchedEpisodes: watchedEpisodes,
      completedSeries: completed,
    );
  }

  static bool _isCompleted(FavoriteDoc doc, List<SeasonCache> cached) {
    final summaries = doc.seasonSummaries;
    final cachedNumbers = {for (final s in cached) s.seasonNumber};
    final catalogCovers =
        cached.isNotEmpty && summaries.every((s) => cachedNumbers.contains(s.seasonNumber));
    if (catalogCovers) {
      final seasons = [
        for (final s in cached) FavoriteMapper.overlayWatched(s, doc.watchedEpisodes)
      ];
      return ProgressCalculator.compute(seasons).isCompleted;
    }
    final total = summaries.fold<int>(0, (sum, s) => sum + s.episodeCount);
    return total > 0 && doc.watchedEpisodes.length >= total;
  }
}
