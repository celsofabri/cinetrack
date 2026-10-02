import 'package:cloud_firestore/cloud_firestore.dart';

import 'deletion_guard.dart';
import 'profile_data_source.dart';
import 'sync_status.dart';

/// Firestore implementation of the profile document `users/{uid}` and of the
/// data wipe used by account deletion. Bound to a single [uid].
///
/// UNVERIFIED against a real project (needs Firebase): the emulator tests
/// cover the rules for this sequence of operations, not this class.
class FirestoreProfileDataSource implements ProfileDataSource {
  final FirebaseFirestore _db;
  final String uid;
  final SyncFailureSink _sink;

  /// Page size of the delete batches (Firestore allows 500 per batch).
  static const batchSize = 400;

  FirestoreProfileDataSource({
    required this.uid,
    required SyncFailureSink sink,
    FirebaseFirestore? firestore,
  })  : _sink = sink,
        _db = firestore ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get _doc => _db.collection('users').doc(uid);
  CollectionReference<Map<String, dynamic>> get _favorites => _doc.collection('favorites');

  @override
  Stream<UserProfile> watch() => _doc.snapshots().map((snapshot) {
        final data = snapshot.data();
        if (data == null) return UserProfile.empty;
        final nickname = data['displayName'];
        return UserProfile(
          nickname: nickname is String && nickname.trim().isNotEmpty ? nickname : null,
          deleting: data['deleting'] == true,
        );
      });

  @override
  Future<void> setNickname(String? nickname) => _sink.fire(
        () => _doc.set(
          {
            'displayName': nickname ?? FieldValue.delete(),
            'schemaVersion': 1,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        ),
        codeOf: (e) => e is FirebaseException ? e.code : null,
      );

  @override
  Future<void> ensureOnline() => guardDeletionStep(
        () => _favorites.limit(1).get(const GetOptions(source: Source.server)),
        write: false,
      );

  @override
  Future<void> markDeleting() => guardDeletionStep(
        () => _doc.set(
          {
            'deleting': true,
            'schemaVersion': 1,
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        ),
        write: true,
      );

  @override
  Future<void> deleteAllFavorites() => wipeInPages<DocumentReference<Map<String, dynamic>>>(
        readPage: () async {
          final snapshot =
              await _favorites.limit(batchSize).get(const GetOptions(source: Source.server));
          return [for (final doc in snapshot.docs) doc.reference];
        },
        deletePage: (refs) {
          final batch = _db.batch();
          for (final ref in refs) {
            batch.delete(ref);
          }
          return batch.commit();
        },
      );

  @override
  Future<void> deleteProfile() => guardDeletionStep(() => _doc.delete(), write: true);
}
