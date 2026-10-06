import 'dart:async';

import 'package:cinetrack/data/social_data_source.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/social/social_validation.dart';

/// In-memory "Firestore" for the social collections, shared by every
/// [InMemorySocialDataSource] of a test. It enforces the same data rules as
/// `firestore.rules` (handle format, 30-day interval, nickname / photo
/// shape, handle taken), so a client bug that the real rules would reject
/// fails here too ([SocialFailureKind.denied]). It does NOT model blocking
/// visibility (that is the job of the rules tests).
class FakeSocialCloud {
  FakeSocialCloud({DateTime Function()? now, List<String>? log})
    : now = now ?? DateTime.now,
      log = log ?? [];

  DateTime Function() now;

  /// Operations that reached the "server", in order.
  final List<String> log;

  /// Reads that reached the "server" (or the device cache), in order: 'read',
  /// 'handleFree', 'lookup:HANDLE', 'count', 'sent:page', 'sweep:KIND'.
  /// Used to prove a screen does not read more than it must (docs/59).
  final List<String> readLog = [];

  bool offline = false;

  /// While set, `read()` (the social state) waits for it: lets a test change
  /// account with a read in flight.
  Completer<void>? readGate;

  /// While set, accept / decline / remove wait for it (to see "Salvando...").
  Completer<void>? writeGate;

  /// While set, the list pages (sent / received / friends) wait for it.
  Completer<void>? pageGate;

  /// While [offline], the list reads still answer from "the device" when true
  /// (persistence on); false = nothing cached.
  bool cacheAvailable = true;

  /// False = the rules that allow the feature are not published (everything
  /// is `permission-denied`, like the old ruleset's catch-all).
  bool rulesLive = true;

  final Map<String, Map<String, dynamic>> social = {}; // uid -> doc
  final Map<String, Map<String, dynamic>> handles = {}; // handle -> card
  final Map<String, Map<String, dynamic>> invites = {};
  final Map<String, Map<String, dynamic>> requests = {}; // "from_to" -> doc
  final Map<String, Map<String, dynamic>> friendships = {}; // "a_b" -> doc
  final Map<String, Map<String, Map<String, dynamic>>> blocks = {}; // uid -> id -> doc

  /// Operation name -> failure thrown ONCE the next time it runs. Names:
  /// 'read', 'activate', 'changeHandle', 'updateCard', 'closeSocial',
  /// 'readSweep:KIND', 'deleteRefs:KIND', 'lookup', 'count', 'sendRequest',
  /// 'cancelRequest', 'sentPage', 'acceptRequest', 'declineRequest',
  /// 'removeFriend', 'countReceived', 'countFriends', 'receivedPage', 'friendsPage'.
  final Map<String, SocialFailure> failures = {};

  /// Number of `deleteRefs` calls so far, and the 1-based call that fails once.
  /// Runs inside `closeSocial`, right before the pointer is removed (simulates a
  /// write from another device / user landing after the first sweep).
  void Function()? beforeClose;

  int deleteCalls = 0;
  int? failOnDeleteCall;
  final List<int> deletePageSizes = [];

  // ---- seeding helpers ----

  void seedActive(
    String uid,
    String handle, {
    String nickname = 'Fulano',
    String? photoUrl,
    bool discoverable = true,
    DateTime? handleChangedAt,
    String? inviteCode,
  }) {
    final at = handleChangedAt ?? now().subtract(const Duration(days: 90));
    social[uid] = {
      'handle': handle,
      'handleChangedAt': at,
      'schemaVersion': 1,
      'inviteCode': ?inviteCode,
    };
    handles[handle] = {
      'uid': uid,
      'nickname': nickname,
      'photoURL': photoUrl,
      'discoverable': discoverable,
      'createdAt': at,
      'updatedAt': at,
    };
    if (inviteCode != null) {
      invites[inviteCode] = {
        'uid': uid,
        'nickname': nickname,
        'createdAt': at,
        'expiresAt': at.add(const Duration(days: 20)),
      };
    }
  }

  static String pairId(String a, String b) => a.compareTo(b) < 0 ? '${a}_$b' : '${b}_$a';

