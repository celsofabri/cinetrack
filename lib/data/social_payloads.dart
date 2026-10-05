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

  static Object? _json(Object? v) => v is ServerTimestamp ? kServerTimestampJson : v;
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

  /// Update only what changed on the card.
  static SocialWrite updateCard(String handle, CardPatch patch) =>
      SocialWrite(SocialWriteMode.transaction, [
        SocialOp.update(handlePath(handle), {
          'nickname': ?patch.nickname,
          if (patch.changePhoto) 'photoURL': patch.photoUrl,
          'discoverable': ?patch.discoverable,
          'updatedAt': serverTimestamp,
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
  /// this user and the inverse one (from the other person) first: if either
  /// exists the data source stops and creates nothing ("já enviado" / "essa
  /// pessoa já enviou um pedido para você"; accepting is slice 3). Optional
  /// photo keys are left out when there is no photo.
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
