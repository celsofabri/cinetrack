import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/social_data_source.dart';
import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/repositories/social_repository.dart'
    show kBlockedPageSize, kFriendsPageSize, kReceivedPageSize, kSentPageSize;
import 'package:cinetrack/social/invite_code.dart';
import 'package:cinetrack/social/social_models.dart';

/// Golden test: what the Dart app writes and queries (SocialPayloads) must
/// equal firestore_rules_test/fixtures/social_payloads.json, which the rules
/// suite (dart_payloads.test.mjs) replays against firestore.rules. A changed
/// field/type/path fails here until the fixture is regenerated on purpose:
///   UPDATE_GOLDEN=1 flutter test test/social_payloads_golden_test.dart
/// then `npm test` in firestore_rules_test (see docs/55).
const _fixturePath = 'firestore_rules_test/fixtures/social_payloads.json';
const _photo = 'https://lh3.googleusercontent.com/a/ana';
const _uid = 'uid-ana';

Map<String, Object?> _scenarios() {
  const draft = SocialDraft(handle: 'ana_9', nickname: 'Ana', discoverable: true);
  const draftPhoto = SocialDraft(
    handle: 'ana_9',
    nickname: 'Ana',
    photoUrl: _photo,
    discoverable: false,
  );
  Map<String, Object?> change(String? photo) => {
    'uid': _uid,
    'oldHandle': 'ana',
    'newHandle': 'ana_novo',
    'nickname': 'Ana',
    'photoUrl': photo,
    'discoverable': true,
  };
  SocialWrite changeWrite(Map<String, Object?> i) => SocialPayloads.changeHandle(
    i['uid']! as String,
    oldHandle: i['oldHandle']! as String,
    newHandle: i['newHandle']! as String,
    nickname: i['nickname'],
    photoUrl: i['photoUrl'],
    discoverable: i['discoverable']! as bool,
  );
  Map<String, Object?> entry(Map<String, Object?> input, SocialWrite w) => {
    'input': input,
    'write': w.toJson(),
  };
  Map<String, Object?> draftJson(SocialDraft d) => {
    'uid': _uid,
    'handle': d.handle,
    'nickname': d.nickname,
    'photoUrl': d.photoUrl,
    'discoverable': d.discoverable,
  };
  const to = 'uid-bruno';
  const plain = SendRequestDraft(toUid: to, fromName: 'Ana', toName: 'Bruno');
  const withPhotos = SendRequestDraft(
    toUid: to,
    fromName: 'Ana',
    fromPhoto: _photo,
    toName: 'Bruno',
    toPhoto: 'https://lh4.googleusercontent.com/a/bruno',
  );
  Map<String, Object?> draftIn(SendRequestDraft d) => {
    'uid': _uid,
    'toUid': d.toUid,
    'fromName': d.fromName,
    'fromPhoto': d.fromPhoto,
    'toName': d.toName,
    'toPhoto': d.toPhoto,
  };
  const accept = AcceptDraft(fromUid: to, fromName: 'Bruno', myName: 'Ana');
  const acceptPhotos = AcceptDraft(
    fromUid: to,
    fromName: 'Bruno',
    fromPhoto: 'https://lh4.googleusercontent.com/a/bruno',
    myName: 'Ana',
    myPhoto: _photo,
  );
  // The same pair seen from the other side: "me" sorts AFTER the other person.
  const acceptAsB = AcceptDraft(fromUid: _uid, fromName: 'Ana', myName: 'Bruno');
  Map<String, Object?> acceptIn(String uid, AcceptDraft d) => {
    'uid': uid,
    'fromUid': d.fromUid,
    'fromName': d.fromName,
    'fromPhoto': d.fromPhoto,
    'myName': d.myName,
    'myPhoto': d.myPhoto,
  };
  const block = BlockDraft(blockedUid: to, name: 'Bruno');
  const blockPhoto = BlockDraft(
    blockedUid: to,
    name: 'Bruno',
    photo: 'https://lh4.googleusercontent.com/a/bruno',
  );
  // No usable name / photo on the card: both optional keys are left out.
  const blockBare = BlockDraft(blockedUid: to);
  Map<String, Object?> blockIn(BlockDraft d) => {
    'uid': _uid,
    'blockedUid': d.blockedUid,
    'name': d.name,
    'photo': d.photo,
  };
  const code = 'AbCdEfGhIjKlMnOpQrStUv12';
  const code2 = 'ZyXwVuTsRqPoNmLkJiHgFe99';
  final week = InviteValidity.duration(7);
  final longest = InviteValidity.duration(30);
  Map<String, Object?> inviteIn(InviteDraft d, {String? replaces}) => {
    'uid': _uid,
    'code': d.code,
    'nickname': d.nickname,
    'photoUrl': d.photoUrl,
    'validityMs': d.validity.inMilliseconds,
    'replacesCode': replaces,
  };
  final invite = InviteDraft(code: code, nickname: 'Ana', validity: week);
  final invitePhoto = InviteDraft(
    code: code2,
    nickname: 'Ana',
    photoUrl: _photo,
    validity: longest,
  );
  Map<String, Object?> halvesIn(List<FriendHalfUpdate> u) => {
    'uid': _uid,
    'updates': [
      for (final h in u) {'pairKey': h.pairKey, 'meIsA': h.meIsA, 'name': h.name, 'photo': h.photo},
    ],
  };
  // uid-ana < uid-bruno: Ana is member A of this pair; Dora (uid-dora) < uid-ana? no: 'uid-ana' < 'uid-dora'.
  // The pair "uid-aaa_uid-ana" has Ana as B.
  final halves = [
    const FriendHalfUpdate(pairKey: 'uid-ana_uid-bruno', meIsA: true, name: 'Ana Nova'),
    const FriendHalfUpdate(
      pairKey: 'uid-aaa_uid-ana',
      meIsA: false,
      name: 'Ana Nova',
      photo: _photo,
    ),
  ];
  return {
    'createInvite': entry(inviteIn(invite), SocialPayloads.createInvite(_uid, invite)),
    'createInvite_with_photo': entry(
      inviteIn(invitePhoto),
      SocialPayloads.createInvite(_uid, invitePhoto),
    ),
    'createInvite_replaces': entry(
      inviteIn(invitePhoto, replaces: code),
      SocialPayloads.createInvite(_uid, invitePhoto, replacesCode: code),
    ),
    'revokeInvite': entry({'uid': _uid, 'code': code}, SocialPayloads.revokeInvite(_uid, code)),
    'revokeInvite_pointer_only': entry({
      'uid': _uid,
      'code': code,
    }, SocialPayloads.revokeInvite(_uid, code, inviteExists: false)),
    'updateCard_nickname_with_invite': entry({
      'handle': 'ana',
      'nickname': 'Nova',
      'inviteCode': code,
    }, SocialPayloads.updateCard('ana', const CardPatch(nickname: 'Nova'), inviteCode: code)),
    'updateCard_photo_on_with_invite': entry(
      {'handle': 'ana', 'photoUrl': _photo, 'inviteCode': code},
      SocialPayloads.updateCard(
        'ana',
        const CardPatch(changePhoto: true, photoUrl: _photo),
        inviteCode: code,
      ),
    ),
    'updateCard_photo_off_with_invite': entry({
      'handle': 'ana',
      'photoUrl': null,
      'inviteCode': code,
    }, SocialPayloads.updateCard('ana', const CardPatch(changePhoto: true), inviteCode: code)),
    'updateCard_discoverable_with_invite': entry({
      'handle': 'ana',
      'discoverable': false,
      'inviteCode': code,
    }, SocialPayloads.updateCard('ana', const CardPatch(discoverable: false), inviteCode: code)),
    'refreshHalves': entry(halvesIn(halves), SocialPayloads.refreshHalves(halves)),
    'refreshHalves_photo_removed': entry(
      halvesIn([const FriendHalfUpdate(pairKey: 'uid-ana_uid-bruno', meIsA: true, name: 'Ana')]),
      SocialPayloads.refreshHalves([
        const FriendHalfUpdate(pairKey: 'uid-ana_uid-bruno', meIsA: true, name: 'Ana'),
      ]),
    ),
    'blockUser': entry(blockIn(block), SocialPayloads.blockUser(_uid, block)),
    'blockUser_with_photo': entry(blockIn(blockPhoto), SocialPayloads.blockUser(_uid, blockPhoto)),
    'blockUser_bare': entry(blockIn(blockBare), SocialPayloads.blockUser(_uid, blockBare)),
    'unblockUser': entry({'uid': _uid, 'blockedUid': to}, SocialPayloads.unblockUser(_uid, to)),
    'acceptRequest': entry(acceptIn(_uid, accept), SocialPayloads.acceptRequest(_uid, accept)),
    'acceptRequest_with_photos': entry(
      acceptIn(_uid, acceptPhotos),
      SocialPayloads.acceptRequest(_uid, acceptPhotos),
    ),
    'acceptRequest_as_b': entry(
      acceptIn(to, acceptAsB),
      SocialPayloads.acceptRequest(to, acceptAsB),
    ),
    'declineRequest': entry({'uid': _uid, 'fromUid': to}, SocialPayloads.declineRequest(_uid, to)),
    'removeFriend': entry({'uid': _uid, 'otherUid': to}, SocialPayloads.removeFriend(_uid, to)),
    'sendRequest': entry(draftIn(plain), SocialPayloads.sendRequest(_uid, plain)),
    'sendRequest_with_photos': entry(
      draftIn(withPhotos),
      SocialPayloads.sendRequest(_uid, withPhotos),
    ),
    'cancelRequest': entry({'uid': _uid, 'toUid': to}, SocialPayloads.cancelRequest(_uid, to)),
    'activate': entry(draftJson(draft), SocialPayloads.activate(_uid, draft)),
    'activate_with_photo': entry(draftJson(draftPhoto), SocialPayloads.activate(_uid, draftPhoto)),
    'changeHandle': entry(change(null), changeWrite(change(null))),
    'changeHandle_with_photo': entry(change(_photo), changeWrite(change(_photo))),
    'updateCard_nickname': entry({
      'handle': 'ana',
      'nickname': 'Nova',
    }, SocialPayloads.updateCard('ana', const CardPatch(nickname: 'Nova'))),
    'updateCard_photo_on': entry({
      'handle': 'ana',
      'photoUrl': _photo,
    }, SocialPayloads.updateCard('ana', const CardPatch(changePhoto: true, photoUrl: _photo))),
    'updateCard_photo_off': entry({
      'handle': 'ana',
      'photoUrl': null,
    }, SocialPayloads.updateCard('ana', const CardPatch(changePhoto: true))),
    'updateCard_discoverable': entry({
      'handle': 'ana',
      'discoverable': false,
    }, SocialPayloads.updateCard('ana', const CardPatch(discoverable: false))),
    'close': entry({'uid': _uid, 'handle': 'ana'}, SocialPayloads.close(_uid, handle: 'ana')),
    'close_with_invite': entry({
      'uid': _uid,
      'handle': 'ana',
      'inviteCode': 'AbCdEfGhIjKlMnOpQrStUv12',
    }, SocialPayloads.close(_uid, handle: 'ana', inviteCode: 'AbCdEfGhIjKlMnOpQrStUv12')),
    'close_pointer_only': entry({'uid': _uid}, SocialPayloads.close(_uid)),
    'sweepDelete': entry(
      {
        'uid': _uid,
        'refs': [
          'requestsSent:uid-ana_uid-x',
          'requestsReceived:uid-y_uid-ana',
          'friendships:uid-ana_uid-b',
          'blocks:uid-z',
        ],
      },
      SocialPayloads.sweepDelete(_uid, const [
        SweepRef(SweepKind.requestsSent, 'uid-ana_uid-x'),
        SweepRef(SweepKind.requestsReceived, 'uid-y_uid-ana'),
        SweepRef(SweepKind.friendships, 'uid-ana_uid-b'),
        SweepRef(SweepKind.blocks, 'uid-z'),
      ]),
    ),
  };
}

