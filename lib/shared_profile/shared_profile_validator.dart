import 'period_key.dart';
import 'shared_profile_models.dart';

/// Ceilings of the shared profile (docs/82 §4.4, layer D). The rules check
/// only shape, `>= 0` on the ranking metrics, key formats, server time and
/// list sizes (expression limit, D12/D16); everything else lives HERE: the
/// app limits what it writes, it never refuses the user's action.
const kMaxCalc = 1000;
const kMaxSharedFavorites = 100000;
const kMaxSharedWatchedEpisodes = 1000000;

/// 100 years of minutes.
const kMaxSharedMinutes = 52560000;

/// How far ahead of "now" a date may be (clock skew margin).
const kSharedDateMargin = Duration(hours: 24);
const kMaxSharedTitle = 300;
const kMaxSharedPoster = 200;
const kMaxSharedId = 999999999;
const kMaxActivityCount = 5000;
const kMaxSeasonNumber = 1000;
const kMaxEpisodeNumber = 100000;
const kMaxSharedActivities = 10;
const kMaxSharedRecItems = 50;
const kMaxSharedRecCount = 100000;

final _posterPattern = RegExp(r'^/[A-Za-z0-9._-]+$');
final _yearPattern = RegExp(r'^20[0-9]{2}$');
final _monthPattern = RegExp(r'^20[0-9]{2}-(0[1-9]|1[0-2])$');

/// Dart mirror of the rules AND the ceilings the rules cannot afford
/// (docs/82 §4.4). [violations] is the oracle of the tests; [clamp] is what
/// the builder applies before anything is written.
class SharedProfileValidator {
  const SharedProfileValidator._();

  /// A poster path the readers may load, or null.
  static String? sanitizePoster(String? poster) =>
      poster != null && poster.length <= kMaxSharedPoster && _posterPattern.hasMatch(poster)
      ? poster
      : null;

  static bool validYearKey(String key) => _yearPattern.hasMatch(key);

  static bool validMonthKey(String key, String yearKey) =>
      _monthPattern.hasMatch(key) && key.split('-').first == yearKey;

  /// Every rule [content] breaks (empty = writable). [actSince] is the
  /// consent of "Atividades" (items before it are refused by the rules).
  static List<String> violations(
    SharedProfileContent content, {
    required DateTime now,
    DateTime? actSince,
  }) {
    final out = <String>[];
    final limit = now.toUtc().add(kSharedDateMargin);
    bool late(DateTime? at) => at != null && at.toUtc().isAfter(limit);
    if (content.calc < 1 || content.calc > kMaxCalc) out.add('calc');
    if (content.tz < kMinTzMinutes || content.tz > kMaxTzMinutes) out.add('tz');

    final stats = content.stats;
    if (stats != null) {
      final t = stats.total;
      if ([t.favorites, t.movies, t.series, ...t.metrics].any((n) => n < 0)) {
        out.add('total.negative');
      }
      if (t.favorites > kMaxSharedFavorites) out.add('total.favorites');
      if (t.movies + t.series != t.favorites) out.add('total.movies+series');
      if (t.watchedMovies > t.movies) out.add('total.watchedMovies');
      if (t.watchedSeries > t.series) out.add('total.watchedSeries');
      if (t.completedSeries > t.watchedSeries) out.add('total.completedSeries');
      if (t.watchedEpisodes > kMaxSharedWatchedEpisodes) out.add('total.watchedEpisodes');
      if (t.minutes > kMaxSharedMinutes) out.add('total.minutes');
      if (t.estimated > t.watchedEpisodes) out.add('total.estimated');
      if (t.unknown > t.watchedEpisodes + t.watchedMovies) out.add('total.unknown');
      for (final (name, p, upper) in [
        ('year', stats.year, t.metrics),
        ('month', stats.month, stats.year.metrics),
      ]) {
        for (var i = 0; i < p.metrics.length; i++) {
          if (p.metrics[i] < 0) out.add('$name.${PeriodStats.metricNames[i]}.negative');
          if (p.metrics[i] > upper[i]) out.add('$name.${PeriodStats.metricNames[i]}');
        }
      }
      if (!validYearKey(stats.year.key)) out.add('year.key');
      if (!validMonthKey(stats.month.key, stats.year.key)) out.add('month.key');
      if (stats.undatedMovies < 0 || stats.undatedMovies > t.watchedMovies) {
        out.add('undatedMovies');
      }
      if (stats.undatedEpisodes < 0 || stats.undatedEpisodes > t.watchedEpisodes) {
        out.add('undatedEpisodes');
      }
      if (late(stats.datedFrom)) out.add('datedFrom');
      if (late(stats.memberSince)) out.add('memberSince');
    }

    final activity = content.activity;
    if (activity != null) {
      if (activity.length > kMaxSharedActivities) out.add('activity.size');
      for (final (i, a) in activity.indexed) {
        out.addAll([
          for (final v in _itemViolations(a.id, a.mediaType, a.title, a.poster)) 'activity[$i].$v',
        ]);
        if (late(a.at)) out.add('activity[$i].at');
        if (actSince != null && a.at.isBefore(actSince)) out.add('activity[$i].actSince');
        if (a.isEpisodes) {
          if (a.count == null || a.count! < 1 || a.count! > kMaxActivityCount) {
            out.add('activity[$i].count');
          }
          if (a.season == null || a.season! < 0 || a.season! > kMaxSeasonNumber) {
            out.add('activity[$i].season');
          }
          if (a.episode == null || a.episode! < 0 || a.episode! > kMaxEpisodeNumber) {
            out.add('activity[$i].episode');
          }
        } else if (a.count != null || a.season != null || a.episode != null) {
          out.add('activity[$i].extra');
        }
      }
    }

    final recs = content.recs;
    if (recs != null) {
      if (recs.items.length > kMaxSharedRecItems) out.add('recs.items.size');
      if (recs.count < recs.items.length || recs.count > kMaxSharedRecCount) out.add('recs.count');
      for (final (i, r) in recs.items.indexed) {
        out.addAll([
          for (final v in _itemViolations(r.id, r.mediaType, r.title, r.poster)) 'recs[$i].$v',
        ]);
      }
    }
    return out;
  }

