import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../social/social_models.dart';
import 'export_data_source.dart';

/// Firestore implementation of the read-only export: pages of
/// `users/{uid}/favorites` ordered by document id, plus `users/{uid}`.
///
/// UNVERIFIED against a real project (no credentials in the dev
/// environment): behavior of `Source.server`/`Source.cache` follows the SDK
/// documentation.
class FirestoreExportDataSource implements ExportDataSource {
  final FirebaseFirestore _db;
  final String uid;
  final Duration timeout;

  FirestoreExportDataSource({
    required this.uid,
    this.timeout = const Duration(seconds: 30),
    FirebaseFirestore? firestore,
  }) : _db = firestore ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get _profile => _db.collection('users').doc(uid);
  CollectionReference<Map<String, dynamic>> get _favorites => _profile.collection('favorites');

  GetOptions _options(bool fromServer) =>
      GetOptions(source: fromServer ? Source.server : Source.cache);

  @override
  Future<RawPage> readPage({String? cursor, required int limit, required bool fromServer}) async {
    var query = _favorites.orderBy(FieldPath.documentId).limit(limit);
    if (cursor != null) query = query.startAfter([cursor]);
    final snapshot = await _guard(() => query.get(_options(fromServer)));
    return RawPage([for (final doc in snapshot.docs) RawDoc(doc.id, convert(doc.data()))]);
  }

  @override
  Future<Map<String, dynamic>?> readProfile({required bool fromServer}) async {
    try {
      final snapshot = await _guard(() => _profile.get(_options(fromServer)));
      final data = snapshot.data();
      return data == null ? null : convert(data);
    } on ExportReadException {
      // A profile that is not on this device is "no profile", not a failure.
      if (!fromServer) return null;
      rethrow;
    }
  }

  DocumentReference<Map<String, dynamic>> get _social => _db.collection('social').doc(uid);

  @override
  Future<RawSocial?> readSocial({required bool fromServer}) async {
    try {
      final options = _options(fromServer);
      final pointer = (await _guard(() => _social.get(options))).data();
      if (pointer == null) return null;
      final handle = pointer['handle'];
      Map<String, dynamic>? card;
      if (handle is String && handle.isNotEmpty) {
        card = (await _guard(() => _db.collection('handles').doc(handle).get(options))).data();
      }
      return RawSocial(social: convert(pointer), card: card == null ? null : convert(card));
    } on ExportReadException catch (e) {
      // Rules not published yet (denied): friendships cannot exist. A document
      // that is not on this device is "not activated", not a failure.
      if (e.kind == ExportReadFailureKind.denied || !fromServer) return null;
      rethrow;
    }
  }

  // The social lists are read without orderBy (documents come by id) and the
  // cursor is the last snapshot of the previous page: the same query shapes as
  // the account-deletion sweeps, so no composite index is needed.
  final Map<SocialExportKind, DocumentSnapshot<Map<String, dynamic>>> _lastSocial = {};

  @override
  Future<RawPage> readSocialPage(
    SocialExportKind kind, {
    String? cursor,
    required int limit,
    required bool fromServer,
  }) async {
    Query<Map<String, dynamic>> query = switch (kind) {
      SocialExportKind.friends =>
        _db.collection('friendships').where('members', arrayContains: uid),
      SocialExportKind.requestsSent =>
        _db.collection('friend_requests').where('from', isEqualTo: uid),
      SocialExportKind.requestsReceived =>
        _db.collection('friend_requests').where('to', isEqualTo: uid),
      SocialExportKind.blocks => _profile.collection('blocks'),
    };
    if (cursor == null) {
      _lastSocial.remove(kind);
    } else {
      final last = _lastSocial[kind];
      if (last == null || last.id != cursor) {
        throw const ExportReadException(ExportReadFailureKind.unknown, code: 'cursor-lost');
      }
      query = query.startAfterDocument(last);
    }
    final snapshot = await _guard(() => query.limit(limit).get(_options(fromServer)));
    if (snapshot.docs.isNotEmpty) _lastSocial[kind] = snapshot.docs.last;
    return RawPage([for (final doc in snapshot.docs) RawDoc(doc.id, convert(doc.data()))]);
  }

  Future<T> _guard<T>(Future<T> Function() read) => guard(read, timeout);

  /// Runs [read] with a timeout, mapping provider errors to
  /// [ExportReadException].
  @visibleForTesting
  static Future<T> guard<T>(Future<T> Function() read, Duration timeout) async {
    try {
      return await read().timeout(timeout);
    } catch (e) {
      final mapped = mapError(e);
      if (mapped == null) rethrow;
      throw mapped;
    }
  }

  /// Maps a provider error to [ExportReadException]; null = not ours.
  @visibleForTesting
  static ExportReadException? mapError(Object e) {
    if (e is TimeoutException) {
      return const ExportReadException(ExportReadFailureKind.unreachable, code: 'timeout');
    }
    if (e is! FirebaseException) return null;
    debugPrint('Export read failed: ${e.code}'); // code only, never data
    return ExportReadException(switch (e.code) {
      'unavailable' || 'deadline-exceeded' || 'cancelled' => ExportReadFailureKind.unreachable,
      'permission-denied' || 'unauthenticated' => ExportReadFailureKind.denied,
      _ => ExportReadFailureKind.unknown,
    }, code: e.code);
  }

  @visibleForTesting
  static Map<String, dynamic> convert(Map<String, dynamic> data) => {
    for (final e in data.entries) e.key: convertValue(e.value),
  };

  @visibleForTesting
  static Object? convertValue(Object? value) => switch (value) {
    Timestamp() => value.toDate(),
    Map() => {for (final e in value.entries) '${e.key}': convertValue(e.value)},
    List() => [for (final item in value) convertValue(item)],
    _ => value,
  };
}
