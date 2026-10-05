import '../account/account_deletion_failure.dart';
import '../data/social_data_source.dart';
import '../social/social_models.dart';
import '../social/social_validation.dart';

/// Result of reading the user's social state.
class SocialLoad {
  /// Null = friendships are not activated for this account.
  final SocialProfile? profile;

  /// The answer came from this device (no server confirmation).
  final bool fromCache;

  const SocialLoad({this.profile, this.fromCache = false});
}

/// Sent requests shown per page ("Ver mais" loads the next one).
const kSentPageSize = 20;

/// Received requests / friends shown per page.
const kReceivedPageSize = 20;
const kFriendsPageSize = 50;

/// Answer of a search: someone to show, or nothing. There is deliberately no
/// third case: missing, hidden, blocked and "yourself" are all [SearchNotFound].
sealed class SearchOutcome {
  const SearchOutcome();
}

class SearchFound extends SearchOutcome {
  final FriendCard card;

  const SearchFound(this.card);
}

class SearchNotFound extends SearchOutcome {
  const SearchNotFound();
}

/// Rules of the friendships feature for the signed-in user, over a
/// [SocialDataSource]: validation that matches `firestore.rules`, the 30-day
/// interval, and the sweeps that the rules cannot do (they never iterate).
///
/// Nothing here writes for a user who did not turn friendships on: the only
/// calls that reach the server for them are reads.
class SocialRepository {
  final SocialDataSource _data;
  final DateTime Function() _now;

  /// Documents deleted per batch (Firestore allows 500).
  final int pageSize;

  /// Guard so a bug can never loop forever (400 * 500 = 200k documents).
  final int maxPages;

  SocialRepository(this._data, {DateTime Function()? now, this.pageSize = 400, this.maxPages = 500})
    : _now = now ?? DateTime.now;

  /// Server first; when the server cannot be reached, whatever the device has.
  /// Throws [SocialFailure] ([SocialFailureKind.denied] = the rules that allow
  /// the feature are not published yet).
  Future<SocialLoad> load() async {
    try {
      final raw = await _data.read(fromServer: true);
      return SocialLoad(profile: SocialProfile.fromRaw(raw.social, raw.card));
    } on SocialFailure catch (e) {
      if (e.kind != SocialFailureKind.offline && e.kind != SocialFailureKind.uncertain) rethrow;
      try {
        final raw = await _data.read(fromServer: false);
        return SocialLoad(profile: SocialProfile.fromRaw(raw.social, raw.card), fromCache: true);
      } on SocialFailure {
        throw e;
      }
    }
  }

  /// pt-BR reason why [rawHandle] cannot be used, or null when it is valid
  /// and free. Throws on network errors.
  Future<String?> handleProblem(String rawHandle, {String? current}) async {
    final error = Handle.errorFor(rawHandle);
    if (error != null) return error;
    final handle = Handle.normalize(rawHandle);
    if (handle == current) return null;
    final free = await _data.isHandleFree(handle);
    return free ? null : const SocialFailure(SocialFailureKind.handleTaken).message;
  }

  /// Turns friendships on. [googlePhotoUrl] is copied to the card only when
  /// it passes the same test as the rules; otherwise the card has no photo.
  Future<void> activate({
    required String rawHandle,
    required String rawNickname,
    String? googlePhotoUrl,
    required bool showPhoto,
    required bool discoverable,
  }) {
    final handleError = Handle.errorFor(rawHandle);
    if (handleError != null) return _invalid(handleError);
    final nicknameError = SocialNickname.errorFor(rawNickname);
    if (nicknameError != null) return _invalid(nicknameError);
    return _data.activate(
      SocialDraft(
        handle: Handle.normalize(rawHandle),
        nickname: SocialNickname.normalize(rawNickname)!,
        photoUrl: showPhoto ? SocialPhoto.sanitize(googlePhotoUrl) : null,
        discoverable: discoverable,
      ),
    );
  }

  /// Changes the handle (at most once every 30 days, checked by the rules
  /// with the server clock; checked here too for a clear message).
  Future<void> changeHandle(String rawHandle, {required SocialProfile current}) {
    final error = Handle.errorFor(rawHandle);
    if (error != null) return _invalid(error);
    final handle = Handle.normalize(rawHandle);
    if (handle == current.handle) return _invalid('Esse já é o seu identificador.');
    if (!current.canChangeHandle(_now())) {
      return Future.error(
        SocialFailure(SocialFailureKind.tooSoon, retryAt: current.nextHandleChange),
      );
    }
    return _data.changeHandle(handle);
  }

