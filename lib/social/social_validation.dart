import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Client-side validation that MUST agree with `firestore.rules` (the rules
/// are the real guard; these checks only give a good message before a write
/// that the server would refuse as a whole). A test compares the reserved
/// handle list with the one in the rules file.

/// The 31 handles nobody can take. Identical to `validHandle` in the rules.
const kReservedHandles = <String>{
  'admin', 'administrador', 'cinetrack', 'suporte', 'support', 'ajuda', 'help', //
  'root', 'api', 'me', 'eu', 'staff', 'oficial', 'official', 'moderador',
  'moderator', 'sistema', 'system', 'seguranca', 'security', 'privacidade',
  'privacy', 'contato', 'contact', 'equipe', 'team', 'null', 'undefined',
  'anonymous', 'anonimo', 'cine',
};

/// Number of days between two handle changes (rules: `duration.value(30,'d')`).
const kHandleChangeIntervalDays = 30;

/// `@handle`: 3-20 of `a-z 0-9 _`, no `_` at either end, not reserved.
class Handle {
  const Handle._();

  static const minLength = 3;
  static const maxLength = 20;
  static final _format = RegExp(r'^[a-z0-9_]{3,20}$');

  /// What the user typed -> canonical form: trimmed, one leading `@` dropped,
  /// lower case. Does not validate (see [errorFor]).
  static String normalize(String raw) {
    var value = raw.trim();
    if (value.startsWith('@')) value = value.substring(1);
    return value.toLowerCase();
  }

  /// pt-BR message for an invalid [raw] handle, or null when it is valid.
  static String? errorFor(String raw) {
    final value = normalize(raw);
    if (value.isEmpty) return 'Digite um identificador.';
    if (value.length < minLength) return 'Use pelo menos $minLength caracteres.';
    if (value.length > maxLength) return 'Use no máximo $maxLength caracteres.';
    if (!_format.hasMatch(value)) {
      return 'Use só letras minúsculas sem acento, números e _ (sem espaços).';
    }
    if (value.startsWith('_') || value.endsWith('_')) {
      return 'O identificador não pode começar nem terminar com _.';
    }
    if (kReservedHandles.contains(value)) return 'Esse identificador não está disponível.';
    return null;
  }

  /// Like [errorFor] for the search field: a reserved handle is a valid thing
  /// to look for (nobody owns it, so the answer is the generic "not found").
  static String? searchErrorFor(String raw) {
    final value = normalize(raw);
    if (kReservedHandles.contains(value)) return null;
    return errorFor(raw);
  }

  /// The canonical handle, or null when invalid.
  static String? parse(String raw) => errorFor(raw) == null ? normalize(raw) : null;
}

/// The nickname that is copied to the public card (`handles/{h}.nickname`).
/// Rules: 1-40 UTF-16 code units after trim, no control / zero-width / bidi
/// characters. They do NOT bar NBSP, U+3000 or tag characters, so those are
/// handled here. The limit counts UTF-16 units exactly like Dart's
/// `String.length`: 40 CJK characters or 20 emoji.
class SocialNickname {
  const SocialNickname._();

  static const maxLength = 40;

  // Removed outright: zero-width, bidi marks and embeddings, word joiner,
  // Arabic letter mark, BOM, line/paragraph separators, tag characters.
  // U+200D (ZWJ) stays: emoji sequences need it.
  static final _invisible = RegExp(
    '[\u200B\u200C\u200E\u200F\u2028\u2029\u202A-\u202E\u2060\u2066-\u2069\u061C\uFEFF]'
    '|[\u{E0000}-\u{E007F}]',
    unicode: true,
  );
  // Blanks that look empty but are not trimmed by the rules: become a plain space.
  static final _blank = RegExp('[\u00A0\u3000\t\n\r]');
  static final _control = RegExp(r'\p{Cc}', unicode: true);

  /// Cleans [raw] for storage and display: NFC, invisible characters removed,
  /// odd blanks turned into spaces, trimmed. May be empty or too long.
  static String clean(String raw) {
    var value = unorm.nfc(raw);
    value = value.replaceAll(_blank, ' ');
    value = value.replaceAll(_invisible, '').replaceAll(_control, '');
    return value.trim();
  }

  /// [clean]ed nickname if it is valid (1-40 UTF-16 units), else null.
  static String? normalize(String raw) {
    final value = clean(raw);
    if (value.isEmpty || value.length > maxLength) return null;
    return value;
  }

  /// pt-BR message for an invalid [raw] nickname, or null when it is valid.
  static String? errorFor(String raw) {
    final value = clean(raw);
    if (value.isEmpty) return 'Digite um apelido (não pode ficar vazio).';
    if (value.length > maxLength) {
      return 'Use no máximo $maxLength caracteres (um emoji conta como 2).';
    }
    return null;
  }
}

/// The photo URL that may be copied to the public card.
class SocialPhoto {
  const SocialPhoto._();

  static const maxLength = 512;
  static final _host = RegExp(r'^https://lh[0-9]+[.]googleusercontent[.]com/');
  // The rules' `.*` does not match line breaks; whitespace has no place in a URL.
  static final _unsafe = RegExp('[\u0000-\u0020\u007F-\u009F\u2028\u2029]');

  /// [url] if the rules would accept it, else null (writing anything else
  /// would make the whole write fail).
  static String? sanitize(String? url) {
    if (url == null || url.length > maxLength) return null;
    if (!_host.hasMatch(url) || _unsafe.hasMatch(url)) return null;
    return url;
  }
}
