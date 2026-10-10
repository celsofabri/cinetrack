import '../models/favorite_doc.dart';
import 'favorite_mapper.dart';

/// Most dates a favorite may hold: the rules cap `epsAt` at 5000 entries
/// (same as `eps`). The app never sends a write that would pass it: the mark
/// then goes WITHOUT a date (a mark is never refused because of its date).
const kMaxEpisodeDates = 5000;

/// Orphan dates removed per write (docs/82 §4.2).
const kMaxOrphanDeletesPerWrite = 500;

/// What one `setEpisodes` write does to `epsAt`: dates to set and keys to
/// delete. Pure value (no Firebase types).
class EpisodeDatesPlan {
  final Map<String, DateTime> set;
  final Set<String> delete;

  const EpisodeDatesPlan({this.set = const {}, this.delete = const {}});

  static const none = EpisodeDatesPlan();

  bool get isEmpty => set.isEmpty && delete.isEmpty;

  /// [watchedAt] after this plan (what the server will hold).
  Map<String, DateTime> applyTo(Map<String, DateTime> watchedAt) => {
    for (final e in watchedAt.entries)
      if (!delete.contains(e.key)) e.key: e.value,
    ...set,
  };
}

/// Pure rules of the episode mark dates (`epsAt`, docs/82 §4.2).
class EpisodeDates {
  const EpisodeDates._();

  /// Plans the `epsAt` part of a `setEpisodes` write.
  ///
  /// - marked keys get [instant] (ONE instant for the whole write), or, when
  ///   [restore] is given (Desfazer), the date they had before (none if they
  ///   had none: an undo never makes the history younger);
  /// - unmarked keys lose their date;
  /// - orphan dates (key no longer in `eps`, left by an older app) are
  ///   deleted, at most [kMaxOrphanDeletesPerWrite] per write;
  /// - [current] null (state unknown): no new dates, only deletions;
  /// - the result never exceeds [kMaxEpisodeDates]: if it would, the marks go
  ///   without dates.
  static EpisodeDatesPlan plan({
    required Map<String, bool> changes,
    required FavoriteDoc? current,
    required DateTime instant,
    Map<String, DateTime>? restore,
  }) {
    final marks = [
      for (final e in changes.entries)
        if (e.value) e.key,
    ];
    final unmarks = [
      for (final e in changes.entries)
        if (!e.value) e.key,
    ];
    final dated = current?.watchedAt ?? const <String, DateTime>{};
    final delete = <String>{
      for (final k in unmarks)
        if (current == null || dated.containsKey(k)) k,
    };
    final set = <String, DateTime>{};
    if (current != null) {
      final after = FavoriteMapper.applyEpisodeChanges(current.watchedEpisodes, changes);
      final orphans = [
        for (final k in dated.keys)
          if (!after.contains(k) && !delete.contains(k)) k,
      ]..sort();
      delete.addAll(orphans.take(kMaxOrphanDeletesPerWrite));
      for (final k in marks) {
        final at = restore == null ? instant : restore[k];
        if (at != null) set[k] = at;
      }
      final remaining = {
        for (final k in dated.keys)
          if (!delete.contains(k)) k,
      };
      if (remaining.union(set.keys.toSet()).length > kMaxEpisodeDates) set.clear();
    }
    // A key both marked and unmarked cannot happen (one map), but a mark of a
    // key we were about to delete as orphan must keep its new date.
    delete.removeAll(set.keys);
    return EpisodeDatesPlan(set: set, delete: delete);
  }
}
