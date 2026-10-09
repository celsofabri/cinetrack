import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException, Timestamp;
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/account/account_deletion_failure.dart';
import 'package:cinetrack/data/firestore_social_data_source.dart';
import 'package:cinetrack/data/social_data_source.dart';
import 'package:cinetrack/repositories/social_repository.dart';
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

  SendRequestDraft get draft =>
      SendRequestDraft(toUid: other, fromHandle: 'ana', fromName: 'Ana', toName: 'Bruno');

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

  // docs/72 L1 + docs/71 G7: the REAL handle branches of activate / changeHandle (the fake
  // in-memory source never runs them). The planner seam runs the class's own plan with reads
  // that may be denied exactly like the rules deny them.
  group('activate / changeHandle: what a denied read means (docs/72 L1)', () {
    test('activate: a card the rules hide (hidden owner / block) is "taken", never free', () async {
      final rig = _PlanRig()..denied.add('handles/maria');
      await expectLater(
        rig.source.activate(_draft('maria')),
        throwsA(_kind(SocialFailureKind.handleTaken)),
      );
      expect(rig.applied, isEmpty);
      expect(rig.reads, ['social/uid-ana', 'handles/maria'], reason: 'own pointer FIRST');
    });

    test('activate: a missing card is free: exactly the activate payload is applied', () async {
      final rig = _PlanRig();
      await rig.source.activate(_draft('livre_1'));
      expect(rig.applied.single.toJson(), SocialPayloads.activate('uid-ana', _draft('livre_1')).toJson());
    });

    test('activate: a visible card of someone else is taken', () async {
      final rig = _PlanRig()..docs['handles/maria'] = {'uid': 'uid-bruno'};
      await expectLater(
        rig.source.activate(_draft('maria')),
        throwsA(_kind(SocialFailureKind.handleTaken)),
      );
      expect(rig.applied, isEmpty);
    });

    test('activate with the OLD rules (own pointer denied): denied, not handleTaken', () async {
      // Old ruleset: everything social is permission-denied, the handle too.
      final rig = _PlanRig()..denied.addAll(['social/uid-ana', 'handles/ana']);
      final failure = await _failure(rig.source.activate(_draft('ana')));
      expect(failure.kind, SocialFailureKind.denied);
      expect(failure.message, 'Amizades ainda não estão disponíveis. Tente mais tarde.');
      expect(rig.applied, isEmpty);
    });

    test('activate: already active wins over a free handle', () async {
      final rig = _PlanRig()..docs['social/uid-ana'] = {'handle': 'ana'};
      await expectLater(
        rig.source.activate(_draft('outro_1')),
        throwsA(_kind(SocialFailureKind.alreadyActive)),
      );
    });

    test('changeHandle: a new handle hidden by the rules is taken; nothing is applied', () async {
      final rig = _PlanRig()..activeAs('ana')..denied.add('handles/escondido');
      await expectLater(
        rig.source.changeHandle('escondido'),
        throwsA(_kind(SocialFailureKind.handleTaken)),
      );
      expect(rig.applied, isEmpty);
    });

    test('changeHandle: a free handle moves the reservation (exact payload)', () async {
      final rig = _PlanRig()..activeAs('ana');
      await rig.source.changeHandle('ana_novo');
      expect(
        rig.applied.single.toJson(),
        SocialPayloads.changeHandle(
          'uid-ana',
          oldHandle: 'ana',
          newHandle: 'ana_novo',
          nickname: 'Ana',
          photoUrl: null,
          discoverable: true,
        ).toJson(),
      );
    });

    test('changeHandle with the OLD rules (own pointer denied): denied', () async {
      final rig = _PlanRig()..denied.addAll(['social/uid-ana', 'handles/ana_novo']);
      expect((await _failure(rig.source.changeHandle('ana_novo'))).kind, SocialFailureKind.denied);
    });
  });

  // docs/71 G5: account deletion must only skip the sweeps when the OWN POINTER read is denied
  // (rules not published); a denied close batch must fail the deletion.
  group('closeSocial / account deletion: which denial is "rules not published" (docs/71 G5)', () {
    test('own pointer read denied: denied with the read code; no write', () async {
      final rig = _PlanRig()..denied.add('social/uid-ana');
      final failure = await _failure(rig.source.closeSocial());
      expect(failure.kind, SocialFailureKind.denied);
      expect(failure.code, kSocialReadDeniedCode);
      expect(rig.batches, isEmpty);
    });

    test('close batch denied: a plain denied (NOT the read code)', () async {
      final rig = _PlanRig()
        ..activeAs('ana')
        ..denyBatches = true;
      final failure = await _failure(rig.source.closeSocial());
      expect(failure.kind, SocialFailureKind.denied);
      expect(failure.code, 'permission-denied');
    });

    test('closeSocial happy path: card + pointer in one batch, true', () async {
      final rig = _PlanRig()..activeAs('ana');
      expect(await rig.source.closeSocial(), isTrue);
      expect(rig.batches.single.toJson(), SocialPayloads.close('uid-ana', handle: 'ana').toJson());
    });

    test('wipeForAccountDeletion: read denied = nothing to delete; batch denied = FAILS', () async {
      final unpublished = _PlanRig()..denied.add('social/uid-ana');
      await SocialRepository(unpublished.source).wipeForAccountDeletion();

      final broken = _PlanRig()
        ..activeAs('ana')
        ..denyBatches = true;
      await expectLater(
        SocialRepository(broken.source).wipeForAccountDeletion(),
        throwsA(isA<AccountDeletionFailure>()),
      );
    });
  });
}

SocialDraft _draft(String handle) =>
    SocialDraft(handle: handle, nickname: 'Ana', discoverable: true);

Matcher _kind(SocialFailureKind kind) => isA<SocialFailure>().having((e) => e.kind, 'kind', kind);

Future<SocialFailure> _failure(Future<Object?> future) async {
  try {
    await future;
  } on SocialFailure catch (e) {
    return e;
  }
  fail('expected a SocialFailure');
}

/// The real data source with the planner (transactions), the server reader and the executor
/// (batches) replaced: reads of [denied] paths throw `permission-denied` like the rules do.
class _PlanRig {
  final Map<String, Map<String, dynamic>> docs = {};
  final Set<String> denied = {};
  final List<String> reads = [];
  final List<SocialWrite> applied = [];
  final List<SocialWrite> batches = [];
  bool denyBatches = false;

  Future<SocialSnapshot> _get(String path) async {
    reads.add(path);
    if (denied.contains(path)) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    }
    return (exists: docs.containsKey(path), data: docs[path]);
  }

  late final FirestoreSocialDataSource source = FirestoreSocialDataSource(
    uid: 'uid-ana',
    planner: (plan) async => applied.add(await plan(_get)),
    docReader: _get,
    executor: (write, {check}) async {
      if (denyBatches) throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
      batches.add(write);
    },
  );

  /// `social/uid-ana` -> [handle], with its card (changed 90 days ago).
  void activeAs(String handle) {
    final at = Timestamp.fromDate(DateTime.now().subtract(const Duration(days: 90)));
    docs['social/uid-ana'] = {'handle': handle, 'handleChangedAt': at, 'schemaVersion': 1};
    docs['handles/$handle'] = {
      'uid': 'uid-ana',
      'nickname': 'Ana',
      'photoURL': null,
      'discoverable': true,
      'createdAt': at,
      'updatedAt': at,
    };
  }
}

