/// Display name ("apelido") the user can set inside the app (the Google
/// name stays untouched). Rules mirror `firestore.rules`: 1 to 40 characters
/// after trimming.
class Nickname {
  const Nickname._();

  static const maxLength = 40;

  /// Trims [raw] and returns it, or null when it is not valid.
  static String? normalize(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.length > maxLength) return null;
    return value;
  }

  /// pt-BR message for an invalid [raw], or null when it is valid.
  static String? errorFor(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return 'Digite um apelido (não pode ficar vazio).';
    if (value.length > maxLength) return 'Use no máximo $maxLength caracteres.';
    return null;
  }
}
