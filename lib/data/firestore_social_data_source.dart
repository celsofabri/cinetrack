import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../social/social_models.dart';
import 'social_data_source.dart';
import 'social_payloads.dart';

/// Firestore implementation of the social documents of ONE user ([uid]).
/// The security rules (`firestore.rules`, docs/51) are the real guard; this
/// class only has to write exactly what they accept:
///
/// - `handles/{h}` (card) and `social/{uid}` (pointer) are created, moved
///   and removed together, in one transaction or batch (the rules check each
///   other with `getAfter`);
/// - every timestamp is `FieldValue.serverTimestamp()` (`== request.time`);
/// - every query is parameterised by [uid] (the browser cache is shared by
///   all accounts of the device).
///
/// UNVERIFIED against a real project (needs Firebase): the emulator tests
/// cover the rules for this sequence of operations, not this class.
class FirestoreSocialDataSource implements SocialDataSource {
  final FirebaseFirestore _db;
  final String uid;
  final Duration timeout;

  FirestoreSocialDataSource({
    required this.uid,
    this.timeout = const Duration(seconds: 30),
    FirebaseFirestore? firestore,
  }) : _db = firestore ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get _social => _db.collection('social').doc(uid);
  DocumentReference<Map<String, dynamic>> _handle(String h) => _db.collection('handles').doc(h);
  DocumentReference<Map<String, dynamic>> _invite(String c) => _db.collection('invites').doc(c);

  @override
  Future<RawSocial> read({required bool fromServer}) => _guard(() async {
    final options = GetOptions(source: fromServer ? Source.server : Source.cache);
    final social = await _social.get(options);
    final data = social.data();
    if (data == null) return const RawSocial();
    final handle = data['handle'];
    Map<String, dynamic>? card;
    if (handle is String && handle.isNotEmpty) {
      card = (await _handle(handle).get(options)).data();
    }
    return RawSocial(social: convert(data), card: card == null ? null : convert(card));
  }, write: false);

  @override
  Future<bool> isHandleFree(String handle) => _guard(() async {
    try {
      final snapshot = await _handle(handle).get(const GetOptions(source: Source.server));
      return !snapshot.exists;
    } on FirebaseException catch (e) {
      // Exists but hidden from us (hidden / blocked): taken.
      if (e.code == 'permission-denied') return false;
      rethrow;
    }
  }, write: false);

  @override
  Future<void> activate(SocialDraft draft) => _guard(
    () => _db.runTransaction((tx) async {
      final card = _handle(draft.handle);
      if ((await _txGetHandle(tx, card)).exists) {
        throw const SocialFailure(SocialFailureKind.handleTaken);
      }
      if ((await tx.get(_social)).exists) {
        throw const SocialFailure(SocialFailureKind.alreadyActive);
      }
      _applyTx(tx, SocialPayloads.activate(uid, draft));
    }),
    write: true,
  );

  @override
  Future<void> changeHandle(String newHandle) => _guard(
    () => _db.runTransaction((tx) async {
      final social = (await tx.get(_social)).data();
      final old = social?['handle'];
      if (old is! String) throw const SocialFailure(SocialFailureKind.notActive);
      if (old == newHandle) return;
      final changed = social?['handleChangedAt'];
      if (changed is Timestamp) {
        final next = changed.toDate().add(const Duration(days: 30));
        if (next.isAfter(DateTime.now())) {
          throw SocialFailure(SocialFailureKind.tooSoon, retryAt: next);
        }
      }
      final oldCard = (await tx.get(_handle(old))).data();
      if (oldCard == null) {
        throw const SocialFailure(SocialFailureKind.unknown, code: 'card-missing');
      }
      final target = _handle(newHandle);
      if ((await _txGetHandle(tx, target)).exists) {
        throw const SocialFailure(SocialFailureKind.handleTaken);
      }
      _applyTx(
        tx,
        SocialPayloads.changeHandle(
          uid,
          oldHandle: old,
          newHandle: newHandle,
          nickname: oldCard['nickname'],
          photoUrl: oldCard['photoURL'],
          discoverable: oldCard['discoverable'] == true,
        ),
      );
    }),
    write: true,
  );

  @override
  Future<void> updateCard(CardPatch patch) {
    if (patch.isEmpty) return Future.value();
    return _guard(
      () => _db.runTransaction((tx) async {
        final handle = (await tx.get(_social)).data()?['handle'];
        if (handle is! String) throw const SocialFailure(SocialFailureKind.notActive);
        _applyTx(tx, SocialPayloads.updateCard(handle, patch));
      }),
      write: true,
    );
  }

