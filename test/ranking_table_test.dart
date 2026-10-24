// Fatia 1 of the ranking (docs/96): the pure ranking function, oracle O1 of
// docs/91 §6 copied 1:1, plus the "input order does not matter" property.
//
// Runs on BOTH platforms (CI and locally):
//   flutter test test/ranking_table_test.dart
//   flutter test --platform chrome test/ranking_table_test.dart
// Keep it free of dart:io, Hive and platform plugins.
import 'dart:math';

import 'package:cinetrack/ranking/ranking_models.dart';
import 'package:cinetrack/ranking/ranking_table.dart';
import 'package:cinetrack/ranking/ranking_texts.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ranking_fixtures.dart';

typedef P = (String uid, String name, int? v, bool me);

class _Row {
  final String id;
  final List<P> people;
  final List<String> order; // uids
  final List<int?> positions;
  final List<bool> tied;
  final int ranked;
  final int? myPosition;
  final bool nobodyScored;
  final String summary;
  final bool meSharing;
  final RankingMetric metric;
  final RankingPeriod period;
  final List<String>? texts;
  const _Row(
    this.id,
    this.people,
    this.order,
    this.positions,
    this.tied,
    this.ranked,
    this.myPosition,
    this.nobodyScored,
    this.summary, {
    this.meSharing = true,
    this.metric = RankingMetric.episodes,
    this.period = RankingPeriod.month,
    this.texts,
  });
}

const T = true, F = false;

final _o1 = <_Row>[
  const _Row(
    '1',
    [('u1', 'Ana', 10, F), ('u2', 'Bia', 10, F), ('u3', 'Caio', 8, T)],
    ['u1', 'u2', 'u3'],
    [1, 1, 3],
    [T, T, F],
    3,
    3,
    F,
    'Sua posição: 3º de 3',
  ),
  const _Row(
    '2',
    [('u9', 'Zé', 5, T), ('u1', 'Ana', 5, F)],
    ['u1', 'u9'],
    [1, 1],
    [T, T],
    2,
    1,
    F,
    'Sua posição: 1º de 2',
  ),
  const _Row(
    '3',
    [('u1', 'Ana', 0, T), ('u2', 'Bia', 0, F)],
    ['u1', 'u2'],
    [1, 1],
    [T, T],
    2,
    1,
    T,
    'Sua posição: 1º de 2',
  ),
  const _Row(
    '4',
    [('u1', 'Ana', 3, T), ('u2', 'Bia', null, F), ('u3', 'Caio', 1, F)],
    ['u1', 'u3', 'u2'],
    [1, 2, null],
    [F, F, F],
    2,
    1,
    F,
    'Sua posição: 1º de 2',
  ),
  const _Row(
    '5',
    [('u1', 'Álvaro', 4, F), ('u2', 'Ana', 4, F), ('u3', 'alice', 4, F)],
    ['u3', 'u1', 'u2'],
    [1, 1, 1],
    [T, T, T],
    3,
    null,
    F,
    'Você não está no ranking',
    meSharing: false,
  ),
  const _Row(
    '6',
    [('u2', 'ana', 4, F), ('u1', 'Ana', 4, F), ('u3', 'ANA', 4, T)],
    ['u1', 'u2', 'u3'],
    [1, 1, 1],
    [T, T, T],
    3,
    1,
    F,
    'Sua posição: 1º de 3',
  ),
  const _Row(
    '7',
    [('u1', 'A', 10, F), ('u2', 'B', 8, F), ('u3', 'C', 8, F), ('u4', 'D', 8, T), ('u5', 'E', 3, F)],
    ['u1', 'u2', 'u3', 'u4', 'u5'],
    [1, 2, 2, 2, 5],
    [F, T, T, T, F],
    5,
    2,
    F,
    'Sua posição: 2º de 5',
  ),
  const _Row(
    '8',
    [('u1', 'Ana', 5, F), ('u2', 'Bia', 2, F), ('u9', 'Zé', null, T)],
    ['u1', 'u2', 'u9'],
    [1, 2, null],
    [F, F, F],
    2,
    null,
    F,
    'Sua posição: sem informação',
  ),
  const _Row(
    '9',
    [('u1', 'Ana', null, F), ('u2', 'Bia', null, T)],
    ['u1', 'u2'],
    [null, null],
    [F, F],
    0,
    null,
    F,
    'Sua posição: sem informação',
  ),
  const _Row(
    '10',
    [('u1', 'Ana', null, F), ('u2', 'Bia', null, F)],
    ['u1', 'u2'],
    [null, null],
    [F, F],
    0,
    null,
    F,
    'Você não está no ranking',
    meSharing: false,
  ),
  const _Row(
    '11',
    [('u1', 'Ana', 0, T), ('u2', 'Bia', null, F)],
    ['u1', 'u2'],
    [1, null],
    [F, F],
    1,
    1,
    T,
    'Sua posição: 1º de 1',
  ),
  _Row(
    '12',
    [for (var i = 1; i <= 51; i++) ('u${i.toString().padLeft(2, '0')}', _name(i), 7, i == 51)],
    _row12Order(),
    List.filled(51, 1),
    List.filled(51, T),
    51,
    1,
    F,
    'Sua posição: 1º de 51',
  ),
  const _Row(
    '13',
    [('u1', 'Ana', 600, F), ('u2', 'Bia', 659, F), ('u3', 'Caio', 659, T)],
    ['u2', 'u3', 'u1'],
    [1, 1, 3],
    [T, T, F],
    3,
    1,
    F,
    'Sua posição: 1º de 3',
    metric: RankingMetric.hours,
    period: RankingPeriod.total,
    texts: ['10 h 59 min', '10 h 59 min', '10 h 00 min'],
  ),
  const _Row('14', [('u9', 'Zé', 12, T)], ['u9'], [1], [F], 1, 1, F, 'Sua posição: 1º de 1'),
  const _Row(
    '15',
    [('u1', 'Ana', 4, T), ('u2', 'Ana', 4, F)],
    ['u1', 'u2'],
    [1, 1],
    [T, T],
    2,
    1,
    F,
    'Sua posição: 1º de 2',
  ),
];

