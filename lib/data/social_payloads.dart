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

  const SocialWrite(this.mode, this.ops);

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'ops': [for (final o in ops) o.toJson()],
  };
}

/// A query the app sends (always filtered by the current uid).
class SocialQuerySpec {
  final String collection;
  final List<(String field, String op, String value)> where;
  final int limit;

  const SocialQuerySpec(this.collection, this.where, this.limit);

  Map<String, Object?> toJson() => {
    'collection': collection,
    'where': [
      for (final w in where) [w.$1, w.$2, w.$3],
    ],
    'limit': limit,
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