  void seedFriendship(String a, String b, {String aName = 'A', String bName = 'B'}) {
    final lo = a.compareTo(b) < 0 ? a : b;
    final hi = a.compareTo(b) < 0 ? b : a;
    friendships[pairId(a, b)] = {
      'members': [lo, hi],
      'createdAt': now(),
      'aName': lo == a ? aName : bName,
      'bName': lo == a ? bName : aName,
    };
  }

  void seedRequest(String from, String to, {String fromName = 'De', String toName = 'Para'}) {
    requests['${from}_$to'] = {
      'from': from,
      'to': to,
      'fromName': fromName,
      'toName': toName,
      'createdAt': now(),
    };
  }

  void seedBlock(
    String uid,
    String blocked, {
    String? name = 'Bloqueado',
    String? photo,
    DateTime? at,
  }) {
    (blocks[uid] ??= {})[blocked] = {
      'blockedName': ?name,
      'blockedPhoto': ?photo,
      'createdAt': at ?? now(),
    };
  }

  /// Everything the cloud holds that involves [uid] (for "nothing orphaned").
  List<String> leftoversOf(String uid) => [
    if (social.containsKey(uid)) 'social/$uid',
    for (final e in handles.entries)
      if (e.value['uid'] == uid) 'handles/${e.key}',
    for (final e in invites.entries)
      if (e.value['uid'] == uid) 'invites/${e.key}',
    for (final e in requests.entries)
      if (e.value['from'] == uid || e.value['to'] == uid) 'friend_requests/${e.key}',
    for (final e in friendships.entries)
      if ((e.value['members'] as List).contains(uid)) 'friendships/${e.key}',
    for (final id in blocks[uid]?.keys ?? const <String>[]) 'users/$uid/blocks/$id',
  ];

  // ---- rules mirror ----

  static final _controlOrInvisible = RegExp(
    '[\u0000-\u001F\u007F-\u009F\u200B\u200C\u200E\u200F\u2028\u2029\u202A-\u202E\u2060'
    '\u2066-\u2069\u061C\uFEFF]',
  );

  /// `validName` of the rules.
  static bool validName(Object? s) =>
      s is String && s.trim().isNotEmpty && s.length <= 40 && !_controlOrInvisible.hasMatch(s);

  /// `validPhoto` of the rules.
  static bool validPhoto(Object? p) =>
      p == null ||
      (p is String &&
          p.length <= 512 &&
          RegExp(r'^https://lh[0-9]+[.]googleusercontent[.]com/[^\n\r\u2028\u2029]*$').hasMatch(p));

  /// `validHandle` of the rules.
  static bool validHandle(Object? h) =>
      h is String && Handle.errorFor(h) == null && h == h.toLowerCase();

  void checkFailure(String op) {
    final failure = failures.remove(op);
    if (failure != null) throw failure;
  }
}

class InMemorySocialDataSource implements SocialDataSource {
  final FakeSocialCloud cloud;
  @override
  final String uid;

  InMemorySocialDataSource(this.cloud, {required this.uid});

  void _gate({required bool server}) {
    if (!cloud.rulesLive) throw const SocialFailure(SocialFailureKind.denied);
    if (server && cloud.offline) throw const SocialFailure(SocialFailureKind.offline);
  }

  Map<String, dynamic>? _copy(Map<String, dynamic>? m) => m == null ? null : {...m};

  @override
  Future<RawSocial> read({required bool fromServer}) async {
    _gate(server: fromServer);
    cloud.readLog.add('read');
    cloud.checkFailure('read');
    await cloud.readGate?.future;
    final social = _copy(cloud.social[uid]);
    final handle = social?['handle'];
    return RawSocial(social: social, card: handle is String ? _copy(cloud.handles[handle]) : null);
  }

  @override
  Future<bool> isHandleFree(String handle) async {
    _gate(server: true);
    cloud.readLog.add('handleFree');
    return !cloud.handles.containsKey(handle);
  }

  @override
  Future<void> activate(SocialDraft draft) async {
    _gate(server: true);
    cloud.checkFailure('activate');
    if (cloud.handles.containsKey(draft.handle)) {
      throw const SocialFailure(SocialFailureKind.handleTaken);
    }
    if (cloud.social.containsKey(uid)) throw const SocialFailure(SocialFailureKind.alreadyActive);
    if (!FakeSocialCloud.validHandle(draft.handle) ||
        !FakeSocialCloud.validName(draft.nickname) ||
        !FakeSocialCloud.validPhoto(draft.photoUrl)) {
      throw const SocialFailure(SocialFailureKind.denied, code: 'permission-denied');
    }
    final at = cloud.now();
    cloud.handles[draft.handle] = {
      'uid': uid,
      'nickname': draft.nickname,
      'photoURL': draft.photoUrl,
      'discoverable': draft.discoverable,
      'createdAt': at,
      'updatedAt': at,
    };
    cloud.social[uid] = {'handle': draft.handle, 'handleChangedAt': at, 'schemaVersion': 1};
    cloud.log.add('activate');
  }

