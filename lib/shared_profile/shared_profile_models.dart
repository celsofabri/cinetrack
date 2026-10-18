/// Content of `shared_profiles/{uid}` (docs/82 §4.1, ADR-006). Pure values:
/// no Firebase types, dates are UTC `DateTime`.
library;

import 'safe_int.dart';
import 'shared_profile_validator.dart'
    show kMaxActivityCount, kMaxEpisodeNumber, kMaxSeasonNumber, kMaxSharedId;

/// Version of the document schema (`v`) and of the calculation (`calc`).
const kSharedSchemaVersion = 1;
const kSharedCalcVersion = 1;

/// A section the owner may share. Present in the document only while its
/// consent (`sharing.<name>`) is.
enum SharedSection {
  stats('stats'),
  activity('activity'),
  recs('recs');

  final String field;

  const SharedSection(this.field);

  static SharedSection? fromField(String field) {
    for (final s in values) {
      if (s.field == field) return s;
    }
    return null;
  }
}

/// The 7 numbers of a period (and of the total, which has 3 more).
class PeriodStats {
  /// `"YYYY"` (year) or `"YYYY-MM"` (month), owner's zone.
  final String key;
  final int watchedMovies;
  final int watchedEpisodes;
  final int watchedSeries;
  final int completedSeries;
  final int minutes;
  final int estimated;
  final int unknown;

  const PeriodStats({
    required this.key,
    this.watchedMovies = 0,
    this.watchedEpisodes = 0,
    this.watchedSeries = 0,
    this.completedSeries = 0,
    this.minutes = 0,
    this.estimated = 0,
    this.unknown = 0,
  });

  /// The metrics in a fixed order (validator and tests walk them).
  static const metricNames = [
    'watchedMovies',
    'watchedEpisodes',
    'watchedSeries',
    'completedSeries',
    'minutes',
    'estimated',
    'unknown',
  ];

  List<int> get metrics => [
    watchedMovies,
    watchedEpisodes,
    watchedSeries,
    completedSeries,
    minutes,
    estimated,
    unknown,
  ];

  PeriodStats withMetrics(List<int> m) => PeriodStats(
    key: key,
    watchedMovies: m[0],
    watchedEpisodes: m[1],
    watchedSeries: m[2],
    completedSeries: m[3],
    minutes: m[4],
    estimated: m[5],
    unknown: m[6],
  );

  Map<String, Object?> toJson() => {
    'key': key,
    for (var i = 0; i < metricNames.length; i++) metricNames[i]: metrics[i],
  };

  @override
  bool operator ==(Object other) =>
      other is PeriodStats && other.key == key && _listEq(other.metrics, metrics);

  @override
  int get hashCode => Object.hash(key, Object.hashAll(metrics));
}

class TotalStats {
  final int favorites;
  final int movies;
  final int series;
  final int watchedMovies;
  final int watchedEpisodes;
  final int watchedSeries;
  final int completedSeries;
  final int minutes;
  final int estimated;
  final int unknown;

  const TotalStats({
    this.favorites = 0,
    this.movies = 0,
    this.series = 0,
    this.watchedMovies = 0,
    this.watchedEpisodes = 0,
    this.watchedSeries = 0,
    this.completedSeries = 0,
    this.minutes = 0,
    this.estimated = 0,
    this.unknown = 0,
  });

  /// Same order as [PeriodStats.metrics].
  List<int> get metrics => [
    watchedMovies,
    watchedEpisodes,
    watchedSeries,
    completedSeries,
    minutes,
    estimated,
    unknown,
  ];

  TotalStats copyWith({int? favorites, int? movies, int? series, List<int>? metrics}) {
    final m = metrics ?? this.metrics;
    return TotalStats(
      favorites: favorites ?? this.favorites,
      movies: movies ?? this.movies,
      series: series ?? this.series,
      watchedMovies: m[0],
      watchedEpisodes: m[1],
      watchedSeries: m[2],
      completedSeries: m[3],
      minutes: m[4],
      estimated: m[5],
      unknown: m[6],
    );
  }

