import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../shared_profile/shared_profile_payloads.dart';
import 'social_payloads.dart';
import '../social/social_models.dart';
import 'firestore_social_data_source.dart';
import 'shared_profile_data_source.dart';

/// Reads one document by path. Default: Firestore; tests inject a fake.
typedef SharedDocGet = Future<Map<String, dynamic>?> Function(String path, {required bool server});

/// Deletes one document by path (awaited). Default: Firestore.
typedef SharedDocDelete = Future<void> Function(String path);

/// Runs a toggle transaction: reads the own document through [read], then
/// calls [apply] with the write to perform. Default: Firestore
/// `runTransaction`; tests inject a fake to run the error mapping.
typedef SharedTxRunner =
    Future<void> Function(
      String path,
      Future<void> Function(Map<String, dynamic>? current, void Function(SocialWrite) apply) body,
    );

/// Sends one recalculation `update`. Default: Firestore.
typedef SharedDocUpdate = Future<void> Function(String path, Map<String, Object?> data);

/// Firestore implementation of [SharedProfileDataSource] for ONE user.
/// Reads/deletes are awaited (with [timeout]) and mapped to [SocialFailure]
/// by the same guard as the social source.
///
/// UNVERIFIED against a real project: the rules tests cover what these calls
/// may do, not this class (same status as the Phase 1 sources).
class FirestoreSharedProfileDataSource implements SharedProfileDataSource {
  final FirebaseFirestore? firestore;
  @override
  final String uid;
  final Duration timeout;
  final SharedDocGet? getter;
  final SharedDocDelete? deleter;
  final SharedTxRunner? txRunner;
  final SharedDocUpdate? updater;

  /// A toggle without an answer within this time is "uncertain" (RF-P7).
  final Duration toggleTimeout;

  FirestoreSharedProfileDataSource({
    required this.uid,
    this.firestore,
    this.timeout = const Duration(seconds: 30),
    this.toggleTimeout = const Duration(seconds: 10),
    @visibleForTesting this.getter,
    @visibleForTesting this.deleter,
    @visibleForTesting this.txRunner,
    @visibleForTesting this.updater,
  });

  FirebaseFirestore get _db => firestore ?? FirebaseFirestore.instance;

  String get _path => SharedProfilePayloads.path(uid);

  Future<Map<String, dynamic>?> _get(String path, {required bool server}) async {
    final custom = getter;
    if (custom != null) return custom(path, server: server);
    final snap = await _db.doc(path).get(GetOptions(source: server ? Source.server : Source.cache));
    // A server read must never be answered by the device cache (D10).
    if (server && snap.metadata.isFromCache) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    final data = snap.data();
    if (!snap.exists || data == null) return null;
    return FirestoreSocialDataSource.convert(data);
  }

  @override
  Future<Map<String, dynamic>?> readOwn({required bool fromServer}) async {
    try {
      return await FirestoreSocialDataSource.guard(
        () => _get(_path, server: fromServer),
        timeout,
        write: false,
      );
    } on SocialFailure {
      // Not on this device is "absent", not a failure.
      if (!fromServer) return null;
      rethrow;
    }
  }

  @override
  Future<RulesProbe> probeRules() async {
    try {
      await FirestoreSocialDataSource.guard(() => _get(_path, server: true), timeout, write: false);
      return RulesProbe.ready;
    } on SocialFailure catch (e) {
      return e.kind == SocialFailureKind.denied ? RulesProbe.oldRules : RulesProbe.unreachable;
    } catch (_) {
      return RulesProbe.unreachable;
    }
  }

  @override
  Future<void> deleteOwn() async {
    try {
      await FirestoreSocialDataSource.guard(
        () {
          final custom = deleter;
          return custom != null ? custom(_path) : _db.doc(_path).delete();
        },
        timeout,
        write: true,
      );
    } on SocialFailure catch (e) {
      // Old rules: the collection cannot be written, so nothing exists.
      if (e.kind == SocialFailureKind.denied) return;
      rethrow;
    }
  }

  /// Codes that, once the write was sent, leave its fate unknown.
  static const _uncertainCodes = {'unavailable', 'deadline-exceeded', 'cancelled'};

  @override
  Future<void> toggle(SocialWrite Function(Map<String, dynamic>? current) plan) async {
    var sent = false;
    Future<void> body(Map<String, dynamic>? current, void Function(SocialWrite) apply) async {
      final write = plan(current);
      if (write.mode != SocialWriteMode.transaction) {
        throw StateError('a toggle is a transaction');
      }
      apply(write);
      sent = true;
    }

    try {
      await _runTx(body).timeout(toggleTimeout);
    } on SocialFailure {
      rethrow;
    } on TimeoutException {
      // The SDK may still commit it: never "failed" (B5).
      throw const SocialFailure(SocialFailureKind.uncertain, code: 'timeout');
    } on FirebaseException catch (e) {
      debugPrint('Shared profile toggle failed: ${e.code}'); // code only, never data
      if (sent && _uncertainCodes.contains(e.code)) {
        throw SocialFailure(SocialFailureKind.uncertain, code: e.code);
      }
      throw SocialFailure.fromFirestoreCode(e.code);
    }
  }

  Future<void> _runTx(
    Future<void> Function(Map<String, dynamic>? current, void Function(SocialWrite) apply) body,
  ) {
    final custom = txRunner;
    if (custom != null) return custom(_path, body);
    final ref = _db.doc(_path);
    return _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data();
      await body(snap.exists && data != null ? FirestoreSocialDataSource.convert(data) : null, (
        write,
      ) {
        for (final op in write.ops) {
          final doc = _db.doc(op.path);
          switch (op.op) {
            case 'set':
              tx.set(doc, _resolved(op.data!));
            case 'update':
              tx.update(doc, _resolved(op.data!));
            case 'delete':
              tx.delete(doc);
          }
        }
      });
    });
  }

  @override
  Future<void> writeSections(SocialWrite write) async {
    if (write.ops.length != 1 || write.ops.single.op != 'update') {
      throw StateError('a recalculation is one update');
    }
    final op = write.ops.single;
    try {
      // Not timed out: the write may wait in the SDK queue (it is only sent
      // online and is idempotent); its outcome is reported when it comes.
      final custom = updater;
      await (custom != null ? custom(op.path, op.data!) : _db.doc(op.path).update(_resolved(op.data!)));
    } on FirebaseException catch (e) {
      debugPrint('Shared profile write failed: ${e.code}'); // code only, never data
      throw SocialFailure.fromFirestoreCode(e.code);
    }
  }

  static Object? _resolve(Object? v) => switch (v) {
    ServerTimestamp() => FieldValue.serverTimestamp(),
    DeleteField() => FieldValue.delete(),
    Map() => {for (final e in v.entries) '${e.key}': _resolve(e.value)},
    List() => [for (final i in v) _resolve(i)],
    _ => v,
  };

  static Map<String, Object?> _resolved(Map<String, Object?> data) => {
    for (final e in data.entries) e.key: _resolve(e.value),
  };

  @override
  Future<Map<String, dynamic>?> readFriend(String friendUid) => FirestoreSocialDataSource.guard(
    () => _get(SharedProfilePayloads.path(friendUid), server: true),
    timeout,
    write: false,
  );
}
