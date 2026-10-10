import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_profile_validator.dart';

/// docs/82 §4.4, layer D (D12/D16): the ceilings and the date margin live in
/// the app. Each row: [violations] reports it, [clamp] fixes it.
final _now = DateTime.utc(2026, 10, 10, 12);
final _since = DateTime.utc(2026, 10, 1);

const _total = TotalStats(
  favorites: 54,
  movies: 20,
  series: 34,
  watchedMovies: 12,
  watchedEpisodes: 300,
  watchedSeries: 10,
  completedSeries: 3,
  minutes: 20000,
  estimated: 5,
  unknown: 2,
);
const _year = PeriodStats(
  key: '2026',
  watchedMovies: 3,
  watchedEpisodes: 40,
  watchedSeries: 4,
  minutes: 2100,
);
const _month = PeriodStats(
  key: '2026-10',
  watchedMovies: 1,
  watchedEpisodes: 12,
  watchedSeries: 2,
  minutes: 600,
);

SharedStats _stats({
  TotalStats total = _total,
  PeriodStats year = _year,
  PeriodStats month = _month,
}) => SharedStats(total: total, year: year, month: month, undatedMovies: 2, undatedEpisodes: 260);

ActivityItem _act({
  ActivityType type = ActivityType.watchedEpisodes,
  int id = 1399,
  String mediaType = 'tv',
  String title = 'Série',
  String? poster = '/abc.jpg',
  DateTime? at,
  int? count = 4,
  int? season = 2,
  int? episode = 4,
}) => ActivityItem(
  type: type,
  id: id,
  mediaType: mediaType,
  title: title,
  poster: poster,
  at: at ?? DateTime.utc(2026, 10, 5),
  count: count,
  season: season,
  episode: episode,
);

SharedProfileContent _c({
  SharedStats? stats,
  List<ActivityItem>? activity,
  SharedRecs? recs,
  int tz = -180,
  int calc = 1,
}) => SharedProfileContent(calc: calc, tz: tz, stats: stats, activity: activity, recs: recs);

List<String> _v(SharedProfileContent c) =>
    SharedProfileValidator.violations(c, now: _now, actSince: _since);

SharedProfileContent _clamp(SharedProfileContent c) =>
    SharedProfileValidator.clamp(c, now: _now, actSince: _since);

