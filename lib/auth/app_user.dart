/// The signed-in person, as far as the app cares. Name/e-mail/photo come
/// from the Google account at runtime and are never copied to the database.
class AppUser {
  final String uid;
  final String? displayName;
  final String? email;
  final String? photoUrl;

  /// "Membro desde" (account creation), when the provider reports it.
  final DateTime? createdAt;

  /// Signed in with Google. Friendships exist only for Google accounts (the
  /// security rules check the sign-in provider); the app only offers Google
  /// login today, so this is true unless the provider says otherwise.
  final bool isGoogle;

  const AppUser({
    required this.uid,
    this.displayName,
    this.email,
    this.photoUrl,
    this.createdAt,
    this.isGoogle = true,
  });

  /// Name to show: Google name, else e-mail, else a generic label.
  String get label {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final mail = email?.trim();
    if (mail != null && mail.isNotEmpty) return mail;
    return 'Usuário';
  }

  /// One or two letters for the avatar placeholder.
  String get initials {
    final parts = label.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

/// One sign-in provider of the Firebase user, without Firebase types
/// (`UserInfo.providerId` / `UserInfo.photoURL`).
typedef ProviderPhoto = ({String providerId, String? photoUrl});

/// The photo the app shows and copies to the friendships card (docs/74 🟡-R1,
/// docs/76 🟡-R2, docs/77 P1). When the user has a `google.com` provider entry,
/// ITS photo is the answer, even when it is null or empty (= no photo): Firebase
/// Auth refreshes `providerData` on every Google sign-in, while the top-level
/// `photoURL` is only filled when the account is created, so falling back to it
/// would republish a photo the person removed from Google. The top-level photo
/// counts only when there is no Google provider entry at all. Empty strings
/// count as "no photo".
String? pickPhotoUrl({required String? topLevel, required Iterable<ProviderPhoto> providers}) {
  String? usable(String? url) => url == null || url.trim().isEmpty ? null : url;
  for (final p in providers) {
    if (p.providerId == 'google.com') return usable(p.photoUrl);
  }
  return usable(topLevel);
}
