import '../models/favorite_item.dart';
import '../models/media_type.dart';
import 'progress_calculator.dart';

/// Where a favorite stands. Drives the "Em andamento" / "Concluídos" groups.
enum WatchState {
  /// Movie watched, or series with every already-aired episode watched.
  completed,

  /// Series with some, but not all, aired episodes watched.
  inProgress,

  /// Movie not watched, or series with nothing watched.
  notStarted,

  /// Series whose seasons are still being downloaded on this device (new
  /// login/device): progress is unknown, never shown as 0.
  calculating,

  /// Same, but the download failed; shown with a retry.
  unavailable,
}

/// Pure rule behind the favorites groups (docs/18). A series is
/// "concluded" when every episode that has already aired is watched — see
/// [SeriesProgress.isCaughtUp]. It can only be decided once the season
/// catalog covers every known season; until then the state is
/// [WatchState.calculating] instead of a false 0.
class FavoriteStatus {
  final WatchState state;

  /// Null for movies and while the series is calculating/unavailable.
  final SeriesProgress? progress;

  /// The numbers come from a PARTIAL catalog (some seasons not downloaded
  /// yet, e.g. offline): shown as "Parcial", never as completed.
  final bool approximate;

  const FavoriteStatus(this.state, [this.progress, this.approximate = false]);

  bool get isCompleted => state == WatchState.completed;

  /// Whether the cached seasons cover every season listed in the summaries.
  /// Hydrated favorites always carry a summaries list: EMPTY means the season
  /// list itself is unknown (favorited offline), so nothing is covered. Null
  /// (items built without cloud data) trusts the seasons given.
  static bool catalogCovers(FavoriteItem item) {
    final seasons = item.seasons ?? const [];
    if (seasons.isEmpty) return false;
    final summaries = item.seasonSummaries;
    if (summaries == null) return true;
    if (summaries.isEmpty) return false;
    final cached = {for (final s in seasons) s.seasonNumber};
    return summaries.every((s) => cached.contains(s.seasonNumber));
  }

  /// [settled]: the background reconciliation finished for this show, so an
  /// empty catalog means "no episodes" rather than "not downloaded yet".
  /// [failed]: it gave up.
  static FavoriteStatus of(FavoriteItem item, {bool settled = false, bool failed = false}) {
    if (item.mediaType == MediaType.movie) {
      return FavoriteStatus(item.watchedMovie ? WatchState.completed : WatchState.notStarted);
    }
    if (!catalogCovers(item)) {
      if (settled) {
        final progress = ProgressCalculator.compute(item.seasons ?? const []);
        return FavoriteStatus(
          progress.isStarted ? WatchState.inProgress : WatchState.notStarted,
          progress,
          (item.seasons ?? const []).isNotEmpty,
        );
      }
      final partial = item.seasons ?? const [];
      if (partial.isNotEmpty) {
        // Keep the last known state instead of losing it: what we have, flagged
        // approximate, and never "completed" (a season may be missing).
        final progress = ProgressCalculator.compute(partial);
        return FavoriteStatus(
          progress.isStarted ? WatchState.inProgress : WatchState.notStarted,
          progress,
          true,
        );
      }
      return FavoriteStatus(failed ? WatchState.unavailable : WatchState.calculating);
    }
    final progress = ProgressCalculator.compute(item.seasons!);
    final state = progress.isCaughtUp
        ? WatchState.completed
        : progress.isStarted
            ? WatchState.inProgress
            : WatchState.notStarted;
    return FavoriteStatus(state, progress);
  }
}
