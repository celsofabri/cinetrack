// Hotfix A2 (docs/91 §5, docs/92): the friend-side readers must read the
// same numbers on the VM and on the web (dart2js), where every integral JS
// number "is int" -- Infinity and 1e300 included.
//
// Runs on BOTH platforms (CI and locally):
//   flutter test test/shared_reading_web_safe_test.dart
//   flutter test --platform chrome test/shared_reading_web_safe_test.dart
// Keep it free of dart:io, Hive and platform plugins.
import 'package:cinetrack/services/watch_time.dart';
import 'package:cinetrack/shared_profile/period_key.dart';
import 'package:cinetrack/shared_profile/safe_int.dart';
import 'package:cinetrack/shared_profile/shared_profile_doc.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_profile_validator.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:cinetrack/widgets/shared_profile_widgets.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Built at run time, as the Firestore plugin delivers them (a JS number on
// the web, a double on the VM).
final inf = double.parse('Infinity');
final negInf = double.parse('-Infinity');
final nan = double.parse('NaN');
final huge = double.parse('1e300');
final twelve = double.parse('12.0');
final twelveAndHalf = double.parse('12.5');
final negZero = double.parse('-0.0');

const _metrics = [
  'watchedMovies',
  'watchedEpisodes',
  'watchedSeries',
  'completedSeries',
  'minutes',
];

Map<String, Object?> _period(String key, [Map<String, Object?> over = const {}]) => {
  'key': key,
  for (final m in _metrics) m: 0,
  'estimated': 0,
  'unknown': 0,
  ...over,
};

Map<String, Object?> _stats({
  Map<String, Object?> total = const {},
  Map<String, Object?> month = const {},
  Map<String, Object?> year = const {},
  Map<String, Object?> extra = const {},
}) => {
  'total': {
    'favorites': 1,
    'movies': 1,
    'series': 0,
    for (final m in _metrics) m: 0,
    'estimated': 0,
    'unknown': 0,
    ...total,
  },
  'month': _period('2026-10', month),
  'year': _period('2026', year),
  ...extra,
};

Map<String, Object?> _activity([Map<String, Object?> over = const {}]) => {
  'type': 'watched_episodes',
  'id': 10,
  'mediaType': 'tv',
  'title': 'Série',
  'at': DateTime.utc(2026, 10, 1),
  'count': 2,
  'season': 1,
  'episode': 3,
  ...over,
};

Map<String, Object?> _rec([Map<String, Object?> over = const {}]) => {
  'id': 7,
  'mediaType': 'movie',
  'title': 'Filme',
  ...over,
};