  Map<String, Object?> toJson() => {
    'favorites': favorites,
    'movies': movies,
    'series': series,
    for (var i = 0; i < PeriodStats.metricNames.length; i++) PeriodStats.metricNames[i]: metrics[i],
  };

  @override
  bool operator ==(Object other) =>
      other is TotalStats &&
      other.favorites == favorites &&
      other.movies == movies &&
      other.series == series &&
      _listEq(other.metrics, metrics);

  @override
  int get hashCode => Object.hash(favorites, movies, series, Object.hashAll(metrics));
}

/// The `stats` section (docs/82 §4.1, §5.2).
class SharedStats {
  final TotalStats total;
  final PeriodStats year;
  final PeriodStats month;

  /// Watched movies / episodes without a mark date: they count only in the
  /// total (B2).
  final int undatedMovies;
  final int undatedEpisodes;

  /// Earliest episode mark date that exists (null: none).
  final DateTime? datedFrom;

  /// "No CineTrack desde" (account creation, Firebase Auth metadata).
  final DateTime? memberSince;

  const SharedStats({
    required this.total,
    required this.year,
    required this.month,
    this.undatedMovies = 0,
    this.undatedEpisodes = 0,
    this.datedFrom,
    this.memberSince,
  });

  SharedStats copyWith({
    TotalStats? total,
    PeriodStats? year,
    PeriodStats? month,
    int? undatedMovies,
    int? undatedEpisodes,
    DateTime? datedFrom,
    DateTime? memberSince,
    bool clearDatedFrom = false,
    bool clearMemberSince = false,
  }) => SharedStats(
    total: total ?? this.total,
    year: year ?? this.year,
    month: month ?? this.month,
    undatedMovies: undatedMovies ?? this.undatedMovies,
    undatedEpisodes: undatedEpisodes ?? this.undatedEpisodes,
    datedFrom: clearDatedFrom ? null : (datedFrom ?? this.datedFrom),
    memberSince: clearMemberSince ? null : (memberSince ?? this.memberSince),
  );

  /// Absent dates are left out (never `null`).
  Map<String, Object?> toJson() => {
    'total': total.toJson(),
    'year': year.toJson(),
    'month': month.toJson(),
    'undatedMovies': undatedMovies,
    'undatedEpisodes': undatedEpisodes,
    if (datedFrom != null) 'datedFrom': datedFrom!.toUtc(),
    if (memberSince != null) 'memberSince': memberSince!.toUtc(),
  };

  @override
  bool operator ==(Object other) =>
      other is SharedStats &&
      other.total == total &&
      other.year == year &&
      other.month == month &&
      other.undatedMovies == undatedMovies &&
      other.undatedEpisodes == undatedEpisodes &&
      _dateEq(other.datedFrom, datedFrom) &&
      _dateEq(other.memberSince, memberSince);

  @override
  int get hashCode => Object.hash(
    total,
    year,
    month,
    undatedMovies,
    undatedEpisodes,
    datedFrom?.millisecondsSinceEpoch,
    memberSince?.millisecondsSinceEpoch,
  );
}

/// What happened (D1). Recommending is never an activity; `rated` is
/// reserved for phase 4.
enum ActivityType {
  favorited('favorited'),
  watchedMovie('watched_movie'),
  watchedEpisodes('watched_episodes'),
  completedSeries('completed_series');

  final String json;

  const ActivityType(this.json);

  static ActivityType? fromJson(Object? value) {
    for (final t in values) {
      if (t.json == value) return t;
    }
    return null;
  }
}

/// One derived activity (docs/82 §5.3).
class ActivityItem {
  final ActivityType type;
  final int id;

  /// `movie` or `tv`.
  final String mediaType;
  final String title;
  final String? poster;
  final DateTime at;

  /// Episodes in the group (episode activities only).
  final int? count;

  /// Highest (season, episode) of the group (episode activities only).
  final int? season;
  final int? episode;

  const ActivityItem({
    required this.type,
    required this.id,
    required this.mediaType,
    required this.title,
    required this.at,
    this.poster,
    this.count,
    this.season,
    this.episode,
  });

  bool get isEpisodes =>
      type == ActivityType.watchedEpisodes || type == ActivityType.completedSeries;

