import '../shared_profile/shared_profile_validator.dart';
import '../shared_profile/shared_stats_reading.dart';

/// The statistics the ranking compares (docs/90 RF-R2, D1), in the order of
/// the selector. [slug] is the value in the address (`?estatistica=`, T2) and
/// [cap] the ceiling of docs/82 §4.4 (the official app never writes more).
enum RankingMetric {
  episodes('episodios', kMaxSharedWatchedEpisodes),
  movies('filmes', kMaxSharedFavorites),
  series('series', kMaxSharedFavorites),
  completed('concluidas', kMaxSharedFavorites),
  hours('horas', kMaxSharedMinutes);

  const RankingMetric(this.slug, this.cap);

  final String slug;
  final int cap;

  /// This metric in [p]. Hours are stored (and ranked) in MINUTES (D14).
  int? of(PeriodReading p) => switch (this) {
    RankingMetric.episodes => p.watchedEpisodes,
    RankingMetric.movies => p.watchedMovies,
    RankingMetric.series => p.watchedSeries,
    RankingMetric.completed => p.completedSeries,
    RankingMetric.hours => p.minutes,
  };
}

/// The periods (D2), in the order of the selector; [slug] is `?periodo=`.
enum RankingPeriod {
  month('mes'),
  year('ano'),
  total('total');

  const RankingPeriod(this.slug);

  final String slug;
}
