import '../social/social_models.dart';
import 'social_data_source.dart';

/// Marks "the server's clock" in a payload. The Firestore data source swaps
/// it for `FieldValue.serverTimestamp()`; the golden fixture writes it as
/// [kServerTimestampJson]. The rules require `== request.time` on these fields.
class ServerTimestamp {
  const ServerTimestamp();

  @override
  String toString() => kServerTimestampJson;
}

const serverTimestamp = ServerTimestamp();

/// How [serverTimestamp] appears in `firestore_rules_test/fixtures/social_payloads.json`.
const kServerTimestampJson = r'$serverTimestamp';

/// "A moment relative to the device clock", for `invites.expiresAt` (the rules
/// need it in the future and at most 30 days ahead of the server clock, and a
/// server timestamp cannot be offset). The Firestore data source turns it into
/// a `Timestamp`; the fixture writes it as [kClientTimePlusPrefix] + ms.
class ClientTimePlus {
  final Duration offset;

  const ClientTimePlus(this.offset);

  @override
  String toString() => '$kClientTimePlusPrefix${offset.inMilliseconds}';
}

const kClientTimePlusPrefix = r'$now+';

/// Removes a field (`FieldValue.delete()`); the fixture writes [kDeleteFieldJson].
class DeleteField {
  const DeleteField();

  @override
  String toString() => kDeleteFieldJson;
}

const deleteField = DeleteField();
const kDeleteFieldJson = r'$deleteField';

/// One write: `set` / `update` / `delete` of the document at [path]
/// (`collection/id[/collection/id]`).
class SocialOp {
  final String op;
  final String path;
  final Map<String, Object?>? data;

  const SocialOp.set(this.path, Map<String, Object?> this.data) : op = 'set';
  const SocialOp.update(this.path, Map<String, Object?> this.data) : op = 'update';
  const SocialOp.delete(this.path) : op = 'delete', data = null;

  Map<String, Object?> toJson() => {
    'op': op,
    'path': path,
    if (data != null) 'data': {for (final e in data!.entries) e.key: _json(e.value)},
  };

  static Object? _json(Object? v) =>
      v is ServerTimestamp || v is ClientTimePlus || v is DeleteField ? v.toString() : v;
}

/// A group of writes that must be atomic.
enum SocialWriteMode { transaction, batch }

class SocialWrite {
  final SocialWriteMode mode;
  final List<SocialOp> ops;

  /// Documents a [SocialWriteMode.transaction] reads BEFORE writing (`get` by
  /// path). The rules suite replays them too: they must be allowed.
  final List<String> reads;

  const SocialWrite(this.mode, this.ops, {this.reads = const []});

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    if (reads.isNotEmpty) 'reads': reads,
    'ops': [for (final o in ops) o.toJson()],
  };
}

/// A query the app sends (always filtered by the current uid).
class SocialQuerySpec {
  final String collection;
  final List<(String field, String op, String value)> where;
  final int limit;

  /// `(field, descending)`; null = no ordering.
  final (String field, bool descending)? orderBy;

  /// `count` = aggregate query (`count()`), null = normal query.
  final String? aggregate;

  const SocialQuerySpec(this.collection, this.where, this.limit, {this.orderBy, this.aggregate});

  Map<String, Object?> toJson() => {
    'collection': collection,
    'where': [
      for (final w in where) [w.$1, w.$2, w.$3],
    ],
    'limit': limit,
    if (orderBy != null) 'orderBy': [orderBy!.$1, orderBy!.$2 ? 'desc' : 'asc'],
    if (aggregate != null) 'aggregate': aggregate,
  };
}

/// The exact documents the app writes and the queries it sends, as pure
/// functions (no Firebase). `FirestoreSocialDataSource` executes these and
/// nothing else; a golden test pins their output to
/// `firestore_rules_test/fixtures/social_payloads.json`, and the rules suite
/// replays that same file against `firestore.rules`. Changing a field here
/// without the fixture (and the rules) fails a test. See docs/55.
class SocialPayloads {
  const SocialPayloads._();

  static String socialPath(String uid) => 'social/$uid';
  static String handlePath(String handle) => 'handles/$handle';
  static String invitePath(String code) => 'invites/$code';

  static Map<String, Object?> _card({
    required String uid,
    required Object? nickname,
    required Object? photoUrl,
    required bool discoverable,
  }) => {
    'uid': uid,
    'nickname': nickname,
    'photoURL': photoUrl,
    'discoverable': discoverable,
    'createdAt': serverTimestamp,
    'updatedAt': serverTimestamp,
  };