  Future<void> updateNickname(String rawNickname) {
    final error = SocialNickname.errorFor(rawNickname);
    if (error != null) return _invalid(error);
    return _data.updateCard(CardPatch(nickname: SocialNickname.normalize(rawNickname)));
  }

  /// Exact search by handle: ONE `get` of `handles/{handle}`. Nothing is read
  /// for your own handle or a reserved one. Every way of "nobody to show"
  /// (missing, hidden, blocked, yourself, permission denied) is the same
  /// [SearchNotFound]; only transport problems (offline, quota...) throw.
  /// An invalid handle throws [SocialFailureKind.invalid] (the field already
  /// explains the format, which reveals nothing about anybody).
  Future<SearchOutcome> search(String rawHandle, {String? ownHandle}) async {
    final error = Handle.searchErrorFor(rawHandle);
    if (error != null) return _invalid(error);
    final handle = Handle.normalize(rawHandle);
    if (kReservedHandles.contains(handle) || handle == ownHandle) return const SearchNotFound();
    final RawCard? raw;
    try {
      raw = await _data.lookupHandle(handle);
    } on SocialFailure catch (e) {
      if (e.kind == SocialFailureKind.denied) return const SearchNotFound();
      rethrow;
    }
    final data = raw?.data;
    final uid = data?['uid'];
    if (data == null || uid is! String || uid.isEmpty || uid == _data.uid) {
      return const SearchNotFound();
    }
    final nickname = SocialNickname.clean('${data['nickname'] ?? ''}');
    final photo = data['photoURL'];
    return SearchFound(
      FriendCard(
        uid: uid,
        handle: handle,
        // A card with a nickname that cleans to nothing is not worth showing as a person.
        nickname: nickname.isEmpty ? '@$handle' : nickname,
        photoUrl: photo is String ? SocialPhoto.sanitize(photo) : null,
      ),
    );
  }

  /// Sends a friend request to [target]. Checks the 50 pending requests
  /// limit (one `count()` read), then one transaction that also detects "you
  /// already asked" and "they already asked you" (nothing is created then).
  /// A denial by the rules is the one generic [SocialFailureKind.notSent]. If
  /// the other person had already asked, ONE batch makes it a friendship
  /// ([SendOutcome.becameFriends], D4).
  Future<SendOutcome> sendRequest(FriendCard target, {required SocialProfile me}) async {
    final fromName = SocialNickname.normalize(me.nickname);
    if (fromName == null) return _invalid('Defina um apelido antes de enviar pedidos.');
    final toName = SocialNickname.normalize(target.nickname) ?? '@${target.handle}';
    try {
      final pending = await _data.countSentRequests();
      if (pending >= kMaxSentRequests) {
        throw const SocialFailure(SocialFailureKind.limitReached);
      }
      return await _data.sendRequest(
        SendRequestDraft(
          toUid: target.uid,
          fromName: fromName,
          fromPhoto: SocialPhoto.sanitize(me.photoUrl),
          toName: toName,
          toPhoto: SocialPhoto.sanitize(target.photoUrl),
        ),
      );
    } on SocialFailure catch (e) {
      if (e.kind == SocialFailureKind.denied) {
        throw SocialFailure(SocialFailureKind.notSent, code: e.code);
      }
      rethrow;
    }
  }

  /// Accepts [request]: ONE batch creates the friendship (the other half is
  /// exactly what their request says) and consumes the request. The 300
  /// friends limit is checked first (one `count()` read). A denial by the
  /// rules (request gone, block...) is the one generic
  /// [SocialFailureKind.notAccepted].
  Future<void> acceptRequest(ReceivedRequest request, {required SocialProfile me}) async {
    final myName = SocialNickname.normalize(me.nickname);
    if (myName == null) return _invalid('Defina um apelido antes de aceitar pedidos.');
    try {
      if (await _data.countFriends() >= kMaxFriends) {
        throw const SocialFailure(SocialFailureKind.friendsLimit);
      }
      await _data.acceptRequest(
        AcceptDraft(
          fromUid: request.fromUid,
          fromName: request.rawFromName,
          fromPhoto: request.rawFromPhoto,
          myName: myName,
          myPhoto: SocialPhoto.sanitize(me.photoUrl),
        ),
      );
    } on SocialFailure catch (e) {
      if (e.kind == SocialFailureKind.denied) {
        throw SocialFailure(SocialFailureKind.notAccepted, code: e.code);
      }
      rethrow;
    }
  }

