import 'social_validation.dart';

/// What a signed-in user published when they turned friendships on: the
/// pointer `social/{uid}` plus the search card `handles/{handle}`.
/// Parsing is tolerant: a document without some field still yields a profile.
class SocialProfile {
  final String handle;

  /// Server time of the last handle change (null if the document lacks it).
  final DateTime? handleChangedAt;

  /// Copy of the nickname on the public card.
  final String nickname;

  /// Google photo URL on the card, or null (initials are shown instead).
  final String? photoUrl;

  /// "Aparecer na busca".
  final bool discoverable;

  /// The card document was missing (inconsistent state, tolerated).
  final bool cardMissing;

  const SocialProfile({
    required this.handle,
    this.handleChangedAt,
    this.nickname = '',
    this.photoUrl,
    this.discoverable = false,
    this.cardMissing = false,
  });

  bool get photoVisible => photoUrl != null;

  /// Earliest moment the handle can change again (null = no restriction known).
  DateTime? get nextHandleChange =>
      handleChangedAt?.add(const Duration(days: kHandleChangeIntervalDays));

  bool canChangeHandle(DateTime now) {
    final next = nextHandleChange;
    return next == null || !now.isBefore(next);
  }

  /// Builds a profile from the raw `social/{uid}` and `handles/{handle}` data.
  /// Returns null when there is no usable `social` pointer (= not activated).
  static SocialProfile? fromRaw(Map<String, dynamic>? social, Map<String, dynamic>? card) {
    final handle = social?['handle'];
    if (handle is! String || handle.isEmpty) return null;
    final changed = social?['handleChangedAt'];
    final nickname = card?['nickname'];
    final photo = card?['photoURL'];
    return SocialProfile(
      handle: handle,
      handleChangedAt: changed is DateTime ? changed : null,
      nickname: nickname is String ? nickname : '',
      photoUrl: photo is String && photo.isNotEmpty ? photo : null,
      discoverable: card?['discoverable'] == true,
      cardMissing: card == null,
    );
  }
}

/// Raw documents `social/{uid}` and the card it points to (timestamps already
/// [DateTime]); either may be null.
class RawSocial {
  final Map<String, dynamic>? social;
  final Map<String, dynamic>? card;

  const RawSocial({this.social, this.card});

  bool get isActive => SocialProfile.fromRaw(social, card) != null;
}

/// Default of "Aparecer na busca" in the activation form (visible switch).
/// Product decision pending the Manager's confirmation (docs/55): change it
/// here only; a test pins the form to this constant.
const kDiscoverableByDefault = true;

/// What the user typed to turn friendships on.
class SocialDraft {
  final String handle;
  final String nickname;
  final String? photoUrl;
  final bool discoverable;

  const SocialDraft({
    required this.handle,
    required this.nickname,
    this.photoUrl,
    required this.discoverable,
  });
}

/// Kinds of documents the sweep (deactivation / account deletion) removes
/// page by page. The rules never iterate, so the client does.
enum SweepKind { requestsSent, requestsReceived, friendships, blocks }

/// A document found by a sweep query.
class SweepRef {
  final SweepKind kind;
  final String id;

  const SweepRef(this.kind, this.id);

  @override
  bool operator ==(Object other) => other is SweepRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'SweepRef($kind, $id)';
}

/// Lists included in "Exportar meus dados".
enum SocialExportKind { friends, requestsSent, requestsReceived, blocks }

/// Why a social operation failed. Rule denials all map to [denied] on
/// purpose: the screen must not tell blocked / hidden / missing apart.
enum SocialFailureKind {
  offline,
  uncertain,
  denied,
  quotaExceeded,
  sessionExpired,
  handleTaken,
  alreadyActive,
  notActive,
  tooSoon,
  notGoogle,
  invalid,
  unknown,
}

class SocialFailure implements Exception {
  final SocialFailureKind kind;

  /// Provider error code (never PII).
  final String? code;

  /// For [SocialFailureKind.tooSoon]: when the handle can change again.
  final DateTime? retryAt;

  /// For [SocialFailureKind.invalid]: the pt-BR reason.
  final String? detail;

  const SocialFailure(this.kind, {this.code, this.retryAt, this.detail});

  factory SocialFailure.fromFirestoreCode(String code) => switch (code) {
    'unavailable' ||
    'deadline-exceeded' ||
    'cancelled' => SocialFailure(SocialFailureKind.offline, code: code),
    'permission-denied' => SocialFailure(SocialFailureKind.denied, code: code),
    'resource-exhausted' => SocialFailure(SocialFailureKind.quotaExceeded, code: code),
    'unauthenticated' => SocialFailure(SocialFailureKind.sessionExpired, code: code),
    _ => SocialFailure(SocialFailureKind.unknown, code: code),
  };

  /// pt-BR text.
  String get message => switch (kind) {
    SocialFailureKind.offline => 'Sem conexão. Tente de novo quando estiver online.',
    SocialFailureKind.uncertain =>
      'Não conseguimos confirmar por falta de conexão. Confira o estado e tente de novo.',
    SocialFailureKind.denied => 'Amizades ainda não estão disponíveis. Tente mais tarde.',
    SocialFailureKind.quotaExceeded => 'Muitas operações hoje. Tente de novo amanhã.',
    SocialFailureKind.sessionExpired => 'Sessão expirada. Entre novamente.',
    SocialFailureKind.handleTaken => 'Esse identificador não está disponível.',
    SocialFailureKind.alreadyActive => 'As amizades já estão ativadas nesta conta.',
    SocialFailureKind.notActive => 'As amizades não estão ativadas nesta conta.',
    SocialFailureKind.tooSoon =>
      retryAt == null
          ? 'Você trocou o identificador há pouco tempo. Tente mais tarde.'
          : 'Você poderá trocar de novo em ${formatSocialDate(retryAt!)}.',
    SocialFailureKind.notGoogle => 'Amizades só estão disponíveis para contas Google.',
    SocialFailureKind.invalid => detail ?? 'Confira os dados e tente de novo.',
    SocialFailureKind.unknown => 'Não foi possível concluir. Tente novamente.',
  };

  @override
  String toString() => 'SocialFailure($kind, code: $code)';
}

/// dd/mm/aaaa in the user's local time.
String formatSocialDate(DateTime date) {
  final local = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year}';
}
