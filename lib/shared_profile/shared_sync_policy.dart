import 'shared_profile_doc.dart';
import 'shared_profile_models.dart';

/// Coalescing window (docs/82 §6, B4): 5 s without a new change, at most
/// 30 s after the first pending change.
const kSharedSyncWindow = Duration(seconds: 5);
const kSharedSyncMaxWait = Duration(seconds: 30);

/// A catalog download running longer than this no longer holds the write.
const kSharedCatalogWait = Duration(seconds: 60);

/// Same content, but `updatedAt` older than this: one pulse (D7).
const kSharedPulseAge = Duration(hours: 24);

/// What one recalculation should write (pure; docs/82 §6).
class SharedSyncDecision {
  /// Sections whose content differs from the server's (shared ones only).
  final Set<SharedSection> changed;

  /// Nothing changed and `updatedAt` is older than [kSharedPulseAge].
  final bool pulse;

  const SharedSyncDecision({this.changed = const {}, this.pulse = false});

  bool get writes => changed.isNotEmpty || pulse;
}

class SharedSyncPolicy {
  const SharedSyncPolicy._();

  /// Compares the freshly built [next] with what the [server] holds
  /// ("só grava se mudou"), keeps the server's time figures when this device
  /// would make them less complete ("não regredir") and asks for a pulse
  /// when nothing changed for [kSharedPulseAge].
  ///
  /// [sections] = the sections the server has consent for (the caller built
  /// [next] with exactly these); nothing else is ever compared or written.
  static SharedSyncDecision decide(
    SharedProfileDoc server,
    SharedProfileContent next,
    DateTime now, {
    Set<SharedSection>? sections,
  }) {
    final current = server.content;
    final changed = <SharedSection>{
      for (final s in sections ?? server.sharing)
        if (!_same(s, current, next)) s,
    };
    if (changed.contains(SharedSection.stats) &&
        current.stats != null &&
        next.stats != null &&
        regresses(current.stats!, next.stats!)) {
      changed.remove(SharedSection.stats);
    }
    final updated = server.updatedAt;
    final pulse =
        changed.isEmpty &&
        server.sharing.isNotEmpty &&
        (updated == null || now.toUtc().difference(updated) > kSharedPulseAge);
    return SharedSyncDecision(changed: changed, pulse: pulse);
  }

  static bool _same(SharedSection s, SharedProfileContent a, SharedProfileContent b) => switch (s) {
    SharedSection.stats => a.stats == b.stats,
    SharedSection.activity => _listEq(a.activity, b.activity),
    SharedSection.recs => a.recs == b.recs,
  };

  static bool _listEq(List<ActivityItem>? a, List<ActivityItem>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// True when [next] has the same counts as [server] and differs only in
  /// the time figures, with more `estimated` or `unknown` somewhere (a
  /// device with an incomplete catalog must not worsen what another wrote).
  static bool regresses(SharedStats server, SharedStats next) {
    bool sameCounts(List<int> a, List<int> b) =>
        a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];
    final t1 = server.total, t2 = next.total;
    final countsEqual =
        t1.favorites == t2.favorites &&
        t1.movies == t2.movies &&
        t1.series == t2.series &&
        sameCounts(t1.metrics, t2.metrics) &&
        server.year.key == next.year.key &&
        server.month.key == next.month.key &&
        sameCounts(server.year.metrics, next.year.metrics) &&
        sameCounts(server.month.metrics, next.month.metrics) &&
        server.undatedMovies == next.undatedMovies &&
        server.undatedEpisodes == next.undatedEpisodes &&
        server == next.copyWith(total: t1, year: server.year, month: server.month);
    if (!countsEqual) return false;
    bool worse(List<int> s, List<int> n) => n[5] > s[5] || n[6] > s[6];
    return worse(t1.metrics, t2.metrics) ||
        worse(server.year.metrics, next.year.metrics) ||
        worse(server.month.metrics, next.month.metrics);
  }

  /// The next instant the owner's month (in [tzMinutes]) turns over, after
  /// [now]: the content changes then even without any mark (RF-S3).
  static DateTime nextMonthTurn(DateTime now, int tzMinutes) {
    final local = now.toUtc().add(Duration(minutes: tzMinutes));
    final start = DateTime.utc(local.year, local.month + 1);
    return start.subtract(Duration(minutes: tzMinutes));
  }
}
