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
  Future<List<SweepRef>> readSweepPage(SweepKind kind, {required int limit}) async => const [];

  @override
  Future<void> deleteRefs(List<SweepRef> refs) async {}
}
