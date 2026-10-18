import 'period_key.dart';
import 'safe_int.dart';
import 'shared_profile_models.dart';
import 'shared_profile_validator.dart';

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
      watchedMovies: readCount(raw['watchedMovies'], max: kMaxSharedFavorites),
      watchedEpisodes: readCount(raw['watchedEpisodes'], max: kMaxSharedWatchedEpisodes),
      watchedSeries: readCount(raw['watchedSeries'], max: kMaxSharedFavorites),
      completedSeries: readCount(raw['completedSeries'], max: kMaxSharedFavorites),
      minutes: readCount(raw['minutes'], max: kMaxSharedMinutes),
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

/// A whole number in 0..[max], else null (unknown, "—"). The ceilings are
/// those of docs/82 §4.4: the official app never writes more (it clamps),
/// so anything above was written by a modified client (hotfix A2, docs/92).
int? readCount(Object? v, {int max = kMaxSafeInt}) => readSafeInt(v, max: max);

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
      favorites: readCount(t['favorites'], max: kMaxSharedFavorites),
      movies: readCount(t['movies'], max: kMaxSharedFavorites),
      series: readCount(t['series'], max: kMaxSharedFavorites),
      total: PeriodReading.read(t),
      month: PeriodReading.read(raw['month']),
      year: PeriodReading.read(raw['year']),
      undatedMovies: readCount(raw['undatedMovies'], max: kMaxSharedFavorites) ?? 0,
      undatedEpisodes: readCount(raw['undatedEpisodes'], max: kMaxSharedWatchedEpisodes) ?? 0,
      datedFrom: date(raw['datedFrom']),
      memberSince: date(raw['memberSince']),
    );
  }
}

/// The recommended titles as a READER shows them (docs/81 RF-R1, RF-F9):
/// the number "Recomendações" (`recs.count`; null = unknown, "—") and the
/// listed titles in the owner's order. The owner's preview builds one from
/// [SharedRecs], so both screens use the same view.
class SharedRecsReading {
  /// `recs.count`: how many titles the owner recommends (null = unknown).
  final int? count;

  /// At most [kMaxSharedRecItems], well-formed only, posters sanitized.
  final List<RecItem> items;

  const SharedRecsReading({this.count, this.items = const []});

  factory SharedRecsReading.of(SharedRecs r) => SharedRecsReading(count: r.count, items: r.items);

  /// Lenient reader of a friend's `recs`: null only when it is not a map
  /// (the section is then treated as not shared). A malformed item (wrong
  /// type, id < 1, unknown media type, blank title) is left out; titles are
  /// cut at [kMaxSharedTitle]; a poster outside the
  /// TMDB path format is dropped (the title shows without it).
  static SharedRecsReading? read(Object? raw) {
    if (raw is! Map) return null;
    final items = raw['items'];
    return SharedRecsReading(
      count: readCount(raw['count'], max: kMaxSharedRecCount),
      items: [
        if (items is List)
          for (final i in items.take(kMaxSharedRecItems)) ?_item(i),
      ],
    );
  }

  static RecItem? _item(Object? raw) {
    if (raw is! Map) return null;
    final id = readSafeInt(raw['id'], min: 1, max: kMaxSharedId);
    final mediaType = raw['mediaType'];
    final title = raw['title'];
    if (id == null || title is! String || title.trim().isEmpty) return null;
    if (mediaType != 'movie' && mediaType != 'tv') return null;
    final poster = raw['poster'];
    return RecItem(
      id: id,
      mediaType: mediaType as String,
      // Same cap as the owner's validator (a modified client could store more).
      title: SharedProfileValidator.cutTitle(title),
      poster: SharedProfileValidator.sanitizePoster(poster is String ? poster : null),
    );
  }

  /// Titles counted in "Recomendações" but not listed: the "e mais N"
  /// footer (0 = no footer; also when the number is unknown).
  int get more {
    final c = count;
    if (c == null) return 0;
    final n = c - items.length;
    return n > 0 ? n : 0;
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

  /// Null = not shared.
  final SharedRecsReading? recs;

  const FriendSharedView({this.updatedAt, this.tz = 0, this.stats, this.activity, this.recs});

  static FriendSharedView parse(Map<String, dynamic> raw) {
    final updated = raw['updatedAt'];
    final activity = raw['activity'];
    return FriendSharedView(
      updatedAt: updated is DateTime ? updated.toUtc() : null,
      tz: readSafeInt(raw['tz'], min: kMinTzMinutes, max: kMaxTzMinutes) ?? 0,
      stats: SharedStatsReading.read(raw['stats']),
      activity: activity is List ? ActivityItem.parseList(activity) : null,
      recs: SharedRecsReading.read(raw['recs']),
    );
  }
}
