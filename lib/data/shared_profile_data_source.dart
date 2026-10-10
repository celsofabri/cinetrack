import '../social/social_models.dart';

/// Answer of the rules probe (docs/82 §4.2, D17).
enum RulesProbe {
  /// The own `shared_profiles/{uid}` could be read (exists or not): the
  /// phase-2 rules are published, `epsAt` may be sent. Rules never go back.
  ready,

  /// `permission-denied` on the owner's own document: the old rules.
  oldRules,

  /// No answer (offline, timeout, quota...): try again next session.
  unreachable,
}

/// Storage seam for `shared_profiles/{uid}` (docs/82 §9). Implementations:
/// Firestore, signed-out (inert) and an in-memory fake (tests). Every method
/// throws [SocialFailure] (never Firebase types), like the social source.
///
/// Fatia 1: INERT. Nothing in the app writes a shared profile yet; the only
/// calls are the rules probe, the deletion (account deletion, deactivating
/// friendships: data that cannot exist yet must still be covered BEFORE the
/// first byte is shared) and the export read.
abstract class SharedProfileDataSource {
  /// The signed-in user this source works for ('' when signed out).
  String get uid;

  /// Raw own document (timestamps as `DateTime`, at any depth), or null when
  /// it does not exist ([fromServer] false: or is not on this device). Old
  /// rules: [SocialFailureKind.denied].
  Future<Map<String, dynamic>?> readOwn({required bool fromServer});

  /// ONE server `get` of the own document; see [RulesProbe]. Never throws.
  Future<RulesProbe> probeRules();

  /// Deletes the own document, awaited from the server (deleting nothing is
  /// success). `permission-denied` = old rules = nothing can exist: success.
  /// Timeout: [SocialFailureKind.uncertain] (retry; it is idempotent).
  Future<void> deleteOwn();

  /// A friend's document, from the SERVER only (never the device cache).
  /// Null = it does not exist (the reader is a friend). Not a friend:
  /// [SocialFailureKind.denied].
  Future<Map<String, dynamic>?> readFriend(String friendUid);
}

/// Inert source for signed-out sessions.
class SignedOutSharedProfileDataSource implements SharedProfileDataSource {
  const SignedOutSharedProfileDataSource();

  @override
  String get uid => '';

  @override
  Future<Map<String, dynamic>?> readOwn({required bool fromServer}) async => null;

  @override
  Future<RulesProbe> probeRules() async => RulesProbe.unreachable;

  @override
  Future<void> deleteOwn() async {}

  @override
  Future<Map<String, dynamic>?> readFriend(String friendUid) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));
}
