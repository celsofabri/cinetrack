// Fatia 1 of the ranking (docs/96): periods and zones (O4) and the
// ranking's clock (O5) of docs/91 §7, copied 1:1.
//
// Runs on BOTH platforms (CI and locally):
//   flutter test test/ranking_period_test.dart
//   flutter test --platform chrome test/ranking_period_test.dart
// Keep it free of dart:io, Hive and platform plugins.
import 'package:cinetrack/data/server_clock.dart';
import 'package:cinetrack/ranking/ranking_models.dart';
import 'package:cinetrack/ranking/ranking_reading.dart';
import 'package:cinetrack/ranking/ranking_table.dart';
import 'package:cinetrack/shared_profile/period_key.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ranking_fixtures.dart';

const _absent = #absent;

/// [monthKey]/[yearKey] with episodes [month]/[year] and [total].
Map<String, Object?> _doc({
  Object? monthKey = _absent,
  Object? yearKey = _absent,
  int month = 0,
  int year = 0,
  int total = 1000,
}) => statsMap(
  monthKey: monthKey,
  yearKey: yearKey,
  total: {'watchedEpisodes': total},
  month: {'watchedEpisodes': month},
  year: {'watchedEpisodes': year},
);

/// Episodes of one friend in this month / this year / total at [now].
List<int?> _read(Map<String, Object?> stats, DateTime now, {int tz = kRankTz}) {
  final p = friendOf('u1', 'Carla', stats, updatedAt: now, tz: tz);
  return [
    for (final period in [RankingPeriod.month, RankingPeriod.year, RankingPeriod.total])
      RankingTable.rank([p], RankingMetric.episodes, period, now).rows.single.value,
  ];
}

