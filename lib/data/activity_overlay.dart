/// Keeps the client-side time of the user's own latest watch marks until the
/// server confirms them.
///
/// `lastWatchedAt` is written with `FieldValue.serverTimestamp()`. While that
/// write is pending, the Firestore snapshot reports the field as null (the
/// plugin exposes no "estimate" option), which used to sink the item to its
/// `addedAt` position until the acknowledgement arrived. This overlay answers
/// with the local time of the mark instead, only while the document still has
/// pending writes; the server value takes over afterwards.
class ActivityOverlay {
  final Map<String, DateTime> _stamps = {};

  /// Call when a watch mark is written for [key].
  void stamp(String key, [DateTime? at]) => _stamps[key] = at ?? DateTime.now();

  /// The `lastWatchedAt` to expose for [key]: [fromDoc] as read from the
  /// snapshot, replaced by the local stamp while the write is [pending].
  DateTime? resolve(String key, DateTime? fromDoc, {required bool pending}) {
    if (!pending) {
      _stamps.remove(key);
      return fromDoc;
    }
    final local = _stamps[key];
    if (local == null) return fromDoc;
    return fromDoc == null || local.isAfter(fromDoc) ? local : fromDoc;
  }
}