Map<String, Object?> _queries() => {
  for (final kind in SweepKind.values)
    kind.name: {'uid': _uid, 'query': SocialPayloads.sweepQuery(kind, _uid, 400).toJson()},
};

Map<String, Object?> _requestQueries() => {
  'sent': {'uid': _uid, 'query': SocialPayloads.sentQuery(_uid, kSentPageSize + 1).toJson()},
  'sentCount': {'uid': _uid, 'query': SocialPayloads.sentCountQuery(_uid).toJson()},
  'received': {
    'uid': _uid,
    'query': SocialPayloads.receivedQuery(_uid, kReceivedPageSize + 1).toJson(),
  },
  'receivedCount': {'uid': _uid, 'query': SocialPayloads.receivedCountQuery(_uid).toJson()},
  'friends': {
    'uid': _uid,
    'query': SocialPayloads.friendsQuery(_uid, kFriendsPageSize + 1).toJson(),
  },
  'friendsCount': {'uid': _uid, 'query': SocialPayloads.friendsCountQuery(_uid).toJson()},
  'blocked': {
    'uid': _uid,
    'query': SocialPayloads.blocksQuery(_uid, kBlockedPageSize + 1).toJson(),
  },
};

Map<String, Object?> _lookups() => {
  'handle': {'handle': 'bruno', 'get': SocialPayloads.lookupPath('bruno')},
  'invite': {
    'code': 'AbCdEfGhIjKlMnOpQrStUv12',
    'get': SocialPayloads.lookupInvitePath('AbCdEfGhIjKlMnOpQrStUv12'),
  },
};

