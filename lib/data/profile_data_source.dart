import '../account/account_deletion_failure.dart';

/// What is stored in `users/{uid}` (no e-mail, name or photo: those come
/// from the Google account at runtime).
class UserProfile {
  /// App-level display name chosen by the user (1-40), or null.
  final String? nickname;

  /// An account deletion started and has not finished: offer to resume.
  final bool deleting;

  const UserProfile({this.nickname, this.deleting = false});

  static const empty = UserProfile();
}

/// Storage seam for the signed-in user's profile document and for wiping
/// the user's data. Implementations: Firestore, signed-out (inert) and an
/// in-memory fake for tests.
abstract class ProfileDataSource {
  Stream<UserProfile> watch();

  /// Sets the nickname (already validated), or removes it when null.
  /// Accepted locally; does not wait for the server (works offline).
  Future<void> setNickname(String? nickname);

  /// Throws [AccountDeletionFailure] (offline) unless the server answers.
  Future<void> ensureOnline();

  /// Marks `users/{uid}.deleting = true` (confirmed by the server).
  Future<void> markDeleting();

  /// Deletes every favorite, in batches (confirmed by the server).
  Future<void> deleteAllFavorites();

  /// Deletes `users/{uid}` (confirmed by the server).
  Future<void> deleteProfile();
}

/// Inert source for signed-out sessions.
class SignedOutProfileDataSource implements ProfileDataSource {
  const SignedOutProfileDataSource();

  @override
  Stream<UserProfile> watch() => Stream.value(UserProfile.empty);

  @override
  Future<void> setNickname(String? nickname) async {}

  @override
  Future<void> ensureOnline() async {}

  @override
  Future<void> markDeleting() async {}

  @override
  Future<void> deleteAllFavorites() async {}

  @override
  Future<void> deleteProfile() async {}
}
