import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/shared_profile/shared_profile_doc.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_profile_texts.dart';
import 'package:cinetrack/shared_profile/shared_sync_policy.dart';

/// Pure parts of Fatia 2: texts (docs/81 RF-P11, RF-A8, RF-S3, RF-S4) and
/// the engine's decisions (docs/82 §6: "só grava se mudou", "não regredir",
/// pulse, month turn).
final _now = DateTime.utc(2026, 10, 15, 15); // 15/10/2026 12:00 in Sao Paulo
const _sp = -180;

SharedStats _stats({
  int minutes = 20000,
  int unknown = 0,
  int estimated = 0,
  int episodes = 300,
  String month = '2026-10',
  String year = '2026',
  int undated = 0,
  DateTime? datedFrom,
}) => SharedStats(
  total: TotalStats(
    favorites: 54,
    movies: 20,
    series: 34,
    watchedMovies: 12,
    watchedEpisodes: episodes,
    watchedSeries: 10,
    completedSeries: 3,
    minutes: minutes,
    estimated: estimated,
    unknown: unknown,
  ),
  year: PeriodStats(key: year, watchedEpisodes: 40, minutes: 2100),
  month: PeriodStats(key: month, watchedEpisodes: 12, minutes: 600),
  undatedEpisodes: undated,
  datedFrom: datedFrom,
);

SharedProfileDoc _server(SharedStats stats, {DateTime? updatedAt}) => SharedProfileDoc(
  sharing: {SharedSection.stats},
  updatedAt: updatedAt ?? _now,
  tz: _sp,
  stats: stats,
);

SharedProfileContent _next(SharedStats stats) => SharedProfileContent(tz: _sp, stats: stats);

ActivityItem _ep(int count, {int season = 2, int episode = 4}) => ActivityItem(
  type: count == 0 ? ActivityType.completedSeries : ActivityType.watchedEpisodes,
  id: 1,
  mediaType: 'tv',
  title: 'Série X',
  at: _now,
  count: count == 0 ? 3 : count,
  season: season,
  episode: episode,
);