  ActivityItem copyWith({
    ActivityType? type,
    String? title,
    DateTime? at,
    int? count,
    int? season,
    int? episode,
    bool clearPoster = false,
  }) => ActivityItem(
    type: type ?? this.type,
    id: id,
    mediaType: mediaType,
    title: title ?? this.title,
    poster: clearPoster ? null : poster,
    at: at ?? this.at,
    count: count ?? this.count,
    season: season ?? this.season,
    episode: episode ?? this.episode,
  );

  Map<String, Object?> toJson() => {
    'type': type.json,
    'id': id,
    'mediaType': mediaType,
    'title': title,
    if (poster != null) 'poster': poster,
    'at': at.toUtc(),
    if (count != null) 'count': count,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
  };

  /// Defensive reader (docs/82 §4.4, transition #20): an item of an unknown
  /// type, or missing / mistyped fields, is IGNORED (null), never thrown.
  /// Numbers go through [readSafeInt] with the §4.4 ceilings (hotfix A2,
  /// docs/92): an id outside 1..[kMaxSharedId] drops the item; an
  /// out-of-range count/season/episode is unknown (null).
  static ActivityItem? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final type = ActivityType.fromJson(raw['type']);
    final mediaType = raw['mediaType'];
    final title = raw['title'];
    final at = raw['at'];
    final id = readSafeInt(raw['id'], min: 1, max: kMaxSharedId);
    if (type == null || id == null || title is! String || at is! DateTime) return null;
    if (mediaType != 'movie' && mediaType != 'tv') return null;
    final poster = raw['poster'];
    return ActivityItem(
      type: type,
      id: id,
      mediaType: mediaType as String,
      title: title,
      poster: poster is String ? poster : null,
      at: at.toUtc(),
      // Out of range (docs/82 §4.4) = unknown, as a mistyped value.
      count: readSafeInt(raw['count'], min: 1, max: kMaxActivityCount),
      season: readSafeInt(raw['season'], max: kMaxSeasonNumber),
      episode: readSafeInt(raw['episode'], max: kMaxEpisodeNumber),
    );
  }

  /// Every well-formed item of [raw], in order; anything else is skipped.
  static List<ActivityItem> parseList(Object? raw) => [
    if (raw is List)
      for (final item in raw) ?tryParse(item),
  ];

  @override
  bool operator ==(Object other) =>
      other is ActivityItem &&
      other.type == type &&
      other.id == id &&
      other.mediaType == mediaType &&
      other.title == title &&
      other.poster == poster &&
      _dateEq(other.at, at) &&
      other.count == count &&
      other.season == season &&
      other.episode == episode;

  @override
  int get hashCode => Object.hash(
    type,
    id,
    mediaType,
    title,
    poster,
    at.millisecondsSinceEpoch,
    count,
    season,
    episode,
  );

  @override
  String toString() =>
      '${type.json}($id${count == null ? '' : ',$count'}${season == null ? '' : ',T${season}E$episode'})';
}

/// One recommended title (`recs.items`).
class RecItem {
  final int id;
  final String mediaType;
  final String title;
  final String? poster;

  const RecItem({required this.id, required this.mediaType, required this.title, this.poster});

  Map<String, Object?> toJson() => {
    'id': id,
    'mediaType': mediaType,
    'title': title,
    if (poster != null) 'poster': poster,
  };

  @override
  bool operator ==(Object other) =>
      other is RecItem &&
      other.id == id &&
      other.mediaType == mediaType &&
      other.title == title &&
      other.poster == poster;

  @override
  int get hashCode => Object.hash(id, mediaType, title, poster);
}

/// The `recs` section: the first [items] in the order of the tab and the
/// total [count].
class SharedRecs {
  final int count;
  final List<RecItem> items;

  const SharedRecs({required this.count, required this.items});