  /// Turn friendships on: card + pointer, one transaction.
  static SocialWrite activate(String uid, SocialDraft draft) =>
      SocialWrite(SocialWriteMode.transaction, [
        SocialOp.set(
          handlePath(draft.handle),
          _card(
            uid: uid,
            nickname: draft.nickname,
            photoUrl: draft.photoUrl,
            discoverable: draft.discoverable,
          ),
        ),
        SocialOp.set(socialPath(uid), {
          'handle': draft.handle,
          'handleChangedAt': serverTimestamp,
          'schemaVersion': 1,
        }),
      ]);

  /// Move the reservation: delete the old card, create the new one (copy of
  /// the old fields), update the pointer. One transaction.
  static SocialWrite changeHandle(
    String uid, {
    required String oldHandle,
    required String newHandle,
    required Object? nickname,
    required Object? photoUrl,
    required bool discoverable,
  }) => SocialWrite(SocialWriteMode.transaction, [
    SocialOp.delete(handlePath(oldHandle)),
    SocialOp.set(
      handlePath(newHandle),
      _card(uid: uid, nickname: nickname, photoUrl: photoUrl, discoverable: discoverable),
    ),
    SocialOp.update(socialPath(uid), {
      'handle': newHandle,
      'handleChangedAt': serverTimestamp,
      'schemaVersion': 1,
    }),
  ]);

  /// Update only what changed on the card. When the user has a live invite
  /// ([inviteCode]) its copy of the nickname / photo follows in the same
  /// transaction ("Aparecer na busca" is not on the invite).
  static SocialWrite updateCard(String handle, CardPatch patch, {String? inviteCode}) =>
      SocialWrite(SocialWriteMode.transaction, [
        SocialOp.update(handlePath(handle), {
          'nickname': ?patch.nickname,
          if (patch.changePhoto) 'photoURL': patch.photoUrl,
          'discoverable': ?patch.discoverable,
          'updatedAt': serverTimestamp,
        }),
        if (inviteCode != null && (patch.nickname != null || patch.changePhoto))
          SocialOp.update(invitePath(inviteCode), {
            'nickname': ?patch.nickname,
            if (patch.changePhoto) 'photoURL': patch.photoUrl,
          }),
      ]);

  /// Create the invite link: the invite document and the pointer in
  /// `social/{uid}` in ONE transaction. [replacesCode] (the invite that exists
  /// now) is deleted in the same write: 1 active invite per user (rotation).
  /// `photoURL` is left out when there is no photo. The transaction first
  /// reads the pointer (and the old invite) to know what to replace.
  static SocialWrite createInvite(String uid, InviteDraft draft, {String? replacesCode}) =>
      SocialWrite(
        SocialWriteMode.transaction,
        [
          if (replacesCode != null) SocialOp.delete(invitePath(replacesCode)),
          SocialOp.set(invitePath(draft.code), {
            'uid': uid,
            'nickname': draft.nickname,
            if (draft.photoUrl != null) 'photoURL': draft.photoUrl,
            'createdAt': serverTimestamp,
            'expiresAt': ClientTimePlus(draft.validity),
          }),
          SocialOp.update(socialPath(uid), {'inviteCode': draft.code}),
        ],
        reads: [socialPath(uid), if (replacesCode != null) invitePath(replacesCode)],
      );

  /// Revoke: delete the invite document (immediate effect) and clear the
  /// pointer in the same write. [inviteExists] false = only the pointer is
  /// left over (a delete of a missing document is denied by the rules).
  static SocialWrite revokeInvite(String uid, String code, {bool inviteExists = true}) =>
      SocialWrite(
        SocialWriteMode.transaction,
        [
          if (inviteExists) SocialOp.delete(invitePath(code)),
          SocialOp.update(socialPath(uid), {'inviteCode': deleteField}),
        ],
        reads: [socialPath(uid), invitePath(code)],
      );

  /// Opening a link: the ONE document read (`get`, never a list).
  static String lookupInvitePath(String code) => invitePath(code);

  /// Refresh of nickname / photo in the friendships (D8): each `update` touches
  /// only THIS user's half (`aName`+`aPhoto` or `bName`+`bPhoto`); the rules
  /// refuse the other half and make no extra call for it. A removed photo is
  /// `null` (accepted by `validPhoto`, read as "no photo"). One batch per page.
  static SocialWrite refreshHalves(List<FriendHalfUpdate> updates) =>
      SocialWrite(SocialWriteMode.batch, [
        for (final u in updates)
          SocialOp.update('friendships/${u.pairKey}', {
            u.meIsA ? 'aName' : 'bName': u.name,
            u.meIsA ? 'aPhoto' : 'bPhoto': u.photo,
          }),
      ]);