/// Distinct names whose collation order differs from the uid order (and
/// mixes case and accents), so row 12 checks "by collationKey, then uid".
String _name(int i) {
  const letters = 'zyxwvutsrqponmlkjihgfedcba';
  final first = letters[i % 26];
  final base = '${i.isEven ? first.toUpperCase() : first}${String.fromCharCode(97 + (i * 7) % 26)}$i';
  return i % 5 == 0 ? 'É$base' : base;
}

List<String> _row12Order() {
  final ids = [for (var i = 1; i <= 51; i++) i];
  String key(int i) => collationLike(_name(i));
  ids.sort((a, b) {
    final c = key(a).compareTo(key(b));
    return c != 0 ? c : a.compareTo(b);
  });
  return [for (final i in ids) 'u${i.toString().padLeft(2, '0')}'];
}

/// Independent re-statement of the pt-BR key (lower case, accents folded)
/// for the names used above (only "É" carries an accent).
String collationLike(String s) => s.toLowerCase().replaceAll('é', 'e');

List<RankingParticipant> _participants(_Row r) => [
  for (final (uid, name, v, me) in r.people) simple(uid, name, v, me: me, metric: r.metric),
];

void _check(_Row r, RankingResult res) {
  expect([for (final x in res.rows) x.who.uid], r.order, reason: 'order');
  expect([for (final x in res.rows) x.position], r.positions, reason: 'position');
  expect([for (final x in res.rows) x.tied], r.tied, reason: 'tied');
  expect(res.ranked, r.ranked, reason: 'ranked');
  expect(res.myPosition, r.myPosition, reason: 'myPosition');
  expect(res.nobodyScored, r.nobodyScored, reason: 'nobodyScored');
  expect(RankingTexts.summaryFor(res, meSharing: r.meSharing), r.summary, reason: 'summary');
  if (r.texts != null) {
    expect([for (final x in res.rows) RankingTexts.value(r.metric, x.value)], r.texts);
  }
}