  @override
  Future<void> changeHandle(String newHandle) async {
    _gate(server: true);
    cloud.checkFailure('changeHandle');
    final social = cloud.social[uid];
    final old = social?['handle'];
    if (old is! String) throw const SocialFailure(SocialFailureKind.notActive);
    if (old == newHandle) return;
    final next = (social!['handleChangedAt'] as DateTime).add(const Duration(days: 30));
    if (next.isAfter(cloud.now())) {
      throw SocialFailure(SocialFailureKind.tooSoon, retryAt: next);
    }
    if (cloud.handles.containsKey(newHandle)) {
      throw const SocialFailure(SocialFailureKind.handleTaken);
    }
    if (!FakeSocialCloud.validHandle(newHandle)) {
      throw const SocialFailure(SocialFailureKind.denied, code: 'permission-denied');
    }
    final card = cloud.handles.remove(old)!;
    final at = cloud.now();
    cloud.handles[newHandle] = {...card, 'createdAt': at, 'updatedAt': at};
    cloud.social[uid] = {...social, 'handle': newHandle, 'handleChangedAt': at};
    cloud.log.add('changeHandle');
  }

  @override
  Future<void> updateCard(CardPatch patch) async {
    _gate(server: true);
    cloud.checkFailure('updateCard');
    final handle = cloud.social[uid]?['handle'];
    if (handle is! String) throw const SocialFailure(SocialFailureKind.notActive);
    final card = {...cloud.handles[handle]!};
    if (patch.nickname != null) card['nickname'] = patch.nickname;
    if (patch.changePhoto) card['photoURL'] = patch.photoUrl;
    if (patch.discoverable != null) card['discoverable'] = patch.discoverable;
    if (!FakeSocialCloud.validName(card['nickname']) ||
        !FakeSocialCloud.validPhoto(card['photoURL'])) {
      throw const SocialFailure(SocialFailureKind.denied, code: 'permission-denied');
    }
    card['updatedAt'] = cloud.now();
    cloud.handles[handle] = card;
    cloud.log.add('updateCard');
  }

  @override
  Future<bool> closeSocial() async {
    _gate(server: true);
    cloud.checkFailure('closeSocial');
    cloud.beforeClose?.call();
    final social = cloud.social[uid];
    if (social == null) return false;
    final handle = social['handle'];
    if (handle is String && cloud.handles[handle]?['uid'] == uid) cloud.handles.remove(handle);
    final invite = social['inviteCode'];
    if (invite is String && cloud.invites[invite]?['uid'] == uid) cloud.invites.remove(invite);
    cloud.social.remove(uid);
    cloud.log.add('closeSocial');
    return true;
  }

  bool _blockedEither(String a, String b) =>
      (cloud.blocks[a]?.containsKey(b) ?? false) || (cloud.blocks[b]?.containsKey(a) ?? false);

  /// `get handles/{h}` under the rules: missing = null; hidden or blocked =
  /// denied (the owner always reads their own card).
  @override
  Future<RawCard?> lookupHandle(String handle) async {
    _gate(server: true);
    cloud.readLog.add('lookup:$handle');
    cloud.checkFailure('lookup');
    final card = cloud.handles[handle];
    if (card == null) return null;
    final owner = card['uid'] as String;
    if (owner != uid && (card['discoverable'] != true || _blockedEither(owner, uid))) {
      throw const SocialFailure(SocialFailureKind.denied, code: 'permission-denied');
    }
    return RawCard(handle, {...card});
  }

  Iterable<MapEntry<String, Map<String, dynamic>>> _sent() =>
      cloud.requests.entries.where((e) => e.value['from'] == uid);

  @override
  Future<int> countSentRequests() async {
    _gate(server: true);
    cloud.readLog.add('count');
    cloud.checkFailure('count');
    return _sent().length.clamp(0, kMaxSentRequests);
  }