  /// Declines a received request: one silent delete (the sender is not told).
  Future<void> declineRequest(String fromUid) => _data.declineRequest(fromUid);

  /// Removes a friendship (one delete; both sides lose it; nobody is told).
  Future<void> removeFriend(String friendUid) => _data.removeFriend(friendUid);

  /// Pending received requests for the badge: `count()`, at most
  /// [kMaxReceivedListed].
  Future<int> receivedCount() => _data.countReceivedRequests();

  /// A page of received requests, newest first.
  Future<ReceivedPage> receivedRequests({Object? cursor, int pageSize = kReceivedPageSize}) async {
    final raw = await _data.readReceivedPage(cursor: cursor, limit: pageSize);
    final items = <ReceivedRequest>[];
    for (final doc in raw.docs) {
      final from = doc.data['from'];
      final fromUid = from is String && from.isNotEmpty ? from : doc.id.split('_').first;
      final rawName = doc.data['fromName'];
      if (fromUid.isEmpty || fromUid == _data.uid || rawName is! String) continue;
      final name = SocialNickname.clean(rawName);
      final photo = doc.data['fromPhoto'];
      final at = doc.data['createdAt'];
      items.add(
        ReceivedRequest(
          fromUid: fromUid,
          fromName: name.isEmpty ? 'Usuário' : name,
          rawFromName: rawName,
          fromPhoto: photo is String ? SocialPhoto.sanitize(photo) : null,
          rawFromPhoto: photo is String ? photo : null,
          createdAt: at is DateTime ? at : null,
        ),
      );
    }
    return ReceivedPage(
      items: items,
      cursor: raw.cursor,
      hasMore: raw.hasMore,
      fromCache: raw.fromCache,
    );
  }

  /// A page of friends (their half of the pair document).
  Future<FriendsPage> friends({Object? cursor, int pageSize = kFriendsPageSize}) async {
    final raw = await _data.readFriendsPage(cursor: cursor, limit: pageSize);
    final items = <Friend>[];
    for (final doc in raw.docs) {
      final members = doc.data['members'];
      if (members is! List || members.length != 2 || !members.contains(_data.uid)) continue;
      final other = members[0] == _data.uid ? members[1] : members[0];
      if (other is! String || other.isEmpty) continue;
      final otherIsA = members[0] == other;
      final name = SocialNickname.clean('${doc.data[otherIsA ? 'aName' : 'bName'] ?? ''}');
      final photo = doc.data[otherIsA ? 'aPhoto' : 'bPhoto'];
      final at = doc.data['createdAt'];
      items.add(
        Friend(
          uid: other,
          name: name.isEmpty ? 'Usuário' : name,
          photoUrl: photo is String ? SocialPhoto.sanitize(photo) : null,
          since: at is DateTime ? at : null,
        ),
      );
    }
    return FriendsPage(
      items: items,
      cursor: raw.cursor,
      hasMore: raw.hasMore,
      fromCache: raw.fromCache,
    );
  }

  /// Cancels a request this user sent (one delete; idempotent).
  Future<void> cancelRequest(String toUid) => _data.cancelRequest(toUid);

  /// A page of pending sent requests, newest first ([pageSize] per page).
  Future<SentPage> sentRequests({Object? cursor, int pageSize = kSentPageSize}) async {
    final raw = await _data.readSentPage(cursor: cursor, limit: pageSize);
    final items = <SentRequest>[];
    for (final doc in raw.docs) {
      final to = doc.data['to'];
      final toUid = to is String && to.isNotEmpty ? to : doc.id.split('_').last;
      if (toUid.isEmpty) continue;
      final name = SocialNickname.clean('${doc.data['toName'] ?? ''}');
      final photo = doc.data['toPhoto'];
      final at = doc.data['createdAt'];
      items.add(
        SentRequest(
          toUid: toUid,
          toName: name.isEmpty ? 'Usuário' : name,
          toPhoto: photo is String ? SocialPhoto.sanitize(photo) : null,
          createdAt: at is DateTime ? at : null,
        ),
      );
    }
    return SentPage(
      items: items,
      cursor: raw.cursor,
      hasMore: raw.hasMore,
      fromCache: raw.fromCache,
    );
  }

