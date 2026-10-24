// Fatia 1 of the ranking (docs/96): the strict reader, oracles O2 (strict
// numbers), O3 (coherence) and O6 (stale marker) of docs/91, copied 1:1.
//
// Runs on BOTH platforms (CI and locally):
//   flutter test test/ranking_reading_test.dart
//   flutter test --platform chrome test/ranking_reading_test.dart
// On Chrome every document also goes through a real JS object
// (`jsify().dartify()`, support/js_roundtrip.dart), where every integral JS
// number "is int" -- Infinity and 1e300 included.
// Keep it free of dart:io, Hive and platform plugins.
import 'dart:convert';
import 'dart:math';

import 'package:cinetrack/ranking/ranking_models.dart';
import 'package:cinetrack/ranking/ranking_reading.dart';
import 'package:cinetrack/ranking/ranking_table.dart';
import 'package:cinetrack/ranking/ranking_texts.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';

import 'support/js_roundtrip.dart';
import 'support/ranking_fixtures.dart';

const _absent = #absent;

/// One stored value, built from several sources (docs/91 O2): Dart literal,
/// `jsonDecode` and `double.parse` / `double.infinity`.
class _V {
  final String label;
  final List<Object? Function()> sources;
  final int? Function(RankingMetric) expected;
  const _V(this.label, this.sources, this.expected);
}

String _label(Object? key) => key == _absent ? 'sem chave' : '$key';

final _generic = <_V>[
  _V('12', [() => 12, () => jsonDecode('12')], (_) => 12),
  _V('12.0 (double)', [() => 12.0, () => jsonDecode('12.0'), () => double.parse('12.0')], (_) => 12),
  _V('-0.0', [() => -0.0, () => jsonDecode('-0.0'), () => double.parse('-0.0')], (_) => 0),
  _V('12.5', [() => 12.5, () => jsonDecode('12.5'), () => double.parse('12.5')], (_) => null),
  _V('Infinity', [() => double.infinity, () => double.parse('Infinity')], (_) => null),
  _V('-Infinity', [() => double.negativeInfinity, () => double.parse('-Infinity')], (_) => null),
  _V('NaN', [() => double.nan, () => double.parse('NaN')], (_) => null),
  _V('1e300', [() => 1e300, () => jsonDecode('1e300'), () => double.parse('1e300')], (_) => null),
  _V('-1', [() => -1, () => jsonDecode('-1')], (_) => null),
  _V('2^53 + 2', [() => pow(2, 53) + 2, () => jsonDecode('9007199254740994')], (_) => null),
  _V('"12"', [() => '12', () => jsonDecode('"12"')], (_) => null),
  _V('true', [() => true, () => jsonDecode('true')], (_) => null),
  _V('null', [() => null, () => jsonDecode('null')], (_) => null),
  _V('ausente', [() => _absent], (_) => null),
];

/// Ceilings per metric (docs/82 §4.4) and the "wrong ceiling" rows.
final _ceilings = <_V>[
  _V('100000', [() => 100000, () => jsonDecode('100000')], (_) => 100000),
  _V(
    '100001',
    [() => 100001, () => jsonDecode('100001.0')],
    (m) => switch (m) {
      RankingMetric.episodes || RankingMetric.hours => 100001, // above the movies cap only
      _ => null,
    },
  ),
  _V(
    '1000000',
    [() => 1000000, () => double.parse('1000000')],
    (m) => switch (m) {
      RankingMetric.episodes || RankingMetric.hours => 1000000,
      _ => null,
    },
  ),
  _V('1000001', [() => 1000001, () => jsonDecode('1000001')], (m) => m == RankingMetric.hours ? 1000001 : null),
  _V('52560000', [() => 52560000, () => double.parse('52560000')], (m) => m == RankingMetric.hours ? 52560000 : null),
  _V('52560001', [() => 52560001, () => jsonDecode('52560001')], (_) => null),
];

/// The document for [v] stored in [metric] at [period]; the same metric in
/// the other periods keeps the cell coherent (O3), so only [v] decides.
Map<String, Object?> _docFor(RankingMetric metric, RankingPeriod period, Object? v) {
  final f = kMetricFields[metric]!;
  final cap = metric.cap;
  final cell = {if (v != _absent) f: v};
  final drop = {if (v == _absent) f};
  return switch (period) {
    RankingPeriod.total => statsMap(total: cell, drop: {'total': drop}),
    RankingPeriod.year => statsMap(total: {f: cap}, year: cell, drop: {'year': drop}),
    RankingPeriod.month => statsMap(total: {f: cap}, year: {f: cap}, month: cell, drop: {'month': drop}),
  };
}

