// Fixtures of the ranking's pure tests (docs/91 O1-O6). Pure: no dart:io,
// Hive or plugins, so the files that use it also run with
// `flutter test --platform chrome`.
import 'package:cinetrack/ranking/ranking_models.dart';
import 'package:cinetrack/ranking/ranking_table.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';

import 'js_roundtrip.dart';

/// "hoje" of docs/90: 12:00 in America/Sao_Paulo.
final kRankNow = DateTime.utc(2026, 10, 15, 15);
const kRankTz = -180;

const kMetricFields = {
  RankingMetric.movies: 'watchedMovies',
  RankingMetric.episodes: 'watchedEpisodes',
  RankingMetric.series: 'watchedSeries',
  RankingMetric.completed: 'completedSeries',
  RankingMetric.hours: 'minutes',
};

/// A `stats` map as the server stores it. [total], [month] and [year]
/// override fields (a `null` VALUE is stored as null; use [drop] to remove a
/// field). [monthKey] / [yearKey]: `#absent` removes the key.
Map<String, Object?> statsMap({
  Map<String, Object?> total = const {},
  Map<String, Object?> month = const {},
  Map<String, Object?> year = const {},
  Object? monthKey = '2026-10',
  Object? yearKey = '2026',
  Map<String, Set<String>> drop = const {},
  Map<String, Object?> extra = const {},
}) {
  Map<String, Object?> period(Object? key, Map<String, Object?> over, String name) => {
    if (key != #absent) 'key': key,
    for (final f in kMetricFields.values) f: 0,
    'estimated': 0,
    'unknown': 0,
    ...over,
  }..removeWhere((k, _) => drop[name]?.contains(k) ?? false);
  return {
    'total': {
      'favorites': 1,
      'movies': 1,
      'series': 0,
      for (final f in kMetricFields.values) f: 0,
      'estimated': 0,
      'unknown': 0,
      ...total,
    }..removeWhere((k, _) => drop['total']?.contains(k) ?? false),
    'month': period(monthKey, month, 'month'),
    'year': period(yearKey, year, 'year'),
    'undatedMovies': 0,
    'undatedEpisodes': 0,
    ...extra,
  };
}

/// The friend's snapshot as the app parses it. The numbers go through
/// [jsRoundTrip] when [viaJs] (a real JS object on Chrome; identity on the
/// VM); dates are added after it, as the plugin converts Timestamps.
FriendSharedView friendView(
  Map<String, Object?> stats, {
  DateTime? updatedAt,
  Object? tz = kRankTz,
  Object? calc = 1,
  bool viaJs = true,
  bool omitCalc = false,
}) {
  final rawStats = viaJs ? jsRoundTrip(stats) : stats;
  return FriendSharedView.parse({'updatedAt': ?updatedAt, 'tz': tz, if (!omitCalc) 'calc': calc, 'stats': rawStats});
}

RankingParticipant friendOf(
  String uid,
  String name,
  Map<String, Object?> stats, {
  DateTime? updatedAt,
  Object? tz = kRankTz,
  Object? calc = 1,
  bool viaJs = true,
  bool omitCalc = false,
}) => RankingParticipant.friend(
  uid: uid,
  name: name,
  view: friendView(stats, updatedAt: updatedAt, tz: tz, calc: calc, viaJs: viaJs, omitCalc: omitCalc),
)!;

/// A participant whose [metric] equals [v] in every period of the current
/// keys at [kRankNow] (null = unknown), fresh (not stale).
RankingParticipant simple(
  String uid,
  String name,
  int? v, {
  bool me = false,
  RankingMetric metric = RankingMetric.episodes,
}) {
  PeriodReading p(String? key) => PeriodReading(
    key: key,
    watchedMovies: metric == RankingMetric.movies ? v : 0,
    watchedEpisodes: metric == RankingMetric.episodes ? v : 0,
    watchedSeries: metric == RankingMetric.series ? v : 0,
    completedSeries: metric == RankingMetric.completed ? v : 0,
    minutes: metric == RankingMetric.hours ? v : 0,
  );
  return RankingParticipant(
    uid: uid,
    name: name,
    isMe: me,
    stats: SharedStatsReading(total: p(null), month: p('2026-10'), year: p('2026')),
    updatedAt: kRankNow,
    tz: kRankTz,
    calc: 1,
  );
}
