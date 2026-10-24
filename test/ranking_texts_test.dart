// Fatia 1 of the ranking (docs/96): the literal texts T1 of docs/90 (values,
// hours at the limits, Semantics of values and rows, plural).
//
// Runs on BOTH platforms (CI and locally):
//   flutter test test/ranking_texts_test.dart
//   flutter test --platform chrome test/ranking_texts_test.dart
// Keep it free of dart:io, Hive and platform plugins.
import 'package:cinetrack/ranking/ranking_models.dart';
import 'package:cinetrack/ranking/ranking_table.dart';
import 'package:cinetrack/ranking/ranking_texts.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:flutter_test/flutter_test.dart';

RankingRow _row({
  String name = 'Ana',
  bool me = false,
  int? value = 120,
  int? position = 3,
  bool tied = false,
  bool stale = false,
  int? staleDays,
}) => RankingRow(
  who: RankingParticipant(uid: 'u1', name: name, isMe: me, stats: const SharedStatsReading()),
  value: value,
  position: position,
  tied: tied,
  stale: stale,
  staleDays: staleDays,
);

void main() {
  group('T1 - textos fixos', () {
    test('constantes literais', () {
      expect(RankingTexts.entry, 'Ranking');
      expect(RankingTexts.seeRanking, 'Ver ranking');
      expect(RankingTexts.periodLabel, 'Período');
      expect(RankingTexts.metricLabel, 'Estatística');
      expect([for (final p in RankingPeriod.values) RankingTexts.period(p)], ['Este mês', 'Este ano', 'Total']);
      expect(
        [for (final m in RankingMetric.values) RankingTexts.metric(m)],
        ['Episódios assistidos', 'Filmes assistidos', 'Séries assistidas', 'Séries concluídas', 'Horas assistidas'],
      );
      expect([for (final m in RankingMetric.values) m.slug], ['episodios', 'filmes', 'series', 'concluidas', 'horas']);
      expect([for (final p in RankingPeriod.values) p.slug], ['mes', 'ano', 'total']);
      expect(RankingTexts.refresh, 'Atualizar');
      expect(RankingTexts.summaryNotIn, 'Você não está no ranking');
      expect(RankingTexts.summaryUnknown, 'Sua posição: sem informação');
      expect(RankingTexts.you, 'Você');
      expect(RankingTexts.loadFailed, 'Não foi possível carregar o ranking.');
      expect(RankingTexts.retry, 'Tentar novamente');
      expect(RankingTexts.offline, 'Sem conexão. Conecte-se para ver o ranking.');
      expect(RankingTexts.quota, 'Muitas operações hoje. Tente de novo amanhã.');
      expect(RankingTexts.sessionExpired, 'Sessão expirada. Entre novamente.');
      expect(RankingTexts.nobodyShares, 'Nenhum amigo compartilha estatísticas ainda.');
      expect(
        RankingTexts.onlyMe,
        'Nenhum amigo compartilha estatísticas ainda. Quando compartilharem, eles aparecem aqui.',
      );
      expect(
        RankingTexts.notSharingSearchOff,
        'Você não aparece no ranking dos seus amigos porque "Aparecer na busca" está desligado.',
      );
      expect(RankingTexts.goToProfile, 'Ir para o Perfil');
      expect(
        RankingTexts.notSharingUnconfirmed,
        'Você não aparece no ranking dos seus amigos porque ainda não confirmou o que eles veem.',
      );
      expect(RankingTexts.review, 'Revisar');
      expect(RankingTexts.staleUnknown, 'Atualização desconhecida');
      expect(RankingTexts.nobodyScored, 'Ninguém pontuou neste período ainda.');
      expect(RankingTexts.undatedNote, 'Marcações anteriores a esta versão contam só no total.');
      expect(RankingTexts.noMoreFriends, 'Você não tem mais amigos no CineTrack.');
      expect(RankingTexts.unknownValue, '—');
      expect(RankingTexts.unknownSemantics, 'sem informação');
    });

    test('posição e resumo', () {
      expect(
        [
          for (final p in [1, 2, 10, 51]) RankingTexts.position(p),
        ],
        ['1º', '2º', '10º', '51º'],
      );
      expect(RankingTexts.summary(3, 8), 'Sua posição: 3º de 8');
    });

    test('RF-E6, RF-E11 e RF-R12 (singular/plural)', () {
      expect(RankingTexts.partialFailure(1), 'Não foi possível carregar 1 amigo. As posições podem mudar.');
      expect(RankingTexts.partialFailure(2), 'Não foi possível carregar 2 amigos. As posições podem mudar.');
      expect(RankingTexts.notSharing(1), '1 amigo não compartilha estatísticas.');
      expect(RankingTexts.notSharing(2), '2 amigos não compartilham estatísticas.');
      // 0 is plural too (T1).
      expect(RankingTexts.partialFailure(0), 'Não foi possível carregar 0 amigos. As posições podem mudar.');
      expect(RankingTexts.notSharing(0), '0 amigos não compartilham estatísticas.');
      expect(RankingTexts.limited(50, 80), 'O ranking compara você com 50 dos seus 80 amigos.');
      expect(RankingTexts.limited(50, null), 'O ranking compara você com 50 dos seus amigos.');
      expect(RankingTexts.limited(50, 1234), 'O ranking compara você com 50 dos seus 1.234 amigos.');
    });
  });

  group('T1 - valores por métrica (visível · Semantics)', () {
    final rows = <(RankingMetric, int?, String, String)>[
      (RankingMetric.movies, 0, '0 filmes', '0 filmes assistidos'),
      (RankingMetric.movies, 1, '1 filme', '1 filme assistido'),
      (RankingMetric.movies, 2, '2 filmes', '2 filmes assistidos'),
      (RankingMetric.movies, 1234, '1.234 filmes', '1234 filmes assistidos'),
      (RankingMetric.movies, 100000, '100.000 filmes', '100000 filmes assistidos'),
      (RankingMetric.series, 0, '0 séries', '0 séries assistidas'),
      (RankingMetric.series, 1, '1 série', '1 série assistida'),
      (RankingMetric.series, 1234, '1.234 séries', '1234 séries assistidas'),
      (RankingMetric.series, 100000, '100.000 séries', '100000 séries assistidas'),
      (RankingMetric.completed, 0, '0 séries', '0 séries concluídas'),
      (RankingMetric.completed, 1, '1 série', '1 série concluída'),
      (RankingMetric.completed, 1234, '1.234 séries', '1234 séries concluídas'),
      (RankingMetric.completed, 100000, '100.000 séries', '100000 séries concluídas'),
      (RankingMetric.episodes, 0, '0 episódios', '0 episódios assistidos'),
      (RankingMetric.episodes, 1, '1 episódio', '1 episódio assistido'),
      (RankingMetric.episodes, 1234, '1.234 episódios', '1234 episódios assistidos'),
      (RankingMetric.episodes, 1000000, '1.000.000 episódios', '1000000 episódios assistidos'),
      for (final m in RankingMetric.values) (m, null, '—', 'sem informação'),
    ];
    for (final (m, v, visible, semantics) in rows) {
      test('${m.slug} $v', () {
        expect(RankingTexts.value(m, v), visible);
        expect(RankingTexts.valueSemantics(m, v), semantics);
      });
    }
  });

  group('T1 - horas assistidas (D14, minutos)', () {
    final rows = <(int, String, String)>[
      (0, '0 min', '0 minutos de tempo assistido'),
      (1, '1 min', '1 minuto de tempo assistido'),
      (45, '45 min', '45 minutos de tempo assistido'),
      (59, '59 min', '59 minutos de tempo assistido'),
      (60, '1 h 00 min', '1 hora de tempo assistido'),
      (61, '1 h 01 min', '1 hora e 1 minuto de tempo assistido'),
      (65, '1 h 05 min', '1 hora e 5 minutos de tempo assistido'),
      (120, '2 h 00 min', '2 horas de tempo assistido'),
      (600, '10 h 00 min', '10 horas de tempo assistido'),
      (659, '10 h 59 min', '10 horas e 59 minutos de tempo assistido'),
      (74045, '1.234 h 05 min', '1234 horas e 5 minutos de tempo assistido'),
      (52560000, '876.000 h 00 min', '876000 horas de tempo assistido'),
    ];
    for (final (minutes, visible, semantics) in rows) {
      test('$minutes min', () {
        expect(RankingTexts.value(RankingMetric.hours, minutes), visible);
        expect(RankingTexts.valueSemantics(RankingMetric.hours, minutes), semantics);
      });
    }
  });

  group('T1 - Semantics de linha', () {
    const ep = RankingMetric.episodes;
    test('normal', () => expect(RankingTexts.rowSemantics(_row(), ep), '3º lugar, Ana, 120 episódios assistidos'));
    test('empatado (qualquer linha do grupo)', () {
      expect(
        RankingTexts.rowSemantics(_row(position: 1, tied: true), ep),
        '1º lugar, empatado, Ana, 120 episódios assistidos',
      );
    });
    test('eu', () => expect(RankingTexts.rowSemantics(_row(me: true), ep), 'Você, 3º lugar, 120 episódios assistidos'));
    test('eu empatado', () {
      expect(
        RankingTexts.rowSemantics(_row(me: true, position: 1, tied: true), ep),
        'Você, 1º lugar, empatado, 120 episódios assistidos',
      );
    });
    test('desconhecido / eu desconhecido', () {
      expect(RankingTexts.rowSemantics(_row(value: null, position: null), ep), 'Ana, sem informação');
      expect(RankingTexts.rowSemantics(_row(me: true, value: null, position: null), ep), 'Você, sem informação');
    });
    test('desatualizado (sufixo)', () {
      expect(
        RankingTexts.rowSemantics(_row(stale: true, staleDays: 8), ep),
        '3º lugar, Ana, 120 episódios assistidos, atualizado há 8 dias',
      );
      expect(
        RankingTexts.rowSemantics(_row(stale: true), ep),
        '3º lugar, Ana, 120 episódios assistidos, atualização desconhecida',
      );
    });
    test('horas e milhares no Semantics sem separador', () {
      expect(
        RankingTexts.rowSemantics(_row(value: 74045, position: 1), RankingMetric.hours),
        '1º lugar, Ana, 1234 horas e 5 minutos de tempo assistido',
      );
      expect(
        RankingTexts.rowSemantics(_row(value: 1234, position: 2), RankingMetric.movies),
        '2º lugar, Ana, 1234 filmes assistidos',
      );
    });
  });

  group('T1 - marcador visível (RF-E12)', () {
    test('sem marcador quando não está desatualizado', () => expect(RankingTexts.stale(_row(staleDays: 30)), isNull));
    test('"Atualizado há N dias" só com N conhecido e > 7', () {
      expect(RankingTexts.stale(_row(stale: true, staleDays: 8)), 'Atualizado há 8 dias');
      expect(RankingTexts.stale(_row(stale: true, staleDays: 30)), 'Atualizado há 30 dias');
      expect(RankingTexts.stale(_row(stale: true, staleDays: 7)), 'Atualização desconhecida', reason: 'calc inválido');
      expect(RankingTexts.stale(_row(stale: true)), 'Atualização desconhecida');
    });
  });

  test('thousands', () {
    expect(
      [
        for (final n in [0, 7, 999, 1000, 12345, 1234567]) RankingTexts.thousands(n),
      ],
      ['0', '7', '999', '1.000', '12.345', '1.234.567'],
    );
  });
}
