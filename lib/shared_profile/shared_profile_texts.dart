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
  static String activity(ActivityItem a) => switch (a.type) {
    ActivityType.favorited => 'Favoritou ${a.title}',
    ActivityType.watchedMovie => 'Assistiu ${a.title}',
    ActivityType.watchedEpisodes =>
      (a.count ?? 1) <= 1
          ? 'Assistiu ${episode(a.season, a.episode)} de ${a.title}'
          : 'Assistiu ${a.count} episódios de ${a.title}, até ${episode(a.season, a.episode)}',
    ActivityType.completedSeries => 'Concluiu ${a.title}',
  };

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
  static String? datesNote(SharedStats stats, int tz) {
    if (stats.undatedMovies + stats.undatedEpisodes <= 0) return null;
    final from = stats.datedFrom;
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
  }) {
    final cut = stats.datedFrom ?? updatedAt;
    if (cut == null || datesNote(stats, tz) == null) return (month: false, year: false);
    final c = periodKey(cut, tz), n = periodKey(now, tz);
    return (month: c.month == n.month, year: c.year == n.year);
  }
}