  Map<String, Object?> toJson() => {
    'count': count,
    'items': [for (final i in items) i.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SharedRecs && other.count == count && _listEq(other.items, items);

  @override
  int get hashCode => Object.hash(count, Object.hashAll(items));
}

/// The calculated part of the document (no `v`, `updatedAt`, `sharing`,
/// `actSince`: those belong to the server / the toggles). Only the sections
/// that are being shared are non-null.
class SharedProfileContent {
  final int calc;
  final int tz;
  final SharedStats? stats;
  final List<ActivityItem>? activity;
  final SharedRecs? recs;

  const SharedProfileContent({
    this.calc = kSharedCalcVersion,
    required this.tz,
    this.stats,
    this.activity,
    this.recs,
  });

  Object? section(SharedSection s) => switch (s) {
    SharedSection.stats => stats?.toJson(),
    SharedSection.activity => activity == null ? null : [for (final a in activity!) a.toJson()],
    SharedSection.recs => recs?.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is SharedProfileContent &&
      other.calc == calc &&
      other.tz == tz &&
      other.stats == stats &&
      (other.activity == null) == (activity == null) &&
      _listEq(other.activity ?? const [], activity ?? const []) &&
      other.recs == recs;

  @override
  int get hashCode => Object.hash(calc, tz, stats, Object.hashAll(activity ?? const []), recs);
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _dateEq(DateTime? a, DateTime? b) =>
    a == null ? b == null : b != null && a.millisecondsSinceEpoch == b.millisecondsSinceEpoch;

/// The owner's own document: same safe reader, no ceilings (only the owner
/// writes there; the app clamps before writing).
int? _nonNegInt(Object? v) => readSafeInt(v);

/// Defensive readers of the stored sections (docs/82 §4.4, RF-F9): anything
/// malformed is null (the section is treated as absent), never thrown.
class SharedSectionParsers {
  const SharedSectionParsers._();

  static PeriodStats? period(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    if (key is! String) return null;
    final m = <int>[];
    for (final name in PeriodStats.metricNames) {
      final v = _nonNegInt(raw[name]);
      if (v == null) return null;
      m.add(v);
    }
    return PeriodStats(key: key).withMetrics(m);
  }

  static TotalStats? total(Object? raw) {
    if (raw is! Map) return null;
    final favorites = _nonNegInt(raw['favorites']);
    final movies = _nonNegInt(raw['movies']);
    final series = _nonNegInt(raw['series']);
    if (favorites == null || movies == null || series == null) return null;
    final m = <int>[];
    for (final name in PeriodStats.metricNames) {
      final v = _nonNegInt(raw[name]);
      if (v == null) return null;
      m.add(v);
    }
    return TotalStats(favorites: favorites, movies: movies, series: series).copyWith(metrics: m);
  }

  static SharedStats? stats(Object? raw) {
    if (raw is! Map) return null;
    final total = SharedSectionParsers.total(raw['total']);
    final year = period(raw['year']);
    final month = period(raw['month']);
    if (total == null || year == null || month == null) return null;
    final datedFrom = raw['datedFrom'];
    final memberSince = raw['memberSince'];
    return SharedStats(
      total: total,
      year: year,
      month: month,
      undatedMovies: _nonNegInt(raw['undatedMovies']) ?? 0,
      undatedEpisodes: _nonNegInt(raw['undatedEpisodes']) ?? 0,
      datedFrom: datedFrom is DateTime ? datedFrom.toUtc() : null,
      memberSince: memberSince is DateTime ? memberSince.toUtc() : null,
    );
  }

  static SharedRecs? recs(Object? raw) {
    if (raw is! Map) return null;
    final count = _nonNegInt(raw['count']);
    final items = raw['items'];
    if (count == null || items is! List) return null;
    return SharedRecs(
      count: count,
      items: [for (final i in items) ?_recItem(i)],
    );
  }

  /// Same safe id reader as the friend's (hotfix A2); the app writes ids in
  /// 1..[kMaxSharedId] only, so its own items read exactly as before.
  static RecItem? _recItem(Object? i) {
    if (i is! Map) return null;
    final id = readSafeInt(i['id'], min: 1, max: kMaxSharedId);
    final title = i['title'];
    final mediaType = i['mediaType'];
    if (id == null || title is! String) return null;
    if (mediaType != 'movie' && mediaType != 'tv') return null;
    final poster = i['poster'];
    return RecItem(
      id: id,
      mediaType: mediaType as String,
      title: title,
      poster: poster is String ? poster : null,
    );
  }
}