  /// `validRequest` of the rules (everything else is "denied").
  bool _requestAllowed(String to, SendRequestDraft draft) =>
      uid != to &&
      RegExp(r'^[^_/]{1,128}$').hasMatch(to) &&
      RegExp(r'^[^_/]{1,128}$').hasMatch(uid) &&
      cloud.social.containsKey(uid) &&
      cloud.social.containsKey(to) &&
      !_blockedEither(uid, to) &&
      !cloud.friendships.containsKey(FakeSocialCloud.pairId(uid, to)) &&
      FakeSocialCloud.validName(draft.fromName) &&
      FakeSocialCloud.validName(draft.toName) &&
      FakeSocialCloud.validPhoto(draft.fromPhoto) &&
      FakeSocialCloud.validPhoto(draft.toPhoto);

  @override
  Future<SendOutcome> sendRequest(SendRequestDraft draft) async {
    _gate(server: true);
    cloud.checkFailure('sendRequest');
    await cloud.writeGate?.future;
    final to = draft.toUid;
    cloud.readLog.add('tx:get:${uid}_$to');
    cloud.readLog.add('tx:get:${to}_$uid');
    if (cloud.requests.containsKey('${uid}_$to')) {
      throw const SocialFailure(SocialFailureKind.alreadySent);
    }
    final inverse = cloud.requests['${to}_$uid'];
    if (inverse != null) {
      // Crossed (D4): the same ONE batch as accepting, after the 300 friends cap.
      cloud.readLog.add('countFriends');
      if (_friends().length >= kMaxFriends) {
        throw const SocialFailure(SocialFailureKind.friendsLimit);
      }
      final photo = inverse['fromPhoto'];
      _applyAccept(
        AcceptDraft(
          fromUid: to,
          fromName: inverse['fromName'] as String,
          fromPhoto: photo is String ? photo : null,
          myName: draft.fromName,
          myPhoto: draft.fromPhoto,
        ),
      );
      cloud.log.add('crossedAccept');
      return SendOutcome.becameFriends;
    }
    if (!_requestAllowed(to, draft)) {
      throw const SocialFailure(SocialFailureKind.denied, code: 'permission-denied');
    }
    cloud.requests['${uid}_$to'] = {
      'from': uid,
      'to': to,
      'fromName': draft.fromName,
      'fromPhoto': ?draft.fromPhoto,
      'toName': draft.toName,
      'toPhoto': ?draft.toPhoto,
      'createdAt': cloud.now(),
    };
    cloud.log.add('sendRequest');
    return SendOutcome.requested;
  }

  /// `validFriendshipCreate` of the rules + the batch that consumes both
  /// requests. Throws denied (and changes nothing) when the rules would.
  void _applyAccept(AcceptDraft draft) {
    final other = draft.fromUid;
    final req = cloud.requests['${other}_$uid'];
    final ok =
        req != null &&
        uid != other &&
        cloud.social.containsKey(uid) &&
        cloud.social.containsKey(other) &&
        !_blockedEither(uid, other) &&
        draft.fromName == req['fromName'] &&
        draft.fromPhoto == req['fromPhoto'] &&
        FakeSocialCloud.validName(draft.fromName) &&
        FakeSocialCloud.validName(draft.myName) &&
        FakeSocialCloud.validPhoto(draft.fromPhoto) &&
        FakeSocialCloud.validPhoto(draft.myPhoto);
    if (!ok) throw const SocialFailure(SocialFailureKind.denied, code: 'permission-denied');
    final meIsA = uid.compareTo(other) < 0;
    cloud.friendships[FakeSocialCloud.pairId(uid, other)] = {
      'members': meIsA ? [uid, other] : [other, uid],
      'createdAt': cloud.now(),
      'aName': meIsA ? draft.myName : draft.fromName,
      if ((meIsA ? draft.myPhoto : draft.fromPhoto) != null)
        'aPhoto': meIsA ? draft.myPhoto : draft.fromPhoto,
      'bName': meIsA ? draft.fromName : draft.myName,
      if ((meIsA ? draft.fromPhoto : draft.myPhoto) != null)
        'bPhoto': meIsA ? draft.fromPhoto : draft.myPhoto,
    };
    cloud.requests.remove('${other}_$uid');
    cloud.requests.remove('${uid}_$other');
  }