int? _read(Map<String, Object?> stats, RankingMetric m, RankingPeriod p, {bool viaJs = true}) {
  final friend = friendOf('u1', 'Carla', stats, updatedAt: kRankNow, viaJs: viaJs);
  return RankingTable.rank([friend], m, p, kRankNow).rows.single.value;
}

void main() {
  group('O2 - leitor estrito (docs/91 §5.3)', () {
    test('no Chrome os documentos passam por um objeto JS de verdade', () {
      expect(jsRoundTripIsReal, kIsWeb);
      final back = jsRoundTrip({'v': double.parse('Infinity'), 'w': 12}) as Map;
      expect((back['v'] as num).isInfinite, isTrue);
      expect(back['w'], 12);
    });

    for (final v in [..._generic, ..._ceilings]) {
      for (final m in RankingMetric.values) {
        for (final p in RankingPeriod.values) {
          test('${v.label} em ${m.slug}/${p.slug}', () {
            for (final (i, source) in v.sources.indexed) {
              final doc = _docFor(m, p, source());
              final want = v.expected(m);
              expect(_read(doc, m, p), want, reason: 'fonte $i, via JS = $jsRoundTripIsReal');
              expect(_read(doc, m, p, viaJs: false), want, reason: 'fonte $i, literal');
            }
          });
        }
      }
    }

    test('-0.0 é mostrado como "0 …" (não negativo)', () {
      final v = _read(
        _docFor(RankingMetric.episodes, RankingPeriod.total, double.parse('-0.0')),
        RankingMetric.episodes,
        RankingPeriod.total,
      );
      expect(RankingTexts.value(RankingMetric.episodes, v), '0 episódios');
    });

    test('minha linha: filmes = 100001 em SharedStats é desconhecido (tetos reaplicados)', () {
      PeriodStats period(String key, int movies) => PeriodStats(key: key, watchedMovies: movies);
      for (final p in RankingPeriod.values) {
        final me = RankingParticipant.me(
          uid: 'me',
          name: 'Eu',
          stats: SharedStats(
            total: const TotalStats(watchedMovies: 100001, watchedEpisodes: 1000001, minutes: 52560001),
            year: period('2026', 100001),
            month: period('2026-10', 100001),
          ),
          updatedAt: kRankNow,
          tz: kRankTz,
          calc: 1,
        );
        final r = RankingTable.rank([me], RankingMetric.movies, p, kRankNow);
        expect(r.rows.single.value, isNull, reason: p.slug);
      }
      final me = RankingParticipant.me(
        uid: 'me',
        name: 'Eu',
        stats: const SharedStats(
          total: TotalStats(
            watchedMovies: 100000,
            watchedEpisodes: 1000001,
            watchedSeries: 100001,
            completedSeries: 100001,
            minutes: 52560001,
          ),
          year: PeriodStats(key: '2026'),
          month: PeriodStats(key: '2026-10'),
        ),
        updatedAt: kRankNow,
        tz: kRankTz,
      );
      final s = me.stats.total;
      expect(
        [s.watchedMovies, s.watchedEpisodes, s.watchedSeries, s.completedSeries, s.minutes],
        [100000, null, null, null, null],
      );
    });

    test('meu fuso fora de −840..840 lê como 0 (também para mim)', () {
      // 2026-10-31T10:00Z: em UTC ainda é outubro; com +900 seria novembro.
      final now = DateTime.utc(2026, 10, 31, 10);
      for (final tz in [900, -900]) {
        final r = RankingReading.read(
          SharedStatsReading(
            total: const PeriodReading(watchedEpisodes: 9),
            month: const PeriodReading(key: '2026-10', watchedEpisodes: 7),
            year: const PeriodReading(key: '2026', watchedEpisodes: 8),
          ),
          tz: tz,
          updatedAt: now,
          calc: 1,
          now: now,
        );
        expect(r.value(RankingMetric.episodes, RankingPeriod.month), 7, reason: 'tz $tz');
      }
    });
  });

  group('O2 - minha linha com o PRÓPRIO teto por métrica', () {
    test('minutos 1000001 e episódios 100001 ficam como estão (teto trocado mata)', () {
      final me = RankingParticipant.me(
        uid: 'me',
        name: 'Eu',
        stats: const SharedStats(
          total: TotalStats(watchedMovies: 100000, watchedEpisodes: 100001, minutes: 1000001),
          year: PeriodStats(key: '2026', watchedEpisodes: 100001, minutes: 1000001),
          month: PeriodStats(key: '2026-10', watchedEpisodes: 100001, minutes: 1000001),
        ),
        updatedAt: kRankNow,
        tz: kRankTz,
        calc: 1,
      );
      for (final p in RankingPeriod.values) {
        expect(RankingTable.rank([me], RankingMetric.hours, p, kRankNow).rows.single.value, 1000001, reason: p.slug);
        expect(RankingTable.rank([me], RankingMetric.episodes, p, kRankNow).rows.single.value, 100001, reason: p.slug);
      }
    });
  });

  group('O3 - coerência (docs/91 §5.3)', () {
    // agora = 2026-10-15T15:00Z, tz −180: atuais "2026-10"/"2026";
    // anteriores "2026-09"/"2025"; "ausente" = sem chave, ilegível ou futura.
    const cur = 'cur', prev = 'prev', none = 'none';
    const monthKeys = {
      cur: ['2026-10'],
      prev: ['2026-09'],
      none: [_absent, '2026-13', '2026-11'],
    };
    const yearKeys = {
      cur: ['2026'],
      prev: ['2025'],
      none: [_absent, '26', '2027'],
    };
    final rows = <(String, String, String, Object?, Object?, Object?, List<int?>)>[
      ('1', cur, cur, 100, 40, 10, [100, 40, 10]),
      ('2', cur, prev, 100, 40, 10, [null, null, null]),
      ('3', cur, none, 100, _absent, 10, [100, null, 10]),
      ('4', prev, cur, 100, 40, 10, [100, 40, 0]),
      ('5', prev, prev, 100, 40, 10, [100, 0, 0]),
      ('6', prev, none, 100, _absent, 10, [100, null, 0]),
      ('7', none, cur, 100, 40, _absent, [100, 40, null]),
      ('8', none, prev, 100, 40, _absent, [100, 0, null]),
      ('9', none, none, 100, _absent, _absent, [100, null, null]),
      ('10', cur, cur, 100, 40, 50, [null, null, null]),
      ('11', cur, cur, 100, 150, 10, [null, null, null]),
      ('12', cur, none, 100, _absent, 150, [null, null, null]),
      ('13', prev, cur, 100, 150, 999, [null, null, null]),
      ('14', prev, cur, 100, 40, 999, [100, 40, 0]),
      ('15', cur, cur, 12.5, 40, 10, [null, 40, 10]),
      ('16', cur, cur, 100, 1e300, 10, [100, null, 10]),
      ('17', cur, cur, 100, 1e300, 150, [null, null, null]),
      // Derived from row 2 ("combinação impossível pelo motor"): it does not
      // depend on the values, a current month of 0 included.
      ('2b', cur, prev, 100, 40, 0, [null, null, null]),
    ];
    for (final (id, mk, yk, t, y, mo, want) in rows) {
      for (final monthKey in monthKeys[mk]!) {
        for (final yearKey in yearKeys[yk]!) {
          test('linha $id (mês ${_label(monthKey)}, ano ${_label(yearKey)})', () {
            for (final m in RankingMetric.values) {
              final f = kMetricFields[m]!;
              final doc = statsMap(
                monthKey: monthKey,
                yearKey: yearKey,
                total: {if (t != _absent) f: t},
                year: {if (y != _absent) f: y},
                month: {if (mo != _absent) f: mo},
                drop: {
                  'year': {if (y == _absent) f},
                  'month': {if (mo == _absent) f},
                },
              );
              final got = [
                for (final p in [RankingPeriod.total, RankingPeriod.year, RankingPeriod.month]) _read(doc, m, p),
              ];
              expect(got, want, reason: m.slug);
            }
          });
        }
      }
    }

    test('linha 18: filmes incoerentes não afetam episódios', () {
      final doc = statsMap(
        total: {'watchedMovies': 100, 'watchedEpisodes': 100},
        year: {'watchedMovies': 40, 'watchedEpisodes': 40},
        month: {'watchedMovies': 50, 'watchedEpisodes': 10},
      );
      List<int?> all(RankingMetric m) => [
        for (final p in [RankingPeriod.total, RankingPeriod.year, RankingPeriod.month]) _read(doc, m, p),
      ];
      expect(all(RankingMetric.movies), [null, null, null]);
      expect(all(RankingMetric.episodes), [100, 40, 10]);
    });

    test('docs/90: período maior que o total (mês 50, ano 50, total 10)', () {
      final doc = statsMap(
        total: {'watchedMovies': 10, 'watchedEpisodes': 3},
        year: {'watchedMovies': 50, 'watchedEpisodes': 2},
        month: {'watchedMovies': 50, 'watchedEpisodes': 1},
      );
      for (final p in RankingPeriod.values) {
        expect(_read(doc, RankingMetric.movies, p), isNull, reason: p.slug);
      }
      expect(_read(doc, RankingMetric.episodes, RankingPeriod.month), 1);
    });
  });

  group('O6 - marcador (docs/91 §7.4)', () {
    // serverNow = 2026-10-15T15:00Z.
    final rows = <(String, DateTime?, List<Object?>, bool, String?)>[
      ('1', DateTime.utc(2026, 10, 8, 15), [1], false, null),
      ('2', DateTime.utc(2026, 10, 7, 15, 0, 1), [1], false, null),
      ('3', DateTime.utc(2026, 10, 7, 15), [1], false, 'Atualizado há 8 dias'),
      ('4', DateTime.utc(2026, 9, 15, 15), [1], false, 'Atualizado há 30 dias'),
      ('5', DateTime.utc(2026, 10, 16), [1], false, null),
      ('6', null, [1], false, 'Atualização desconhecida'),
      ('7', DateTime.utc(2026, 10, 15, 14), [_absent, 'x', 0], false, 'Atualização desconhecida'),
      ('8', DateTime.utc(2026, 10, 7, 15), [0], false, 'Atualizado há 8 dias'),
      ('9', DateTime.utc(2026, 10, 15, 14), [2], false, null),
      ('10', DateTime.utc(2026, 9, 15, 15), [1], true, null),
    ];
    for (final (id, updatedAt, calcs, me, want) in rows) {
      test('linha $id', () {
        for (final calc in calcs) {
          final RankingParticipant p;
          if (me) {
            p = RankingParticipant.me(
              uid: 'me',
              name: 'Eu',
              stats: const SharedStats(
                total: TotalStats(),
                year: PeriodStats(key: '2026'),
                month: PeriodStats(key: '2026-10'),
              ),
              updatedAt: updatedAt,
              tz: kRankTz,
              calc: calc as int,
            );
          } else {
            p = friendOf('u1', 'Carla', statsMap(), updatedAt: updatedAt, calc: calc, omitCalc: calc == _absent);
          }
          final row = RankingTable.rank([p], RankingMetric.episodes, RankingPeriod.total, kRankNow).rows.single;
          expect(RankingTexts.stale(row), want, reason: 'calc $calc');
          expect(row.stale, want != null, reason: 'calc $calc');
        }
      });
    }

    test('minha linha sem updatedAt nem calc também não tem marcador', () {
      final p = RankingParticipant.me(
        uid: 'me',
        name: 'Eu',
        stats: const SharedStats(
          total: TotalStats(),
          year: PeriodStats(key: '2026'),
          month: PeriodStats(key: '2026-10'),
        ),
        tz: kRankTz,
      );
      final row = RankingTable.rank([p], RankingMetric.episodes, RankingPeriod.total, kRankNow).rows.single;
      expect(row.stale, isFalse);
      expect(RankingTexts.stale(row), isNull);
    });

    test('staleDays conta dias inteiros no agora do ranking (O5)', () {
      final p = friendOf('u1', 'Carla', statsMap(), updatedAt: DateTime.utc(2026, 10, 7, 15));
      final row = RankingTable.rank([p], RankingMetric.episodes, RankingPeriod.total, kRankNow).rows.single;
      expect(row.staleDays, 8);
    });

    test('calc ilegível no FriendSharedView: 0, fração, Infinity, texto = null', () {
      for (final c in <Object?>[0, -1, 1.5, double.parse('Infinity'), 'x', null]) {
        expect(friendView(statsMap(), calc: c).calc, isNull, reason: '$c');
      }
      expect(friendView(statsMap(), calc: 2).calc, 2);
      expect(friendView(statsMap(), calc: 2.0).calc, 2);
    });
  });
}
