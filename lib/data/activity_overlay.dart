import 'server_clock.dart';

/// Keeps the client-side time of the user's own latest watch marks until the
/// server confirms them.
///
/// `lastWatchedAt` is written with `FieldValue.serverTimestamp()`. While that
/// write is pending, the Firestore snapshot reports the field as null (the
/// plugin exposes no "estimate" option), which used to sink the item to its
/// `addedAt` position until the acknowledgement arrived. This overlay answers
/// with the local time of the mark instead, only while the document still has
/// pending writes; the server value takes over afterwards.
///
/// The confirmation is also how the [ServerClock] learns the server offset
/// (docs/82 §4.2): the first snapshot WITHOUT pending writes after one WITH
/// them carries the server time of that mark.
class ActivityOverlay {
  final ServerClock? clock;
  final Map<String, _Stamp> _stamps = {};

  ActivityOverlay({this.clock});

  /// Call when a watch mark is written for [key].
  void stamp(String key, [DateTime? at]) =>
      _stamps[key] = _Stamp(at ?? DateTime.now(), Stopwatch()..start());

  /// The `lastWatchedAt` to expose for [key]: [fromDoc] as read from the
  /// snapshot, replaced by the local stamp while the write is [pending].
  DateTime? resolve(String key, DateTime? fromDoc, {required bool pending}) {
    if (!pending) {
      final done = _stamps.remove(key);
      if (done != null && done.seenPending && fromDoc != null) {
        clock?.sample(local: done.at, server: fromDoc, elapsed: done.watch.elapsed);
      }
      return fromDoc;
    }
    final local = _stamps[key];
    if (local == null) return fromDoc;
    local.seenPending = true;
    return fromDoc == null || local.at.isAfter(fromDoc) ? local.at : fromDoc;
  }
}

class _Stamp {
  final DateTime at;
  final Stopwatch watch;
  bool seenPending = false;

  _Stamp(this.at, this.watch);
}
