import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

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