  @override
  Future<bool> closeSocial() async {
    const server = GetOptions(source: Source.server);
    final social = await _guard(() => _social.get(server), write: false);
    final data = social.data();
    if (data == null) return false;

    String? cardHandle;
    final handle = data['handle'];
    if (handle is String && handle.isNotEmpty) {
      final card = await _guard(() => _handle(handle).get(server), write: false);
      if (card.exists && card.data()?['uid'] == uid) cardHandle = handle;
    }
    String? inviteCode;
    final invite = data['inviteCode'];
    if (invite is String && invite.isNotEmpty) {
      final doc = await _guard(() => _invite(invite).get(server), write: false);
      if (doc.exists && doc.data()?['uid'] == uid) inviteCode = invite;
    }
    final close = SocialPayloads.close(uid, handle: cardHandle, inviteCode: inviteCode);
    await _guard(() => _commit(close), write: true);
    return true;
  }

  @override
  Future<List<SweepRef>> readSweepPage(SweepKind kind, {required int limit}) => _guard(() async {
    final spec = SocialPayloads.sweepQuery(kind, uid, limit);
    Query<Map<String, dynamic>> query = _db.collection(spec.collection);
    for (final (field, op, value) in spec.where) {
      query = switch (op) {
        '==' => query.where(field, isEqualTo: value),
        'array-contains' => query.where(field, arrayContains: value),
        _ => throw StateError('unsupported operator $op'),
      };
    }
    final snapshot = await query.limit(spec.limit).get(const GetOptions(source: Source.server));
    return [for (final doc in snapshot.docs) SweepRef(kind, doc.id)];
  }, write: false);

  @override
  Future<void> deleteRefs(List<SweepRef> refs) =>
      _guard(() => _commit(SocialPayloads.sweepDelete(uid, refs)), write: true);

  Object? _resolve(Object? v) => v is ServerTimestamp ? FieldValue.serverTimestamp() : v;

  Map<String, Object?> _resolved(Map<String, Object?> data) => {
    for (final e in data.entries) e.key: _resolve(e.value),
  };

  DocumentReference<Map<String, dynamic>> _doc(String path) => _db.doc(path);

  /// Executes the payload inside a transaction (the caller did the reads).
  void _applyTx(Transaction tx, SocialWrite write) {
    for (final op in write.ops) {
      switch (op.op) {
        case 'set':
          tx.set(_doc(op.path), _resolved(op.data!));
        case 'update':
          tx.update(_doc(op.path), _resolved(op.data!));
        case 'delete':
          tx.delete(_doc(op.path));
      }
    }
  }

  Future<void> _commit(SocialWrite write) {
    final batch = _db.batch();
    for (final op in write.ops) {
      switch (op.op) {
        case 'set':
          batch.set(_doc(op.path), _resolved(op.data!));
        case 'update':
          batch.update(_doc(op.path), _resolved(op.data!));
        case 'delete':
          batch.delete(_doc(op.path));
      }
    }
    return batch.commit();
  }

  /// Reads a handle card inside a transaction. The rules hide a card that
  /// belongs to someone else when it is not discoverable (or blocked): from
  /// here that is just "taken".
  Future<DocumentSnapshot<Map<String, dynamic>>> _txGetHandle(
    Transaction tx,
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    try {
      return await tx.get(ref);
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw const SocialFailure(SocialFailureKind.handleTaken, code: 'permission-denied');
      }
      rethrow;
    }
  }

  Future<T> _guard<T>(Future<T> Function() action, {required bool write}) =>
      guard(action, timeout, write: write);

  /// Runs [action] with a timeout, mapping provider errors to [SocialFailure].
  /// A timed-out WRITE is "uncertain": the SDK may still deliver it later.
  @visibleForTesting
  static Future<T> guard<T>(
    Future<T> Function() action,
    Duration timeout, {
    required bool write,
  }) async {
    try {
      return await action().timeout(timeout);
    } on SocialFailure {
      rethrow;
    } on TimeoutException {
      throw SocialFailure(
        write ? SocialFailureKind.uncertain : SocialFailureKind.offline,
        code: 'timeout',
      );
    } on FirebaseException catch (e) {
      debugPrint('Social operation failed: ${e.code}'); // code only, never data
      throw SocialFailure.fromFirestoreCode(e.code);
    }
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