  @override
  Future<void> acceptRequest(AcceptDraft draft) async {
    _gate(server: true);
    cloud.checkFailure('acceptRequest');
    await cloud.writeGate?.future;
    _applyAccept(draft);
    cloud.log.add('acceptRequest');
  }

  @override
  Future<void> declineRequest(String fromUid) async {
    _gate(server: true);
    cloud.checkFailure('declineRequest');
    await cloud.writeGate?.future;
    cloud.requests.remove('${fromUid}_$uid');
    cloud.log.add('declineRequest');
  }

  @override
  Future<void> removeFriend(String otherUid) async {
    _gate(server: true);
    cloud.checkFailure('removeFriend');
    await cloud.writeGate?.future;
    cloud.friendships.remove(FakeSocialCloud.pairId(uid, otherUid));
    cloud.log.add('removeFriend');
  }

  /// `users/{me}/blocks/{other}` create under the rules: the same batch
  /// deletes the friendship and both requests; a second create on an existing
  /// block is an update, which the rules refuse; self-block and bad
  /// name / photo are refused too.
  @override
  Future<void> blockUser(BlockDraft draft) async {
    _gate(server: true);
    cloud.checkFailure('blockUser');
    await cloud.writeGate?.future;
    final other = draft.blockedUid;
    final ok =
        other != uid &&
        RegExp(r'^[^_/]{1,128}$').hasMatch(other) &&
        !(cloud.blocks[uid]?.containsKey(other) ?? false) &&
        (draft.name == null || FakeSocialCloud.validName(draft.name)) &&
        FakeSocialCloud.validPhoto(draft.photo);
    if (!ok) throw const SocialFailure(SocialFailureKind.denied, code: 'permission-denied');
    cloud.friendships.remove(FakeSocialCloud.pairId(uid, other));
    cloud.requests.remove('${uid}_$other');
    cloud.requests.remove('${other}_$uid');
    (cloud.blocks[uid] ??= {})[other] = {
      'blockedName': ?draft.name,
      'blockedPhoto': ?draft.photo,
      'createdAt': cloud.now(),
    };
    cloud.log.add('blockUser');
  }

  @override
  Future<void> unblockUser(String blockedUid) async {
    _gate(server: true);
    cloud.checkFailure('unblockUser');
    await cloud.writeGate?.future;
    cloud.blocks[uid]?.remove(blockedUid);
    cloud.log.add('unblockUser');
  }

