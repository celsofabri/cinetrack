import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/firestore_social_data_source.dart';
import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/social/social_models.dart';

/// The REAL [FirestoreSocialDataSource] with its two seams (executor and
/// `count()` reader) replaced: no Firebase, but the logic of the class runs
/// (crossed request, 300 friends cap, block). Docs/64 🟢-1 / docs/65.
class _Rig {
  final String uid = 'uid-ana';
  final String other = 'uid-bruno';

  /// Documents "on the server": path -> data.
  final Map<String, Map<String, dynamic>> docs = {};

  /// Every payload that reached the executor, with whether it was applied.
  final List<({SocialWrite write, bool applied})> executed = [];

  /// Specs the count reader was asked.
  final List<SocialQuerySpec> counts = [];
  int friends = 0;

  late final FirestoreSocialDataSource source = FirestoreSocialDataSource(
    uid: uid,
    executor: _execute,
    countReader: (spec) async {
      counts.add(spec);
      return friends;
    },
  );

  Future<void> _execute(
    SocialWrite write, {
    void Function(Map<String, SocialSnapshot> reads)? check,
  }) async {
    if (write.mode == SocialWriteMode.transaction) {
      final reads = {
        for (final path in write.reads) path: (exists: docs.containsKey(path), data: docs[path]),
      };
      try {
        check?.call(reads);
      } catch (_) {
        executed.add((write: write, applied: false));
        rethrow;
      }
    }
    for (final op in write.ops) {
      switch (op.op) {
        case 'set' || 'update':
          docs[op.path] = {...?op.data};
        case 'delete':
          docs.remove(op.path);
      }
    }
    executed.add((write: write, applied: true));
  }

  SendRequestDraft get draft => SendRequestDraft(toUid: other, fromName: 'Ana', toName: 'Bruno');

  String get theirs => SocialPayloads.requestPath(other, uid);
  String get mine => SocialPayloads.requestPath(uid, other);

  void theyAsked() => docs[theirs] = {'from': other, 'to': uid, 'fromName': 'Bruno'};
}

