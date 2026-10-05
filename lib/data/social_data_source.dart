import '../social/social_models.dart';

/// Changes to the public card. A `null` field means "leave as is"; the photo
/// has its own flag because "no photo" (null) is a value.
class CardPatch {
  final String? nickname;
  final bool changePhoto;
  final String? photoUrl;
  final bool? discoverable;

  const CardPatch({this.nickname, this.changePhoto = false, this.photoUrl, this.discoverable});

  bool get isEmpty => nickname == null && !changePhoto && discoverable == null;
}

/// Storage seam for the signed-in user's social documents: `social/{uid}`,
/// `handles/{handle}` and the sweeps of requests, friendships and blocks.
/// Implementations: Firestore, signed-out (inert) and an in-memory fake.
/// Every method throws [SocialFailure] (never Firebase types).
///
/// Writes are confirmed by the server (transactions / awaited batches): a
/// social action queued offline and applied hours later would be wrong.
/// Nothing here is ever called for a user who did not turn friendships on,
/// except the reads that tell whether they did.
abstract class SocialDataSource {
  /// The signed-in user this source works for ('' when signed out).
  String get uid;

  /// `social/{uid}` and the card it points to. [fromServer] false = whatever
  /// this device has. Throws [SocialFailureKind.denied] while the rules that
  /// allow the feature are not published.
  Future<RawSocial> read({required bool fromServer});

  /// True when `handles/{handle}` does not exist (server read). A card that
  /// exists but is hidden from this user counts as taken.
  Future<bool> isHandleFree(String handle);

  /// Reserves the handle, writes the card and the pointer in ONE transaction.
  /// Throws [SocialFailureKind.handleTaken] / [SocialFailureKind.alreadyActive].
  Future<void> activate(SocialDraft draft);

  /// Moves the reservation and the pointer to [newHandle] in one transaction;
  /// the old handle is freed. Throws handleTaken / notActive / tooSoon.
  Future<void> changeHandle(String newHandle);

  /// Updates the card (nickname, photo, "Aparecer na busca").
  Future<void> updateCard(CardPatch patch);

  /// Frees the handle (and invite, if any) and removes the card and the
  /// pointer in one batch. Returns false when there was nothing to remove.
  /// Idempotent. Reads from the server.
  Future<bool> closeSocial();

  /// Search: ONE `get` of `handles/{handle}` (never a list). Null = the
  /// document does not exist. A card that is hidden or whose owner blocked
  /// this user (or the reverse) is answered by the rules with
  /// [SocialFailureKind.denied]; callers must treat both exactly alike.
  Future<RawCard?> lookupHandle(String handle);

  /// Number of pending requests sent by this user (aggregate `count()`, at
  /// most [kMaxSentRequests]); server read.
  Future<int> countSentRequests();

  /// Creates `friend_requests/{me}_{to}` in one transaction. Throws
  /// [SocialFailureKind.alreadySent] / [SocialFailureKind.incomingRequest]
  /// (nothing is created), [SocialFailureKind.denied] when the rules refuse.
  Future<void> sendRequest(SendRequestDraft draft);

  /// Deletes the request this user sent to [toUid] (idempotent).
  Future<void> cancelRequest(String toUid);

  /// A page of sent requests, newest first: server when reachable, else the
  /// device ([RawSentPage.fromCache]). [cursor] comes from the previous page.
  Future<RawSentPage> readSentPage({Object? cursor, required int limit});

  /// Up to [limit] documents of [kind] that involve this user, from the
  /// server. Empty = nothing left.
  Future<List<SweepRef>> readSweepPage(SweepKind kind, {required int limit});

  /// Deletes exactly [refs] in one batch (idempotent).
  Future<void> deleteRefs(List<SweepRef> refs);
}

/// Inert source for signed-out sessions.
class SignedOutSocialDataSource implements SocialDataSource {
  const SignedOutSocialDataSource();

  @override
  String get uid => '';

  @override
  Future<RawSocial> read({required bool fromServer}) async => const RawSocial();

  @override
  Future<bool> isHandleFree(String handle) async => false;

  @override
  Future<void> activate(SocialDraft draft) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> changeHandle(String newHandle) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> updateCard(CardPatch patch) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<bool> closeSocial() async => false;

  @override
  Future<RawCard?> lookupHandle(String handle) async => null;

  @override
  Future<int> countSentRequests() async => 0;

  @override
  Future<void> sendRequest(SendRequestDraft draft) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> cancelRequest(String toUid) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<RawSentPage> readSentPage({Object? cursor, required int limit}) async =>
      const RawSentPage(docs: []);

  @override
  Future<List<SweepRef>> readSweepPage(SweepKind kind, {required int limit}) async => const [];

  @override
  Future<void> deleteRefs(List<SweepRef> refs) async {}
}
