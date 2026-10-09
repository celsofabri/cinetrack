import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/account/account_deleter.dart';
import 'package:cinetrack/account/account_deletion_failure.dart';
import 'package:cinetrack/data/profile_data_source.dart';
import 'package:cinetrack/repositories/social_repository.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/fake_auth_repository.dart';
import 'support/fake_social_cloud.dart';
import 'support/in_memory_favorites_data_source.dart';

const _photo = 'https://lh3.googleusercontent.com/a/ana';

class _Rig {
  DateTime clock = DateTime.utc(2026, 10, 5);
  late final cloud = FakeSocialCloud(now: () => clock);
  late final ds = InMemorySocialDataSource(cloud, uid: 'uid-ana');
  late final repo = SocialRepository(ds, now: () => clock, pageSize: 2);
}

Future<SocialFailure?> _fail(Future<void> f) async {
  try {
    await f;
    return null;
  } on SocialFailure catch (e) {
    return e;
  }
}

void main() {
  group('load', () {
    test('not activated: no profile, and nothing was written', () async {
      final r = _Rig();
      final load = await r.repo.load();
      expect(load.profile, isNull);
      expect(r.cloud.log, isEmpty);
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
    });

    test('rules not published: denied (section says unavailable)', () async {
      final r = _Rig()..cloud.rulesLive = false;
      expect((await _fail(r.repo.load()))!.kind, SocialFailureKind.denied);
    });

    test('offline falls back to the device copy', () async {
      final r = _Rig()..cloud.seedActive('uid-ana', 'ana');
      r.cloud.offline = true;
      // fromServer reads throw offline; the fake serves the device copy
      final load = await r.repo.load();
      expect(load.fromCache, isTrue);
      expect(load.profile!.handle, 'ana');
    });
  });

  group('activate', () {
    test('writes card + pointer with a sanitized photo', () async {
      final r = _Rig();
      await r.repo.activate(
        rawHandle: '@Ana_9',
        rawNickname: '  Ana ',
        googlePhotoUrl: _photo,
        showPhoto: true,
        discoverable: true,
      );
      expect(r.cloud.handles['ana_9']!['nickname'], 'Ana');
      expect(r.cloud.handles['ana_9']!['photoURL'], _photo);
      expect(r.cloud.social['uid-ana']!['handle'], 'ana_9');
    });

    test('a photo the rules would refuse is sent as null (whole write would fail)', () async {
      final r = _Rig();
      await r.repo.activate(
        rawHandle: 'ana',
        rawNickname: 'Ana',
        googlePhotoUrl: 'https://evil.example/x.png',
        showPhoto: true,
        discoverable: false,
      );
      expect(r.cloud.handles['ana']!['photoURL'], isNull);
      expect(r.cloud.handles['ana']!['discoverable'], false);
    });

    test('invalid input never reaches the server', () async {
      final r = _Rig();
      for (final h in ['admin', 'ab', '_x_']) {
        final f = await _fail(
          r.repo.activate(rawHandle: h, rawNickname: 'Ana', showPhoto: false, discoverable: true),
        );
        expect(f!.kind, SocialFailureKind.invalid, reason: h);
      }
      final f = await _fail(
        r.repo.activate(rawHandle: 'ana', rawNickname: '  ', showPhoto: false, discoverable: true),
      );
      expect(f!.kind, SocialFailureKind.invalid);
      expect(r.cloud.log, isEmpty);
    });

    test('taken handle: nothing is created; second activation refused', () async {
      final r = _Rig()..cloud.seedActive('uid-bruno', 'maria');
      final f = await _fail(
        r.repo.activate(
          rawHandle: 'maria',
          rawNickname: 'Ana',
          showPhoto: false,
          discoverable: true,
        ),
      );
      expect(f!.kind, SocialFailureKind.handleTaken);
      expect(r.cloud.social.containsKey('uid-ana'), isFalse);
      expect(r.cloud.handles['maria']!['uid'], 'uid-bruno', reason: 'the owner keeps it');

      await r.repo.activate(
        rawHandle: 'livre_1',
        rawNickname: 'Ana',
        showPhoto: false,
        discoverable: true,
      );
      final again = await _fail(
        r.repo.activate(
          rawHandle: 'outro_1',
          rawNickname: 'Ana',
          showPhoto: false,
          discoverable: true,
        ),
      );
      expect(again!.kind, SocialFailureKind.alreadyActive);
    });

    test('rules not published: visible failure, nothing lost', () async {
      final r = _Rig()..cloud.rulesLive = false;
      final f = await _fail(
        r.repo.activate(rawHandle: 'ana', rawNickname: 'Ana', showPhoto: false, discoverable: true),
      );
      expect(f!.kind, SocialFailureKind.denied);
      expect(f.message, 'Amizades ainda não estão disponíveis. Tente mais tarde.');
    });
  });

  group('change handle / card', () {
    test('30-day interval: blocked at 29 days, allowed at 30, old handle freed', () async {
      final r = _Rig();
      await r.repo.activate(
        rawHandle: 'ana',
        rawNickname: 'Ana',
        showPhoto: false,
        discoverable: true,
      );
      var current = (await r.repo.load()).profile!;

      r.clock = r.clock.add(const Duration(days: 29));
      var f = await _fail(r.repo.changeHandle('ana2', current: current));
      expect(f!.kind, SocialFailureKind.tooSoon);
      expect(f.retryAt, DateTime.utc(2026, 11, 4));
      expect(r.cloud.handles.keys, ['ana']);

      r.clock = r.clock.add(const Duration(days: 1));
      await r.repo.changeHandle('ana2', current: current);
      expect(r.cloud.handles.keys, ['ana2']);
      expect(r.cloud.social['uid-ana']!['handle'], 'ana2');
      expect(r.cloud.handles.containsKey('ana'), isFalse, reason: 'the old handle is free again');

      current = (await r.repo.load()).profile!;
      f = await _fail(r.repo.changeHandle('ana3', current: current));
      expect(f!.kind, SocialFailureKind.tooSoon);
    });

    test('same handle, invalid handle and taken handle', () async {
      final r = _Rig()
        ..cloud.seedActive('uid-ana', 'ana')
        ..cloud.seedActive('uid-b', 'bia');
      final current = (await r.repo.load()).profile!;
      expect(
        (await _fail(r.repo.changeHandle('@ANA', current: current)))!.kind,
        SocialFailureKind.invalid,
      );
      expect(
        (await _fail(r.repo.changeHandle('root', current: current)))!.kind,
        SocialFailureKind.invalid,
      );
      expect(
        (await _fail(r.repo.changeHandle('bia', current: current)))!.kind,
        SocialFailureKind.handleTaken,
      );
    });

    test('nickname, discoverable and photo updates', () async {
      final r = _Rig()..cloud.seedActive('uid-ana', 'ana', nickname: 'Velho');
      await r.repo.updateNickname(' Novo ');
      await r.repo.setDiscoverable(false);
      await r.repo.setPhotoVisible(true, googlePhotoUrl: _photo);
      var card = r.cloud.handles['ana']!;
      expect(card['nickname'], 'Novo');
      expect(card['discoverable'], false);
      expect(card['photoURL'], _photo);
      await r.repo.setPhotoVisible(false);
      expect(r.cloud.handles['ana']!['photoURL'], isNull);
      expect(
        (await _fail(r.repo.setPhotoVisible(true, googlePhotoUrl: 'https://x.test/a')))!.kind,
        SocialFailureKind.invalid,
      );
      expect((await _fail(r.repo.updateNickname('')))!.kind, SocialFailureKind.invalid);
    });
  });

  group('deactivate', () {
    _Rig seeded() {
      final r = _Rig();
      r.cloud
        ..seedActive('uid-ana', 'ana', inviteCode: 'inv')
        ..seedActive('uid-bruno', 'bruno')
        ..seedActive('uid-caio', 'caio')
        ..seedFriendship('uid-ana', 'uid-bruno')
        ..seedFriendship('uid-ana', 'uid-caio')
        ..seedFriendship('uid-bruno', 'uid-caio')
        ..seedRequest('uid-ana', 'uid-dani')
        ..seedRequest('uid-eva', 'uid-ana')
        ..seedRequest('uid-eva', 'uid-bruno')
        ..seedBlock('uid-ana', 'uid-fabi');
      return r;
    }

    test('removes only this user\'s social data, in pages', () async {
      final r = seeded();
      await r.repo.deactivate();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      expect(r.cloud.invites, isEmpty);
      // others untouched
      expect(r.cloud.social.keys, containsAll(['uid-bruno', 'uid-caio']));
      expect(r.cloud.friendships.keys, ['uid-bruno_uid-caio']);
      expect(r.cloud.requests.keys, ['uid-eva_uid-bruno']);
      expect(r.cloud.deletePageSizes.every((n) => n <= 2), isTrue);
      expect(r.cloud.log.last, 'closeSocial');
    });

    test(
      'a pair/request created between the first sweep and the close is swept after it',
      () async {
        final r = seeded();
        r.cloud.beforeClose = () {
          // another device / user writes AFTER the first sweep, BEFORE the pointer goes
          r.cloud
            ..seedFriendship('uid-ana', 'uid-late')
            ..seedRequest('uid-late2', 'uid-ana')
            ..seedBlock('uid-ana', 'uid-late3');
          r.cloud.beforeClose = null;
        };
        await r.repo.deactivate();
        expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      },
    );

    test(
      'final sweep failing: cleanup-pending, friendships already off, finishCleanup completes',
      () async {
        final r = seeded();
        // make the delete right after the close fail
        r.cloud.beforeClose = () {
          r.cloud.seedFriendship('uid-ana', 'uid-late');
          r.cloud.failOnDeleteCall = r.cloud.deleteCalls + 1;
          r.cloud.beforeClose = null;
        };
        final f = await _fail(r.repo.deactivate());
        expect(f!.code, SocialRepository.cleanupPendingCode);
        expect(r.cloud.social.containsKey('uid-ana'), isFalse);
        expect(r.cloud.friendships.keys, contains('uid-ana_uid-late'));
        await r.repo.finishCleanup();
        expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      },
    );

    test('failure in the middle keeps friendships on; retry finishes (idempotent)', () async {
      final r = seeded();
      r.cloud.failOnDeleteCall = 2;
      final f = await _fail(r.repo.deactivate());
      expect(f, isNotNull);
      expect(r.cloud.social.containsKey('uid-ana'), isTrue);
      await r.repo.deactivate();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      await r.repo.deactivate(); // again: no-op
    });
  });

  group('account deletion (wipeForAccountDeletion + AccountDeleter)', () {
    test('door first, then sweeps; user disappears from friends\' lists', () async {
      final r = _Rig();
      r.cloud
        ..seedActive('uid-ana', 'ana')
        ..seedActive('uid-bruno', 'bruno')
        ..seedFriendship('uid-ana', 'uid-bruno')
        ..seedRequest('uid-ana', 'uid-x')
        ..seedRequest('uid-y', 'uid-ana')
        ..seedBlock('uid-ana', 'uid-z')
        // someone else's block against Ana stays (not hers to delete)
        ..seedBlock('uid-z', 'uid-ana');
      await r.repo.wipeForAccountDeletion();
      expect(r.cloud.log.first, 'closeSocial');
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      expect(r.cloud.blocks['uid-z']!.keys, ['uid-ana']);
      expect(
        InMemorySocialDataSource(
          r.cloud,
          uid: 'uid-bruno',
        ).readSweepPage(SweepKind.friendships, limit: 10),
        completion(isEmpty),
      );
    });

    test('account without friendships: only reads (no writes), same as before', () async {
      final r = _Rig();
      await r.repo.wipeForAccountDeletion();
      expect(r.cloud.log, isEmpty);
    });

    test('rules not published: nothing to delete, deletion proceeds', () async {
      final r = _Rig()..cloud.rulesLive = false;
      await r.repo.wipeForAccountDeletion();
    });

    test('a denied CLOSE (not the own-pointer read) fails the deletion: no silent skip (docs/71 G5)', () async {
      final r = _Rig();
      r.cloud
        ..seedActive('uid-ana', 'ana')
        ..seedFriendship('uid-ana', 'uid-b')
        ..failures['closeSocial'] = const SocialFailure(
          SocialFailureKind.denied,
          code: 'permission-denied',
        );
      await expectLater(r.repo.wipeForAccountDeletion(), throwsA(isA<AccountDeletionFailure>()));
      // Nothing was skipped silently: a rerun closes and sweeps everything.
      await r.repo.wipeForAccountDeletion();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
    });

    test('failure maps to AccountDeletionFailure and a rerun resumes', () async {
      final r = _Rig();
      r.cloud
        ..seedActive('uid-ana', 'ana')
        ..seedFriendship('uid-ana', 'uid-a')
        ..seedFriendship('uid-ana', 'uid-b')
        ..seedFriendship('uid-ana', 'uid-c');
      r.cloud.failOnDeleteCall = 2;
      await expectLater(
        r.repo.wipeForAccountDeletion(),
        throwsA(
          isA<AccountDeletionFailure>().having(
            (e) => e.kind,
            'kind',
            AccountDeletionFailureKind.offline,
          ),
        ),
      );
      expect(r.cloud.social.containsKey('uid-ana'), isFalse); // door already closed
      expect(r.cloud.friendships, isNotEmpty);
      await r.repo.wipeForAccountDeletion();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
    });

    test('AccountDeleter runs the social step between marker and favorites', () async {
      final cloud = FakeCloud();
      final social = FakeSocialCloud(log: cloud.deletionLog);
      social
        ..seedActive('uid-ana', 'ana')
        ..seedFriendship('uid-ana', 'uid-bruno');
      cloud.profiles['uid-ana'] = const UserProfile(nickname: 'Ana');
      final auth = FakeAuthRepository(initialUser: kAna);
      final deleter = AccountDeleter(
        uid: 'uid-ana',
        auth: auth,
        profile: InMemoryProfileDataSource(cloud, uid: 'uid-ana'),
        social: SocialRepository(InMemorySocialDataSource(social, uid: 'uid-ana')),
      );
      await deleter.run();
      expect(cloud.deletionLog.take(3), ['ensureOnline', 'markDeleting', 'closeSocial']);
      expect(
        cloud.deletionLog.indexOf('delete:friendships:1'),
        lessThan(cloud.deletionLog.indexOf('deleteAllFavorites')),
      );
      expect(social.leftoversOf('uid-ana'), isEmpty);
      expect(auth.deleteUserCalls, 1);
    });

    test('AccountDeleter: social failure stops before favorites; retry completes', () async {
      final cloud = FakeCloud();
      final social = FakeSocialCloud()
        ..seedActive('uid-ana', 'ana')
        ..seedFriendship('uid-ana', 'uid-bruno');
      social.failures['deleteRefs:friendships'] = const SocialFailure(SocialFailureKind.offline);
      cloud.profiles['uid-ana'] = const UserProfile(nickname: 'Ana');
      final auth = FakeAuthRepository(initialUser: kAna);
      final deleter = AccountDeleter(
        uid: 'uid-ana',
        auth: auth,
        profile: InMemoryProfileDataSource(cloud, uid: 'uid-ana'),
        social: SocialRepository(InMemorySocialDataSource(social, uid: 'uid-ana')),
      );
      await expectLater(deleter.run(), throwsA(isA<AccountDeletionFailure>()));
      expect(cloud.deletionLog, isNot(contains('deleteAllFavorites')));
      expect(cloud.profiles['uid-ana']!.deleting, isTrue);
      expect(auth.deleteUserCalls, 0);
      await deleter.run();
      expect(social.leftoversOf('uid-ana'), isEmpty);
      expect(auth.deleteUserCalls, 1);
    });
  });

  test('uid ordering contract: pairId matches Dart compareTo for real-looking uids', () {
    const uids = ['Zz9', 'aB1', 'a', 'A', '9x', 'abc', 'abd', 'M0'];
    for (final a in uids) {
      for (final b in uids) {
        if (a == b) continue;
        expect(FakeSocialCloud.pairId(a, b), FakeSocialCloud.pairId(b, a));
        final lo = a.compareTo(b) < 0 ? a : b;
        expect(FakeSocialCloud.pairId(a, b).startsWith('${lo}_'), isTrue);
      }
    }
  });
}