  /// Free the handle (and invite) and remove the pointer: one batch. Only
  /// the documents that exist and belong to the user are passed in.
  static SocialWrite close(String uid, {String? handle, String? inviteCode}) =>
      SocialWrite(SocialWriteMode.batch, [
        if (handle != null) SocialOp.delete(handlePath(handle)),
        if (inviteCode != null) SocialOp.delete(invitePath(inviteCode)),
        SocialOp.delete(socialPath(uid)),
      ]);

  /// Search: the ONE document a lookup reads (`get`, never a list).
  static String lookupPath(String handle) => handlePath(handle);

  static String requestPath(String from, String to) => 'friend_requests/${from}_$to';

  /// "Enviar pedido": ONE transaction. It reads the request already sent by
  /// this user and the inverse one (from the other person) first: if mine
  /// exists the data source stops ("já enviado"); if the inverse exists it
  /// creates NOTHING here and runs [acceptRequest] instead (crossed request,
  /// D4: it becomes a friendship). Optional photo keys are left out when
  /// there is no photo.
  static SocialWrite sendRequest(String uid, SendRequestDraft draft) => SocialWrite(
    SocialWriteMode.transaction,
    [
      SocialOp.set(requestPath(uid, draft.toUid), {
        'from': uid,
        'to': draft.toUid,
        'fromName': draft.fromName,
        if (draft.fromPhoto != null) 'fromPhoto': draft.fromPhoto,
        'toName': draft.toName,
        if (draft.toPhoto != null) 'toPhoto': draft.toPhoto,
        'createdAt': serverTimestamp,
      }),
    ],
    reads: [requestPath(uid, draft.toUid), requestPath(draft.toUid, uid)],
  );

  static String pairId(String a, String b) => a.compareTo(b) < 0 ? '${a}_$b' : '${b}_$a';
  static String friendshipPath(String a, String b) => 'friendships/${pairId(a, b)}';

  /// "Aceitar" (and a crossed request, D4): ONE batch that creates
  /// `friendships/{menor}_{maior}` AND consumes the request: the rules demand
  /// the pending request of the other person (`get`) and that neither
  /// `{other}_{me}` nor `{me}_{other}` exists after the batch (`existsAfter`).
  /// The other half is exactly what their request says; deleting
  /// `{me}_{other}` when it does not exist is allowed (id has my uid).
  static SocialWrite acceptRequest(String uid, AcceptDraft draft) {
    final other = draft.fromUid;
    final meIsA = uid.compareTo(other) < 0;
    final (aName, aPhoto, bName, bPhoto) = meIsA
        ? (draft.myName, draft.myPhoto, draft.fromName, draft.fromPhoto)
        : (draft.fromName, draft.fromPhoto, draft.myName, draft.myPhoto);
    return SocialWrite(SocialWriteMode.batch, [
      SocialOp.set(friendshipPath(uid, other), {
        'members': meIsA ? [uid, other] : [other, uid],
        'createdAt': serverTimestamp,
        'aName': aName,
        'aPhoto': ?aPhoto,
        'bName': bName,
        'bPhoto': ?bPhoto,
      }),
      SocialOp.delete(requestPath(other, uid)),
      SocialOp.delete(requestPath(uid, other)),
    ]);
  }

  /// "Recusar": deletes `{from}_{me}` (silent; the sender is not told).
  static SocialWrite declineRequest(String uid, String fromUid) =>
      SocialWrite(SocialWriteMode.batch, [SocialOp.delete(requestPath(fromUid, uid))]);

  /// "Remover amizade": deletes the one pair document (both sides lose it).
  static SocialWrite removeFriend(String uid, String otherUid) =>
      SocialWrite(SocialWriteMode.batch, [SocialOp.delete(friendshipPath(uid, otherUid))]);

  static String blockPath(String blocker, String blocked) => 'users/$blocker/blocks/$blocked';

