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

/// [SocialFailure.code] of a [SocialFailureKind.denied] raised by the FIRST
/// read of [SocialDataSource.closeSocial] (the user's own pointer): only the
/// rules not being published deny that read, so there is nothing social to
/// delete. Any other denial (the close batch itself) is a real failure
/// (docs/71 G5).
const kSocialReadDeniedCode = 'own-pointer-denied';

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

  /// Reserves the handle, writes the card and the pointer in ONE transaction.
  /// Throws [SocialFailureKind.handleTaken] (also when the card exists but the
  /// rules hide it: hidden owner or a block) / [SocialFailureKind.alreadyActive]
  /// / [SocialFailureKind.denied] (rules not published: the own pointer is read
  /// FIRST, so this is never mistaken for "taken").
  Future<void> activate(SocialDraft draft);

  /// Moves the reservation and the pointer to [newHandle] in one transaction;
  /// the old handle is freed. Throws handleTaken / notActive / tooSoon.
  Future<void> changeHandle(String newHandle);

  /// Updates the card (nickname, photo, "Aparecer na busca").
  Future<void> updateCard(CardPatch patch);

  /// Creates the invite link ([draft]): the invite document and the pointer in
  /// ONE transaction, replacing the one that exists (1 active invite per user).
  /// Throws [SocialFailureKind.notActive] / [SocialFailureKind.denied].
  Future<void> createInvite(InviteDraft draft);

  /// Revokes the invite: deletes it and clears the pointer in one transaction.
  /// Idempotent (nothing to revoke is not an error).
  Future<void> revokeInvite();

  /// Opening a link: ONE `get` of `invites/{code}` (never a list). Null = it
  /// does not exist (or was revoked). An expired invite, or one of somebody
  /// who blocked this user (or the reverse), is answered by the rules with
  /// [SocialFailureKind.denied]; callers must treat all of them alike.
  Future<RawInvite?> lookupInvite(String code);

  /// Updates this user's half of the friendships listed in [updates] (D8): ONE
  /// batch; the rules only accept the user's own half.
  Future<void> updateFriendHalves(List<FriendHalfUpdate> updates);

  /// Frees the handle (and invite, if any) and removes the card and the
  /// pointer in one batch. Returns false when there was nothing to remove.
  /// Idempotent. Reads from the server. A denied read of the own pointer
  /// throws denied with code [kSocialReadDeniedCode]; a denied batch throws a
  /// plain denied.
  Future<bool> closeSocial();

  /// Search: ONE `get` of `handles/{handle}` (never a list). Null = the
  /// document does not exist. A card that is hidden or whose owner blocked
  /// this user (or the reverse) is answered by the rules with
  /// [SocialFailureKind.denied]; callers must treat both exactly alike.
  Future<RawCard?> lookupHandle(String handle);

  /// Number of pending requests sent by this user (aggregate `count()`, at
  /// most [kMaxSentRequests]); server read.
  Future<int> countSentRequests();

  /// Creates `friend_requests/{me}_{to}` in one transaction. If the other
  /// person had already asked (crossed request, D4) nothing is requested: ONE
  /// batch creates the friendship and consumes their request
  /// ([SendOutcome.becameFriends]). Throws [SocialFailureKind.alreadySent]
  /// (nothing is created), [SocialFailureKind.denied] when the rules refuse.
  Future<SendOutcome> sendRequest(SendRequestDraft draft);

  /// Accepts a received request: ONE batch (friendship + both requests
  /// deleted). [SocialFailureKind.denied] when the rules refuse (request gone,
  /// block, friendships off...).
  Future<void> acceptRequest(AcceptDraft draft);

  /// Declines a received request: deletes `{from}_{me}` (silent, idempotent).
  Future<void> declineRequest(String fromUid);

  /// Removes the friendship with [otherUid] for both sides (idempotent).
  Future<void> removeFriend(String otherUid);

  /// Blocks [BlockDraft.blockedUid]: ONE batch (block + friendship and both
  /// requests deleted). [SocialFailureKind.denied] when the rules refuse
  /// (e.g. already blocked: the second create would be an update).
  Future<void> blockUser(BlockDraft draft);

  /// Deletes the block of [blockedUid] (idempotent). Restores nothing.
  Future<void> unblockUser(String blockedUid);

  /// A page of blocked people, newest first (server, else the device).
  Future<RawSocialPage> readBlockedPage({Object? cursor, required int limit});

  /// Number of pending requests received (aggregate `count()`, at most
  /// [kMaxReceivedListed]); server read.
  Future<int> countReceivedRequests();

  /// Number of friends (aggregate `count()`, at most [kMaxFriends]); server.
  Future<int> countFriends();

  /// A page of received requests, newest first (server, else the device).
  Future<RawSocialPage> readReceivedPage({Object? cursor, required int limit});

  /// A page of friendships (document-id order; server, else the device).
  Future<RawSocialPage> readFriendsPage({Object? cursor, required int limit});

  /// Deletes the request this user sent to [toUid] (idempotent).
  Future<void> cancelRequest(String toUid);

  /// A page of sent requests, newest first: server when reachable, else the
  /// device ([RawSocialPage.fromCache]). [cursor] comes from the previous page.
  Future<RawSocialPage> readSentPage({Object? cursor, required int limit});

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
  Future<void> activate(SocialDraft draft) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> changeHandle(String newHandle) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> updateCard(CardPatch patch) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> createInvite(InviteDraft draft) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> revokeInvite() =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<RawInvite?> lookupInvite(String code) async => null;

  @override
  Future<void> updateFriendHalves(List<FriendHalfUpdate> updates) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<bool> closeSocial() async => false;

  @override
  Future<RawCard?> lookupHandle(String handle) async => null;

  @override
  Future<int> countSentRequests() async => 0;

  @override
  Future<SendOutcome> sendRequest(SendRequestDraft draft) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> acceptRequest(AcceptDraft draft) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> declineRequest(String fromUid) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> removeFriend(String otherUid) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> blockUser(BlockDraft draft) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> unblockUser(String blockedUid) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<RawSocialPage> readBlockedPage({Object? cursor, required int limit}) async =>
      const RawSocialPage(docs: []);

  @override
  Future<int> countReceivedRequests() async => 0;

  @override
  Future<int> countFriends() async => 0;

  @override
  Future<RawSocialPage> readReceivedPage({Object? cursor, required int limit}) async =>
      const RawSocialPage(docs: []);

  @override
  Future<RawSocialPage> readFriendsPage({Object? cursor, required int limit}) async =>
      const RawSocialPage(docs: []);

  @override
  Future<void> cancelRequest(String toUid) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<RawSocialPage> readSentPage({Object? cursor, required int limit}) async =>
      const RawSocialPage(docs: []);

  @override
  Future<List<SweepRef>> readSweepPage(SweepKind kind, {required int limit}) async => const [];

  @override
  Future<void> deleteRefs(List<SweepRef> refs) async {}
}
