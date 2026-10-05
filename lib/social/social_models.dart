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

  /// Sending a request failed for a reason the screen must NOT explain: the
  /// rules answer the same for blocked, hidden, not activated and "already
  /// friends" (docs/51). One generic message.
  notSent,

  /// This user already has a pending request to the same person.
  alreadySent,

  /// Accepting failed for a reason the screen must NOT explain (the request
  /// was cancelled, a block, friendships off: the rules answer the same).
  notAccepted,

  /// 300 friends (docs/49 D5; client-side limit).
  friendsLimit,

  /// 50 pending sent requests (docs/49 D5; client-side limit).
  limitReached,
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
    SocialFailureKind.notSent => 'Não foi possível enviar o pedido. Tente de novo mais tarde.',
    SocialFailureKind.alreadySent => 'Você já enviou um pedido para essa pessoa.',
    SocialFailureKind.notAccepted =>
      'Não foi possível aceitar o pedido. Ele pode ter sido cancelado. Atualizamos a lista.',
    SocialFailureKind.friendsLimit =>
      'Você atingiu o limite de $kMaxFriends amigos. Remova alguém para adicionar outro amigo.',
    SocialFailureKind.limitReached =>
      'Você atingiu o limite de $kMaxSentRequests pedidos enviados. '
          'Cancele algum pedido para enviar outro.',
    SocialFailureKind.unknown => 'Não foi possível concluir. Tente novamente.',
  };

  @override
  String toString() => 'SocialFailure($kind, code: $code)';
}

/// The only message a search shows when nobody can be shown: the handle does
/// not exist, the person is hidden, blocked you, or is yourself. It must be
/// identical in all of those cases (docs/49, docs/51).
const kSearchNotFoundMessage = 'Não encontramos ninguém com esse apelido';

/// Pending sent requests allowed per user (docs/49 D5). Client-side only: the
/// rules cannot count documents.
const kMaxSentRequests = 50;

/// Friends allowed per user (docs/49 D5). Client-side only.
const kMaxFriends = 300;

/// Received requests listed at most (docs/49 D5: 50; the rest wait until the
/// user answers some). Client-side only.
const kMaxReceivedListed = 50;

/// What the public card of someone else shows in a search result.
class FriendCard {
  final String uid;
  final String handle;
  final String nickname;
  final String? photoUrl;

  const FriendCard({
    required this.uid,
    required this.handle,
    required this.nickname,
    this.photoUrl,
  });
}

/// A request this user sent and nobody answered yet.
class SentRequest {
  final String toUid;
  final String toName;
  final String? toPhoto;
  final DateTime? createdAt;

  const SentRequest({required this.toUid, required this.toName, this.toPhoto, this.createdAt});
}

/// One page of sent requests, newest first.
class SentPage {
  final List<SentRequest> items;

  /// Opaque cursor for the next page; null when [hasMore] is false.
  final Object? cursor;
  final bool hasMore;

  /// Answered from this device (no server confirmation).
  final bool fromCache;

  const SentPage({required this.items, this.cursor, this.hasMore = false, this.fromCache = false});
}

/// A request somebody sent to this user and nobody answered yet.
class ReceivedRequest {
  final String fromUid;

  /// Cleaned for display.
  final String fromName;

  /// Exactly as stored: accepting copies it (the rules compare it with the
  /// request, character by character).
  final String rawFromName;

  /// Photo to show (sanitised) and as stored (copied on accept).
  final String? fromPhoto;
  final String? rawFromPhoto;
  final DateTime? createdAt;

  const ReceivedRequest({
    required this.fromUid,
    required this.fromName,
    required this.rawFromName,
    this.fromPhoto,
    this.rawFromPhoto,
    this.createdAt,
  });
}

/// One page of received requests, newest first.
class ReceivedPage {
  final List<ReceivedRequest> items;
  final Object? cursor;
  final bool hasMore;
  final bool fromCache;

  const ReceivedPage({
    required this.items,
    this.cursor,
    this.hasMore = false,
    this.fromCache = false,
  });
}

/// A friend as the friendship document shows them (their half).
class Friend {
  final String uid;
  final String name;
  final String? photoUrl;
  final DateTime? since;

  const Friend({required this.uid, required this.name, this.photoUrl, this.since});
}

/// One page of friends (document-id order; the screen sorts by name).
class FriendsPage {
  final List<Friend> items;
  final Object? cursor;
  final bool hasMore;
  final bool fromCache;

  const FriendsPage({
    required this.items,
    this.cursor,
    this.hasMore = false,
    this.fromCache = false,
  });
}

/// What "Enviar pedido" ended up doing.
enum SendOutcome {
  /// A pending request now exists.
  requested,

  /// The other person had already asked: it became a friendship (D4).
  becameFriends,
}

/// What to write to accept a request (names already as the rules need them).
class AcceptDraft {
  final String fromUid;

  /// The other person's half: exactly what their request says.
  final String fromName;
  final String? fromPhoto;

  /// This user's half: the nickname / photo of their own card.
  final String myName;
  final String? myPhoto;

  const AcceptDraft({
    required this.fromUid,
    required this.fromName,
    this.fromPhoto,
    required this.myName,
    this.myPhoto,
  });
}

/// Raw `handles/{h}` read for a search (timestamps already [DateTime]).
class RawCard {
  final String handle;
  final Map<String, dynamic> data;

  const RawCard(this.handle, this.data);
}

/// A page of raw `friend_requests` documents (id + data) as the data source
/// found them.
class RawSentPage {
  final List<({String id, Map<String, dynamic> data})> docs;
  final Object? cursor;
  final bool hasMore;
  final bool fromCache;

  const RawSentPage({
    required this.docs,
    this.cursor,
    this.hasMore = false,
    this.fromCache = false,
  });
}

/// What to write for "Enviar pedido" (already validated and cleaned).
class SendRequestDraft {
  final String toUid;
  final String fromName;
  final String? fromPhoto;
  final String toName;
  final String? toPhoto;

  const SendRequestDraft({
    required this.toUid,
    required this.fromName,
    this.fromPhoto,
    required this.toName,
    this.toPhoto,
  });
}

/// dd/mm/aaaa in the user's local time.
String formatSocialDate(DateTime date) {
  final local = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year}';
}