  /// "Bloquear": ONE batch. Creates `users/{me}/blocks/{other}` and, in the
  /// same batch, deletes the friendship and BOTH requests: the rules refuse the
  /// block unless none of the three exists afterwards (`existsAfter`). The
  /// deletes are sent whether or not the documents exist: deleting a missing
  /// document is allowed because every id contains my uid, so the app needs no
  /// read to decide (0 reads). Name and photo are optional snapshots.
  static SocialWrite blockUser(String uid, BlockDraft draft) {
    final other = draft.blockedUid;
    return SocialWrite(SocialWriteMode.batch, [
      SocialOp.set(blockPath(uid, other), {
        'blockedName': ?draft.name,
        'blockedPhoto': ?draft.photo,
        'createdAt': serverTimestamp,
      }),
      SocialOp.delete(friendshipPath(uid, other)),
      SocialOp.delete(requestPath(uid, other)),
      SocialOp.delete(requestPath(other, uid)),
    ]);
  }

  /// "Desbloquear": deletes the block document. Does not bring anything back.
  static SocialWrite unblockUser(String uid, String blockedUid) =>
      SocialWrite(SocialWriteMode.batch, [SocialOp.delete(blockPath(uid, blockedUid))]);

  /// The blocked list, newest block first (automatic single-field index).
  static SocialQuerySpec blocksQuery(String uid, int limit) =>
      SocialQuerySpec('users/$uid/blocks', const [], limit, orderBy: ('createdAt', true));

  /// Pending requests received, newest first (index `to ASC, createdAt DESC`).
  static SocialQuerySpec receivedQuery(String uid, int limit) =>
      SocialQuerySpec('friend_requests', [('to', '==', uid)], limit, orderBy: ('createdAt', true));

  /// Counts the pending received requests for the badge (one billed read).
  static SocialQuerySpec receivedCountQuery(String uid) => SocialQuerySpec(
    'friend_requests',
    [('to', '==', uid)],
    kMaxReceivedListed,
    aggregate: 'count',
  );

  /// The friends list: `members array-contains uid` (automatic single-field
  /// index; document-id order, the screen sorts by name).
  static SocialQuerySpec friendsQuery(String uid, int limit) =>
      SocialQuerySpec('friendships', [('members', 'array-contains', uid)], limit);

  /// Counts friends (limit check on accept).
  static SocialQuerySpec friendsCountQuery(String uid) => SocialQuerySpec(
    'friendships',
    [('members', 'array-contains', uid)],
    kMaxFriends,
    aggregate: 'count',
  );

  /// "Cancelar pedido enviado": deletes `{me}_{to}` (the rules also let the
  /// recipient delete it, which is slice 3's "recusar").
  static SocialWrite cancelRequest(String uid, String toUid) =>
      SocialWrite(SocialWriteMode.batch, [SocialOp.delete(requestPath(uid, toUid))]);

  /// Lists the pending requests sent by this user, newest first (index
  /// `from ASC, createdAt DESC`). Pages continue with `startAfterDocument`.
  static SocialQuerySpec sentQuery(String uid, int limit) => SocialQuerySpec(
    'friend_requests',
    [('from', '==', uid)],
    limit,
    orderBy: ('createdAt', true),
  );

  /// Counts the pending sent requests (stops at [kMaxSentRequests]): one
  /// billed read for the limit check instead of loading the list.
  static SocialQuerySpec sentCountQuery(String uid) => SocialQuerySpec(
    'friend_requests',
    [('from', '==', uid)],
    kMaxSentRequests,
    aggregate: 'count',
  );

  /// The sweep queries (server reads), always parameterised by the uid.
  static SocialQuerySpec sweepQuery(SweepKind kind, String uid, int limit) => switch (kind) {
    SweepKind.requestsSent => SocialQuerySpec('friend_requests', [('from', '==', uid)], limit),
    SweepKind.requestsReceived => SocialQuerySpec('friend_requests', [('to', '==', uid)], limit),
    SweepKind.friendships => SocialQuerySpec('friendships', [
      ('members', 'array-contains', uid),
    ], limit),
    SweepKind.blocks => SocialQuerySpec('users/$uid/blocks', const [], limit),
  };

  static String sweepPath(SweepRef ref, String uid) => switch (ref.kind) {
    SweepKind.requestsSent || SweepKind.requestsReceived => 'friend_requests/${ref.id}',
    SweepKind.friendships => 'friendships/${ref.id}',
    SweepKind.blocks => 'users/$uid/blocks/${ref.id}',
  };

  /// Delete a page of swept documents: one batch.
  static SocialWrite sweepDelete(String uid, List<SweepRef> refs) => SocialWrite(
    SocialWriteMode.batch,
    [for (final ref in refs) SocialOp.delete(sweepPath(ref, uid))],
  );
}
