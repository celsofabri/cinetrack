import '../shared_profile/shared_profile_texts.dart';
import 'ranking_models.dart';
import 'ranking_reading.dart';
import 'ranking_table.dart';

/// pt-BR texts of the ranking: the literal oracle T1 of docs/90. Pure.
///
/// Visible numbers use the pt-BR thousands separator ("1.234"); Semantics
/// labels do not ("1234"). Plural: 1 = singular; 0 and >= 2 = plural.
class RankingTexts {
  const RankingTexts._();

  static const entry = 'Ranking';
  static const seeRanking = 'Ver ranking';
  static const periodLabel = 'Período';
  static const metricLabel = 'Estatística';
  static const refresh = 'Atualizar';
  static const summaryNotIn = 'Você não está no ranking';
  static const summaryUnknown = 'Sua posição: sem informação';
  static const you = 'Você';
  static const loadFailed = 'Não foi possível carregar o ranking.';
  static const retry = 'Tentar novamente';
  static const offline = 'Sem conexão. Conecte-se para ver o ranking.';
  static const quota = 'Muitas operações hoje. Tente de novo amanhã.';
  static const sessionExpired = 'Sessão expirada. Entre novamente.';
  static const nobodyShares = 'Nenhum amigo compartilha estatísticas ainda.';
  static const onlyMe = 'Nenhum amigo compartilha estatísticas ainda. Quando compartilharem, eles aparecem aqui.';

  /// RF-E10 (D9 with the Fatia S, docs/95 §10): "Aparecer na busca" off.
  static const notSharingSearchOff =
      'Você não aparece no ranking dos seus amigos porque "Aparecer na busca" está desligado.';
  static const goToProfile = 'Ir para o Perfil';

  /// RF-E10: sharing not confirmed yet (docs/95 E2); the button opens notice A.
  static const notSharingUnconfirmed =
      'Você não aparece no ranking dos seus amigos porque ainda não confirmou o que eles veem.';
  static const review = 'Revisar';
  static const staleUnknown = 'Atualização desconhecida';
  static const nobodyScored = 'Ninguém pontuou neste período ainda.';

  /// RF-R9: the generic text of Phase 2.
  static const undatedNote = 'Marcações anteriores a esta versão contam só no total.';
  static const noMoreFriends = 'Você não tem mais amigos no CineTrack.';

  /// Visible marker of an unknown value / its Semantics.
  static const unknownValue = SharedProfileTexts.unknownValue;
  static const unknownSemantics = 'sem informação';

  static String period(RankingPeriod p) => switch (p) {
    RankingPeriod.month => 'Este mês',
    RankingPeriod.year => 'Este ano',
    RankingPeriod.total => 'Total',
  };

  static String metric(RankingMetric m) => switch (m) {
    RankingMetric.episodes => 'Episódios assistidos',
    RankingMetric.movies => 'Filmes assistidos',
    RankingMetric.series => 'Séries assistidas',
    RankingMetric.completed => 'Séries concluídas',
    RankingMetric.hours => 'Horas assistidas',
  };

  /// "1º", "51º".
  static String position(int p) => '$pº';

  /// "Sua posição: 3º de 8" (N = `ranked`).
  static String summary(int position, int ranked) => 'Sua posição: ${RankingTexts.position(position)} de $ranked';

  /// The summary at the top (T1, N5): none while my sharing is not
  /// confirmed ([meSharing] null); "não está" when I do not share; "sem
  /// informação" when I take part with an unknown value.
  static String? summaryFor(RankingResult r, {required bool? meSharing}) {
    if (meSharing == null) return null;
    if (!meSharing) return summaryNotIn;
    final p = r.myPosition;
    return p == null ? summaryUnknown : summary(p, r.ranked);
  }

  /// RF-E6.
  static String partialFailure(int n) => n == 1
      ? 'Não foi possível carregar 1 amigo. As posições podem mudar.'
      : 'Não foi possível carregar ${thousands(n)} amigos. As posições podem mudar.';

