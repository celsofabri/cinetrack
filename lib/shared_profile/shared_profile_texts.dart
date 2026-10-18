import 'period_key.dart';
import 'shared_profile_models.dart';

/// pt-BR texts of the shared profile (docs/81 RF-P11, RF-A8, RF-S3, RF-S4).
/// Pure: the clock and the owner's zone are arguments. Used by "Meu perfil"
/// (this slice) and by the friend's profile (Fatia 3).
class SharedProfileTexts {
  const SharedProfileTexts._();

  /// "agora" (< 1 min), "há N min" (< 60), "há N h" (< 24), "há N dia(s)".
  static String ago(DateTime at, DateTime now) {
    final d = now.toUtc().difference(at.toUtc());
    if (d.inMinutes < 1) return 'agora';
    if (d.inMinutes < 60) return 'há ${d.inMinutes} min';
    if (d.inHours < 24) return 'há ${d.inHours} h';
    final days = d.inDays;
    return days == 1 ? 'há 1 dia' : 'há $days dias';
  }

  /// "Atualizado agora" / "Atualizado há X": always neutral, never an alarm
  /// of "out of date" (Manager's decision, ex-❓-3).
  static String updated(DateTime at, DateTime now) {
    final a = ago(at, now);
    return a == 'agora' ? 'Atualizado agora' : 'Atualizado $a';
  }

  static String episode(int? season, int? episode) => 'T${season ?? 0}E${episode ?? 0}';

  /// The sentence of an activity (RF-A8), without the relative date.
  /// An episode activity whose season or episode is unknown (a value the
  /// reader refused, hotfix A2) leaves the "TxEy" part out instead of
  /// showing "T0E0" (Orquestrador's decision, docs/92 rodada 2).
  static String activity(ActivityItem a) => switch (a.type) {
    ActivityType.favorited => 'Favoritou ${a.title}',
    ActivityType.watchedMovie => 'Assistiu ${a.title}',
    ActivityType.watchedEpisodes => _episodes(a),
    ActivityType.completedSeries => 'Concluiu ${a.title}',
  };

  static String _episodes(ActivityItem a) {
    final known = a.season != null && a.episode != null;
    final at = known ? episode(a.season, a.episode) : null;
    if ((a.count ?? 1) <= 1) {
      return at == null ? 'Assistiu um episódio de ${a.title}' : 'Assistiu $at de ${a.title}';
    }
    final base = 'Assistiu ${a.count} episódios de ${a.title}';
    return at == null ? base : '$base, até $at';
  }

  /// DD/MM/AAAA of [instant] in the owner's zone [tz].
  static String date(DateTime instant, int tz) {
    final local = instant.toUtc().add(Duration(minutes: tz));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }

  /// "Este mês" / "este ano" as every reader sees them (B1): the stored
  /// period if it is the owner's current one, else zeros.
  static PeriodStats current(
    PeriodStats stored, {
    required bool month,
    required int tz,
    required DateTime now,
  }) {
    final keys = periodKey(now, tz);
    final key = month ? keys.month : keys.year;
    return stored.key == key ? stored : PeriodStats(key: key);
  }

  /// The note on dates (B2, RF-S4): null when every mark has a date.
  static String? datesNote(SharedStats stats, int tz) => datesNoteFor(
    undated: stats.undatedMovies + stats.undatedEpisodes,
    datedFrom: stats.datedFrom,
    tz: tz,
  );

  /// [datesNote] from the plain values (the friend's lenient reading too).
  static String? datesNoteFor({required int undated, DateTime? datedFrom, required int tz}) {
    if (undated <= 0) return null;
    final from = datedFrom;
    return from == null
        ? 'Marcações anteriores a esta versão contam só no total.'
        : 'Marcações feitas antes de ${date(from, tz)} contam só no total.';
  }

  /// Where the note goes: under "este mês" when the cut (`datedFrom`, or
  /// `updatedAt` without it) is in the owner's current month, under "este
  /// ano" when it is in the current year.
  static ({bool month, bool year}) notePlacement(
    SharedStats stats, {
    required DateTime? updatedAt,
    required int tz,
    required DateTime now,
  }) => notePlacementFor(
    undated: stats.undatedMovies + stats.undatedEpisodes,
    datedFrom: stats.datedFrom,
    updatedAt: updatedAt,
    tz: tz,
    now: now,
  );

  /// [notePlacement] from the plain values.
  static ({bool month, bool year}) notePlacementFor({
    required int undated,
    required DateTime? datedFrom,
    required DateTime? updatedAt,
    required int tz,
    required DateTime now,
  }) {
    final cut = datedFrom ?? updatedAt;
    if (cut == null || undated <= 0) return (month: false, year: false);
    final c = periodKey(cut, tz), n = periodKey(now, tz);
    return (month: c.month == n.month, year: c.year == n.year);
  }

  // ---- Friend's profile (docs/81 RF-F5, docs/82 §7.2) ----

  /// Every "unavailable" case (not a friend, ex-friend, block in either
  /// direction, deleted account, malformed uid) shows THIS text (RNF8).
  static const unavailable = 'Este perfil não está disponível.';
  static const backToFriends = 'Voltar para Amigos';
  static const loadFailed = 'Não foi possível carregar o perfil.';
  static const retry = 'Tentar novamente';

  static String sharesNothing(String name) => '$name ainda não compartilha nada além do cartão.';

  static String noStats(String name) => '$name não compartilha estatísticas com amigos.';

  static String noActivity(String name) => '$name não compartilha atividades com amigos.';

  static String noActivityYet(String name) => '$name ainda não tem atividades recentes.';

  static String noRecs(String name) => '$name não compartilha recomendados com amigos.';

  /// The friend shares "Recomendados" but has none listed.
  static String noRecsYet(String name) => '$name ainda não tem recomendados.';

  /// The owner's preview with nothing recommended yet.
  static const ownNoRecs = 'Você ainda não marcou nenhum título com Recomendo.';

  /// Footer when `recs.count` is larger than the list (RF-R1: 51 = "e mais 1").
  static String andMore(int n) => 'e mais $n';

  /// Without a name (opened by address, header not known yet).
  static String offline(String? name) => name == null
      ? 'Sem conexão. Conecte-se para ver este perfil.'
      : 'Sem conexão. Conecte-se para ver o perfil de $name.';

  /// Marker of a number the document does not have (RF-F9): never 0.
  static const unknownValue = '—';
}
