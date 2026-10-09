import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../social/invite_code.dart';
import '../social/social_models.dart';
import 'social_data_source.dart';
import 'social_payloads.dart';

/// A document read inside a transaction, without Firestore types: the seam
/// ([SocialExecutor]) lets a test run this class's logic (crossed request,
/// 300 cap, block) with no Firebase.
typedef SocialSnapshot = ({bool exists, Map<String, dynamic>? data});

/// Runs a [SocialWrite] the way its `mode` says. The default talks to
/// Firestore; tests inject a recorder/fake. [check] sees the `reads` of a
/// transaction and may throw to stop before anything is written.
typedef SocialExecutor =
    Future<void> Function(
      SocialWrite write, {
      void Function(Map<String, SocialSnapshot> reads)? check,
    });

/// Runs an aggregate `count()` query. The default asks the server.
typedef SocialCountReader = Future<int> Function(SocialQuerySpec spec);

/// Reads one document (by path) from the server, outside a transaction.
/// The default asks Firestore; tests inject a fake (docs/71 G5).
typedef SocialDocReader = Future<SocialSnapshot> Function(String path);

/// Reads one document (by path) inside a planned transaction. Provider errors
/// (`FirebaseException`) come out as they are.
typedef SocialTxGet = Future<SocialSnapshot> Function(String path);