  static List<String> _itemViolations(int id, String mediaType, String title, String? poster) => [
    if (id < 1 || id > kMaxSharedId) 'id',
    if (mediaType != 'movie' && mediaType != 'tv') 'mediaType',
    if (title.length > kMaxSharedTitle) 'title',
    if (poster != null && sanitizePoster(poster) == null) 'poster',
  ];

  /// [content] limited to the table: numbers clamped into their ranges and
  /// made coherent (month <= year <= total), dates kept within the margin,
  /// titles cut, posters that do not match dropped, items that cannot be
  /// fixed (bad id/type, before the consent) left out, lists cut. Key
  /// formats cannot be fixed: [violations] still reports them.
  static SharedProfileContent clamp(
    SharedProfileContent content, {
    required DateTime now,
    DateTime? actSince,
  }) {
    final limit = now.toUtc().add(kSharedDateMargin);
    DateTime? capDate(DateTime? at) =>
        at == null ? null : (at.toUtc().isAfter(limit) ? limit : at.toUtc());
    return SharedProfileContent(
      calc: content.calc.clamp(1, kMaxCalc),
      tz: normalizeTz(content.tz),
      stats: content.stats == null ? null : _clampStats(content.stats!, capDate),
      activity: content.activity == null
          ? null
          : [
              for (final a in content.activity!)
                if (_fixable(a.id, a.mediaType) && (actSince == null || !a.at.isBefore(actSince)))
                  ActivityItem(
                    type: a.type,
                    id: a.id,
                    mediaType: a.mediaType,
                    title: _cut(a.title),
                    poster: sanitizePoster(a.poster),
                    at: capDate(a.at)!,
                    count: a.isEpisodes ? (a.count ?? 1).clamp(1, kMaxActivityCount) : null,
                    season: a.isEpisodes ? (a.season ?? 0).clamp(0, kMaxSeasonNumber) : null,
                    episode: a.isEpisodes ? (a.episode ?? 0).clamp(0, kMaxEpisodeNumber) : null,
                  ),
            ].take(kMaxSharedActivities).toList(),
      recs: content.recs == null ? null : _clampRecs(content.recs!),
    );
  }

  static SharedStats _clampStats(SharedStats s, DateTime? Function(DateTime?) capDate) {
    final t = s.total;
    final movies = t.movies.clamp(0, kMaxSharedFavorites);
    final series = t.series.clamp(0, kMaxSharedFavorites - movies);
    final watchedMovies = t.watchedMovies.clamp(0, movies);
    final watchedEpisodes = t.watchedEpisodes.clamp(0, kMaxSharedWatchedEpisodes);
    final watchedSeries = t.watchedSeries.clamp(0, series);
    final total = [
      watchedMovies,
      watchedEpisodes,
      watchedSeries,
      t.completedSeries.clamp(0, watchedSeries),
      t.minutes.clamp(0, kMaxSharedMinutes),
      t.estimated.clamp(0, watchedEpisodes),
      t.unknown.clamp(0, watchedEpisodes + watchedMovies),
    ];
    List<int> under(List<int> values, List<int> upper) => [
      for (var i = 0; i < values.length; i++) values[i].clamp(0, upper[i]),
    ];
    final year = under(s.year.metrics, total);
    final month = under(s.month.metrics, year);
    return SharedStats(
      total: t.copyWith(favorites: movies + series, movies: movies, series: series, metrics: total),
      year: s.year.withMetrics(year),
      month: s.month.withMetrics(month),
      undatedMovies: s.undatedMovies.clamp(0, watchedMovies),
      undatedEpisodes: s.undatedEpisodes.clamp(0, watchedEpisodes),
      datedFrom: capDate(s.datedFrom),
      memberSince: capDate(s.memberSince),
    );
  }

  static SharedRecs _clampRecs(SharedRecs r) {
    final items = [
      for (final i in r.items)
        if (_fixable(i.id, i.mediaType))
          RecItem(
            id: i.id,
            mediaType: i.mediaType,
            title: _cut(i.title),
            poster: sanitizePoster(i.poster),
          ),
    ].take(kMaxSharedRecItems).toList();
    return SharedRecs(count: r.count.clamp(items.length, kMaxSharedRecCount), items: items);
  }

  static bool _fixable(int id, String mediaType) =>
      id >= 1 && id <= kMaxSharedId && (mediaType == 'movie' || mediaType == 'tv');

  /// At most [kMaxSharedTitle] UTF-16 units, never splitting a surrogate pair.
  static String _cut(String title) {
    if (title.length <= kMaxSharedTitle) return title;
    var end = kMaxSharedTitle;
    final unit = title.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end--;
    return title.substring(0, end);
  }
}