void main() {
  group('readSafeInt (same answer on VM and web)', () {
    test('rejects non-finite, fractional, negative and unsafe numbers', () {
      expect(readSafeInt(inf), isNull, reason: 'Infinity');
      expect(readSafeInt(negInf), isNull, reason: '-Infinity');
      expect(readSafeInt(nan), isNull, reason: 'NaN');
      expect(readSafeInt(huge), isNull, reason: '1e300');
      expect(readSafeInt(twelveAndHalf), isNull, reason: '12.5');
      expect(readSafeInt(-1), isNull, reason: '-1');
      expect(readSafeInt(double.parse('-1.0')), isNull, reason: '-1.0');
      expect(readSafeInt(9007199254740992), isNull, reason: '2^53');
      expect(readSafeInt(double.parse('9007199254740994')), isNull, reason: '2^53 + 2');
      expect(readSafeInt('12'), isNull, reason: 'string');
      expect(readSafeInt(null), isNull);
      expect(readSafeInt(true), isNull);
    });

    test('accepts whole numbers, whole doubles included', () {
      expect(readSafeInt(12), 12);
      expect(readSafeInt(twelve), 12, reason: '12.0 is 12 on both platforms');
      expect(readSafeInt(0), 0);
      expect(readSafeInt(kMaxSafeInt), kMaxSafeInt, reason: '2^53 - 1');
    });

    test('-0 reads as a plain 0 (on the web -0.0 "is int")', () {
      final z = readSafeInt(negZero);
      expect(z, 0);
      expect(z!.isNegative, isFalse);
      expect('$z', '0');
    });

    test('bounds are inclusive', () {
      expect(readSafeInt(5, max: 5), 5);
      expect(readSafeInt(6, max: 5), isNull);
      expect(readSafeInt(1, min: 1), 1);
      expect(readSafeInt(0, min: 1), isNull);
      expect(readSafeInt(-840, min: -840, max: 840), -840);
      expect(readSafeInt(-841, min: -840, max: 840), isNull);
      expect(readSafeInt(inf, min: -840, max: 840), isNull);
      expect(readSafeInt(negInf, min: -840, max: 840), isNull);
    });
  });

  group('friend statistics (docs/82 §4.4 ceilings)', () {
    SharedStatsReading read(Map<String, Object?> stats) => SharedStatsReading.read(stats)!;

    const totalCaps = {
      'favorites': kMaxSharedFavorites,
      'movies': kMaxSharedFavorites,
      'series': kMaxSharedFavorites,
      'watchedMovies': kMaxSharedFavorites,
      'watchedEpisodes': kMaxSharedWatchedEpisodes,
      'watchedSeries': kMaxSharedFavorites,
      'completedSeries': kMaxSharedFavorites,
      'minutes': kMaxSharedMinutes,
    };
    int? totalOf(SharedStatsReading r, String f) => switch (f) {
      'favorites' => r.favorites,
      'movies' => r.movies,
      'series' => r.series,
      'watchedMovies' => r.total.watchedMovies,
      'watchedEpisodes' => r.total.watchedEpisodes,
      'watchedSeries' => r.total.watchedSeries,
      'completedSeries' => r.total.completedSeries,
      'minutes' => r.total.minutes,
      _ => throw ArgumentError(f),
    };
    int? periodOf(PeriodReading p, String f) => switch (f) {
      'watchedMovies' => p.watchedMovies,
      'watchedEpisodes' => p.watchedEpisodes,
      'watchedSeries' => p.watchedSeries,
      'completedSeries' => p.completedSeries,
      'minutes' => p.minutes,
      _ => throw ArgumentError(f),
    };

    for (final e in totalCaps.entries) {
      test('total.${e.key}: ceiling ${e.value} kept, one more is unknown', () {
        expect(totalOf(read(_stats(total: {e.key: e.value})), e.key), e.value);
        expect(totalOf(read(_stats(total: {e.key: e.value + 1})), e.key), isNull);
        for (final bad in [inf, negInf, nan, huge, twelveAndHalf, -1]) {
          expect(totalOf(read(_stats(total: {e.key: bad})), e.key), isNull, reason: '$bad');
        }
        expect(totalOf(read(_stats(total: {e.key: twelve})), e.key), 12);
      });
    }

    for (final m in _metrics) {
      final cap = totalCaps[m]!;
      test('month/year.$m: ceiling $cap kept, one more is unknown', () {
        for (final which in ['month', 'year']) {
          Map<String, Object?> at(Object? v) => {m: v};
          PeriodReading p(Object? v) {
            final r = read(which == 'month' ? _stats(month: at(v)) : _stats(year: at(v)));
            return which == 'month' ? r.month : r.year;
          }

          expect(periodOf(p(cap), m), cap, reason: which);
          expect(periodOf(p(cap + 1), m), isNull, reason: which);
          expect(periodOf(p(inf), m), isNull, reason: which);
          expect(periodOf(p(huge), m), isNull, reason: which);
        }
      });
    }

    test('undated counts: ceilings, unknown reads as 0', () {
      final ok = read(
        _stats(
          extra: {
            'undatedMovies': kMaxSharedFavorites,
            'undatedEpisodes': kMaxSharedWatchedEpisodes,
          },
        ),
      );
      expect(ok.undatedMovies, kMaxSharedFavorites);
      expect(ok.undatedEpisodes, kMaxSharedWatchedEpisodes);
      final over = read(
        _stats(
          extra: {
            'undatedMovies': kMaxSharedFavorites + 1,
            'undatedEpisodes': kMaxSharedWatchedEpisodes + 1,
          },
        ),
      );
      expect(over.undatedMovies, 0);
      expect(over.undatedEpisodes, 0);
      final infinite = read(_stats(extra: {'undatedMovies': inf, 'undatedEpisodes': inf}));
      expect(infinite.undatedMovies, 0);
      expect(infinite.undatedEpisodes, 0);
    });
  });

  group('friend activity items', () {
    ActivityItem? parse(Map<String, Object?> over) => ActivityItem.tryParse(_activity(over));

    test('id: 1..$kMaxSharedId, else the item is ignored', () {
      expect(parse({'id': kMaxSharedId})!.id, kMaxSharedId);
      expect(parse({'id': 1})!.id, 1);
      expect(parse({'id': twelve})!.id, 12);
      for (final bad in [kMaxSharedId + 1, 0, -1, inf, negInf, nan, huge, twelveAndHalf]) {
        expect(parse({'id': bad}), isNull, reason: '$bad');
      }
    });

    test('count 1..$kMaxActivityCount, season 0..$kMaxSeasonNumber, '
        'episode 0..$kMaxEpisodeNumber; out of range = unknown', () {
      final ok = parse({
        'count': kMaxActivityCount,
        'season': kMaxSeasonNumber,
        'episode': kMaxEpisodeNumber,
      })!;
      expect(
        [ok.count, ok.season, ok.episode],
        [kMaxActivityCount, kMaxSeasonNumber, kMaxEpisodeNumber],
      );
      final low = parse({'count': 1, 'season': 0, 'episode': 0})!;
      expect([low.count, low.season, low.episode], [1, 0, 0]);
      final over = parse({
        'count': kMaxActivityCount + 1,
        'season': kMaxSeasonNumber + 1,
        'episode': kMaxEpisodeNumber + 1,
      })!;
      expect([over.count, over.season, over.episode], [null, null, null]);
      expect(parse({'count': 0})!.count, isNull);
      expect(parse({'season': -1})!.season, isNull);
      expect(parse({'episode': -1})!.episode, isNull);
      for (final bad in [inf, negInf, nan, huge, twelveAndHalf]) {
        final a = parse({'count': bad, 'season': bad, 'episode': bad})!;
        expect([a.count, a.season, a.episode], [null, null, null], reason: '$bad');
      }
      final whole = parse({'count': twelve, 'season': twelve, 'episode': twelve})!;
      expect([whole.count, whole.season, whole.episode], [12, 12, 12]);
    });
  });

  group('friend recommended titles', () {
    test('item id 1..$kMaxSharedId, else the item is left out', () {
      List<int> ids(List<Object?> items) =>
          SharedRecsReading.read({'count': 50, 'items': items})!.items.map((i) => i.id).toList();
      expect(
        ids([
          _rec({'id': kMaxSharedId}),
          _rec({'id': twelve}),
        ]),
        [kMaxSharedId, 12],
      );
      expect(
        ids([
          for (final bad in [kMaxSharedId + 1, 0, inf, nan, huge, twelveAndHalf]) _rec({'id': bad}),
        ]),
        isEmpty,
      );
    });

    test('count: ceiling $kMaxSharedRecCount', () {
      int? count(Object? v) => SharedRecsReading.read({'count': v, 'items': const []})!.count;
      expect(count(kMaxSharedRecCount), kMaxSharedRecCount);
      expect(count(kMaxSharedRecCount + 1), isNull);
      expect(count(twelve), 12);
      for (final bad in [inf, negInf, nan, huge, twelveAndHalf, -1]) {
        expect(count(bad), isNull, reason: '$bad');
      }
      expect(
        SharedRecsReading.read({
          'count': inf,
          'items': [_rec()],
        })!.more,
        0,
      );
    });
  });

  group('friend document', () {
    test('tz: $kMinTzMinutes..$kMaxTzMinutes, else 0 (UTC)', () {
      int tz(Object? v) => FriendSharedView.parse({'tz': v}).tz;
      expect(tz(kMaxTzMinutes), kMaxTzMinutes);
      expect(tz(kMinTzMinutes), kMinTzMinutes);
      expect(tz(kMaxTzMinutes + 1), 0);
      expect(tz(kMinTzMinutes - 1), 0);
      expect(tz(double.parse('-180.0')), -180);
      for (final bad in [inf, negInf, nan, huge, double.parse('-180.5')]) {
        expect(tz(bad), 0, reason: '$bad');
      }
    });

    test('a document full of Infinity reads as unknown everywhere', () {
      final view = FriendSharedView.parse({
        'tz': inf,
        'stats': _stats(
          total: {
            for (final m in [..._metrics, 'favorites', 'movies', 'series']) m: inf,
          },
          month: {for (final m in _metrics) m: huge},
        ),
        'activity': [
          _activity({'id': inf}),
          _activity({'count': inf, 'season': inf, 'episode': huge}),
        ],
        'recs': {
          'count': inf,
          'items': [
            _rec({'id': inf}),
            _rec(),
          ],
        },
      });
      expect(view.tz, 0);
      final s = view.stats!;
      expect([s.favorites, s.movies, s.series], [null, null, null]);
      expect([for (final m in _metrics) s.total.toJsonLike()[m]], everyElement(isNull));
      expect([for (final m in _metrics) s.month.toJsonLike()[m]], everyElement(isNull));
      expect(view.activity, hasLength(1));
      final a = view.activity!.single;
      expect([a.id, a.count, a.season, a.episode], [10, null, null, null]);
      expect(view.recs!.count, isNull);
      expect(view.recs!.items.map((i) => i.id), [7]);
    });
  });

  group('own document (owner side, no ceilings)', () {
    test('same safe reader: Infinity drops the section, 12.0 is 12', () {
      SharedStats? stats(Object? minutes) => SharedProfileDoc.parse({
        'sharing': {'stats': true},
        'stats': _stats(total: {'minutes': minutes}),
      })!.stats;
      expect(stats(kMaxSafeInt)!.total.minutes, kMaxSafeInt);
      expect(stats(twelve)!.total.minutes, 12);
      for (final bad in [inf, negInf, nan, huge, twelveAndHalf, -1]) {
        expect(stats(bad), isNull, reason: '$bad');
      }
    });
  });

  group('WatchTimeFormatter never throws', () {
    test('clamps at 2^53 - 1 minutes; the 100-year shared ceiling is untouched', () {
      expect(kMaxFormattedMinutes, kMaxSafeInt);
      expect(WatchTimeFormatter.format(kMaxSharedMinutes), '100 anos');
      expect(WatchTimeFormatter.accumulatedHours(kMaxSharedMinutes), '876.000 h no total');
      final top = WatchTimeFormatter.format(kMaxSafeInt);
      expect(top, startsWith('17136984883 anos'));
      expect(WatchTimeFormatter.format(9007199254740992), top, reason: '2^53');
      // Far above the ceiling (an int64 on the VM, an integral JS number on the web).
      expect(WatchTimeFormatter.format(kMaxSafeInt * 1000), top);
      expect(WatchTimeFormatter.format(kMaxSafeInt - 60), isNot(top));
      final hours = WatchTimeFormatter.accumulatedHours(kMaxSafeInt);
      expect(hours, '150.119.987.579.016 h no total');
      expect(WatchTimeFormatter.accumulatedHours(9007199254740992), hours);
      expect(WatchTimeFormatter.accumulatedHours(kMaxSafeInt * 1000), hours);
      expect(WatchTimeFormatter.format(-1), '0 min');
      expect(WatchTimeFormatter.accumulatedHours(-60), '0 h no total');
    });

    test('Infinity (only reachable on the web, where it "is int")', () {
      final Object v = inf;
      if (v is int) {
        expect(kIsWeb, isTrue);
        expect(WatchTimeFormatter.format(v), WatchTimeFormatter.format(kMaxSafeInt));
        expect(
          WatchTimeFormatter.accumulatedHours(v),
          WatchTimeFormatter.accumulatedHours(kMaxSafeInt),
        );
        final Object n = negInf;
        expect(WatchTimeFormatter.format(n as int), '0 min');
      } else {
        expect(kIsWeb, isFalse, reason: 'on the web Infinity "is int"');
      }
    });
  });

  group('friend profile statistics section (widget)', () {
    Future<void> pump(WidgetTester tester, SharedStatsReading reading) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SharedStatsView.reading(
              reading: reading,
              tz: -180,
              now: DateTime.utc(2026, 10, 18, 12),
            ),
          ),
        ),
      ),
    );

    testWidgets('a document with Infinity renders "—", no error widget', (tester) async {
      final view = FriendSharedView.parse({
        'tz': -180,
        'stats': _stats(
          total: {
            for (final m in [..._metrics, 'favorites', 'movies', 'series']) m: inf,
          },
          month: {for (final m in _metrics) m: inf},
          year: {for (final m in _metrics) m: huge},
        ),
      });
      await pump(tester, view.stats!);
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.textContaining('Infinity'), findsNothing);
      expect(find.textContaining('e+'), findsNothing);
      expect(find.text('Tempo assistido: —'), findsNWidgets(3));
      expect(find.text('—'), findsWidgets);
    });

    testWidgets('Infinity reaching the view directly (web) still renders', (tester) async {
      final Object v = inf;
      if (v is! int) return; // VM: an int cannot be Infinity
      await pump(
        tester,
        SharedStatsReading(
          total: PeriodReading(minutes: v),
          year: PeriodReading(key: '2026', minutes: v),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(
        find.text('Tempo assistido: ${WatchTimeFormatter.format(kMaxSafeInt)}'),
        findsNWidgets(2),
      );
    });
  });
}

extension on PeriodReading {
  Map<String, int?> toJsonLike() => {
    'watchedMovies': watchedMovies,
    'watchedEpisodes': watchedEpisodes,
    'watchedSeries': watchedSeries,
    'completedSeries': completedSeries,
    'minutes': minutes,
  };
}
