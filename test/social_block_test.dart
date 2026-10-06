import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/export/data_exporter.dart';
import 'package:cinetrack/export/export_serializer.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/social_lists_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:cinetrack/repositories/social_repository.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_export_data_source.dart';
import 'support/fake_social_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Slice 4 (docs/65): block, unblock, the blocked list, and what a block does
/// to everything else, over the in-memory fakes. The fake mirrors the data
/// rules of `firestore.rules`; the real rules are exercised by
/// `dart_payloads.test.mjs` with the very same payloads.

const _photo = 'https://lh3.googleusercontent.com/a/ana';
const _brunoPhoto = 'https://lh4.googleusercontent.com/b';
const _me = SocialProfile(handle: 'ana', nickname: 'Ana', photoUrl: _photo, discoverable: true);

class _Rig {
  DateTime clock = DateTime.utc(2026, 10, 5, 12);
  late final cloud = FakeSocialCloud(now: () => clock);
  late final ds = InMemorySocialDataSource(cloud, uid: 'uid-ana');
  late final repo = SocialRepository(ds, now: () => clock, pageSize: 2);

  _Rig() {
    cloud
      ..seedActive('uid-ana', 'ana', nickname: 'Ana', photoUrl: _photo)
      ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno', photoUrl: _brunoPhoto);
  }

  SocialRepository repoFor(String uid) =>
      SocialRepository(InMemorySocialDataSource(cloud, uid: uid), now: () => clock);

