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

  bool offline = false;

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
  /// 'readSweep:KIND', 'deleteRefs:KIND'.
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

  void seedBlock(String uid, String blocked, {String name = 'Bloqueado'}) {
    (blocks[uid] ??= {})[blocked] = {'blockedName': name, 'createdAt': now()};
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
    cloud.checkFailure('read');
    final social = _copy(cloud.social[uid]);
    final handle = social?['handle'];
    return RawSocial(social: social, card: handle is String ? _copy(cloud.handles[handle]) : null);
  }

  @override
  Future<bool> isHandleFree(String handle) async {
    _gate(server: true);
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