  /// RF-E11.
  static String notSharing(int n) =>
      n == 1 ? '1 amigo não compartilha estatísticas.' : '${thousands(n)} amigos não compartilham estatísticas.';

  /// RF-R12: with [total] only when the count is confirmed.
  static String limited(int shown, int? total) => total == null
      ? 'O ranking compara você com $shown dos seus amigos.'
      : 'O ranking compara você com $shown dos seus ${thousands(total)} amigos.';

  /// RF-E12: the visible marker of a stale row (null = no marker). The days
  /// are shown only when known and above the threshold (always plural).
  static String? stale(RankingRow row) {
    if (!row.stale) return null;
    final d = row.staleDays;
    return d != null && d > kRankingStaleDays ? 'Atualizado há $d dias' : staleUnknown;
  }

  /// The visible value of [metric] (hours: [v] in minutes, D14).
  static String value(RankingMetric metric, int? v) {
    if (v == null) return unknownValue;
    final n = thousands(v);
    return switch (metric) {
      RankingMetric.movies => '$n ${v == 1 ? 'filme' : 'filmes'}',
      RankingMetric.series || RankingMetric.completed => '$n ${v == 1 ? 'série' : 'séries'}',
      RankingMetric.episodes => '$n ${v == 1 ? 'episódio' : 'episódios'}',
      RankingMetric.hours => hours(v),
    };
  }

  /// The Semantics of a value (no thousands separator).
  static String valueSemantics(RankingMetric metric, int? v) {
    if (v == null) return unknownSemantics;
    final one = v == 1;
    return switch (metric) {
      RankingMetric.movies => '$v ${one ? 'filme assistido' : 'filmes assistidos'}',
      RankingMetric.series => '$v ${one ? 'série assistida' : 'séries assistidas'}',
      RankingMetric.completed => '$v ${one ? 'série concluída' : 'séries concluídas'}',
      RankingMetric.episodes => '$v ${one ? 'episódio assistido' : 'episódios assistidos'}',
      RankingMetric.hours => hoursSemantics(v),
    };
  }

  /// D14: `< 60` "M min"; else "H h MM min" (hours with thousands, minutes
  /// with 2 digits): 74045 => "1.234 h 05 min".
  static String hours(int minutes) {
    final m = minutes < 0 ? 0 : minutes;
    if (m < 60) return '$m min';
    final h = m ~/ 60, rest = m % 60;
    return '${thousands(h)} h ${rest.toString().padLeft(2, '0')} min';
  }

  /// "1 hora e 1 minuto de tempo assistido"; whole hours drop the minutes.
  static String hoursSemantics(int minutes) {
    final m = minutes < 0 ? 0 : minutes;
    String mins(int n) => '$n ${n == 1 ? 'minuto' : 'minutos'}';
    if (m < 60) return '${mins(m)} de tempo assistido';
    final h = m ~/ 60, rest = m % 60;
    final hs = '$h ${h == 1 ? 'hora' : 'horas'}';
    return rest == 0 ? '$hs de tempo assistido' : '$hs e ${mins(rest)} de tempo assistido';
  }

  /// The Semantics label of a line (one node, a button).
  static String rowSemantics(RankingRow row, RankingMetric metric) {
    final p = row.position;
    final head = row.who.isMe ? you : null;
    final String body;
    if (p == null || row.value == null) {
      body = [head ?? row.who.name, unknownSemantics].join(', ');
    } else {
      body = [
        ?head,
        '${position(p)} lugar',
        if (row.tied) 'empatado',
        if (head == null) row.who.name,
        valueSemantics(metric, row.value),
      ].join(', ');
    }
    final marker = stale(row);
    return marker == null ? body : '$body, ${marker[0].toLowerCase()}${marker.substring(1)}';
  }

  /// "1.234.567" (pt-BR thousands separator).
  static String thousands(int n) {
    final digits = n.abs().toString();
    final out = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write('.');
      out.write(digits[i]);
    }
    return out.toString();
  }
}
