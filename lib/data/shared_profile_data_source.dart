import '../data/social_payloads.dart';
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
/// Fatia 2: the owner's toggles ([toggle], a transaction) and the
/// recalculation engine ([writeSections], its own `update`, never in a batch
/// with a favorite, D4) write the document; deletion, export and the rules
/// probe come from Fatia 1.
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

  /// A consent change as ONE transaction (docs/82 §7.1, RF-P4–P7): reads the
  /// own document, [plan] builds the write for what was read (it may throw a
  /// [SocialFailure] to stop), and the write is applied in the same
  /// transaction. Never queued. Failures: [SocialFailureKind.offline] =
  /// nothing was sent (the read failed); [SocialFailureKind.uncertain] = the
  /// write was sent and no answer came (timeout, `unavailable` /
  /// `deadline-exceeded` on the commit): the caller reconciles with a server
  /// read; [SocialFailureKind.denied] = old rules or friendships off.
  Future<void> toggle(SocialWrite Function(Map<String, dynamic>? current) plan);

  /// A recalculation or pulse (docs/82 §6): ONE `update` of the own document,
  /// resolved when the server acknowledges it. Its failures go to the caller
  /// only (never to the favorites' sync banner). `not-found` comes out as
  /// [SocialFailureKind.unknown] with code `not-found`.
  Future<void> writeSections(SocialWrite write);

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
  Future<void> toggle(SocialWrite Function(Map<String, dynamic>? current) plan) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<void> writeSections(SocialWrite write) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));

  @override
  Future<Map<String, dynamic>?> readFriend(String friendUid) =>
      Future.error(const SocialFailure(SocialFailureKind.sessionExpired));
}