  void brunoAsks() => cloud.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno');
  void anaAsks() => cloud.seedRequest('uid-ana', 'uid-bruno', fromName: 'Ana', toName: 'Bruno');
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
  group('block (ONE batch: block + friendship and both requests deleted)', () {
    final states = <String, void Function(_Rig)>{
      'nothing': (r) {},
      'only a friendship': (r) => r.cloud.seedFriendship('uid-ana', 'uid-bruno'),
      'only a received request': (r) => r.brunoAsks(),
      'only a sent request': (r) => r.anaAsks(),
      'both requests': (r) {
        r.brunoAsks();
        r.anaAsks();
      },
      'friendship and both requests': (r) {
        r.cloud.seedFriendship('uid-ana', 'uid-bruno');
        r.brunoAsks();
        r.anaAsks();
      },
    };

    for (final entry in states.entries) {
      test('from "${entry.key}": the block exists, nothing else between them', () async {
        final r = _Rig();
        entry.value(r);
        r.cloud.seedFriendship('uid-ana', 'uid-caio'); // unrelated, must survive
        r.cloud.seedRequest('uid-caio', 'uid-ana');
        await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno', photo: _brunoPhoto);
        expect(r.cloud.blocks['uid-ana']!.keys, ['uid-bruno']);
        expect(r.cloud.blocks['uid-ana']!['uid-bruno'], {
          'blockedName': 'Bruno',
          'blockedPhoto': _brunoPhoto,
          'createdAt': r.clock,
        });
        expect(r.cloud.friendships.keys, ['uid-ana_uid-caio']);
        expect(r.cloud.requests.keys, ['uid-caio_uid-ana']);
        expect(r.cloud.log.where((e) => e == 'blockUser'), hasLength(1));
      });
    }

    test('it costs no read at all (the deletes need no "does it exist?")', () async {
      final r = _Rig();
      r.cloud.seedFriendship('uid-ana', 'uid-bruno');
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      expect(r.cloud.readLog, isEmpty);
    });

    test('name and photo are only snapshots: invalid ones are left out, not sent', () async {
      final r = _Rig();
      await r.repo.blockUser(uid: 'uid-bruno', name: 'x' * 41, photo: 'https://evil.example/x.png');
      expect(r.cloud.blocks['uid-ana']!['uid-bruno'], {'createdAt': r.clock});
      final page = await r.repo.blockedUsers();
      expect(page.items.single.name, 'Usuário');
      expect(page.items.single.photoUrl, isNull);
    });

    test('blocking myself or an empty uid never reaches the server', () async {
      final r = _Rig();
      expect(
        (await _fail(r.repo.blockUser(uid: 'uid-ana', name: 'Ana')))!.kind,
        SocialFailureKind.notBlocked,
      );
      expect(
        (await _fail(r.repo.blockUser(uid: '', name: 'X')))!.kind,
        SocialFailureKind.notBlocked,
      );
      expect(r.cloud.log, isEmpty);
    });

    test('blocking twice: the second is refused (an update), the first stays', () async {
      final r = _Rig();
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      final first = {...r.cloud.blocks['uid-ana']!['uid-bruno']!};
      r.clock = r.clock.add(const Duration(hours: 1));
      final failure = await _fail(r.repo.blockUser(uid: 'uid-bruno', name: 'Outro'));
      expect(failure!.kind, SocialFailureKind.notBlocked);
      expect(r.cloud.blocks['uid-ana']!['uid-bruno'], first);
    });

    test(
      'someone who never turned friendships on can still be blocked (the block is mine)',
      () async {
        final r = _Rig();
        await r.repo.blockUser(uid: 'uid-sem-social', name: 'Fulano');
        expect(r.cloud.blocks['uid-ana']!.keys, ['uid-sem-social']);
      },
    );

    test('offline: nothing happens and the failure says so; uncertain is passed on', () async {
      final r = _Rig();
      r.cloud.seedFriendship('uid-ana', 'uid-bruno');
      r.cloud.offline = true;
      expect(
        (await _fail(r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno')))!.kind,
        SocialFailureKind.offline,
      );
      r.cloud.offline = false;
      expect(r.cloud.friendships, isNotEmpty);
      expect(r.cloud.blocks, isEmpty);
      r.cloud.failures['blockUser'] = const SocialFailure(SocialFailureKind.uncertain);
      expect(
        (await _fail(r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno')))!.kind,
        SocialFailureKind.uncertain,
      );
    });

    test('rules not published: a visible, generic failure and nothing is lost', () async {
      final r = _Rig();
      r.cloud.seedFriendship('uid-ana', 'uid-bruno');
      r.cloud.rulesLive = false;
      final failure = await _fail(r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno'));
      expect(failure!.kind, SocialFailureKind.notBlocked);
      r.cloud.rulesLive = true;
      expect(r.cloud.friendships, isNotEmpty);
    });
  });

  group('what the blocked person (and the blocker) can do afterwards', () {
    test('the blocked person does not find the blocker: same answer as "not found"', () async {
      final r = _Rig();
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      final bruno = r.repoFor('uid-bruno');
      expect(await bruno.search('ana'), isA<SearchNotFound>());
      // a hidden card and a handle that does not exist answer the very same way
      r.cloud.seedActive('uid-caio', 'caio', discoverable: false);
      expect(await bruno.search('caio'), isA<SearchNotFound>());
      expect(await bruno.search('ninguem'), isA<SearchNotFound>());
    });

    test('the blocker does not find the blocked person either; unblocking reopens both', () async {
      final r = _Rig();
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      expect(await r.repo.search('bruno'), isA<SearchNotFound>());
      await r.repo.unblockUser('uid-bruno');
      expect(await r.repo.search('bruno'), isA<SearchFound>());
      expect(await r.repoFor('uid-bruno').search('ana'), isA<SearchFound>());
    });

    test('the blocked person cannot send a request: one generic failure', () async {
      final r = _Rig();
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      const target = FriendCard(uid: 'uid-ana', handle: 'ana', nickname: 'Ana');
      const brunoMe = SocialProfile(handle: 'bruno', nickname: 'Bruno');
      final failure = await _fail(
        r.repoFor('uid-bruno').sendRequest(target, me: brunoMe).then((_) {}),
      );
      expect(failure!.kind, SocialFailureKind.notSent);
      expect(r.cloud.requests, isEmpty);
      // the blocker cannot ask the blocked person either
      const toBruno = FriendCard(uid: 'uid-bruno', handle: 'bruno', nickname: 'Bruno');
      final mine = await _fail(r.repo.sendRequest(toBruno, me: _me).then((_) {}));
      expect(mine!.kind, SocialFailureKind.notSent);
    });

    test('accepting the (deleted) request of somebody I blocked fails generically', () async {
      final r = _Rig();
      r.brunoAsks();
      final stale = (await r.repo.receivedRequests()).items.single;
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      expect((await r.repo.receivedRequests()).items, isEmpty);
      final failure = await _fail(r.repo.acceptRequest(stale, me: _me));
      expect(failure!.kind, SocialFailureKind.notAccepted);
      expect(r.cloud.friendships, isEmpty);
    });

    test('unblock deletes only the block: friendship and requests do NOT come back', () async {
      final r = _Rig();
      r.cloud.seedFriendship('uid-ana', 'uid-bruno');
      r.brunoAsks();
      r.anaAsks();
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      await r.repo.unblockUser('uid-bruno');
      expect(r.cloud.blocks['uid-ana'], isEmpty);
      expect(r.cloud.friendships, isEmpty);
      expect(r.cloud.requests, isEmpty);
      expect((await r.repo.friends()).items, isEmpty);
      // a new request is possible again
      const toBruno = FriendCard(uid: 'uid-bruno', handle: 'bruno', nickname: 'Bruno');
      expect(await r.repo.sendRequest(toBruno, me: _me), SendOutcome.requested);
    });

    test('unblocking somebody who is not blocked, twice, is harmless', () async {
      final r = _Rig();
      await r.repo.unblockUser('uid-bruno');
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      await r.repo.unblockUser('uid-bruno');
      await r.repo.unblockUser('uid-bruno');
      expect(r.cloud.blocks['uid-ana'], isEmpty);
    });

    test('the blocked person sees nothing of the block: only the pair / request vanish', () async {
      final r = _Rig();
      r.cloud.seedFriendship('uid-ana', 'uid-bruno');
      r.cloud.seedRequest('uid-ana', 'uid-bruno');
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      final bruno = r.repoFor('uid-bruno');
      expect((await bruno.friends()).items, isEmpty);
      expect((await bruno.receivedRequests()).items, isEmpty);
      expect((await bruno.blockedUsers()).items, isEmpty, reason: 'his list is HIS blocks');
      // no document of Ana's names Bruno's account except her own block namespace
      expect(r.cloud.leftoversOf('uid-bruno'), isNot(contains(startsWith('users/uid-ana'))));
    });
  });

  group('blocked list: newest first, paged, device copy', () {
    test('pages of 2, newest block first, with the snapshot name; no listener involved', () async {
      final r = _Rig();
      final base = DateTime.utc(2026, 9, 1);
      for (var i = 0; i < 5; i++) {
        r.cloud.seedBlock(
          'uid-ana',
          'uid-b$i',
          name: 'Pessoa $i',
          at: base.add(Duration(days: i)),
        );
      }
      final first = await r.repo.blockedUsers(pageSize: 2);
      expect(first.items.map((u) => u.name), ['Pessoa 4', 'Pessoa 3']);
      expect(first.hasMore, isTrue);
      final second = await r.repo.blockedUsers(cursor: first.cursor, pageSize: 2);
      expect(second.items.map((u) => u.name), ['Pessoa 2', 'Pessoa 1']);
      final third = await r.repo.blockedUsers(cursor: second.cursor, pageSize: 2);
      expect(third.items.map((u) => u.name), ['Pessoa 0']);
      expect(third.hasMore, isFalse);
      expect(r.cloud.readLog.where((e) => e == 'blocked:page'), hasLength(3));
    });

    test(
      'names are cleaned; a block without a name shows "Usuário"; offline serves the device',
      () async {
        final r = _Rig();
        r.cloud.seedBlock('uid-ana', 'uid-x', name: '​Zé​');
        r.cloud.seedBlock(
          'uid-ana',
          'uid-y',
          name: null,
          at: r.clock.subtract(const Duration(days: 1)),
        );
        r.cloud.offline = true;
        final page = await r.repo.blockedUsers();
        expect(page.fromCache, isTrue);
        expect(page.items.map((u) => u.name), ['Zé', 'Usuário']);
        r.cloud.cacheAvailable = false;
        expect((await _fail(r.repo.blockedUsers()))!.kind, SocialFailureKind.offline);
      },
    );

    test('only MY blocks are listed', () async {
      final r = _Rig();
      r.cloud.seedBlock('uid-ana', 'uid-x', name: 'X');
      r.cloud.seedBlock('uid-bruno', 'uid-y', name: 'Y');
      expect((await r.repo.blockedUsers()).items.map((u) => u.uid), ['uid-x']);
    });
  });

  group('deactivate, account deletion and export with blocks made by the app', () {
    test('deactivate removes the blocks (and everything else) created through the app', () async {
      final r = _Rig();
      r.cloud.seedFriendship('uid-ana', 'uid-bruno');
      await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
      await r.repo.blockUser(uid: 'uid-caio', name: 'Caio');
      await r.repo.deactivate();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      expect(r.cloud.blocks['uid-ana'], isEmpty);
    });

    test(
      'account deletion sweeps the blocks; a block somebody made against me stays theirs',
      () async {
        final r = _Rig();
        await r.repo.blockUser(uid: 'uid-bruno', name: 'Bruno');
        await r.repoFor('uid-bruno').blockUser(uid: 'uid-ana', name: 'Ana');
        await r.repo.wipeForAccountDeletion();
        expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
        expect(r.cloud.blocks['uid-bruno']!.keys, [
          'uid-ana',
        ], reason: 'his data, readable only by him');
      },
    );

    test('AccountController.deleteAccount sweeps real blocks', () async {
      final social = FakeSocialCloud()
        ..seedActive('uid-ana', 'ana', nickname: 'Ana')
        ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno');
      final c = ProviderContainer(
        overrides: cloudOverrides(
          auth: FakeAuthRepository(initialUser: kAna),
          cloud: FakeCloud(),
          socialCloud: social,
        ),
      );
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      c.listen(syncStatusProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      await InMemorySocialDataSourceFactory(social).blockAs('uid-ana', 'uid-bruno');
      expect(social.blocks['uid-ana'], isNotEmpty);
      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
      expect(social.leftoversOf('uid-ana'), isEmpty);
    });

    test(
      'export lists the blocks the app wrote: uid + nickname, no photo, schema unchanged',
      () async {
        final op = SocialPayloads.blockUser(
          'uid-ana',
          const BlockDraft(blockedUid: 'uid-bruno', name: 'Bruno', photo: _brunoPhoto),
        ).ops.first;
        final stored = <String, dynamic>{
          for (final e in op.data!.entries)
            e.key: e.value is ServerTimestamp ? DateTime.utc(2026, 10, 5) : e.value,
        };
        final source = FakeExportDataSource({})
          ..social = const RawSocial(social: {'handle': 'ana'});
        source.socialLists[SocialExportKind.blocks] = {'uid-bruno': stored};
        final file = await runExport(
          source: source,
          from: ExportSource.server,
          now: () => DateTime.utc(2026, 10, 5),
          isCurrent: () => true,
          uid: 'uid-ana',
        );
        final social =
            (jsonDecode(file.json) as Map<String, dynamic>)['social'] as Map<String, dynamic>;
        final block = (social['blocks'] as List).single as Map<String, dynamic>;
        expect(block['uid'], 'uid-bruno');
        expect(block['nickname'], 'Bruno');
        expect(block['createdAt'], '2026-10-05T00:00:00.000Z');
        expect(jsonEncode(social['blocks']), isNot(contains('googleusercontent')));
        expect(social['counts']['blocks'], 1);
        expect(kExportSchemaVersion, 2, reason: 'the blocks list already existed: same schema');
      },
    );

    test('an older block document (name only, or empty) is still readable by the export', () async {
      final source = FakeExportDataSource({})..social = const RawSocial(social: {'handle': 'ana'});
      source.socialLists[SocialExportKind.blocks] = {
        'uid-old': {'createdAt': DateTime.utc(2026, 9, 1)},
        'uid-old2': {'blockedName': 'Antigo', 'createdAt': DateTime.utc(2026, 9, 2)},
      };
      final file = await runExport(
        source: source,
        from: ExportSource.server,
        now: () => DateTime.utc(2026, 10, 5),
        isCurrent: () => true,
        uid: 'uid-ana',
      );
      final social =
          (jsonDecode(file.json) as Map<String, dynamic>)['social'] as Map<String, dynamic>;
      final blocks = (social['blocks'] as List).cast<Map<String, dynamic>>();
      expect(blocks.map((b) => b['uid']), ['uid-old', 'uid-old2']);
      expect(blocks.map((b) => b['nickname']), [null, 'Antigo']);
    });
  });

  group('controllers: lists rebuilt on the right events, no leak between accounts', () {
    late FakeSocialCloud social;
    late FakeAuthRepository auth;
    var now = DateTime.utc(2026, 10, 5, 12);

    ProviderContainer make({void Function(FakeSocialCloud s)? seed}) {
      social = FakeSocialCloud();
      social
        ..seedActive('uid-ana', 'ana', nickname: 'Ana')
        ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno')
        ..seedActive('uid-caio', 'caio', nickname: 'Caio');
      seed?.call(social);
      auth = FakeAuthRepository(initialUser: kAna);
      final c = ProviderContainer(
        overrides: [
          ...cloudOverrides(
            auth: auth,
            cloud: FakeCloud(),
            socialCloud: social,
            store: FakeLocalStore(),
          ),
          socialClockProvider.overrideWithValue(() => now),
          receivedCountTtlProvider.overrideWithValue(const Duration(minutes: 10)),
        ],
      );
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      c.listen(syncStatusProvider, (_, _) {});
      c.listen(socialControllerProvider, (_, _) {});
      c.listen(sentRequestsControllerProvider, (_, _) {});
      c.listen(receivedRequestsControllerProvider, (_, _) {});
      c.listen(friendsControllerProvider, (_, _) {});
      c.listen(blockedControllerProvider, (_, _) {});
      c.listen(receivedCountControllerProvider, (_, _) {});
      return c;
    }

    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    int reads(String what) => social.readLog.where((e) => e == what).length;

    test(
      'blocking a friend: leaves Amigos, appears first in Bloqueados, 0 reads, no "salvando" left',
      () async {
        final c = make(
          seed: (s) {
            s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno');
            s.seedFriendship('uid-ana', 'uid-caio', bName: 'Caio');
            s.seedBlock('uid-ana', 'uid-velho', name: 'Velho', at: DateTime.utc(2026, 1, 1));
          },
        );
        await settle();
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        await c.read(blockedControllerProvider.notifier).ensureLoaded();
        social.readLog.clear();
        social.writeGate = Completer<void>();
        final friend = c
            .read(friendsControllerProvider)
            .items
            .firstWhere((f) => f.uid == 'uid-bruno');
        final pending = c.read(friendsControllerProvider.notifier).block(friend);
        await settle();
        final saving = c.read(friendsControllerProvider);
        expect(saving.busy, {'uid-bruno'});
        expect(saving.blocking, {'uid-bruno'});
        expect(
          saving.items.map((f) => f.uid),
          contains('uid-bruno'),
          reason: 'not gone before the server says so',
        );
        social.writeGate!.complete();
        expect(await pending, isNull);
        final after = c.read(friendsControllerProvider);
        expect(after.items.map((f) => f.uid), ['uid-caio']);
        expect(after.busy, isEmpty);
        expect(after.blocking, isEmpty);
        expect(c.read(blockedControllerProvider).items.map((u) => u.uid), [
          'uid-bruno',
          'uid-velho',
        ]);
        expect(social.readLog, isEmpty, reason: 'no read after the block');
        expect(social.friendships.keys, ['uid-ana_uid-caio']);
      },
    );

    test(
      'blocking the sender of a received request: it leaves the list, the badge drops, Bloqueados shows them',
      () async {
        final c = make(
          seed: (s) {
            s.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno');
            s.seedRequest('uid-caio', 'uid-ana', fromName: 'Caio');
          },
        );
        await settle();
        final received = c.read(receivedRequestsControllerProvider.notifier);
        await received.ensureLoaded();
        expect(c.read(receivedBadgeProvider), 2);
        await c.read(blockedControllerProvider.notifier).ensureLoaded();
        social.readLog.clear();
        final bruno = c
            .read(receivedRequestsControllerProvider)
            .items
            .firstWhere((r) => r.fromUid == 'uid-bruno');
        expect(await received.blockSender(bruno), isNull);
        expect(c.read(receivedRequestsControllerProvider).items.map((r) => r.fromUid), [
          'uid-caio',
        ]);
        expect(c.read(receivedBadgeProvider), 1);
        expect(c.read(blockedControllerProvider).items.map((u) => u.uid), ['uid-bruno']);
        expect(c.read(blockedControllerProvider).items.single.name, 'Bruno');
        expect(social.requests.keys, ['uid-caio_uid-ana']);
        expect(social.readLog, isEmpty);
      },
    );

    test(
      'blocking while the received list was never loaded: the badge is asked again (one count), not guessed',
      () async {
        final c = make(
          seed: (s) {
            s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno');
            s.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno');
            s.seedRequest('uid-caio', 'uid-ana', fromName: 'Caio');
          },
        );
        await settle();
        final counts = c.read(receivedCountControllerProvider.notifier);
        await counts.ensureFresh();
        expect(c.read(receivedBadgeProvider), 2);
        // from a search result the person may have a pending request: ask again
        expect(
          await c
              .read(blockedControllerProvider.notifier)
              .blockPerson(uid: 'uid-bruno', name: 'Bruno'),
          isNull,
        );
        social.readLog.clear();
        await counts.ensureFresh(); // invalidated by the block, so no TTL wait
        expect(reads('countReceived'), 1);
        expect(c.read(receivedBadgeProvider), 1, reason: 'Bruno\'s request went with the block');
      },
    );

    test('blocking a person from a search result: every loaded list forgets them', () async {
      final c = make(
        seed: (s) {
          s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno');
          s.seedRequest('uid-ana', 'uid-caio', fromName: 'Ana', toName: 'Caio');
        },
      );
      await settle();
      await c.read(friendsControllerProvider.notifier).ensureLoaded();
      await c.read(sentRequestsControllerProvider.notifier).ensureLoaded();
      expect(
        await c.read(blockedControllerProvider.notifier).blockPerson(uid: 'uid-caio', name: 'Caio'),
        isNull,
      );
      expect(c.read(sentRequestsControllerProvider).items, isEmpty);
      expect(c.read(friendsControllerProvider).items.map((f) => f.uid), ['uid-bruno']);
      // not loaded before: opening the tab reads it
      await c.read(blockedControllerProvider.notifier).ensureLoaded();
      expect(c.read(blockedControllerProvider).items.map((u) => u.uid), ['uid-caio']);
    });

    test(
      'blocking a person who is a friend, from a search result, removes them from Amigos too',
      () async {
        final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
        await settle();
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        expect(
          await c
              .read(blockedControllerProvider.notifier)
              .blockPerson(uid: 'uid-bruno', name: 'Bruno'),
          isNull,
        );
        expect(c.read(friendsControllerProvider).items, isEmpty);
      },
    );

    test(
      'a refused block (already blocked): generic failure, busy cleared, loaded lists are read again',
      () async {
        final c = make(
          seed: (s) {
            s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno');
            s.seedBlock('uid-ana', 'uid-bruno', name: 'Bruno');
          },
        );
        await settle();
        final friends = c.read(friendsControllerProvider.notifier);
        await friends.ensureLoaded();
        await c.read(blockedControllerProvider.notifier).ensureLoaded();
        social.readLog.clear();
        final friend = c.read(friendsControllerProvider).items.single;
        final failure = await friends.block(friend);
        expect(failure!.kind, SocialFailureKind.notBlocked);
        await settle();
        expect(c.read(friendsControllerProvider).busy, isEmpty);
        expect(reads('friends:page'), 1);
        expect(reads('blocked:page'), 1);
      },
    );

    test('an unconfirmed block (timeout) reads the lists again instead of guessing', () async {
      final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
      await settle();
      final friends = c.read(friendsControllerProvider.notifier);
      await friends.ensureLoaded();
      social.failures['blockUser'] = const SocialFailure(SocialFailureKind.uncertain);
      social.readLog.clear();
      final failure = await friends.block(c.read(friendsControllerProvider).items.single);
      expect(failure!.kind, SocialFailureKind.uncertain);
      await settle();
      expect(reads('friends:page'), 1, reason: 'runFor already read the own list: not twice');
    });

    test('an unconfirmed block reads the OTHER loaded lists once each', () async {
      final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
      await settle();
      final friends = c.read(friendsControllerProvider.notifier);
      await friends.ensureLoaded();
      await c.read(blockedControllerProvider.notifier).ensureLoaded();
      social.failures['blockUser'] = const SocialFailure(SocialFailureKind.uncertain);
      social.readLog.clear();
      await friends.block(c.read(friendsControllerProvider).items.single);
      await settle();
      expect(reads('friends:page'), 1);
      expect(reads('blocked:page'), 1);
    });

    test('blocking a FRIEND costs no badge count (friends have no pending request)', () async {
      final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
      await settle();
      final counts = c.read(receivedCountControllerProvider.notifier);
      await counts.ensureFresh();
      await c.read(friendsControllerProvider.notifier).ensureLoaded();
      expect(
        await c
            .read(friendsControllerProvider.notifier)
            .block(c.read(friendsControllerProvider).items.single),
        isNull,
      );
      social.readLog.clear();
      await counts.ensureFresh();
      expect(reads('countReceived'), 0);
    });

    test('a second block of the same person while one is running is NOT a success', () async {
      final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
      await settle();
      final friends = c.read(friendsControllerProvider.notifier);
      await friends.ensureLoaded();
      final friend = c.read(friendsControllerProvider).items.single;
      social.writeGate = Completer<void>();
      final first = friends.block(friend);
      await settle();
      final second = await friends.block(friend);
      expect(second, same(kBusyFailure));
      social.writeGate!.complete();
      expect(await first, isNull);
      expect(social.log.where((e) => e == 'blockUser'), hasLength(1));
    });

    test('the name shown right after blocking is the cleaned one, as in the list', () async {
      final c = make();
      await settle();
      final blocked = c.read(blockedControllerProvider.notifier);
      await blocked.ensureLoaded();
      await blocked.blockPerson(
        uid: 'uid-bruno',
        name: '  Zé\u200B ',
        photo: 'https://evil.example/x',
      );
      final shown = c.read(blockedControllerProvider).items.single;
      expect(shown.name, 'Zé');
      expect(shown.photoUrl, isNull);
      await blocked.reload();
      expect(c.read(blockedControllerProvider).items.single.name, 'Zé');
    });

    test(
      'unblock: leaves the list after the server says so; nothing is restored; no re-read',
      () async {
        final c = make(seed: (s) => s.seedBlock('uid-ana', 'uid-bruno', name: 'Bruno'));
        await settle();
        final blocked = c.read(blockedControllerProvider.notifier);
        await blocked.ensureLoaded();
        social.readLog.clear();
        social.writeGate = Completer<void>();
        final pending = blocked.unblock(c.read(blockedControllerProvider).items.single);
        await settle();
        expect(c.read(blockedControllerProvider).busy, {'uid-bruno'});
        expect(c.read(blockedControllerProvider).items, hasLength(1));
        social.writeGate!.complete();
        expect(await pending, isNull);
        expect(c.read(blockedControllerProvider).items, isEmpty);
        expect(social.friendships, isEmpty);
        expect(social.readLog, isEmpty);
      },
    );

    test('unblock offline fails visibly and keeps the person listed', () async {
      final c = make(seed: (s) => s.seedBlock('uid-ana', 'uid-bruno', name: 'Bruno'));
      await settle();
      final blocked = c.read(blockedControllerProvider.notifier);
      await blocked.ensureLoaded();
      social.offline = true;
      final failure = await blocked.unblock(c.read(blockedControllerProvider).items.single);
      expect(failure!.kind, SocialFailureKind.offline);
      expect(c.read(blockedControllerProvider).items, hasLength(1));
      expect(c.read(blockedControllerProvider).busy, isEmpty);
    });

    test(
      'Bloqueados: nothing is read until the tab asks; the TTL and the cooldown apply',
      () async {
        final c = make(seed: (s) => s.seedBlock('uid-ana', 'uid-bruno', name: 'Bruno'));
        await settle();
        expect(reads('blocked:page'), 0);
        final blocked = c.read(blockedControllerProvider.notifier);
        await blocked.ensureLoaded();
        await blocked.ensureLoaded();
        expect(reads('blocked:page'), 1);
        expect(
          await blocked.refresh(),
          isFalse,
          reason: 'inside the 15 s cooldown: no read, and it says so',
        );
        expect(reads('blocked:page'), 1);
        now = now.add(const Duration(seconds: 16));
        expect(await blocked.refresh(), isTrue);
        expect(reads('blocked:page'), 2);
      },
    );

    test(
      'logout and a different account drop the blocked list; an in-flight block of A touches nothing of B',
      () async {
        final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
        await settle();
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        await c.read(blockedControllerProvider.notifier).ensureLoaded();
        social.writeGate = Completer<void>();
        final friend = c.read(friendsControllerProvider).items.single;
        final pending = c.read(friendsControllerProvider.notifier).block(friend);
        await settle();
        // Ana signs out and Bruno signs in while the block of Ana is still in flight
        await c.read(authControllerProvider.notifier).signOut();
        await settle();
        auth.nextUser = kBruno;
        await auth.signInWithGoogle();
        await settle();
        // Bruno opens HIS Bloqueados (loaded, empty) while Ana's block is still in flight
        await c.read(blockedControllerProvider.notifier).ensureLoaded();
        expect(c.read(blockedControllerProvider).phase, SentPhase.loaded);
        social.writeGate!.complete();
        await pending;
        await settle();
        expect(c.read(blockedControllerProvider).phase, SentPhase.loaded);
        expect(
          c.read(blockedControllerProvider).items,
          isEmpty,
          reason: 'Ana\'s block is not Bruno\'s',
        );
        expect(c.read(friendsControllerProvider).items, isEmpty);
      },
    );

    test(
      'turning friendships off and on again forgets the blocked list (blocks were swept)',
      () async {
        final c = make(seed: (s) => s.seedBlock('uid-ana', 'uid-bruno', name: 'Bruno'));
        await settle();
        await c.read(blockedControllerProvider.notifier).ensureLoaded();
        expect(c.read(blockedControllerProvider).items, hasLength(1));
        expect(await c.read(socialControllerProvider.notifier).deactivate(), isNull);
        await settle();
        expect(c.read(blockedControllerProvider).phase, SentPhase.idle);
        expect(c.read(blockedControllerProvider).items, isEmpty);
        expect(social.blocks['uid-ana'], isEmpty);
      },
    );
  });
}

/// Runs a block as another account's repository over the shared fake cloud.
class InMemorySocialDataSourceFactory {
  final FakeSocialCloud cloud;

  InMemorySocialDataSourceFactory(this.cloud);

  Future<void> blockAs(String uid, String other) =>
      SocialRepository(InMemorySocialDataSource(cloud, uid: uid)).blockUser(uid: other, name: 'X');
}
