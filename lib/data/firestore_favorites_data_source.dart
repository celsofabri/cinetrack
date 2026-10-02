import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/favorite_doc.dart';
import '../models/tv_season_summary.dart';
import '../services/favorite_mapper.dart';
import 'favorites_data_source.dart';
import 'sync_status.dart';

/// Firestore implementation: one document per favorite under
/// `users/{uid}/favorites/{key}`; episode progress is the `eps` map
/// (`"{season}_{episode}": true`) updated by field path, so the server
/// merges concurrent edits per episode. Bound to a single [uid] — the only
/// path this class can read or write is that user's space.
///
/// UNVERIFIED against a real project/emulator (no credentials yet): the
/// offline behaviors below follow the SDK documentation.
class FirestoreFavoritesDataSource implements FavoritesDataSource {
  final FirebaseFirestore _db;
  final String uid;
  final SyncFailureSink _sink;

  FirestoreFavoritesDataSource({
    required this.uid,
    required SyncFailureSink sink,
    FirebaseFirestore? firestore,
  })  : _sink = sink,
        _db = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('users').doc(uid).collection('favorites');

  @override
  Stream<List<FavoriteDoc>> watchAll() => _col.snapshots().map(
        (snapshot) => [
          for (final doc in snapshot.docs)
            if (FavoriteMapper.fromMap(doc.id, _fromFirestore(doc.data())) case final parsed?)
              parsed,
        ],
      );

  /// Metadata-aware listener: `hasPendingWrites` / `isFromCache` drive the
  /// sync indicator. Its errors (rules, quota, expired session) are not
  /// thrown to the UI here: they go to the sink, and the same error also
  /// reaches [watchAll] subscribers (which show the retry state).
  @override
  Stream<SyncMeta> watchSyncMeta() => _col
      .snapshots(includeMetadataChanges: true)
      .map((snapshot) => SyncMeta(
            hasPendingWrites: snapshot.metadata.hasPendingWrites,
            fromCache: snapshot.metadata.isFromCache,
          ))
      .handleError(_report);

  @override
  Future<FavoriteDoc?> get(String key) async {
    final ref = _col.doc(key);
    DocumentSnapshot<Map<String, dynamic>> snap;
    try {
      // The cache is kept warm by the active listener; reading it avoids
      // waiting on the network when offline.
      snap = await ref.get(const GetOptions(source: Source.cache));
    } on FirebaseException {
      try {
        snap = await ref.get();
      } on FirebaseException catch (e) {
        debugPrint('Firestore read failed: ${e.code}');
        throw const FavoritesUnavailableException();
      }
    }
    final data = snap.data();
    if (!snap.exists || data == null) return null;
    return FavoriteMapper.fromMap(key, _fromFirestore(data));
  }

  @override
  Future<void> add(FavoriteDoc doc) {
    final data = FavoriteMapper.toMap(doc)
      ..['addedAt'] = Timestamp.fromDate(doc.addedAt)
      ..['lastWatchedAt'] = null
      ..['updatedAt'] = FieldValue.serverTimestamp();
    return _fire(() => _col.doc(doc.key).set(data));
  }

  @override
  Future<void> remove(String key) => _fire(() => _col.doc(key).delete());

  @override
  Future<void> setWatchedMovie(String key, bool watched) => _fire(
        () => _col.doc(key).update({
          'watchedMovie': watched,
          'updatedAt': FieldValue.serverTimestamp(),
        }),
      );

  @override
  Future<void> setEpisodes(String key, Map<String, bool> changes) => _fire(
        () => _col.doc(key).update({
          for (final entry in changes.entries)
            'eps.${entry.key}': entry.value ? true : FieldValue.delete(),
          'lastWatchedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }),
      );

  @override
  Future<void> setSeasonSummaries(String key, List<TvSeasonSummary> summaries) => _fire(
        () => _col.doc(key).update({
          'seasonSummaries': summaries.map((s) => s.toJson()).toList(),
          'updatedAt': FieldValue.serverTimestamp(),
        }),
      );

  /// See [SyncFailureSink.fire]: not awaited on purpose; rejections reach
  /// the sink (code only, no PII) and become visible to the user.
  Future<void> _fire(Future<void> Function() write) =>
      _sink.fire(write, codeOf: (e) => e is FirebaseException ? e.code : null);

  void _report(Object error) {
    if (error is FirebaseException) {
      debugPrint('Firestore failure: ${error.code}');
      _sink.reportCode(error.code);
    } else {
      _sink.reportUnknown(error);
    }
  }

  Map<String, dynamic> _fromFirestore(Map<String, dynamic> data) => {
        for (final entry in data.entries)
          entry.key: entry.value is Timestamp ? (entry.value as Timestamp).toDate() : entry.value,
      };
}