void main() {
  group('"Atualizado há" (RF-P11)', () {
    final cases = <Duration, String>{
      const Duration(seconds: 30): 'Atualizado agora',
      const Duration(minutes: 59): 'Atualizado há 59 min',
      const Duration(minutes: 60): 'Atualizado há 1 h',
      const Duration(hours: 23, minutes: 59): 'Atualizado há 23 h',
      const Duration(hours: 24): 'Atualizado há 1 dia',
      const Duration(days: 40): 'Atualizado há 40 dias',
    };
    for (final MapEntry(key: age, value: text) in cases.entries) {
      test('$age -> $text', () {
        expect(SharedProfileTexts.updated(_now.subtract(age), _now), text);
      });
    }
  });

  test('activity sentences (RF-A8)', () {
    final base = ActivityItem(
      type: ActivityType.favorited,
      id: 9,
      mediaType: 'movie',
      title: 'Filme Y',
      at: _now,
    );
    expect(SharedProfileTexts.activity(base), 'Favoritou Filme Y');
    expect(
      SharedProfileTexts.activity(base.copyWith(type: ActivityType.watchedMovie)),
      'Assistiu Filme Y',
    );
    expect(SharedProfileTexts.activity(_ep(1, season: 1, episode: 3)), 'Assistiu T1E3 de Série X');
    expect(SharedProfileTexts.activity(_ep(4)), 'Assistiu 4 episódios de Série X, até T2E4');
    expect(SharedProfileTexts.activity(_ep(0)), 'Concluiu Série X');
    expect(SharedProfileTexts.ago(_now.subtract(const Duration(hours: 2)), _now), 'há 2 h');
  });

  group('"este mês" / "este ano" in the OWNER\'s zone (B1)', () {
    test('every reader sees the stored month while it is the owner\'s current one', () {
      final s = _stats();
      // 01/11/2026 02:30 UTC = 31/10 23:30 in Sao Paulo: still October for Ana.
      final reader = DateTime.utc(2026, 11, 1, 2, 30);
      expect(SharedProfileTexts.current(s.month, month: true, tz: _sp, now: reader), s.month);
    });

    test('a past month reads 0; December read in January: month and year 0', () {
      final s = _stats(month: '2026-09');
      final zero = SharedProfileTexts.current(s.month, month: true, tz: _sp, now: _now);
      expect(zero.watchedEpisodes, 0);
      expect(zero.key, '2026-10');
      final dec = _stats(month: '2026-12', year: '2026');
      final jan = DateTime.utc(2027, 1, 5, 15);
      expect(
        SharedProfileTexts.current(dec.month, month: true, tz: _sp, now: jan).watchedEpisodes,
        0,
      );
      expect(
        SharedProfileTexts.current(dec.year, month: false, tz: _sp, now: jan).watchedEpisodes,
        0,
      );
    });
  });

  group('note on dates (B2, RF-S4)', () {
    test('no undated marks: no note', () {
      expect(SharedProfileTexts.datesNote(_stats(), _sp), isNull);
    });

    test('with datedFrom: "Marcações feitas antes de 11/10/2026 contam só no total."', () {
      final s = _stats(undated: 260, datedFrom: DateTime.utc(2026, 10, 11, 22, 10));
      expect(
        SharedProfileTexts.datesNote(s, _sp),
        'Marcações feitas antes de 11/10/2026 contam só no total.',
      );
      final place = SharedProfileTexts.notePlacement(s, updatedAt: _now, tz: _sp, now: _now);
      expect(place, (month: true, year: true));
    });

    test('without datedFrom: the generic note, placed by updatedAt', () {
      final s = _stats(undated: 300);
      expect(
        SharedProfileTexts.datesNote(s, _sp),
        'Marcações anteriores a esta versão contam só no total.',
      );
      final place = SharedProfileTexts.notePlacement(
        s,
        updatedAt: DateTime.utc(2026, 3, 1),
        tz: _sp,
        now: _now,
      );
      expect(place, (month: false, year: true));
    });
  });

  group('SharedSyncPolicy.decide', () {
    test('equal content, fresh: nothing to write', () {
      final d = SharedSyncPolicy.decide(_server(_stats()), _next(_stats()), _now);
      expect(d.writes, isFalse);
    });

    test('one more episode: stats changed', () {
      final d = SharedSyncPolicy.decide(_server(_stats()), _next(_stats(episodes: 301)), _now);
      expect(d.changed, {SharedSection.stats});
      expect(d.pulse, isFalse);
    });

    test('the month key changing counts as a change', () {
      final d = SharedSyncPolicy.decide(_server(_stats()), _next(_stats(month: '2026-11')), _now);
      expect(d.changed, {SharedSection.stats});
    });

    test('"não regredir": same counts, less complete time (unknown 4) = no write', () {
      final d = SharedSyncPolicy.decide(
        _server(_stats(minutes: 20000, unknown: 0)),
        _next(_stats(minutes: 18000, unknown: 4)),
        _now,
      );
      expect(d.writes, isFalse);
      expect(SharedSyncPolicy.regresses(_stats(), _stats(minutes: 18000, estimated: 2)), isTrue);
    });

    test('more complete time (unknown 4 -> 0) is written', () {
      final d = SharedSyncPolicy.decide(
        _server(_stats(minutes: 18000, unknown: 4)),
        _next(_stats(minutes: 20000)),
        _now,
      );
      expect(d.changed, {SharedSection.stats});
    });

    test('pulse only when nothing changed and updatedAt > 24 h', () {
      final old = _now.subtract(const Duration(hours: 25));
      expect(
        SharedSyncPolicy.decide(_server(_stats(), updatedAt: old), _next(_stats()), _now).pulse,
        isTrue,
      );
      final recent = _now.subtract(const Duration(hours: 3));
      expect(
        SharedSyncPolicy.decide(_server(_stats(), updatedAt: recent), _next(_stats()), _now).pulse,
        isFalse,
      );
    });

    test('activity compared item by item', () {
      final server = SharedProfileDoc(
        sharing: {SharedSection.activity},
        updatedAt: _now,
        activity: [_ep(3)],
      );
      expect(
        SharedSyncPolicy.decide(
          server,
          SharedProfileContent(tz: _sp, activity: [_ep(3)]),
          _now,
        ).writes,
        isFalse,
      );
      expect(
        SharedSyncPolicy.decide(
          server,
          SharedProfileContent(tz: _sp, activity: [_ep(4)]),
          _now,
        ).changed,
        {SharedSection.activity},
      );
    });

    test('next month turn in the owner\'s zone', () {
      expect(
        SharedSyncPolicy.nextMonthTurn(DateTime.utc(2026, 11, 1, 2, 59), _sp),
        DateTime.utc(2026, 11, 1, 3),
      );
      expect(SharedSyncPolicy.nextMonthTurn(DateTime.utc(2026, 12, 31, 12), 0), DateTime.utc(2027));
    });
  });
}