void main() {
  group('O4 - períodos e fusos (docs/91 §7.2)', () {
    final oct15 = DateTime.utc(2026, 10, 15, 15);
    test('linha 1: chaves atuais = valor gravado', () {
      expect(periodKey(oct15, -180), (month: '2026-10', year: '2026'));
      expect(_read(_doc(monthKey: '2026-10', month: 7, yearKey: '2026', year: 30), oct15).take(2), [7, 30]);
    });
    test('linha 2: mês anterior = 0', () {
      expect(_read(_doc(monthKey: '2026-09', month: 40, yearKey: '2026', year: 90), oct15).take(2), [0, 90]);
    });
    test('linha 3: mês futuro = —; o ano conforme a chave', () {
      expect(_read(_doc(monthKey: '2026-11', month: 5, yearKey: '2026', year: 30), oct15).take(2), [null, 30]);
      expect(_read(_doc(monthKey: '2026-11', month: 5, yearKey: '2025', year: 30), oct15).take(2), [null, 0]);
    });
    test('linha 4: mês ilegível, não string ou ausente = —', () {
      for (final key in <Object?>['abc', '2026-13', '2026-1', 12, _absent, '2026-00', ' 2026-10', '2026-10 ', null]) {
        expect(
          _read(_doc(monthKey: key, month: 5, yearKey: '2026', year: 30), oct15).first,
          isNull,
          reason: '$key',
        );
      }
    });
    test('linha 5: ano "2025" = 0, "2027" = —, "26" = —', () {
      expect(_read(_doc(yearKey: '2025', year: 30), oct15)[1], 0);
      expect(_read(_doc(yearKey: '2027', year: 30), oct15)[1], isNull);
      expect(_read(_doc(yearKey: '26', year: 30), oct15)[1], isNull);
      expect(_read(_doc(yearKey: 2026, year: 30), oct15)[1], isNull, reason: 'não string');
    });

    final nov1 = DateTime.utc(2026, 11, 1, 2, 30);
    for (final (id, tz, current, other) in [
      ('6', -180, '2026-10', '2026-11'),
      ('7', 0, '2026-11', '2026-10'),
      ('8', 840, '2026-11', '2026-10'),
      ('9', -840, '2026-10', '2026-11'),
      ('10', 900, '2026-11', '2026-10'),
    ]) {
      test('linha $id: tz $tz ⇒ chave atual "$current" (no fuso do dono)', () {
        expect(periodKey(nov1, readZone(tz)).month, current);
        final year = current.substring(0, 4);
        expect(
          _read(
            _doc(monthKey: current, month: 7, yearKey: year, year: 9),
            nov1,
            tz: tz,
          ).first,
          7,
        );
        // The neighbour key is the past (0) or the future (—), never the value.
        final got = _read(
          _doc(monthKey: other, month: 7, yearKey: year, year: 9),
          nov1,
          tz: tz,
        ).first;
        expect(got, other.compareTo(current) < 0 ? 0 : null);
      });
    }

    test('linha 11: 2027-01-01T02:59Z em −180 ainda é dezembro', () {
      final at = DateTime.utc(2027, 1, 1, 2, 59);
      expect(_read(_doc(monthKey: '2026-12', month: 5, yearKey: '2026', year: 80), at).take(2), [5, 80]);
    });
    test('linha 12: 2027-01-01T03:00Z em −180 já é janeiro', () {
      final at = DateTime.utc(2027, 1, 1, 3);
      expect(_read(_doc(monthKey: '2026-12', month: 5, yearKey: '2026', year: 80), at).take(2), [0, 0]);
    });
    test('linha 13: dezembro lido em 5 de janeiro', () {
      final at = DateTime.utc(2027, 1, 5, 15);
      expect(_read(_doc(monthKey: '2026-12', month: 5, yearKey: '2026', year: 80, total: 300), at), [0, 0, 300]);
    });
    test('linha 14: cada participante no próprio fuso', () {
      final ana = friendOf(
        'u1',
        'Ana',
        _doc(monthKey: '2026-10', month: 4, yearKey: '2026', year: 4),
        updatedAt: nov1,
        tz: -180,
      );
      final carla = friendOf(
        'u2',
        'Carla',
        _doc(monthKey: '2026-11', month: 2, yearKey: '2026', year: 2),
        updatedAt: nov1,
        tz: 0,
      );
      final r = RankingTable.rank([carla, ana], RankingMetric.episodes, RankingPeriod.month, nov1);
      expect([for (final x in r.rows) (x.who.name, x.value)], [('Ana', 4), ('Carla', 2)]);
    });
    test('virada com a tela aberta: 02:59:59Z ⇒ 7, 1 s depois ⇒ 0 (sem leitura)', () {
      final carla = friendOf(
        'u1',
        'Carla',
        _doc(monthKey: '2026-10', month: 7, yearKey: '2026', year: 7),
        updatedAt: DateTime.utc(2026, 10, 20),
        tz: -180,
      );
      int? at(DateTime now) =>
          RankingTable.rank([carla], RankingMetric.episodes, RankingPeriod.month, now).rows.single.value;
      expect(at(DateTime.utc(2026, 11, 1, 2, 59, 59)), 7);
      expect(at(DateTime.utc(2026, 11, 1, 3)), 0);
    });
    test('linhas 4/5: chave com largura errada que compararia como antiga é ilegível ("—", não 0)', () {
      int? read(Object? monthKey, Object? yearKey, RankingPeriod p) {
        final f = friendOf(
          'u1',
          'Carla',
          statsMap(
            monthKey: monthKey,
            yearKey: yearKey,
            total: {'watchedEpisodes': 100},
            year: {'watchedEpisodes': 30},
            month: {'watchedEpisodes': 5},
          ),
          updatedAt: kRankNow,
        );
        return RankingTable.rank([f], RankingMetric.episodes, p, kRankNow).rows.single.value;
      }

      for (final y in ['199', '20', '1']) {
        expect(read('2026-09', y, RankingPeriod.year), isNull, reason: 'ano "$y"');
      }
      for (final m in ['999-10', '202-09', '2025-9']) {
        expect(read(m, '2026', RankingPeriod.month), isNull, reason: 'mês "$m"');
      }
    });
    test('tz fora da faixa vale 0 também para a nota de datas (RF-R9)', () {
      // Corte 2026-10-31T08:00Z e agora 10:00Z: em UTC, ambos em outubro;
      // com +900 cru, o corte cairia em outubro e o agora em novembro.
      final now = DateTime.utc(2026, 10, 31, 10);
      for (final tz in [900, -900]) {
        final r = RankingReading.read(
          SharedStatsReading(
            total: const PeriodReading(watchedEpisodes: 9),
            month: const PeriodReading(key: '2026-10', watchedEpisodes: 1),
            year: const PeriodReading(key: '2026', watchedEpisodes: 2),
            undatedEpisodes: 5,
            datedFrom: DateTime.utc(2026, 10, 31, 8),
          ),
          tz: tz,
          updatedAt: now,
          calc: 1,
          now: now,
        );
        expect(r.undatedPlacement, (month: true, year: true), reason: 'tz $tz');
      }
    });
    test('fuso do próprio dono fora da faixa (RankingReading direto) lê como 0', () {
      // 2026-10-31T10:00Z: UTC ainda em outubro; +900 min já seria novembro.
      final at = DateTime.utc(2026, 10, 31, 10);
      for (final tz in [900, -900, 841, -841]) {
        final r = RankingReading.read(
          const SharedStatsReading(
            total: PeriodReading(watchedEpisodes: 9),
            month: PeriodReading(key: '2026-10', watchedEpisodes: 7),
            year: PeriodReading(key: '2026', watchedEpisodes: 8),
          ),
          tz: tz,
          updatedAt: at,
          calc: 1,
          now: at,
        );
        expect(r.value(RankingMetric.episodes, RankingPeriod.month), 7, reason: 'tz $tz');
      }
      // Inside the range the owner's zone is used (+840 there is November).
      final r = RankingReading.read(
        const SharedStatsReading(
          total: PeriodReading(watchedEpisodes: 9),
          month: PeriodReading(key: '2026-10', watchedEpisodes: 7),
          year: PeriodReading(key: '2026', watchedEpisodes: 8),
        ),
        tz: 840,
        updatedAt: at,
        calc: 1,
        now: at,
      );
      expect(r.value(RankingMetric.episodes, RankingPeriod.month), 0);
    });
  });

  group('O5 - relógio (docs/91 §7.3)', () {
    final device = DateTime.utc(2026, 10, 31, 23);
    final carla = friendOf(
      'u1',
      'Carla',
      _doc(monthKey: '2026-11', month: 3, yearKey: '2026', year: 3),
      updatedAt: DateTime.utc(2026, 11, 1, 1),
      tz: 0,
    );
    final davi = friendOf(
      'u2',
      'Davi',
      _doc(monthKey: '2026-10', month: 9, yearKey: '2026', year: 9),
      updatedAt: DateTime.utc(2026, 10, 30, 12),
      tz: 0,
    );

    RankingResult rank(List<RankingParticipant> ps, ServerClock clock) =>
        RankingTable.rank(ps, RankingMetric.episodes, RankingPeriod.month, clock.now());
    Map<String, int?> values(RankingResult r) => {for (final x in r.rows) x.who.name: x.value};

    test('linha 1: o max com updatedAt corrige o relógio atrasado', () {
      final r = rank([carla], ServerClock(deviceNow: () => device));
      expect(r.now, DateTime.utc(2026, 11, 1, 1));
      expect(values(r), {'Carla': 3});
    });
    test('linha 2: um amigo carregado corrige o mês do outro', () {
      final r = rank([carla, davi], ServerClock(deviceNow: () => device));
      expect(r.now, DateTime.utc(2026, 11, 1, 1));
      expect(values(r), {'Carla': 3, 'Davi': 0});
    });
    test('linha 3: só Davi (Carla falhou) ⇒ relógio do aparelho', () {
      final r = rank([davi], ServerClock(deviceNow: () => device));
      expect(r.now, device);
      expect(values(r), {'Davi': 9});
    });
    test('linha 4: a minha linha entra no max', () {
      final me = RankingParticipant(
        uid: 'me',
        name: 'Eu',
        isMe: true,
        stats: const SharedStatsReading(),
        updatedAt: DateTime.utc(2026, 11, 1, 0, 10),
        calc: 1,
      );
      final r = rank([me, davi], ServerClock(deviceNow: () => device));
      expect(r.now, DateTime.utc(2026, 11, 1, 0, 10));
      expect(values(r)['Davi'], 0);
    });
    test('linha 5: amostra do ServerClock com desvio +2 h', () {
      final clock = ServerClock(deviceNow: () => DateTime.utc(2026, 10, 31, 22, 30));
      expect(
        clock.sample(
          local: DateTime.utc(2026, 10, 31, 22),
          server: DateTime.utc(2026, 11, 1, 0),
          elapsed: const Duration(seconds: 1),
        ),
        isTrue,
      );
      final r = rank([davi], clock);
      expect(r.now, DateTime.utc(2026, 11, 1, 0, 30));
      expect(values(r), {'Davi': 0});
    });
    test('linha 6: relógio adiantado continua errado (aceito)', () {
      final c = friendOf(
        'u1',
        'Carla',
        _doc(monthKey: '2026-10', month: 5, yearKey: '2026', year: 5),
        updatedAt: DateTime.utc(2026, 10, 31, 20),
        tz: 0,
      );
      final r = rank([c], ServerClock(deviceNow: () => DateTime.utc(2026, 11, 2)));
      expect(r.now, DateTime.utc(2026, 11, 2));
      expect(values(r), {'Carla': 0});
    });
    test('agora() não depende da ordem e ignora updatedAt ausente', () {
      final noDate = friendOf('u3', 'Eva', _doc(), tz: 0);
      expect(RankingTable.agora([noDate, davi, carla], device), DateTime.utc(2026, 11, 1, 1));
      expect(RankingTable.agora([carla, noDate, davi], device), DateTime.utc(2026, 11, 1, 1));
      expect(RankingTable.agora([noDate], device), device);
    });
  });
}

/// The zone as the ranking reads it (out of −840..840 = 0).
int readZone(int tz) => tz < kMinTzMinutes || tz > kMaxTzMinutes ? 0 : tz;
