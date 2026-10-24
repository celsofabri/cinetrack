import '../data/shared_profile_data_source.dart';
import '../shared_profile/shared_profile_doc.dart';
import '../shared_profile/shared_profile_models.dart';
import '../shared_profile/shared_profile_payloads.dart';
import '../shared_profile/shared_stats_reading.dart';
import '../social/social_models.dart';

/// Why an operation on the owner's shared profile did not happen (docs/82
/// §9). The screens only ever see this type.
enum SharedProfileFailureKind {
  /// Nothing was sent (no connection before the write).
  offline,

  /// The write was sent and no answer came: reconcile with a server read
  /// (B5). NEVER a failure: it may have happened.
  uncertain,

  /// `permission-denied`: old rules, or friendships turned off elsewhere
  /// (the caller tells them apart by reading the friendships state).
  denied,

  /// `not-found` on an update (the document was deleted elsewhere).
  notFound,
  quota,
  sessionExpired,

  /// Another toggle of this account is still running: nothing was done.
  busy,
  unknown,
}

class SharedProfileFailure implements Exception {
  final SharedProfileFailureKind kind;

  /// Provider code (never data).
  final String? code;

  /// [SharedProfileFailureKind.uncertain] only: completes when the original
  /// transaction ends (see `SharedToggleUncertain`); null = already ended.
  final Future<void>? settled;

  const SharedProfileFailure(this.kind, {this.code, this.settled});

  factory SharedProfileFailure.fromSocial(SocialFailure f) => SharedProfileFailure(
    switch (f.kind) {
      SocialFailureKind.offline => SharedProfileFailureKind.offline,
      SocialFailureKind.uncertain => SharedProfileFailureKind.uncertain,
      SocialFailureKind.denied => SharedProfileFailureKind.denied,
      SocialFailureKind.quotaExceeded => SharedProfileFailureKind.quota,
      SocialFailureKind.sessionExpired => SharedProfileFailureKind.sessionExpired,
      SocialFailureKind.busy => SharedProfileFailureKind.busy,
      _ when f.code == 'not-found' => SharedProfileFailureKind.notFound,
      _ => SharedProfileFailureKind.unknown,
    },
    code: f.code,
    settled: f is SharedToggleUncertain ? f.settled : null,
  );

  static const offlineMessage = 'Sem conexão. Tente de novo quando estiver online.';
  static const unavailableMessage = 'O perfil compartilhado ainda não está disponível.';

  /// pt-BR text (the quota one is the existing app message).
  String get message => switch (kind) {
    SharedProfileFailureKind.offline => offlineMessage,
    SharedProfileFailureKind.uncertain => 'Ainda não confirmado…',
    SharedProfileFailureKind.denied => unavailableMessage,
    SharedProfileFailureKind.notFound => 'Não foi possível concluir. Tente novamente.',
    SharedProfileFailureKind.quota => const SocialFailure(SocialFailureKind.quotaExceeded).message,
    SharedProfileFailureKind.sessionExpired => 'Sessão expirada. Entre novamente.',
    SharedProfileFailureKind.busy => 'Aguarde a operação anterior terminar.',
    SharedProfileFailureKind.unknown => 'Não foi possível concluir. Tente novamente.',
  };

  @override
  String toString() => 'SharedProfileFailure($kind, code: $code)';
}

/// The owner's side of `shared_profiles/{uid}` (docs/82 §7.1, §6, §9): reads
/// the own document, runs "Aparecer na busca" (one transaction) and
/// sends the engine's recalculations. Maps every failure to
/// [SharedProfileFailure]. Fatia 3: a friend's profile ([readFriend]).
class SharedProfileRepository {
  final SharedProfileDataSource source;

  const SharedProfileRepository(this.source);

  String get uid => source.uid;

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on SocialFailure catch (f) {
      throw SharedProfileFailure.fromSocial(f);
    } on SharedProfileFailure {
      rethrow;
    } on ArgumentError {
      // Content outside the ceilings table: never sent (the validator
      // clamps first, so this means a bug, not the user's fault).
      throw const SharedProfileFailure(SharedProfileFailureKind.unknown, code: 'invalid');
    }
  }

  /// The own document from the SERVER (null = it does not exist).
  Future<SharedProfileDoc?> readOwn() =>
      _guard(() async => SharedProfileDoc.parse(await source.readOwn(fromServer: true)));

  /// "Aparecer na busca" (docs/95 §9): ONE transaction over the card
  /// `handles/{handle}` and the own document, idempotent (it reads both and
  /// writes only what differs, RF-SC7). [on] with [content] (the preview the
  /// dialog showed): card on + the missing sections; off: card off + the
  /// document deleted. A card that is missing or not this user's stops it
  /// before anything is written ([SharedProfileFailureKind.denied] when
  /// turning on: friendships are off; turning off still deletes the
  /// document).
  Future<void> searchAndShare(
    bool on, {
    required String handle,
    SharedProfileContent? content,
    required DateTime now,
  }) => _guard(
    () => source.searchAndShare(handle, (card, current) {
      final mine = card != null && card['uid'] == uid;
      if (on && !mine) {
        throw const SocialFailure(SocialFailureKind.denied, code: 'card-missing');
      }
      return SharedProfilePayloads.searchAndShare(
        uid,
        handle: handle,
        on: on,
        cardDiscoverable: mine ? card['discoverable'] == true : null,
        // A document that exists but does not parse still counts as
        // existing: turning off deletes it.
        current: current == null ? null : (SharedProfileDoc.parse(current)?.sharing ?? const {}),
        content: content,
        now: now,
      );
    }),
  );

  /// The engine's recalculation of [changed] (never `sharing`/`actSince`).
  Future<void> recalc(
    SharedProfileContent content,
    Set<SharedSection> changed, {
    required DateTime now,
    DateTime? actSince,
  }) => _guard(
    () => source.writeSections(
      SharedProfilePayloads.recalc(
        uid,
        content: content,
        changed: changed,
        now: now,
        actSince: actSince,
      ),
    ),
  );

  /// "Atualizado há" pulse (same content, only `updatedAt`).
  Future<void> pulse() => _guard(() => source.writeSections(SharedProfilePayloads.pulse(uid)));

  /// A friend's shared profile (docs/82 §7.2), from the SERVER only: null =
  /// it does not exist (the reader IS a friend: "não compartilha nada além
  /// do cartão"). Not a friend (or blocked, or the rules not published):
  /// [SharedProfileFailureKind.denied]. Never cached here: the memory cache
  /// with its TTL lives in `FriendProfileCache` (one per account).
  Future<FriendSharedView?> readFriend(String friendUid) => _guard(() async {
    final raw = await source.readFriend(friendUid);
    return raw == null ? null : FriendSharedView.parse(raw);
  });
}