void main() {
  group('O1 - empates (docs/91 §6)', () {
    for (final r in _o1) {
      test('linha ${r.id}', () {
        final ps = _participants(r);
        _check(r, RankingTable.rank(ps, r.metric, r.period, kRankNow));
      });
    }

    test('embaralhar a entrada 20 vezes (semente fixa) dá a mesma saída', () {
      final random = Random(20261024);
      for (final r in _o1) {
        final ps = _participants(r);
        for (var i = 0; i < 20; i++) {
          final shuffled = [...ps]..shuffle(random);
          _check(r, RankingTable.rank(shuffled, r.metric, r.period, kRankNow));
        }
      }
    });
  });

  group('O1 - complementos', () {
    test('row 3 vs 11: nobodyScored também com um desconhecido; falso sem posicionados', () {
      final none = RankingTable.rank(
        [simple('u1', 'Ana', null, me: true)],
        RankingMetric.episodes,
        RankingPeriod.month,
        kRankNow,
      );
      expect(none.ranked, 0);
      expect(none.nobodyScored, isFalse);
      expect(RankingTexts.summaryFor(none, meSharing: null), isNull, reason: 'sem resumo antes de confirmar');
    });

    test('desconhecido não é 0: 0 posicionado acima de desconhecido, sem empate', () {
      final r = RankingTable.rank(
        [simple('u2', 'Bia', 0), simple('u1', 'Ana', null)],
        RankingMetric.episodes,
        RankingPeriod.month,
        kRankNow,
      );
      expect([for (final x in r.rows) (x.who.uid, x.position, x.tied)], [('u2', 1, false), ('u1', null, false)]);
    });

    test('desconhecidos no fim por apelido e depois uid, mesmo com apelido "menor"', () {
      final r = RankingTable.rank(
        [simple('u3', 'Zé', 1), simple('u2', 'bia', null), simple('u1', 'Ana', null), simple('u0', 'Bia', null)],
        RankingMetric.episodes,
        RankingPeriod.month,
        kRankNow,
      );
      expect([for (final x in r.rows) x.who.uid], ['u3', 'u1', 'u0', 'u2']);
    });

    test('a 1ª linha de um grupo empatado no meio também tem tied', () {
      final r = RankingTable.rank(
        [simple('u1', 'A', 9), simple('u2', 'B', 5), simple('u3', 'C', 5)],
        RankingMetric.episodes,
        RankingPeriod.month,
        kRankNow,
      );
      expect([for (final x in r.rows) x.tied], [false, true, true]);
    });

    test('"Você" não tem prioridade no empate mesmo com apelido igual e uid maior', () {
      final r = RankingTable.rank(
        [simple('u2', 'Ana', 4, me: true), simple('u1', 'Ana', 4)],
        RankingMetric.episodes,
        RankingPeriod.month,
        kRankNow,
      );
      expect([for (final x in r.rows) x.who.uid], ['u1', 'u2']);
    });

    test('kRankingMaxFriends = 50 (D5)', () => expect(kRankingMaxFriends, 50));

    test('undatedNote (RF-R9): só em Este mês/Este ano e só de quem participa', () {
      RankingParticipant undated(String uid, {int episodes = 300, DateTime? from}) => RankingParticipant(
        uid: uid,
        name: uid,
        stats: SharedStatsReading(
          total: const PeriodReading(watchedEpisodes: 400),
          month: const PeriodReading(key: '2026-10', watchedEpisodes: 1),
          year: const PeriodReading(key: '2026', watchedEpisodes: 2),
          undatedEpisodes: episodes,
          datedFrom: from ?? DateTime.utc(2026, 10, 2),
        ),
        updatedAt: kRankNow,
        tz: kRankTz,
        calc: 1,
      );
      bool note(List<RankingParticipant> ps, RankingPeriod p) =>
          RankingTable.rank(ps, RankingMetric.episodes, p, kRankNow).undatedNote;
      final carla = undated('carla');
      expect(note([carla], RankingPeriod.month), isTrue);
      expect(note([carla], RankingPeriod.year), isTrue);
      expect(note([carla], RankingPeriod.total), isFalse);
      // Without marks lacking a date there is no note.
      expect(note([undated('ana', episodes: 0)], RankingPeriod.month), isFalse);
      // Cut in an earlier month of this year: only "Este ano".
      final march = undated('bia', from: DateTime.utc(2026, 3, 10));
      expect(note([march], RankingPeriod.month), isFalse);
      expect(note([march], RankingPeriod.year), isTrue);
      // A friend who is not passed to rank (failed / not sharing) adds nothing.
      expect(note([simple('u1', 'Ana', 3)], RankingPeriod.month), isFalse);
    });
  });
}
