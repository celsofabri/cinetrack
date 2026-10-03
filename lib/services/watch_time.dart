import '../models/favorite_doc.dart';
import '../models/media_type.dart';
import '../models/season_cache.dart';
import 'favorite_mapper.dart';

/// Conversion conventions of the "Tempo assistido" statistic (docs/18):
/// 1 day = 24 h, 1 month = 30 days, 1 year = 365 days.
const int kMinutesPerHour = 60;
const int kMinutesPerDay = 24 * kMinutesPerHour;
const int kMinutesPerMonth = 30 * kMinutesPerDay;
const int kMinutesPerYear = 365 * kMinutesPerDay;

/// Total watched time and how trustworthy it is.
class WatchTime {
  final int minutes;

  /// Episodes counted with the show's typical runtime instead of their own.
  final int estimated;

  /// Watched titles/episodes with no runtime available yet (not in the total).
  final int unknown;

  const WatchTime({this.minutes = 0, this.estimated = 0, this.unknown = 0});

  bool get isExact => estimated == 0 && unknown == 0;
}

class WatchTimeCalculator {
  const WatchTimeCalculator._();

  /// Sums the runtime of watched movies and watched episodes. Episode
  /// runtime: the episode's own (local catalog), else the show's typical
  /// `episode_run_time` (counted as estimated), else unknown (NOT counted:
  /// never a made-up number).
  static WatchTime compute(
    List<FavoriteDoc> docs, {
    required List<SeasonCache> Function(int tvId) catalog,
    required int? Function(int movieId) movieRuntime,
    required int? Function(int tvId) tvFallbackRuntime,
  }) {
    var minutes = 0, estimated = 0, unknown = 0;
    for (final doc in docs) {
      if (doc.mediaType == MediaType.movie) {
        if (!doc.watchedMovie) continue;
        final runtime = movieRuntime(doc.id);
        runtime == null ? unknown++ : minutes += runtime;
        continue;
      }
      if (doc.watchedEpisodes.isEmpty) continue;
      final own = <String, int>{
        for (final season in catalog(doc.id))
          for (final ep in season.episodes)
            if (ep.runtime != null)
              FavoriteMapper.episodeKey(season.seasonNumber, ep.episodeNumber): ep.runtime!,
      };
      final fallback = tvFallbackRuntime(doc.id);
      for (final key in doc.watchedEpisodes) {
        final runtime = own[key];
        if (runtime != null) {
          minutes += runtime;
        } else if (fallback != null) {
          minutes += fallback;
          estimated++;
        } else {
          unknown++;
        }
      }
    }
    return WatchTime(minutes: minutes, estimated: estimated, unknown: unknown);
  }
}

/// pt-BR formatting of a duration, showing only the relevant units:
/// `< 1 h` minutes; `< 24 h` hours (+ minutes); `>= 24 h` days and hours;
/// `>= 30 days` months, days, hours; `>= 365 days` years, months, days, hours.
/// Zero units are omitted; from one day up minutes are dropped.
class WatchTimeFormatter {
  const WatchTimeFormatter._();

  static String format(int totalMinutes) {
    final minutes = totalMinutes < 0 ? 0 : totalMinutes;
    if (minutes < kMinutesPerHour) return _unit(minutes, 'min', 'min');
    if (minutes < kMinutesPerDay) {
      final h = minutes ~/ kMinutesPerHour;
      final m = minutes % kMinutesPerHour;
      return _join([_unit(h, 'hora', 'horas'), if (m > 0) _unit(m, 'min', 'min')]);
    }
    var rest = minutes;
    final years = rest ~/ kMinutesPerYear;
    rest %= kMinutesPerYear;
    final months = rest ~/ kMinutesPerMonth;
    rest %= kMinutesPerMonth;
    final days = rest ~/ kMinutesPerDay;
    rest %= kMinutesPerDay;
    final hours = rest ~/ kMinutesPerHour;
    return _join([
      if (years > 0) _unit(years, 'ano', 'anos'),
      if (months > 0) _unit(months, 'mês', 'meses'),
      if (days > 0) _unit(days, 'dia', 'dias'),
      if (hours > 0) _unit(hours, 'hora', 'horas'),
    ]);
  }

  /// "1.234 h no total" (whole hours, thousands separated with a dot).
  static String accumulatedHours(int totalMinutes) {
    final hours = (totalMinutes < 0 ? 0 : totalMinutes) ~/ kMinutesPerHour;
    return '${_thousands(hours)} h no total';
  }

  static String _thousands(int n) {
    final digits = n.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write('.');
      out.write(digits[i]);
    }
    return out.toString();
  }

  static String _unit(int n, String one, String many) => '$n ${n == 1 ? one : many}';

  static String _join(List<String> parts) {
    if (parts.length <= 1) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} e ${parts.last}';
  }
}
