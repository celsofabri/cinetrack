import '../models/favorite_doc.dart';
import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/profile_stats.dart';
import '../models/season_cache.dart';
import '../services/favorite_mapper.dart';
import '../services/watch_time.dart';
import 'activity_deriver.dart';
import 'period_key.dart';
import 'shared_profile_models.dart';
import 'shared_profile_validator.dart';

/// Recommended titles kept in the document (D9).
const kMaxSharedRecs = 50;

/// Builds the shared content from the user's documents (docs/82 §5): a pure
/// function of its arguments, recalculated in full every time (idempotent;
/// two devices with the same data build the same content). The result is
/// already limited by [SharedProfileValidator.clamp].
class SharedProfileBuilder {
  const SharedProfileBuilder._();

  static SharedProfileContent build(
    List<FavoriteDoc> docs, {
    required List<SeasonCache> Function(int tvId) catalog,
    int? Function(int movieId)? movieRuntime,
    int? Function(int tvId)? tvFallbackRuntime,
    required Set<SharedSection> sections,
    required DateTime now,
    required int tzMinutes,
    DateTime? actSince,
    DateTime? memberSince,
  }) {
    final tz = normalizeTz(tzMinutes);
    bool completed(FavoriteDoc d) => ProfileStats.isCompleted(d, catalog(d.id), now: now);
    final content = SharedProfileContent(
      tz: tz,
      stats: sections.contains(SharedSection.stats)
          ? stats(
              docs,
              catalog: catalog,
              movieRuntime: movieRuntime ?? (_) => null,
              tvFallbackRuntime: tvFallbackRuntime ?? (_) => null,
              isCompleted: completed,
              now: now,
              tzMinutes: tz,
              memberSince: memberSince,
            )
          : null,
      activity: sections.contains(SharedSection.activity)
          ? ActivityDeriver.derive(
              docs,
              actSince: actSince ?? now,
              now: now,
              isCompleted: completed,
            )
          : null,
      recs: sections.contains(SharedSection.recs) ? recs(docs) : null,
    );
    return SharedProfileValidator.clamp(content, now: now, actSince: actSince);
  }

  /// The `stats` section (docs/82 §5.2, B2/B3).
  static SharedStats stats(
    List<FavoriteDoc> docs, {
    required List<SeasonCache> Function(int tvId) catalog,
    required int? Function(int movieId) movieRuntime,
    required int? Function(int tvId) tvFallbackRuntime,
    required bool Function(FavoriteDoc doc) isCompleted,
    required DateTime now,
    required int tzMinutes,
    DateTime? memberSince,
  }) {
    final keys = periodKey(now, tzMinutes);
    var movies = 0, series = 0, watchedMovies = 0, watchedEpisodes = 0;
    var watchedSeries = 0, completedSeries = 0, undatedMovies = 0, undatedEpisodes = 0;
    DateTime? datedFrom;
    final done = <String>{};
    for (final doc in docs) {
      if (doc.mediaType == MediaType.movie) {
        movies++;
        if (doc.watchedMovie) {
          watchedMovies++;
          if (doc.lastWatchedAt == null) undatedMovies++;
        }
        continue;
      }
      series++;
      watchedEpisodes += doc.watchedEpisodes.length;
      if (doc.watchedEpisodes.isNotEmpty) watchedSeries++;
      if (isCompleted(doc)) {
        completedSeries++;
        done.add(doc.key);
      }
      for (final k in doc.watchedEpisodes) {
        final at = doc.markedAt(k);
        if (at == null) {
          undatedEpisodes++;
        } else if (datedFrom == null || at.isBefore(datedFrom)) {
          datedFrom = at;
        }
      }
    }
    final watch = WatchTimeCalculator.compute(
      docs,
      catalog: catalog,
      movieRuntime: movieRuntime,
      tvFallbackRuntime: tvFallbackRuntime,
    );
    PeriodStats period(String key, bool Function(PeriodKeys k) inPeriod) {
      bool dated(DateTime? at) => at != null && inPeriod(periodKey(at, tzMinutes));
      var pMovies = 0, pEpisodes = 0, pSeries = 0, pCompleted = 0;
      final restricted = <FavoriteDoc>[];
      for (final doc in docs) {
        if (doc.mediaType == MediaType.movie) {
          final counts = doc.watchedMovie && dated(doc.lastWatchedAt);
          if (counts) pMovies++;
          restricted.add(doc.copyWith(watchedMovie: counts));
          continue;
        }
        final inP = {
          for (final k in doc.watchedEpisodes)
            if (dated(doc.markedAt(k))) k,
        };
        pEpisodes += inP.length;
        if (inP.isNotEmpty) pSeries++;
        if (done.contains(doc.key) && dated(_conclusion(doc))) pCompleted++;
        restricted.add(doc.copyWith(watchedEpisodes: inP));
      }
      final t = WatchTimeCalculator.compute(
        restricted,
        catalog: catalog,
        movieRuntime: movieRuntime,
        tvFallbackRuntime: tvFallbackRuntime,
      );
      return PeriodStats(
        key: key,
        watchedMovies: pMovies,
        watchedEpisodes: pEpisodes,
        watchedSeries: pSeries,
        completedSeries: pCompleted,
        minutes: t.minutes,
        estimated: t.estimated,
        unknown: t.unknown,
      );
    }

    return SharedStats(
      total: TotalStats(
        favorites: docs.length,
        movies: movies,
        series: series,
        watchedMovies: watchedMovies,
        watchedEpisodes: watchedEpisodes,
        watchedSeries: watchedSeries,
        completedSeries: completedSeries,
        minutes: watch.minutes,
        estimated: watch.estimated,
        unknown: watch.unknown,
      ),
      year: period(keys.year, (k) => k.year == keys.year),
      month: period(keys.month, (k) => k.month == keys.month),
      undatedMovies: undatedMovies,
      undatedEpisodes: undatedEpisodes,
      datedFrom: datedFrom?.toUtc(),
      memberSince: memberSince?.toUtc(),
    );
  }

  /// Conclusion of a series = the latest date among its marked episodes
  /// (null: none dated, then it counts only in the total).
  static DateTime? _conclusion(FavoriteDoc doc) {
    DateTime? last;
    for (final k in doc.watchedEpisodes) {
      final at = doc.markedAt(k);
      if (at != null && (last == null || at.isAfter(last))) last = at;
    }
    return last;
  }

  /// The `recs` section (docs/82 §5.4): the order of the "Minhas
  /// recomendações" tab, first [kMaxSharedRecs], and the total.
  static SharedRecs recs(List<FavoriteDoc> docs) {
    final recommended = [
      for (final d in docs)
        if (d.recommended) FavoriteMapper.hydrate(d, const []),
    ]..sort(FavoriteItem.byRecentActivity);
    return SharedRecs(
      count: recommended.length,
      items: [
        for (final i in recommended.take(kMaxSharedRecs))
          RecItem(id: i.id, mediaType: i.mediaType.jsonValue, title: i.title, poster: i.posterPath),
      ],
    );
  }
}