void main() {
  group('sendRequest: crossed request on the real data source', () {
    test('300 friends: nothing is created, their request stays, friendsLimit', () async {
      final rig = _Rig()
        ..friends = kMaxFriends
        ..theyAsked();
      await expectLater(
        rig.source.sendRequest(rig.draft),
        throwsA(isA<SocialFailure>().having((e) => e.kind, 'kind', SocialFailureKind.friendsLimit)),
      );
      expect(rig.counts.map((s) => s.toJson()), [
        SocialPayloads.friendsCountQuery(rig.uid).toJson(),
      ]);
      expect(rig.docs.containsKey(rig.theirs), isTrue, reason: 'their request must survive');
      expect(rig.docs.keys.where((p) => p.startsWith('friendships/')), isEmpty);
      expect(rig.docs.containsKey(rig.mine), isFalse);
      // The only payload that ran was the read-only transaction (not applied).
      expect(rig.executed.where((e) => e.applied), isEmpty);
    });

    test('299 friends: becomes the 300th, ONE batch, both requests gone', () async {
      final rig = _Rig()
        ..friends = kMaxFriends - 1
        ..theyAsked();
      final outcome = await rig.source.sendRequest(rig.draft);
      expect(outcome, SendOutcome.becameFriends);
      final applied = rig.executed.where((e) => e.applied).toList();
      expect(applied, hasLength(1));
      expect(applied.single.write.mode, SocialWriteMode.batch);
      expect(
        applied.single.write.toJson(),
        SocialPayloads.acceptRequest(
          rig.uid,
          const AcceptDraft(fromUid: 'uid-bruno', fromName: 'Bruno', myName: 'Ana'),
        ).toJson(),
        reason: 'the crossed request runs the very payload of "Aceitar"',
      );
      expect(rig.docs.keys.where((p) => p.startsWith('friendships/')), hasLength(1));
      expect(rig.docs.containsKey(rig.theirs), isFalse);
      expect(rig.docs.containsKey(rig.mine), isFalse);
    });

    test('the count is read only on the crossed branch', () async {
      final rig = _Rig()..friends = kMaxFriends;
      final outcome = await rig.source.sendRequest(rig.draft);
      expect(outcome, SendOutcome.requested);
      expect(rig.counts, isEmpty, reason: 'a normal request pays no extra read');
      expect(rig.docs.containsKey(rig.mine), isTrue);
    });

    test('my own pending request: alreadySent, nothing written, no count', () async {
      final rig = _Rig()
        ..friends = 0
        ..docs[SocialPayloads.requestPath('uid-ana', 'uid-bruno')] = {'from': 'uid-ana'};
      await expectLater(
        rig.source.sendRequest(rig.draft),
        throwsA(isA<SocialFailure>().having((e) => e.kind, 'kind', SocialFailureKind.alreadySent)),
      );
      expect(rig.counts, isEmpty);
      expect(rig.executed.where((e) => e.applied), isEmpty);
    });

    test('their request without a name cannot be accepted: denied, nothing written', () async {
      final rig = _Rig()..friends = 0;
      rig.docs[rig.theirs] = {'from': rig.other};
      await expectLater(
        rig.source.sendRequest(rig.draft),
        throwsA(isA<SocialFailure>().having((e) => e.kind, 'kind', SocialFailureKind.denied)),
      );
      expect(rig.docs.keys.where((p) => p.startsWith('friendships/')), isEmpty);
    });
  });

  group('block / unblock on the real data source', () {
    test('blockUser: ONE batch with exactly the payload, no read, nothing else', () async {
      final rig = _Rig();
      rig.docs[SocialPayloads.friendshipPath(rig.uid, rig.other)] = {'members': []};
      rig.docs[rig.theirs] = {};
      rig.docs[rig.mine] = {};
      await rig.source.blockUser(
        const BlockDraft(blockedUid: 'uid-bruno', name: 'Bruno', photo: null),
      );
      expect(rig.executed, hasLength(1));
      final write = rig.executed.single.write;
      expect(write.mode, SocialWriteMode.batch);
      expect(write.reads, isEmpty);
      expect(rig.counts, isEmpty);
      expect(
        write.toJson(),
        SocialPayloads.blockUser(
          rig.uid,
          const BlockDraft(blockedUid: 'uid-bruno', name: 'Bruno'),
        ).toJson(),
      );
      expect(rig.docs.keys, ['users/uid-ana/blocks/uid-bruno']);
    });

    test('unblockUser deletes only the block', () async {
      final rig = _Rig();
      rig.docs['users/uid-ana/blocks/uid-bruno'] = {'createdAt': 1};
      rig.docs[SocialPayloads.friendshipPath(rig.uid, rig.other)] = {'members': []};
      await rig.source.unblockUser('uid-bruno');
      expect(rig.docs.keys, [SocialPayloads.friendshipPath(rig.uid, rig.other)]);
      expect(
        rig.executed.single.write.toJson(),
        SocialPayloads.unblockUser('uid-ana', 'uid-bruno').toJson(),
      );
    });
  });
  group('refresh of friendship halves on the real data source (docs/68)', () {
    test('updateFriendHalves is ONE batch with exactly the payload, my half only', () async {
      final rig = _Rig();
      rig.docs['friendships/uid-ana_uid-bruno'] = {'aName': 'Velha', 'bName': 'Bruno'};
      const updates = [FriendHalfUpdate(pairKey: 'uid-ana_uid-bruno', meIsA: true, name: 'Ana')];
      await rig.source.updateFriendHalves(updates);
      expect(rig.executed, hasLength(1));
      final write = rig.executed.single.write;
      expect(write.mode, SocialWriteMode.batch);
      expect(write.reads, isEmpty);
      expect(write.toJson(), SocialPayloads.refreshHalves(updates).toJson());
      expect(rig.docs['friendships/uid-ana_uid-bruno'], {'aName': 'Ana', 'aPhoto': null});
    });

    test('nothing to update: no write at all', () async {
      final rig = _Rig();
      await rig.source.updateFriendHalves(const []);
      expect(rig.executed, isEmpty);
    });
  });
}