/// Runs a planned write (activate, change handle, card, invite): [plan] reads
/// through the getter it receives and returns the payload to apply. The
/// default is a Firestore transaction; tests inject a fake (docs/72 L1) to run
/// the real branches (handle hidden by the rules = taken; own pointer denied =
/// rules not published) without Firebase.
typedef SocialPlanner = Future<void> Function(Future<SocialWrite> Function(SocialTxGet get) plan);

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
  final FirebaseFirestore? firestore;
  @override
  final String uid;
  final Duration timeout;
  final SocialExecutor? executor;
  final SocialCountReader? countReader;
  final SocialPlanner? planner;
  final SocialDocReader? docReader;

  /// [executor], [countReader] and [planner] are test seams: with them
  /// injected this class never touches Firebase (the instance is looked up
  /// lazily).
  FirestoreSocialDataSource({
    required this.uid,
    this.timeout = const Duration(seconds: 30),
    this.firestore,
    @visibleForTesting this.executor,
    @visibleForTesting this.countReader,
    @visibleForTesting this.planner,
    @visibleForTesting this.docReader,
  });

  FirebaseFirestore get _db => firestore ?? FirebaseFirestore.instance;

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
    // The invite is the user's own: always readable by the owner. A failure
    // here must not hide the whole profile (it just shows "no invite data").
    final code = data['inviteCode'];
    Map<String, dynamic>? invite;
    var inviteUnreadable = false;
    if (code is String && InviteCode.isValid(code)) {
      try {
        invite = (await _invite(code).get(options)).data();
      } on FirebaseException {
        inviteUnreadable = true;
      }
    }
    return RawSocial(
      social: convert(data),
      card: card == null ? null : convert(card),
      invite: invite == null ? null : convert(invite),
      inviteUnreadable: inviteUnreadable,
    );
  }, write: false);

  String get _socialPath => SocialPayloads.socialPath(uid);

  @override
  Future<void> activate(SocialDraft draft) => _guard(
    () => _executePlanned((get) async {
      // The own pointer FIRST: it is always readable by its owner once the rules are
      // published, so a denial here means "rules not published" (denied) and is never
      // confused with a handle hidden by the rules (taken), docs/72 L1.
      final social = await get(_socialPath);
      final card = await _getHandle(get, draft.handle);
      if (card.exists) throw const SocialFailure(SocialFailureKind.handleTaken);
      if (social.exists) throw const SocialFailure(SocialFailureKind.alreadyActive);
      return SocialPayloads.activate(uid, draft);
    }),
    write: true,
  );

  @override
  Future<void> changeHandle(String newHandle) => _guard(
    () => _executePlanned((get) async {
      final social = (await get(_socialPath)).data;
      final old = social?['handle'];
      if (old is! String) throw const SocialFailure(SocialFailureKind.notActive);
      if (old == newHandle) return const SocialWrite(SocialWriteMode.transaction, []);
      final changed = social?['handleChangedAt'];
      if (changed is Timestamp) {
        final next = changed.toDate().add(const Duration(days: 30));
        if (next.isAfter(DateTime.now())) {
          throw SocialFailure(SocialFailureKind.tooSoon, retryAt: next);
        }
      }
      final oldCard = (await get(SocialPayloads.handlePath(old))).data;
      if (oldCard == null) {
        throw const SocialFailure(SocialFailureKind.unknown, code: 'card-missing');
      }
      if ((await _getHandle(get, newHandle)).exists) {
        throw const SocialFailure(SocialFailureKind.handleTaken);
      }
      return SocialPayloads.changeHandle(
        uid,
        oldHandle: old,
        newHandle: newHandle,
        nickname: oldCard['nickname'],
        photoUrl: oldCard['photoURL'],
        discoverable: oldCard['discoverable'] == true,
      );
    }),
    write: true,
  );

  @override
  Future<void> updateCard(CardPatch patch) {
    if (patch.isEmpty) return Future.value();
    return _guard(
      () => _executePlanned((get) async {
        final social = (await get(_socialPath)).data;
        final handle = social?['handle'];
        if (handle is! String) throw const SocialFailure(SocialFailureKind.notActive);
        String? inviteCode;
        final pointer = social?['inviteCode'];
        if ((patch.nickname != null || patch.changePhoto) &&
            pointer is String &&
            InviteCode.isValid(pointer)) {
          // An expired invite is left alone (the rules check `expiresAt` on
          // every update, so touching it would fail the whole card update).
          final invite = (await get(SocialPayloads.invitePath(pointer))).data;
          final expires = invite?['expiresAt'];
          if (invite?['uid'] == uid &&
              expires is Timestamp &&
              expires.toDate().isAfter(DateTime.now().add(_inviteSlack))) {
            inviteCode = pointer;
          }
        }
        return SocialPayloads.updateCard(handle, patch, inviteCode: inviteCode);
      }),
      write: true,
    );
  }

  /// An invite that expires within this margin is not touched by a card update.
  static const _inviteSlack = Duration(minutes: 5);

  @override
  Future<void> createInvite(InviteDraft draft) => _guard(
    () => _executePlanned((get) async {
      final social = (await get(_socialPath)).data;
      if (social?['handle'] is! String) throw const SocialFailure(SocialFailureKind.notActive);
      String? replaces;
      final pointer = social?['inviteCode'];
      if (pointer is String && InviteCode.isValid(pointer)) {
        // Deleting a document that does not exist is denied: only replace it
        // when it is really there and ours.
        final old = (await get(SocialPayloads.invitePath(pointer))).data;
        if (old != null && old['uid'] == uid) replaces = pointer;
      }
      return SocialPayloads.createInvite(uid, draft, replacesCode: replaces);
    }),
    write: true,
  );

  @override
  Future<void> revokeInvite() => _guard(
    () => _executePlanned((get) async {
      final pointer = (await get(_socialPath)).data?['inviteCode'];
      if (pointer is! String || !InviteCode.isValid(pointer)) {
        return const SocialWrite(SocialWriteMode.transaction, []);
      }
      final doc = (await get(SocialPayloads.invitePath(pointer))).data;
      return SocialPayloads.revokeInvite(
        uid,
        pointer,
        inviteExists: doc != null && doc['uid'] == uid,
      );
    }),
    write: true,
  );

  @override
  Future<RawInvite?> lookupInvite(String code) => _guard(() async {
    final snapshot = await _doc(
      SocialPayloads.lookupInvitePath(code),
    ).get(const GetOptions(source: Source.server));
    final data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    return RawInvite(code, convert(data));
  }, write: false);

  @override
  Future<void> updateFriendHalves(List<FriendHalfUpdate> updates) {
    if (updates.isEmpty) return Future.value();
    return _guard(() => _execute(SocialPayloads.refreshHalves(updates)), write: true);
  }

  Future<SocialSnapshot> _serverGet(String path) {
    final custom = docReader;
    if (custom != null) return custom(path);
    return _doc(path).get(const GetOptions(source: Source.server)).then(
      (snap) => (exists: snap.exists, data: snap.data()),
    );
  }

  @override
  Future<bool> closeSocial() async {
    final SocialSnapshot social;
    try {
      social = await _guard(() => _serverGet(_socialPath), write: false);
    } on SocialFailure catch (e) {
      // Only this read tells "rules not published" (docs/71 G5).
      if (e.kind == SocialFailureKind.denied) {
        throw const SocialFailure(SocialFailureKind.denied, code: kSocialReadDeniedCode);
      }
      rethrow;
    }
    final data = social.data;
    if (data == null) return false;

    String? cardHandle;
    final handle = data['handle'];
    if (handle is String && handle.isNotEmpty) {
      final card = await _guard(() => _serverGet(SocialPayloads.handlePath(handle)), write: false);
      if (card.exists && card.data?['uid'] == uid) cardHandle = handle;
    }
    String? inviteCode;
    final invite = data['inviteCode'];
    if (invite is String && invite.isNotEmpty) {
      final doc = await _guard(() => _serverGet(SocialPayloads.invitePath(invite)), write: false);
      if (doc.exists && doc.data?['uid'] == uid) inviteCode = invite;
    }
    final close = SocialPayloads.close(uid, handle: cardHandle, inviteCode: inviteCode);
    await _guard(() => _execute(close), write: true);
    return true;
  }

  @override
  Future<RawCard?> lookupHandle(String handle) => _guard(() async {
    final snapshot = await _doc(
      SocialPayloads.lookupPath(handle),
    ).get(const GetOptions(source: Source.server));
    final data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    return RawCard(handle, convert(data));
  }, write: false);

  @override
  Future<int> countSentRequests() =>
      _guard(() => _count(SocialPayloads.sentCountQuery(uid)), write: false);

  @override
  Future<SendOutcome> sendRequest(SendRequestDraft draft) => _guard(() async {
    Map<String, dynamic>? inverse;
    try {
      await _execute(
        SocialPayloads.sendRequest(uid, draft),
        check: (reads) {
          inverse = null;
          final own = reads[SocialPayloads.requestPath(uid, draft.toUid)];
          final other = reads[SocialPayloads.requestPath(draft.toUid, uid)];
          if (own?.exists ?? false) throw const SocialFailure(SocialFailureKind.alreadySent);
          if (other?.exists ?? false) {
            inverse = other!.data;
            throw const _CrossedRequest();
          }
        },
      );
      return SendOutcome.requested;
    } on _CrossedRequest {
      // The other person asked first: friendship + their request, ONE batch.
      // The 300 friends cap holds on this door too (one extra read, only here).
      if (await _count(SocialPayloads.friendsCountQuery(uid)) >= kMaxFriends) {
        throw const SocialFailure(SocialFailureKind.friendsLimit);
      }
      final data = inverse;
      final name = data?['fromName'];
      if (name is! String) throw const SocialFailure(SocialFailureKind.denied);
      final photo = data?['fromPhoto'];
      await _execute(
        SocialPayloads.acceptRequest(
          uid,
          AcceptDraft(
            fromUid: draft.toUid,
            fromName: name,
            fromPhoto: photo is String ? photo : null,
            myName: draft.fromName,
            myPhoto: draft.fromPhoto,
          ),
        ),
      );
      return SendOutcome.becameFriends;
    }
  }, write: true);

  @override
  Future<void> acceptRequest(AcceptDraft draft) =>
      _guard(() => _execute(SocialPayloads.acceptRequest(uid, draft)), write: true);

  @override
  Future<void> declineRequest(String fromUid) =>
      _guard(() => _execute(SocialPayloads.declineRequest(uid, fromUid)), write: true);

  @override
  Future<void> removeFriend(String otherUid) =>
      _guard(() => _execute(SocialPayloads.removeFriend(uid, otherUid)), write: true);

  @override
  Future<void> blockUser(BlockDraft draft) =>
      _guard(() => _execute(SocialPayloads.blockUser(uid, draft)), write: true);

  @override
  Future<void> unblockUser(String blockedUid) =>
      _guard(() => _execute(SocialPayloads.unblockUser(uid, blockedUid)), write: true);

  @override
  Future<RawSocialPage> readBlockedPage({Object? cursor, required int limit}) =>
      _page(SocialPayloads.blocksQuery(uid, limit + 1), cursor, limit);

  Future<int> _count(SocialQuerySpec spec) {
    final reader = countReader;
    return reader != null ? reader(spec) : _countOnFirestore(spec);
  }

  Future<int> _countOnFirestore(SocialQuerySpec spec) async {
    final result = await _query(spec).count().get(source: AggregateSource.server);
    return result.count ?? 0;
  }

  @override
  Future<int> countReceivedRequests() =>
      _guard(() => _count(SocialPayloads.receivedCountQuery(uid)), write: false);

  @override
  Future<int> countFriends() =>
      _guard(() => _count(SocialPayloads.friendsCountQuery(uid)), write: false);

  @override
  Future<void> cancelRequest(String toUid) =>
      _guard(() => _execute(SocialPayloads.cancelRequest(uid, toUid)), write: true);

  @override
  Future<RawSocialPage> readSentPage({Object? cursor, required int limit}) =>
      _page(SocialPayloads.sentQuery(uid, limit + 1), cursor, limit);

  @override
  Future<RawSocialPage> readReceivedPage({Object? cursor, required int limit}) =>
      _page(SocialPayloads.receivedQuery(uid, limit + 1), cursor, limit);

  @override
  Future<RawSocialPage> readFriendsPage({Object? cursor, required int limit}) =>
      _page(SocialPayloads.friendsQuery(uid, limit + 1), cursor, limit);

  /// One page of [spec] (built with `limit + 1`): the extra document only
  /// tells whether there is a next page and is not returned.
  Future<RawSocialPage> _page(SocialQuerySpec spec, Object? cursor, int limit) => _guard(() async {
    var query = _query(spec);
    if (cursor is DocumentSnapshot<Map<String, dynamic>>) {
      query = query.startAfterDocument(cursor);
    }
    final snapshot = await query.get();
    final docs = snapshot.docs;
    final page = docs.take(limit).toList();
    return RawSocialPage(
      docs: [for (final d in page) (id: d.id, data: convert(d.data()))],
      cursor: page.isEmpty ? null : page.last,
      hasMore: docs.length > limit,
      fromCache: snapshot.metadata.isFromCache,
    );
  }, write: false);

  @override
  Future<List<SweepRef>> readSweepPage(SweepKind kind, {required int limit}) => _guard(() async {
    final spec = SocialPayloads.sweepQuery(kind, uid, limit);
    final snapshot = await _query(spec).get(const GetOptions(source: Source.server));
    return [for (final doc in snapshot.docs) SweepRef(kind, doc.id)];
  }, write: false);

  @override
  Future<void> deleteRefs(List<SweepRef> refs) =>
      _guard(() => _execute(SocialPayloads.sweepDelete(uid, refs)), write: true);

  Query<Map<String, dynamic>> _query(SocialQuerySpec spec) => socialQuery(_db, spec);

  Object? _resolve(Object? v) => switch (v) {
    ServerTimestamp() => FieldValue.serverTimestamp(),
    ClientTimePlus() => Timestamp.fromDate(DateTime.now().add(v.offset)),
    DeleteField() => FieldValue.delete(),
    _ => v,
  };

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

  /// Runs [write] the way ITS payload says: a transaction (reading
  /// `write.reads` first; [check] sees them and may throw to stop before
  /// anything is written) or one batch. The executor never picks the mode
  /// itself, so changing it in `SocialPayloads` changes what runs (and the
  /// golden + the rules replay follow).
  Future<void> _execute(
    SocialWrite write, {
    void Function(Map<String, SocialSnapshot> reads)? check,
  }) {
    final custom = executor;
    if (custom != null) return custom(write, check: check);
    switch (write.mode) {
      case SocialWriteMode.transaction:
        return _db.runTransaction((tx) async {
          final reads = <String, SocialSnapshot>{};
          for (final path in write.reads) {
            final snap = await tx.get(_doc(path));
            reads[path] = (exists: snap.exists, data: snap.data());
          }
          check?.call(reads);
          _applyTx(tx, write);
        });
      case SocialWriteMode.batch:
        if (write.reads.isNotEmpty || check != null) {
          throw StateError('a batch cannot read first');
        }
        return _commit(write);
    }
  }

  /// For writes whose payload depends on what a read returns (change handle,
  /// card update): [plan] reads inside a transaction and returns the payload;
  /// a transaction-mode payload is applied inside it, a batch-mode one right
  /// after (the reads are then not part of its atomicity, as for any batch).
  Future<void> _executePlanned(Future<SocialWrite> Function(SocialTxGet get) plan) async {
    final custom = planner;
    if (custom != null) return custom(plan);
    SocialWrite? deferred;
    await _db.runTransaction((tx) async {
      deferred = null;
      final write = await plan((path) async {
        final snap = await tx.get(_doc(path));
        return (exists: snap.exists, data: snap.data());
      });
      if (write.mode == SocialWriteMode.transaction) {
        _applyTx(tx, write);
      } else {
        deferred = write;
      }
    });
    final pending = deferred;
    if (pending != null) await _commit(pending);
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

  /// Reads a handle card inside a planned transaction. The rules hide a card
  /// that belongs to someone else when it is not discoverable (or blocked):
  /// from here that is just "taken" (never "free"). Callers read the own
  /// pointer before this, so "rules not published" is already told apart.
  Future<SocialSnapshot> _getHandle(SocialTxGet get, String handle) async {
    try {
      return await get(SocialPayloads.handlePath(handle));
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

/// Internal signal: the transaction found the inverse request (D4).
class _CrossedRequest implements Exception {
  const _CrossedRequest();
}

/// Builds the Firestore query of a [SocialQuerySpec]: the only place that
/// turns a spec into a query (the social data source and the export share it,
/// docs/71 G8).
Query<Map<String, dynamic>> socialQuery(FirebaseFirestore db, SocialQuerySpec spec) {
  Query<Map<String, dynamic>> query = db.collection(spec.collection);
  for (final (field, op, value) in spec.where) {
    query = switch (op) {
      '==' => query.where(field, isEqualTo: value),
      'array-contains' => query.where(field, arrayContains: value),
      _ => throw StateError('unsupported operator $op'),
    };
  }
  final order = spec.orderBy;
  if (order != null) query = query.orderBy(order.$1, descending: order.$2);
  return query.limit(spec.limit);
}
