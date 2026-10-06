import 'dart:math';

/// The invite code is the SECRET id of `invites/{code}` (docs/51, docs/68).
/// The rules only check the format (`^[A-Za-z0-9]{22,40}$`); entropy is up to
/// this generator: [Random.secure], 24 base62 characters (~143 bits), never
/// derived from the uid, the time or a counter.
class InviteCode {
  const InviteCode._();

  static const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  static const minLength = 22;
  static const maxLength = 40;

  /// Characters generated (>= [minLength]).
  static const length = 24;

  static final _format = RegExp(r'^[A-Za-z0-9]{22,40}$');

  /// Same test as `validInviteCode` in `firestore.rules`.
  static bool isValid(String code) => _format.hasMatch(code);

  /// A fresh code. [random] exists so a test can inject a deterministic source;
  /// production code must use the default ([Random.secure]).
  static String generate({Random? random}) {
    final rng = random ?? Random.secure();
    final buffer = StringBuffer();
    // nextInt(62) is uniform: no modulo bias.
    for (var i = 0; i < length; i++) {
      buffer.write(alphabet[rng.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  /// The code inside whatever the user pasted: a bare code, or a link such as
  /// `https://host/cinetrack/#/invite/CODE`. Null when nothing valid is found.
  static String? parse(String raw) {
    final text = raw.trim();
    if (isValid(text)) return text;
    final match = RegExp(r'/invite/([A-Za-z0-9]{22,40})(?![A-Za-z0-9])').firstMatch(text);
    return match?.group(1);
  }
}

/// How long an invite lasts. The rules accept `expiresAt` in the future and at
/// most 30 days AHEAD OF THE SERVER CLOCK; the app sends its own clock plus
/// the validity, so the longest option keeps a margin for a fast device clock.
class InviteValidity {
  const InviteValidity._();

  static const maxDays = 30;

  /// Safety margin kept below the 30-day cap (device clock ahead of the server).
  static const clockMargin = Duration(hours: 12);

  /// Options offered, in days. The longest ("30 dias") is sent as 30 days minus
  /// [clockMargin].
  static const options = [1, 7, 30];

  /// Default validity (docs/68: 7 days: long enough to be answered, short
  /// enough to not stay open by accident).
  static const defaultDays = 7;

  /// What to send for [days] (never more than the cap minus the margin).
  static Duration duration(int days) {
    final wanted = Duration(days: days.clamp(1, maxDays));
    final cap = const Duration(days: maxDays) - clockMargin;
    return wanted > cap ? cap : wanted;
  }
}

/// Builds and reads the shareable link. The app uses the default (hash) URL
/// strategy, so the link is `<page>#/invite/<code>`: it never reaches the
/// server, works under the `/cinetrack/` base href of GitHub Pages and needs no
/// 404 fallback.
class InviteLink {
  const InviteLink._();

  /// [base] is the page the app is served from (`Uri.base`).
  static String build(Uri base, String code) {
    final page = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: base.path.isEmpty ? '/' : base.path,
    );
    return page.replace(fragment: '/invite/$code').toString();
  }
}