Map<String, Object?> _golden() => {
  'comment':
      'Generated by test/social_payloads_golden_test.dart (UPDATE_GOLDEN=1). Do not edit by hand.',
  'serverTimestamp': kServerTimestampJson,
  'clientTimePlusPrefix': kClientTimePlusPrefix,
  'deleteField': kDeleteFieldJson,
  'scenarios': _scenarios(),
  'queries': _queries(),
  'requestQueries': _requestQueries(),
  'lookups': _lookups(),
};

void main() {
  test('Dart payloads equal the fixture the rules suite replays', () {
    final golden = jsonDecode(jsonEncode(_golden()));
    final file = File(_fixturePath);
    if (Platform.environment['UPDATE_GOLDEN'] == '1') {
      file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(golden)}\n');
    }
    expect(file.existsSync(), isTrue, reason: 'run with UPDATE_GOLDEN=1 to create $_fixturePath');
    expect(
      golden,
      equals(jsonDecode(file.readAsStringSync())),
      reason: 'payloads changed: regenerate the fixture AND run npm test (docs/55)',
    );
  });

  test('server timestamps are marked, never real values', () {
    final text = jsonEncode(_scenarios());
    expect(text, contains(kServerTimestampJson));
    expect(const ServerTimestamp().toString(), kServerTimestampJson);
  });
}
