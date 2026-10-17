import 'shared_profile_models.dart';

/// The shared statistics as a READER shows them (docs/81 RF-F9): every
/// number is nullable. A field the document lacks (older schema), or whose
/// type is not the expected one (newer schema), is null and shows "—",
/// never 0. Unknown fields are ignored. The owner's preview builds one from
/// [SharedStats] (every number known), so both screens use the same view.
class PeriodReading {
  /// `"YYYY"` / `"YYYY-MM"` in the owner's zone; null = unknown.
  final String? key;
  final int? watchedMovies;
  final int? watchedEpisodes;
  final int? watchedSeries;
  final int? completedSeries;
  final int? minutes;

  const PeriodReading({
    this.key,
    this.watchedMovies,
    this.watchedEpisodes,
    this.watchedSeries,
    this.completedSeries,
    this.minutes,
  });

  /// A period that is not the owner's current one: nothing in it counts now.
  const PeriodReading.zero(String this.key)
    : watchedMovies = 0,
      watchedEpisodes = 0,
      watchedSeries = 0,
      completedSeries = 0,
      minutes = 0;

  factory PeriodReading.of(PeriodStats p) => PeriodReading(
    key: p.key,
    watchedMovies: p.watchedMovies,
    watchedEpisodes: p.watchedEpisodes,
    watchedSeries: p.watchedSeries,
    completedSeries: p.completedSeries,
    minutes: p.minutes,
  );

  /// Lenient reader: not a map = every field unknown.
  factory PeriodReading.read(Object? raw) {
    if (raw is! Map) return const PeriodReading();
    final key = raw['key'];
    return PeriodReading(
      key: key is String ? key : null,
      watchedMovies: readCount(raw['watchedMovies']),
      watchedEpisodes: readCount(raw['watchedEpisodes']),
      watchedSeries: readCount(raw['watchedSeries']),
      completedSeries: readCount(raw['completedSeries']),
      minutes: readCount(raw['minutes']),
    );
  }

  /// "Este mês" / "este ano" as every reader sees them (B1): the stored
  /// period when it is the owner's current one [currentKey], zeros when it
  /// is an older one, unknown ("—") when the stored key is unknown.
  PeriodReading current(String currentKey) {
    final k = key;
    if (k == null) return const PeriodReading();
    return k == currentKey ? this : PeriodReading.zero(currentKey);
  }
}

/// A non-negative int, else null (unknown).
int? readCount(Object? v) => v is int && v >= 0 ? v : null;

class SharedStatsReading {
  final int? favorites;
  final int? movies;
  final int? series;

  /// Totals (the period numbers plus the three favorites counts above).
  final PeriodReading total;
  final PeriodReading month;
  final PeriodReading year;

  /// Unknown counts read as 0: the dates note is simply not shown then.
  final int undatedMovies;
  final int undatedEpisodes;
  final DateTime? datedFrom;
  final DateTime? memberSince;

  const SharedStatsReading({
    this.favorites,
    this.movies,
    this.series,
    this.total = const PeriodReading(),
    this.month = const PeriodReading(),
    this.year = const PeriodReading(),
    this.undatedMovies = 0,
    this.undatedEpisodes = 0,
    this.datedFrom,
    this.memberSince,
  });

  factory SharedStatsReading.of(SharedStats s) => SharedStatsReading(
    favorites: s.total.favorites,
    movies: s.total.movies,
    series: s.total.series,
    total: PeriodReading(
      watchedMovies: s.total.watchedMovies,
      watchedEpisodes: s.total.watchedEpisodes,
      watchedSeries: s.total.watchedSeries,
      completedSeries: s.total.completedSeries,
      minutes: s.total.minutes,
    ),
    month: PeriodReading.of(s.month),
    year: PeriodReading.of(s.year),
    undatedMovies: s.undatedMovies,
    undatedEpisodes: s.undatedEpisodes,
    datedFrom: s.datedFrom,
    memberSince: s.memberSince,
  );

  /// Lenient reader of a friend's `stats`: null only when it is not a map
  /// (the section is then treated as not shared).
  static SharedStatsReading? read(Object? raw) {
    if (raw is! Map) return null;
    final total = raw['total'];
    final t = total is Map ? total : const {};
    DateTime? date(Object? v) => v is DateTime ? v.toUtc() : null;
    return SharedStatsReading(
      favorites: readCount(t['favorites']),
      movies: readCount(t['movies']),
      series: readCount(t['series']),
      total: PeriodReading.read(t),
      month: PeriodReading.read(raw['month']),
      year: PeriodReading.read(raw['year']),
      undatedMovies: readCount(raw['undatedMovies']) ?? 0,
      undatedEpisodes: readCount(raw['undatedEpisodes']) ?? 0,
      datedFrom: date(raw['datedFrom']),
      memberSince: date(raw['memberSince']),
    );
  }
}

/// What a friend shares, as their profile shows it (docs/82 §7.2). A
/// section is shown when its FIELD is in the document (the rules keep a
/// section and its consent together); an absent one is "não compartilha".
class FriendSharedView {
  final DateTime? updatedAt;

  /// The owner's zone in minutes (periods); unknown = UTC.
  final int tz;

  /// Null = not shared.
  final SharedStatsReading? stats;

  /// Null = not shared. Malformed / unknown items are already left out.
  final List<ActivityItem>? activity;

  const FriendSharedView({this.updatedAt, this.tz = 0, this.stats, this.activity});

  static FriendSharedView parse(Map<String, dynamic> raw) {
    final updated = raw['updatedAt'];
    final tz = raw['tz'];
    final activity = raw['activity'];
    return FriendSharedView(
      updatedAt: updated is DateTime ? updated.toUtc() : null,
      tz: tz is int && tz >= -840 && tz <= 840 ? tz : 0,
      stats: SharedStatsReading.read(raw['stats']),
      activity: activity is List ? ActivityItem.parseList(activity) : null,
    );
  }
}