  @override
  Future<RawSentPage> readBlockedPage({Object? cursor, required int limit}) async {
    _gate(server: false);
    cloud.readLog.add('blocked:page');
    if (cloud.offline && !cloud.cacheAvailable) {
      throw const SocialFailure(SocialFailureKind.offline);
    }
    cloud.checkFailure('blockedPage');
    await cloud.pageGate?.future;
    final all = (cloud.blocks[uid] ?? {}).entries.toList()
      ..sort((a, b) {
        final byTime = (b.value['createdAt'] as DateTime).compareTo(
          a.value['createdAt'] as DateTime,
        );
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    return _pageOf(all, cursor, limit);
  }

  Iterable<MapEntry<String, Map<String, dynamic>>> _received() =>
      cloud.requests.entries.where((e) => e.value['to'] == uid);

  Iterable<MapEntry<String, Map<String, dynamic>>> _friends() =>
      cloud.friendships.entries.where((e) => (e.value['members'] as List).contains(uid));

  @override
  Future<int> countReceivedRequests() async {
    _gate(server: true);
    cloud.readLog.add('countReceived');
    cloud.checkFailure('countReceived');
    return _received().length.clamp(0, kMaxReceivedListed);
  }

  @override
  Future<int> countFriends() async {
    _gate(server: true);
    cloud.readLog.add('countFriends');
    cloud.checkFailure('countFriends');
    return _friends().length.clamp(0, kMaxFriends);
  }

  RawSentPage _pageOf(List<MapEntry<String, Map<String, dynamic>>> all, Object? cursor, int limit) {
    final start = cursor is int ? cursor : 0;
    final slice = all.skip(start).take(limit + 1).toList();
    final page = slice.take(limit).toList();
    return RawSentPage(
      docs: [
        for (final e in page) (id: e.key, data: {...e.value}),
      ],
      cursor: start + page.length,
      hasMore: slice.length > limit,
      fromCache: cloud.offline,
    );
  }

  @override
  Future<RawSentPage> readReceivedPage({Object? cursor, required int limit}) async {
    _gate(server: false);
    cloud.readLog.add('received:page');
    if (cloud.offline && !cloud.cacheAvailable) {
      throw const SocialFailure(SocialFailureKind.offline);
    }
    cloud.checkFailure('receivedPage');
    await cloud.pageGate?.future;
    final all = _received().toList()
      ..sort((a, b) {
        final byTime = (b.value['createdAt'] as DateTime).compareTo(
          a.value['createdAt'] as DateTime,
        );
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    return _pageOf(all, cursor, limit);
  }

  @override
  Future<RawSentPage> readFriendsPage({Object? cursor, required int limit}) async {
    _gate(server: false);
    cloud.readLog.add('friends:page');
    if (cloud.offline && !cloud.cacheAvailable) {
      throw const SocialFailure(SocialFailureKind.offline);
    }
    cloud.checkFailure('friendsPage');
    await cloud.pageGate?.future;
    final all = _friends().toList()..sort((a, b) => a.key.compareTo(b.key));
    return _pageOf(all, cursor, limit);
  }

  @override
  Future<void> cancelRequest(String toUid) async {
    _gate(server: true);
    cloud.checkFailure('cancelRequest');
    cloud.requests.remove('${uid}_$toUid');
    cloud.log.add('cancelRequest');
  }

  @override
  Future<RawSentPage> readSentPage({Object? cursor, required int limit}) async {
    _gate(server: false);
    cloud.readLog.add('sent:page');
    final cached = cloud.offline;
    if (cached && !cloud.cacheAvailable) throw const SocialFailure(SocialFailureKind.offline);
    cloud.checkFailure('sentPage');
    await cloud.pageGate?.future;
    final all = _sent().toList()
      ..sort((a, b) {
        final byTime = (b.value['createdAt'] as DateTime).compareTo(
          a.value['createdAt'] as DateTime,
        );
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    final start = cursor is int ? cursor : 0;
    final slice = all.skip(start).take(limit + 1).toList();
    final page = slice.take(limit).toList();
    return RawSentPage(
      docs: [
        for (final e in page) (id: e.key, data: {...e.value}),
      ],
      cursor: start + page.length,
      hasMore: slice.length > limit,
      fromCache: cached,
    );
  }

  Iterable<String> _ids(SweepKind kind) => switch (kind) {
    SweepKind.requestsSent => [
      for (final e in cloud.requests.entries)
        if (e.value['from'] == uid) e.key,
    ],
    SweepKind.requestsReceived => [
      for (final e in cloud.requests.entries)
        if (e.value['to'] == uid) e.key,
    ],
    SweepKind.friendships => [
      for (final e in cloud.friendships.entries)
        if ((e.value['members'] as List).contains(uid)) e.key,
    ],
    SweepKind.blocks => [...?cloud.blocks[uid]?.keys],
  };

  @override
  Future<List<SweepRef>> readSweepPage(SweepKind kind, {required int limit}) async {
    _gate(server: true);
    cloud.readLog.add('sweep:${kind.name}');
    cloud.checkFailure('readSweep:${kind.name}');
    return [for (final id in _ids(kind).take(limit)) SweepRef(kind, id)];
  }

  @override
  Future<void> deleteRefs(List<SweepRef> refs) async {
    _gate(server: true);
    final kind = refs.first.kind;
    cloud.checkFailure('deleteRefs:${kind.name}');
    cloud.deleteCalls++;
    if (cloud.failOnDeleteCall == cloud.deleteCalls) {
      cloud.failOnDeleteCall = null;
      throw const SocialFailure(SocialFailureKind.offline, code: 'injected');
    }
    for (final ref in refs) {
      switch (ref.kind) {
        case SweepKind.requestsSent || SweepKind.requestsReceived:
          cloud.requests.remove(ref.id);
        case SweepKind.friendships:
          cloud.friendships.remove(ref.id);
        case SweepKind.blocks:
          cloud.blocks[uid]?.remove(ref.id);
      }
    }
    cloud.deletePageSizes.add(refs.length);
    cloud.log.add('delete:${kind.name}:${refs.length}');
  }
}