  Future<void> setDiscoverable(bool value) => _data.updateCard(CardPatch(discoverable: value));

  Future<void> setPhotoVisible(bool visible, {String? googlePhotoUrl}) {
    final url = visible ? SocialPhoto.sanitize(googlePhotoUrl) : null;
    if (visible && url == null) {
      return _invalid('Não foi possível usar a foto da sua conta Google.');
    }
    return _data.updateCard(CardPatch(changePhoto: true, photoUrl: url));
  }

  /// Turns friendships off: sweep (friends, requests sent and received,
  /// blocks), close the door (card, invite and pointer in one batch), sweep
  /// AGAIN. The first sweep keeps friendships visibly "on" if it fails (retry
  /// from the UI). Once the pointer is gone nobody can create requests or
  /// pairs involving this user, so the second sweep removes whatever was
  /// created between the first sweep and the close: no residue is possible,
  /// except when that last sweep itself fails. Then this throws a
  /// [SocialFailure] with code [cleanupPendingCode] (the UI offers
  /// [finishCleanup]; account deletion also always sweeps). Retryable and
  /// idempotent; pages of [pageSize].
  Future<void> deactivate() async {
    await sweepAll();
    await _data.closeSocial();
    try {
      await sweepAll();
    } on SocialFailure catch (e) {
      throw SocialFailure(e.kind, code: cleanupPendingCode);
    }
  }

  /// Code of the failure thrown when friendships are already off but the
  /// final sweep did not finish.
  static const cleanupPendingCode = 'cleanup-pending';

  /// Removes any friends, requests and blocks still involving this user.
  Future<void> sweepAll() async {
    for (final kind in SweepKind.values) {
      await _sweep(kind);
    }
  }

  /// Completes a deactivation whose last sweep failed.
  Future<void> finishCleanup() => sweepAll();

  /// Account deletion: the pointer goes FIRST ("close the door": without
  /// `social` nobody can send or accept a request for this uid), then the
  /// sweeps. Throws [AccountDeletionFailure]. Retryable and idempotent: a
  /// second run finds no pointer and just finishes the sweeps.
  ///
  /// Rollout: while the rules are not published the first read is denied and
  /// no social data can exist, so there is nothing to delete.
  Future<void> wipeForAccountDeletion() async {
    try {
      try {
        await _data.closeSocial();
      } on SocialFailure catch (e) {
        if (e.kind == SocialFailureKind.denied) return;
        rethrow;
      }
      for (final kind in SweepKind.values) {
        await _sweep(kind);
      }
    } on SocialFailure catch (e) {
      throw toAccountDeletionFailure(e);
    }
  }

  Future<void> _sweep(SweepKind kind) async {
    for (var i = 0; i < maxPages; i++) {
      final page = await _data.readSweepPage(kind, limit: pageSize);
      if (page.isEmpty) return;
      await _data.deleteRefs(page);
    }
    throw const SocialFailure(SocialFailureKind.unknown, code: 'too-many-pages');
  }

  Future<T> _invalid<T>(String detail) =>
      Future.error(SocialFailure(SocialFailureKind.invalid, detail: detail));
}

/// Account deletion speaks [AccountDeletionFailure].
AccountDeletionFailure toAccountDeletionFailure(SocialFailure e) =>
    AccountDeletionFailure(switch (e.kind) {
      SocialFailureKind.offline => AccountDeletionFailureKind.offline,
      SocialFailureKind.uncertain => AccountDeletionFailureKind.uncertain,
      SocialFailureKind.quotaExceeded => AccountDeletionFailureKind.quotaExceeded,
      SocialFailureKind.sessionExpired => AccountDeletionFailureKind.sessionExpired,
      _ => AccountDeletionFailureKind.unknown,
    }, code: e.code);
