/// The signed-in person, as far as the app cares. Name/e-mail/photo come
/// from the Google account at runtime and are never copied to the database.
class AppUser {
  final String uid;
  final String? displayName;
  final String? email;
  final String? photoUrl;

  /// "Membro desde" (account creation), when the provider reports it.
  final DateTime? createdAt;

  const AppUser({
    required this.uid,
    this.displayName,
    this.email,
    this.photoUrl,
    this.createdAt,
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
