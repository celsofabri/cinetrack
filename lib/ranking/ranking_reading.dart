import '../shared_profile/period_key.dart';
import '../shared_profile/shared_profile_texts.dart';
import '../shared_profile/shared_stats_reading.dart';
import 'ranking_models.dart';

/// Days after which a friend's line gets the "out of date" marker (D11):
/// strictly MORE than this many whole days (7 d 23:59:59 has no marker).
const kRankingStaleDays = 7;

/// One participant's numbers as the ranking reads them at one instant
/// (docs/91 §5.3): `(metric, period) -> int?` (null = unknown, "—"), plus
/// the out-of-date marker and where the dates note applies.
class RankingStats {
  final Map<(RankingMetric, RankingPeriod), int?> _values;

  /// `updatedAt` absent, `calc` unreadable / < 1, or older than
  /// [kRankingStaleDays] whole days (O6). The table never shows it on "Você".
  final bool stale;

  /// Whole days since `updatedAt` at the ranking's "agora"; null = unknown.
  final int? staleDays;

  /// [SharedProfileTexts.notePlacementFor] at the ranking's "agora".
  final ({bool month, bool year}) undatedPlacement;

  const RankingStats._(this._values, {required this.stale, this.staleDays, required this.undatedPlacement});

  int? value(RankingMetric m, RankingPeriod p) => _values[(m, p)];
}

/// How a stored period key compares with the owner's current one (O4).
enum _Key { current, past, unknown }

final _monthKey = RegExp(r'^\d{4}-(0[1-9]|1[0-2])$');
final _yearKey = RegExp(r'^\d{4}$');

/// The strict reader of the ranking (RF-L1..RF-L4). Pure; never throws:
/// any input becomes a number or unknown.
class RankingReading {
  const RankingReading._();

  /// The ranking's reading of one participant at [now] (the "agora" of O5).
  ///
  /// [stats] is already strict for a friend (`SharedStatsReading.read`,
  /// hotfix A2 ceilings); for "Você" pass it through [fromOwn] first.
  static RankingStats read(
    SharedStatsReading stats, {
    required int tz,
    required DateTime? updatedAt,
    required int? calc,
    required DateTime now,
  }) {
    final zone = tz < kMinTzMinutes || tz > kMaxTzMinutes ? 0 : tz;
    final keys = periodKey(now, zone);
    final month = _classify(stats.month.key, keys.month, _monthKey);
    final year = _classify(stats.year.key, keys.year, _yearKey);
    final values = <(RankingMetric, RankingPeriod), int?>{};
    for (final m in RankingMetric.values) {
      final t = m.of(stats.total);
      final y = _period(year, m.of(stats.year));
      final mo = _period(month, m.of(stats.month));
      final ok = _coherent(
        t: t,
        y: y,
        m: mo,
        yearCurrent: year == _Key.current,
        monthCurrent: month == _Key.current,
        yearPast: year == _Key.past,
      );
      values[(m, RankingPeriod.total)] = ok ? t : null;
      values[(m, RankingPeriod.year)] = ok ? y : null;
      values[(m, RankingPeriod.month)] = ok ? mo : null;
    }
    final at = updatedAt?.toUtc();
    final days = at == null ? null : now.toUtc().difference(at).inDays;
    final c = calc;
    final stale = days == null || c == null || c < 1 || days > kRankingStaleDays;
    return RankingStats._(
      values,
      stale: stale,
      staleDays: days,
      undatedPlacement: SharedProfileTexts.notePlacementFor(
        undated: stats.undatedMovies + stats.undatedEpisodes,
        datedFrom: stats.datedFrom,
        updatedAt: at,
        tz: zone,
        now: now,
      ),
    );
  }

  /// "Você" as the friends see it (docs/91 §5.2): the own document's reader
  /// has no ceilings, so they are applied here.
  static SharedStatsReading fromOwn(SharedStatsReading s) => SharedStatsReading(
    favorites: s.favorites,
    movies: s.movies,
    series: s.series,
    total: _cap(s.total),
    month: _cap(s.month),
    year: _cap(s.year),
    undatedMovies: s.undatedMovies,
    undatedEpisodes: s.undatedEpisodes,
    datedFrom: s.datedFrom,
    memberSince: s.memberSince,
  );

  static PeriodReading _cap(PeriodReading p) => PeriodReading(
    key: p.key,
    watchedMovies: readCount(p.watchedMovies, max: RankingMetric.movies.cap),
    watchedEpisodes: readCount(p.watchedEpisodes, max: RankingMetric.episodes.cap),
    watchedSeries: readCount(p.watchedSeries, max: RankingMetric.series.cap),
    completedSeries: readCount(p.completedSeries, max: RankingMetric.completed.cap),
    minutes: readCount(p.minutes, max: RankingMetric.hours.cap),
  );

  /// Equal to the current key = the stored value; a VALID older key = 0 (the
  /// owner has not opened the app since the turn, docs/91 §7.2); absent,
  /// malformed or later (future) = unknown. Fixed-width formats, so the text
  /// comparison is the chronological one.
  static _Key _classify(String? key, String current, RegExp format) {
    if (key == null || !format.hasMatch(key)) return _Key.unknown;
    if (key == current) return _Key.current;
    return key.compareTo(current) < 0 ? _Key.past : _Key.unknown;
  }

  static int? _period(_Key k, int? stored) => switch (k) {
    _Key.current => stored,
    _Key.past => 0,
    _Key.unknown => null,
  };

  /// O3: month <= year <= total, comparing only the values of CURRENT keys
  /// (the 0 of an old key is never compared), and only known ones. A
  /// current month with an old year cannot come from the engine (it rewrites
  /// both at the turn): the metric is then unknown in every period.
  static bool _coherent({
    required int? t,
    required int? y,
    required int? m,
    required bool yearCurrent,
    required bool monthCurrent,
    required bool yearPast,
  }) {
    if (monthCurrent && yearPast) return false;
    bool le(int? a, int? b) => a == null || b == null || a <= b;
    if (yearCurrent && !le(y, t)) return false;
    if (monthCurrent && !le(m, t)) return false;
    if (monthCurrent && yearCurrent && !le(m, y)) return false;
    return true;
  }
}
