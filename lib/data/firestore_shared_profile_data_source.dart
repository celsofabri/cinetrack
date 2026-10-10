import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../shared_profile/shared_profile_payloads.dart';
import '../social/social_models.dart';
import 'firestore_social_data_source.dart';
import 'shared_profile_data_source.dart';

/// Reads one document by path. Default: Firestore; tests inject a fake.
typedef SharedDocGet = Future<Map<String, dynamic>?> Function(String path, {required bool server});

/// Deletes one document by path (awaited). Default: Firestore.
typedef SharedDocDelete = Future<void> Function(String path);

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

  FirestoreSharedProfileDataSource({
    required this.uid,
    this.firestore,
    this.timeout = const Duration(seconds: 30),
    @visibleForTesting this.getter,
    @visibleForTesting this.deleter,
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

  @override
  Future<Map<String, dynamic>?> readFriend(String friendUid) => FirestoreSocialDataSource.guard(
    () => _get(SharedProfilePayloads.path(friendUid), server: true),
    timeout,
    write: false,
  );
}