void main() {
  test('a legal document has no violation and clamp keeps it as is', () {
    final c = _c(
      stats: _stats(),
      activity: [_act()],
      recs: const SharedRecs(
        count: 3,
        items: [RecItem(id: 1, mediaType: 'movie', title: 'A')],
      ),
    );
    expect(_v(c), isEmpty);
    expect(_clamp(c), c);
  });

  group('ceilings (teto)', () {
    test('favorites <= 100000 with movies + series == favorites', () {
      final c = _c(
        stats: _stats(total: _total.copyWith(favorites: 100001, movies: 50001, series: 50000)),
      );
      expect(_v(c), contains('total.favorites'));
      final t = _clamp(c).stats!.total;
      expect(t.favorites, kMaxSharedFavorites);
      expect(t.movies + t.series, t.favorites);
      expect(_v(_clamp(c)), isEmpty);
    });

    test('watchedEpisodes <= 1 000 000 and minutes <= 100 years', () {
      final big = _total.copyWith(metrics: [12, 1000001, 10, 3, 52560001, 5, 2]);
      final c = _c(stats: _stats(total: big));
      expect(_v(c), containsAll(['total.watchedEpisodes', 'total.minutes']));
      final t = _clamp(c).stats!.total;
      expect(t.watchedEpisodes, kMaxSharedWatchedEpisodes);
      expect(t.minutes, kMaxSharedMinutes);
    });

    test('coherence: watched <= owned, completed <= watched, estimated/unknown bounded', () {
      final bad = _total.copyWith(metrics: [21, 300, 35, 36, 20000, 301, 400]);
      final c = _c(stats: _stats(total: bad));
      expect(
        _v(c),
        containsAll([
          'total.watchedMovies',
          'total.watchedSeries',
          'total.completedSeries',
          'total.estimated',
          'total.unknown',
        ]),
      );
      expect(_v(_clamp(c)), isEmpty);
    });

    test('month <= year <= total, metric by metric', () {
      final c = _c(
        stats: _stats(
          year: _year.withMetrics([13, 40, 4, 0, 2100, 0, 0]),
          month: _month.withMetrics([1, 41, 2, 0, 600, 0, 0]),
        ),
      );
      expect(_v(c), containsAll(['year.watchedMovies', 'month.watchedEpisodes']));
      final s = _clamp(c).stats!;
      expect(s.year.watchedMovies, 12);
      expect(s.month.watchedEpisodes, 40);
    });

    test('negative numbers are refused and clamped to 0', () {
      final c = _c(stats: _stats(month: _month.withMetrics([-1, 0, 0, 0, 0, 0, 0])));
      expect(_v(c), contains('month.watchedMovies.negative'));
      expect(_clamp(c).stats!.month.watchedMovies, 0);
    });

    test('undated counters <= watched; calc 1..1000; tz -840..840', () {
      final c = _c(
        stats: _stats().copyWith(undatedMovies: 13, undatedEpisodes: 301),
        calc: 1001,
        tz: 900,
      );
      expect(_v(c), containsAll(['undatedMovies', 'undatedEpisodes', 'calc', 'tz']));
      final fixed = _clamp(c);
      expect(_v(fixed), isEmpty);
      expect(fixed.calc, kMaxCalc);
      expect(fixed.tz, 840);
    });
  });

  group('date margin (24 h)', () {
    test('a date beyond now + 24 h is refused and clamped to the margin', () {
      final late = _now.add(const Duration(hours: 25));
      final c = _c(
        stats: _stats().copyWith(datedFrom: late, memberSince: late),
        activity: [_act(at: late)],
      );
      expect(_v(c), containsAll(['datedFrom', 'memberSince', 'activity[0].at']));
      final fixed = _clamp(c);
      expect(fixed.activity!.single.at, _now.add(kSharedDateMargin));
      expect(fixed.stats!.datedFrom, _now.add(kSharedDateMargin));
      expect(_v(fixed), isEmpty);
    });

    test('exactly now + 24 h is accepted', () {
      final c = _c(activity: [_act(at: _now.add(kSharedDateMargin))]);
      expect(_v(c), isEmpty);
    });
  });

  group('list items (D16)', () {
    test('items outside the schema are reported', () {
      final c = _c(
        activity: [
          _act(id: 0),
          _act(mediaType: 'book'),
          _act(title: 'x' * 301),
          _act(poster: 'https://x/y.jpg'),
          _act(count: 0),
          _act(count: 5001),
          _act(season: 1001),
          _act(episode: 100001),
          _act(type: ActivityType.favorited, count: 1),
          _act(at: _since.subtract(const Duration(seconds: 1))),
        ],
      );
      final v = _v(c);
      for (final e in [
        'activity[0].id',
        'activity[1].mediaType',
        'activity[2].title',
        'activity[3].poster',
        'activity[4].count',
        'activity[5].count',
        'activity[6].season',
        'activity[7].episode',
        'activity[8].extra',
        'activity[9].actSince',
      ]) {
        expect(v, contains(e));
      }
      final fixed = _clamp(c);
      expect(_v(fixed), isEmpty);
      expect(
        fixed.activity,
        hasLength(7),
        reason: 'bad id/type and pre-consent items cannot be fixed',
      );
    });

    test('at most 10 activities and 50 recommended; count >= items', () {
      final c = _c(
        activity: [for (var i = 0; i < 11; i++) _act(id: 1 + i)],
        recs: SharedRecs(
          count: 10,
          items: [for (var i = 0; i < 51; i++) RecItem(id: 1 + i, mediaType: 'tv', title: 'R')],
        ),
      );
      expect(_v(c), containsAll(['activity.size', 'recs.items.size', 'recs.count']));
      final fixed = _clamp(c);
      expect(fixed.activity, hasLength(kMaxSharedActivities));
      expect(fixed.recs!.items, hasLength(kMaxSharedRecItems));
      expect(fixed.recs!.count, kMaxSharedRecItems);
      expect(_v(fixed), isEmpty);
    });

    test('recommended items: same formats as activities', () {
      final c = _c(
        recs: const SharedRecs(
          count: 2,
          items: [
            RecItem(id: 1000000000, mediaType: 'tv', title: 'R'),
            RecItem(id: 2, mediaType: 'tv', title: 'R', poster: '/ok space.jpg'),
          ],
        ),
      );
      expect(_v(c), containsAll(['recs[0].id', 'recs[1].poster']));
    });

    test('poster sanitizer', () {
      expect(SharedProfileValidator.sanitizePoster('/abc-1_2.jpg'), '/abc-1_2.jpg');
      expect(SharedProfileValidator.sanitizePoster('/a/b.jpg'), isNull);
      expect(SharedProfileValidator.sanitizePoster('/${'a' * 200}'), isNull);
      expect(SharedProfileValidator.sanitizePoster(null), isNull);
    });

    test('titles are cut without splitting an emoji', () {
      final title = '${'a' * 299}🎬';
      final c = _clamp(_c(activity: [_act(title: title)]));
      expect(c.activity!.single.title, 'a' * 299);
    });
  });

  test('period keys (rules format) cannot be fixed: reported', () {
    final c = _c(
      stats: _stats(
        year: _year.withMetrics(_year.metrics).copyKey('1970'),
        month: _month.copyKey('1970-01'),
      ),
    );
    expect(_v(c), containsAll(['year.key', 'month.key']));
    final mismatch = _c(stats: _stats(month: _month.copyKey('2025-10')));
    expect(_v(mismatch), contains('month.key'));
  });
}

extension on PeriodStats {
  PeriodStats copyKey(String key) => PeriodStats(
    key: key,
    watchedMovies: watchedMovies,
    watchedEpisodes: watchedEpisodes,
    watchedSeries: watchedSeries,
    completedSeries: completedSeries,
    minutes: minutes,
    estimated: estimated,
    unknown: unknown,
  );
}
