import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// Slice 3 (docs/62): accept / decline / friends list / remove / crossed
/// request, over the in-memory fakes. The fake mirrors the data rules of
/// `firestore.rules`; the real rules are exercised by dart_payloads.test.mjs
/// with the same payloads.

const _photo = 'https://lh3.googleusercontent.com/a/ana';
const _brunoPhoto = 'https://lh4.googleusercontent.com/b';
const _me = SocialProfile(handle: 'ana', nickname: 'Ana', photoUrl: _photo, discoverable: true);

class _Rig {
  DateTime clock = DateTime.utc(2026, 10, 5, 12);
  late final cloud = FakeSocialCloud(now: () => clock);
  late final ds = InMemorySocialDataSource(cloud, uid: 'uid-ana');
  late final repo = SocialRepository(ds, now: () => clock);

  _Rig() {
    cloud
      ..seedActive('uid-ana', 'ana', nickname: 'Ana', photoUrl: _photo)
      ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno', photoUrl: _brunoPhoto);
  }

  /// Bruno's request to Ana, as the app of Bruno writes it.
  void brunoAsks({String name = 'Bruno', String? photo}) {
    cloud.requests['uid-bruno_uid-ana'] = {
      'from': 'uid-bruno',
      'to': 'uid-ana',
      'fromName': name,
      'fromPhoto': ?photo,
      'toName': 'Ana',
      'createdAt': clock,
    };
  }

  Future<ReceivedRequest> firstReceived() async => (await repo.receivedRequests()).items.first;
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
  group('accept (ONE batch: friendship + request consumed)', () {
    test(
      'creates the pair with both halves and consumes the request; nobody else is touched',
      () async {
        final r = _Rig();
        r.brunoAsks(photo: _brunoPhoto);
        r.cloud.seedRequest('uid-bruno', 'uid-c'); // unrelated
        final request = await r.firstReceived();
        await r.repo.acceptRequest(request, me: _me);
        expect(r.cloud.requests.keys, ['uid-bruno_uid-c']);
        final pair = r.cloud.friendships['uid-ana_uid-bruno']!;
        expect(pair['members'], ['uid-ana', 'uid-bruno']);
        expect((pair['aName'], pair['aPhoto']), ('Ana', _photo));
        expect((pair['bName'], pair['bPhoto']), ('Bruno', _brunoPhoto));
        expect(r.cloud.log.where((e) => e == 'acceptRequest'), hasLength(1));
      },
    );

    test(
      '1 read only (the friends count) and the other half is exactly what THEIR request says',
      () async {
        final r = _Rig();
        r.brunoAsks(name: 'Bruno ');
        final request = await r.firstReceived();
        expect(request.fromName, 'Bruno', reason: 'shown clean');
        expect(request.rawFromName, 'Bruno ', reason: 'copied as stored');
        r.cloud.readLog.clear();
        await r.repo.acceptRequest(request, me: _me);
        expect(r.cloud.readLog, ['countFriends']);
        expect(r.cloud.friendships['uid-ana_uid-bruno']!['bName'], 'Bruno ');
      },
    );

    test('the same pair id when the accepting user sorts AFTER the sender', () async {
      final r = _Rig();
      final bruno = InMemorySocialDataSource(r.cloud, uid: 'uid-bruno');
      r.cloud.requests['uid-ana_uid-bruno'] = {
        'from': 'uid-ana',
        'to': 'uid-bruno',
        'fromName': 'Ana',
        'toName': 'Bruno',
        'createdAt': r.clock,
      };
      final repo = SocialRepository(bruno);
      final request = (await repo.receivedRequests()).items.single;
      await repo.acceptRequest(
        request,
        me: const SocialProfile(handle: 'bruno', nickname: 'Bruno'),
      );
      final pair = r.cloud.friendships['uid-ana_uid-bruno']!;
      expect(pair['members'], ['uid-ana', 'uid-bruno']);
      expect((pair['aName'], pair['bName']), ('Ana', 'Bruno'));
      expect(r.cloud.requests, isEmpty);
    });

    test('the request is gone (cancelled meanwhile): generic message, nothing created', () async {
      final r = _Rig();
      r.brunoAsks();
      final request = await r.firstReceived();
      r.cloud.requests.clear(); // Bruno cancelled
      final f = await _fail(r.repo.acceptRequest(request, me: _me));
      expect(f!.kind, SocialFailureKind.notAccepted);
      expect(f.message, contains('pode ter sido cancelado'));
      expect(r.cloud.friendships, isEmpty);
    });

    test('a block between the two: the SAME generic answer, nothing created', () async {
      final r = _Rig();
      r.brunoAsks();
      final request = await r.firstReceived();
      r.cloud.seedBlock('uid-bruno', 'uid-ana');
      final f = await _fail(r.repo.acceptRequest(request, me: _me));
      expect(f!.kind, SocialFailureKind.notAccepted);
      expect(r.cloud.friendships, isEmpty);
      expect(r.cloud.requests, hasLength(1), reason: 'the batch is all or nothing');
    });

    test('accepting twice: the second is refused and nothing changes', () async {
      final r = _Rig();
      r.brunoAsks();
      final request = await r.firstReceived();
      await r.repo.acceptRequest(request, me: _me);
      final f = await _fail(r.repo.acceptRequest(request, me: _me));
      expect(f!.kind, SocialFailureKind.notAccepted);
      expect(r.cloud.friendships, hasLength(1));
    });

    test('limit of 300 friends: refused before any write; 299 still works', () async {
      final r = _Rig();
      for (var i = 0; i < 299; i++) {
        r.cloud.seedFriendship('uid-ana', 'uid-f$i');
      }
      r.brunoAsks();
      final request = await r.firstReceived();
      await r.repo.acceptRequest(request, me: _me); // the 300th
      expect(r.cloud.friendships, hasLength(300));
      r.cloud.requests['uid-c_uid-ana'] = {
        'from': 'uid-c',
        'to': 'uid-ana',
        'fromName': 'Caio',
        'toName': 'Ana',
        'createdAt': r.clock,
      };
      r.cloud.seedActive('uid-c', 'caio');
      final over = (await r.repo.receivedRequests()).items.single;
      final f = await _fail(r.repo.acceptRequest(over, me: _me));
      expect(f!.kind, SocialFailureKind.friendsLimit);
      expect(r.cloud.friendships, hasLength(300));
      expect(r.cloud.requests, hasLength(1));
    });

    test('offline: honest failure, nothing created (the write is never queued)', () async {
      final r = _Rig();
      r.brunoAsks();
      final request = await r.firstReceived();
      r.cloud.offline = true;
      final f = await _fail(r.repo.acceptRequest(request, me: _me));
      expect(f!.kind, SocialFailureKind.offline);
      r.cloud.offline = false;
      expect(r.cloud.friendships, isEmpty);
      expect(r.cloud.requests, hasLength(1));
    });

    test('without a nickname on my card the accept is refused before any read', () async {
      final r = _Rig();
      r.brunoAsks();
      final request = await r.firstReceived();
      r.cloud.readLog.clear();
      final f = await _fail(
        r.repo.acceptRequest(
          request,
          me: const SocialProfile(handle: 'ana', nickname: '  '),
        ),
      );
      expect(f!.kind, SocialFailureKind.invalid);
      expect(r.cloud.readLog, isEmpty);
    });
  });

  group('crossed request (D4): sending to someone who already asked becomes a friendship', () {
    test('one batch; no request is left in either direction; their half is THEIR name', () async {
      final r = _Rig();
      r.brunoAsks(name: 'Bruno do Cinema', photo: _brunoPhoto);
      final card = ((await r.repo.search('bruno', ownHandle: 'ana')) as SearchFound).card;
      final outcome = await r.repo.sendRequest(card, me: _me);
      expect(outcome, SendOutcome.becameFriends);
      expect(r.cloud.requests, isEmpty);
      final pair = r.cloud.friendships['uid-ana_uid-bruno']!;
      expect(pair['bName'], 'Bruno do Cinema', reason: 'what Bruno wrote, not the search card');
      expect(r.cloud.log, contains('crossedAccept'));
      expect(r.cloud.log, isNot(contains('sendRequest')));
    });

    test('the 300 friends cap holds here too: nothing is created, their request stays', () async {
      final r = _Rig();
      for (var i = 0; i < 300; i++) {
        r.cloud.seedFriendship('uid-ana', 'uid-f$i');
      }
      r.brunoAsks();
      final card = ((await r.repo.search('bruno', ownHandle: 'ana')) as SearchFound).card;
      r.cloud.readLog.clear();
      final f = await _fail(r.repo.sendRequest(card, me: _me));
      expect(f!.kind, SocialFailureKind.friendsLimit);
      expect(f.message, contains('300 amigos'));
      expect(r.cloud.friendships, hasLength(300));
      expect(r.cloud.requests.keys, ['uid-bruno_uid-ana']);
      expect(r.cloud.readLog.where((e) => e == 'countFriends'), hasLength(1));
    });

    test('299 friends: the crossed request still becomes the 300th', () async {
      final r = _Rig();
      for (var i = 0; i < 299; i++) {
        r.cloud.seedFriendship('uid-ana', 'uid-f$i');
      }
      r.brunoAsks();
      final card = ((await r.repo.search('bruno', ownHandle: 'ana')) as SearchFound).card;
      expect(await r.repo.sendRequest(card, me: _me), SendOutcome.becameFriends);
      expect(r.cloud.friendships, hasLength(300));
    });

    test('a plain send still creates the request (outcome requested)', () async {
      final r = _Rig();
      final card = ((await r.repo.search('bruno', ownHandle: 'ana')) as SearchFound).card;
      expect(await r.repo.sendRequest(card, me: _me), SendOutcome.requested);
      expect(r.cloud.requests.keys, ['uid-ana_uid-bruno']);
      expect(r.cloud.friendships, isEmpty);
    });

    test('with a block it is the generic "not sent" and nothing is created', () async {
      final r = _Rig();
      r.brunoAsks();
      final card = ((await r.repo.search('bruno', ownHandle: 'ana')) as SearchFound).card;
      r.cloud.seedBlock('uid-ana', 'uid-bruno');
      final f = await _fail(r.repo.sendRequest(card, me: _me));
      expect(f!.kind, SocialFailureKind.notSent);
      expect(r.cloud.friendships, isEmpty);
    });
  });

  group('decline and remove (silent, one delete each)', () {
    test('decline deletes only that request; nobody is notified; 0 reads', () async {
      final r = _Rig();
      r.brunoAsks();
      r.cloud.seedRequest('uid-ana', 'uid-bruno'); // my own request to him stays
      r.cloud.readLog.clear();
      await r.repo.declineRequest('uid-bruno');
      expect(r.cloud.requests.keys, ['uid-ana_uid-bruno']);
      expect(r.cloud.friendships, isEmpty);
      expect(r.cloud.readLog, isEmpty);
      expect(
        r.cloud.log.where((e) => e != 'declineRequest'),
        isEmpty,
        reason: 'only the delete reached the server',
      );
      await r.repo.declineRequest('uid-bruno'); // repeating is harmless
    });

    test('remove deletes the one pair document: both lists lose it; 0 reads; idempotent', () async {
      final r = _Rig();
      r.cloud.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana', bName: 'Bruno');
      r.cloud.seedFriendship('uid-ana', 'uid-zeca');
      final bruno = SocialRepository(InMemorySocialDataSource(r.cloud, uid: 'uid-bruno'));
      expect((await bruno.friends()).items.single.name, 'Ana');
      r.cloud.readLog.clear();
      await r.repo.removeFriend('uid-bruno');
      expect(r.cloud.readLog, isEmpty);
      expect((await r.repo.friends()).items.map((f) => f.uid), ['uid-zeca']);
      expect((await bruno.friends()).items, isEmpty);
      await r.repo.removeFriend('uid-bruno');
    });

    test(
      'after removing, a new request works again (and sending to a friend is refused)',
      () async {
        final r = _Rig();
        r.cloud.seedFriendship('uid-ana', 'uid-bruno');
        final card = ((await r.repo.search('bruno', ownHandle: 'ana')) as SearchFound).card;
        expect((await _fail(r.repo.sendRequest(card, me: _me)))!.kind, SocialFailureKind.notSent);
        await r.repo.removeFriend('uid-bruno');
        expect(await r.repo.sendRequest(card, me: _me), SendOutcome.requested);
      },
    );
  });

  group('lists: received requests and friends', () {
    test(
      'received: newest first, 20 per page, look-ahead tells there is more; names cleaned, raw kept',
      () async {
        final r = _Rig();
        final base = DateTime.utc(2026, 9, 1);
        for (var i = 0; i < 45; i++) {
          r.cloud.requests['uid-p${i}_uid-ana'] = {
            'from': 'uid-p$i',
            'to': 'uid-ana',
            'fromName': 'Pessoa $i',
            'toName': 'Ana',
            'createdAt': base.add(Duration(hours: i)),
          };
        }
        final p1 = await r.repo.receivedRequests();
        expect(p1.items, hasLength(20));
        expect(p1.hasMore, isTrue);
        expect(p1.items.first.fromName, 'Pessoa 44');
        final p2 = await r.repo.receivedRequests(cursor: p1.cursor);
        final p3 = await r.repo.receivedRequests(cursor: p2.cursor);
        expect(p3.items, hasLength(5));
        expect(p3.hasMore, isFalse);
        final all = [...p1.items, ...p2.items, ...p3.items].map((e) => e.fromUid).toSet();
        expect(all, hasLength(45), reason: 'no duplicates and none skipped');
      },
    );

    test('received: malformed documents are skipped; a photo outside Google is dropped', () async {
      final r = _Rig();
      r.cloud.requests['uid-x_uid-ana'] = {
        'from': 'uid-x',
        'to': 'uid-ana',
        'fromName': 'Xis​',
        'fromPhoto': 'https://evil.example/x.png',
        'toName': 'Ana',
        'createdAt': r.clock,
      };
      r.cloud.requests['uid-y_uid-ana'] = {'from': 'uid-y', 'to': 'uid-ana', 'createdAt': r.clock};
      r.cloud.requests['uid-ana_uid-ana'] = {
        'from': 'uid-ana',
        'to': 'uid-ana',
        'fromName': 'Eu',
        'createdAt': r.clock,
      };
      final items = (await r.repo.receivedRequests()).items;
      expect(items.single.fromUid, 'uid-x');
      expect(items.single.fromName, 'Xis');
      expect(items.single.fromPhoto, isNull);
    });

    test('friends: 50 per page, the OTHER half whichever side I am; pages do not repeat', () async {
      final r = _Rig();
      for (var i = 0; i < 120; i++) {
        // alternate who sorts first
        final other = i.isEven ? 'uid-a$i' : 'uid-z$i';
        r.cloud.seedFriendship('uid-ana', other, aName: 'Ana', bName: 'Amigo $i');
      }
      final p1 = await r.repo.friends();
      expect(p1.items, hasLength(50));
      expect(p1.hasMore, isTrue);
      final p2 = await r.repo.friends(cursor: p1.cursor);
      final p3 = await r.repo.friends(cursor: p2.cursor);
      expect(p3.items, hasLength(20));
      expect(p3.hasMore, isFalse);
      final all = [...p1.items, ...p2.items, ...p3.items];
      expect(all.map((f) => f.uid).toSet(), hasLength(120));
      expect(all.every((f) => f.uid != 'uid-ana'), isTrue);
      expect(all.every((f) => f.name.startsWith('Amigo ')), isTrue, reason: 'never my own half');
    });

    test('friends: a foreign document that does not list me is ignored', () async {
      final r = _Rig();
      r.cloud.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana', bName: 'Bruno');
      final page = await r.repo.friends();
      expect(page.items.single.name, 'Bruno');
      expect(page.items.single.since, isNotNull);
    });

    test('count for the badge is capped at 50 and costs one read', () async {
      final r = _Rig();
      for (var i = 0; i < 70; i++) {
        r.cloud.seedRequest('uid-p$i', 'uid-ana');
      }
      r.cloud.readLog.clear();
      expect(await r.repo.receivedCount(), kMaxReceivedListed);
      expect(r.cloud.readLog, ['countReceived']);
    });

    test('offline: the device copy is flagged; nothing cached: an offline failure', () async {
      final r = _Rig();
      r.brunoAsks();
      r.cloud.seedFriendship('uid-ana', 'uid-zeca');
      r.cloud.offline = true;
      expect((await r.repo.receivedRequests()).fromCache, isTrue);
      expect((await r.repo.friends()).fromCache, isTrue);
      r.cloud.cacheAvailable = false;
      expect((await _fail(r.repo.receivedRequests()))!.kind, SocialFailureKind.offline);
      expect((await _fail(r.repo.friends()))!.kind, SocialFailureKind.offline);
    });
  });

  group('controllers: cache + TTL, rebuilt on the right events, no listener', () {
    late FakeSocialCloud social;
    late FakeAuthRepository auth;
    late FakeLocalStore store;
    var now = DateTime.utc(2026, 10, 5, 12);

    ProviderContainer make({
      Duration ttl = const Duration(minutes: 5),
      Duration countTtl = const Duration(minutes: 10),
      FakeLocalStore? withStore,
      void Function(FakeSocialCloud s)? seed,
    }) {
      social = FakeSocialCloud();
      social
        ..seedActive('uid-ana', 'ana', nickname: 'Ana')
        ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno');
      seed?.call(social);
      auth = FakeAuthRepository(initialUser: kAna);
      store = withStore ?? FakeLocalStore();
      final c = ProviderContainer(
        overrides: [
          ...cloudOverrides(auth: auth, cloud: FakeCloud(), socialCloud: social, store: store),
          sentRequestsTtlProvider.overrideWithValue(ttl),
          receivedCountTtlProvider.overrideWithValue(countTtl),
          socialClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      c.listen(syncStatusProvider, (_, _) {});
      c.listen(socialControllerProvider, (_, _) {});
      c.listen(sentRequestsControllerProvider, (_, _) {});
      c.listen(receivedRequestsControllerProvider, (_, _) {});
      c.listen(friendsControllerProvider, (_, _) {});
      c.listen(receivedCountControllerProvider, (_, _) {});
      return c;
    }

    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    int reads(String what) => social.readLog.where((e) => e == what).length;

    test('nothing is read until a screen asks; reopening within the TTL reads nothing', () async {
      final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
      await settle();
      expect(reads('friends:page'), 0);
      expect(reads('received:page'), 0);
      final friends = c.read(friendsControllerProvider.notifier);
      await friends.ensureLoaded();
      await friends.ensureLoaded();
      expect(reads('friends:page'), 1);
      expect(c.read(friendsControllerProvider).items.single.name, 'Bruno');
    });

    test(
      'after the TTL the next open reads once more; a list from the device is not fresh',
      () async {
        final c = make(ttl: Duration.zero);
        await settle();
        final received = c.read(receivedRequestsControllerProvider.notifier);
        await received.ensureLoaded();
        await received.ensureLoaded();
        expect(reads('received:page'), 2);

        final d = make();
        await settle();
        social.offline = true;
        final friends = d.read(friendsControllerProvider.notifier);
        await friends.ensureLoaded();
        expect(d.read(friendsControllerProvider).fromCache, isTrue);
        social.offline = false;
        await friends.ensureLoaded();
        expect(d.read(friendsControllerProvider).fromCache, isFalse);
      },
    );

    test(
      'accept: the request leaves the list, the friend appears (sorted), the count drops, no re-read',
      () async {
        final c = make(
          seed: (s) {
            s.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno');
            s.seedRequest('uid-caio', 'uid-ana', fromName: 'Caio');
            s.seedActive('uid-caio', 'caio');
            s.seedFriendship('uid-ana', 'uid-aline', aName: 'Ana', bName: 'Aline');
          },
        );
        await settle();
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        final received = c.read(receivedRequestsControllerProvider.notifier);
        await received.ensureLoaded();
        expect(c.read(receivedCountControllerProvider).count, 2, reason: 'the list is the count');
        final bruno = c
            .read(receivedRequestsControllerProvider)
            .items
            .firstWhere((r) => r.fromUid == 'uid-bruno');
        social.readLog.clear();
        final saving = received.accept(bruno);
        expect(c.read(receivedRequestsControllerProvider).busy, {'uid-bruno'});
        expect(await saving, isNull);
        expect(c.read(receivedRequestsControllerProvider).busy, isEmpty);
        expect(c.read(receivedRequestsControllerProvider).items.map((r) => r.fromUid), [
          'uid-caio',
        ]);
        expect(c.read(friendsControllerProvider).items.map((f) => f.name), ['Aline', 'Bruno']);
        expect(c.read(receivedCountControllerProvider).count, 1);
        expect(social.readLog, ['countFriends'], reason: 'no list was read again');
        expect(social.friendships.keys, contains('uid-ana_uid-bruno'));
      },
    );

    test(
      'accept that fails keeps the request and says why; "not accepted" drops it (it is gone)',
      () async {
        final c = make(seed: (s) => s.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno'));
        await settle();
        final received = c.read(receivedRequestsControllerProvider.notifier);
        await received.ensureLoaded();
        final request = c.read(receivedRequestsControllerProvider).items.single;
        social.offline = true;
        expect((await received.accept(request))!.kind, SocialFailureKind.offline);
        social.offline = false;
        expect(c.read(receivedRequestsControllerProvider).items, hasLength(1));
        expect(c.read(receivedRequestsControllerProvider).busy, isEmpty);
        social.requests.clear(); // cancelled by the sender
        expect((await received.accept(request))!.kind, SocialFailureKind.notAccepted);
        expect(c.read(receivedRequestsControllerProvider).items, isEmpty);
        expect(c.read(friendsControllerProvider).items, isEmpty);
      },
    );

    test(
      'decline: the request leaves the list and the count; a second tap while saving is ignored',
      () async {
        final c = make(seed: (s) => s.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno'));
        await settle();
        final received = c.read(receivedRequestsControllerProvider.notifier);
        await received.ensureLoaded();
        final request = c.read(receivedRequestsControllerProvider).items.single;
        final first = received.decline(request);
        expect(await received.decline(request), isNull, reason: 'already saving');
        expect(await first, isNull);
        expect(c.read(receivedRequestsControllerProvider).items, isEmpty);
        expect(c.read(receivedCountControllerProvider).count, 0);
        expect(social.log.where((e) => e == 'declineRequest'), hasLength(1));
      },
    );

    test('remove: the friend leaves the list; a failure keeps it', () async {
      final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
      await settle();
      final friends = c.read(friendsControllerProvider.notifier);
      await friends.ensureLoaded();
      final friend = c.read(friendsControllerProvider).items.single;
      social.offline = true;
      expect((await friends.remove(friend))!.kind, SocialFailureKind.offline);
      expect(c.read(friendsControllerProvider).items, hasLength(1));
      social.offline = false;
      expect(await friends.remove(friend), isNull);
      expect(c.read(friendsControllerProvider).items, isEmpty);
      expect(social.friendships, isEmpty);
    });

    test('received list is capped at 50 shown; "Ver mais" asks for exactly what is left', () async {
      final c = make(
        seed: (s) {
          for (var i = 0; i < 60; i++) {
            s.requests['uid-p${i}_uid-ana'] = {
              'from': 'uid-p$i',
              'to': 'uid-ana',
              'fromName': 'P$i',
              'toName': 'Ana',
              'createdAt': DateTime.utc(2026, 9, 1).add(Duration(hours: i)),
            };
          }
        },
      );
      await settle();
      final received = c.read(receivedRequestsControllerProvider.notifier);
      await received.ensureLoaded();
      await received.loadMore();
      await received.loadMore();
      final state = c.read(receivedRequestsControllerProvider);
      expect(state.items, hasLength(kMaxReceivedListed));
      expect(state.hasMore, isFalse, reason: 'the rest waits until the user answers some');
      expect(reads('received:page'), 3);
    });

    test(
      'crossed send through the sent controller: friend added, their request gone, count down',
      () async {
        final c = make(seed: (s) => s.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno'));
        await settle();
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        await c.read(receivedRequestsControllerProvider.notifier).ensureLoaded();
        await c.read(sentRequestsControllerProvider.notifier).ensureLoaded();
        const card = FriendCard(uid: 'uid-bruno', handle: 'bruno', nickname: 'Bruno');
        final result = await c.read(sentRequestsControllerProvider.notifier).send(card);
        expect(result.failure, isNull);
        expect(result.outcome, SendOutcome.becameFriends);
        expect(c.read(friendsControllerProvider).items.map((f) => f.uid), ['uid-bruno']);
        expect(c.read(receivedRequestsControllerProvider).items, isEmpty);
        expect(c.read(sentRequestsControllerProvider).items, isEmpty, reason: 'nothing pending');
        expect(c.read(receivedCountControllerProvider).count, 0);
        expect(social.requests, isEmpty);
      },
    );

    group('badge count: one aggregate read per TTL, never a listener', () {
      test('asks once; within the TTL nothing; after the TTL (clock) exactly once more', () async {
        final c = make(
          seed: (s) {
            s.seedRequest('uid-bruno', 'uid-ana');
            s.seedRequest('uid-caio', 'uid-ana');
          },
        );
        await settle();
        final count = c.read(receivedCountControllerProvider.notifier);
        await count.ensureFresh();
        expect(c.read(receivedBadgeProvider), 2);
        expect(reads('countReceived'), 1);
        social.seedRequest('uid-dora', 'uid-ana');
        now = now.add(const Duration(minutes: 9, seconds: 59));
        await count.ensureFresh();
        await count.ensureFresh();
        expect(reads('countReceived'), 1, reason: 'before the TTL: no read');
        expect(c.read(receivedBadgeProvider), 2);
        now = now.add(const Duration(seconds: 2));
        await count.ensureFresh();
        expect(reads('countReceived'), 2, reason: 'after the TTL: one read');
        expect(c.read(receivedBadgeProvider), 3, reason: 'the new request shows up');
        await count.ensureFresh();
        expect(reads('countReceived'), 2);
      });

      test('an account without friendships never asks; nothing is shown', () async {
        final c = make(seed: (s) => s.social.remove('uid-ana'));
        await settle();
        await c.read(receivedCountControllerProvider.notifier).ensureFresh();
        expect(c.read(receivedBadgeProvider), 0);
        expect(reads('countReceived'), 0);
      });

      test(
        'a failed count is silent (no badge, no error) and is not retried before the TTL',
        () async {
          final c = make(seed: (s) => s.seedRequest('uid-bruno', 'uid-ana'));
          await settle();
          social.failures['countReceived'] = const SocialFailure(SocialFailureKind.quotaExceeded);
          final count = c.read(receivedCountControllerProvider.notifier);
          await count.ensureFresh();
          expect(c.read(receivedBadgeProvider), 0);
          await count.ensureFresh();
          expect(reads('countReceived'), 1);
          now = now.add(const Duration(minutes: 11));
          await count.ensureFresh();
          expect(c.read(receivedBadgeProvider), 1);
        },
      );

      test('opening the list sets the count for free (no extra aggregate read)', () async {
        final c = make(
          seed: (s) {
            s.seedRequest('uid-bruno', 'uid-ana');
            s.seedRequest('uid-caio', 'uid-ana');
          },
        );
        await settle();
        await c.read(receivedRequestsControllerProvider.notifier).ensureLoaded();
        expect(c.read(receivedCountControllerProvider).count, 2);
        await c.read(receivedCountControllerProvider.notifier).ensureFresh();
        expect(reads('countReceived'), 0, reason: 'the list already told the number');
      });
    });

    group('rebuilt on the right events (like the sent list of slice 2)', () {
      test('deactivate then activate: friends, received, count and sent are gone', () async {
        final c = make(
          seed: (s) {
            s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno');
            s.seedRequest('uid-caio', 'uid-ana');
          },
        );
        await settle();
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        await c.read(receivedRequestsControllerProvider.notifier).ensureLoaded();
        expect(c.read(friendsControllerProvider).items, hasLength(1));
        final ctl = c.read(socialControllerProvider.notifier);
        expect(await ctl.deactivate(), isNull);
        expect(social.friendships, isEmpty, reason: 'the server deleted the pairs');
        expect(
          await ctl.activate(handle: 'ana', nickname: 'Ana', showPhoto: false, discoverable: true),
          isNull,
        );
        await settle();
        expect(c.read(friendsControllerProvider).phase, SentPhase.idle);
        expect(c.read(receivedRequestsControllerProvider).phase, SentPhase.idle);
        expect(c.read(receivedCountControllerProvider).count, isNull);
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        expect(c.read(friendsControllerProvider).items, isEmpty);
      });

      test('changing the handle keeps the lists (the friendships are still valid)', () async {
        final c = make(seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'));
        await settle();
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        expect(await c.read(socialControllerProvider.notifier).changeHandle('ana_nova'), isNull);
        await settle();
        expect(c.read(friendsControllerProvider).phase, SentPhase.loaded);
        expect(reads('friends:page'), 1);
      });

      test('logout and a different account drop everything in memory', () async {
        final c = make(
          seed: (s) {
            s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno');
            s.seedRequest('uid-caio', 'uid-ana');
          },
        );
        await settle();
        await c.read(friendsControllerProvider.notifier).ensureLoaded();
        await c.read(receivedRequestsControllerProvider.notifier).ensureLoaded();
        await c.read(authControllerProvider.notifier).signOut();
        await settle();
        expect(c.read(friendsControllerProvider).phase, SentPhase.idle);
        expect(c.read(receivedRequestsControllerProvider).phase, SentPhase.idle);
        expect(c.read(receivedBadgeProvider), 0);
        auth.nextUser = kBruno;
        await auth.signInWithGoogle();
        await settle();
        expect(c.read(friendsControllerProvider).items, isEmpty, reason: 'not Ana\'s friends');
        expect(c.read(receivedRequestsControllerProvider).items, isEmpty);
      });
    });

    group('socialHint race (docs/61 a): a reply for account A is never the hint of account B', () {
      test('the same account: the server answer is remembered for ITS uid', () async {
        make();
        await settle();
        expect(store.socialHints['uid-ana']?.active, isTrue);
      });

      test(
        'A in flight, switch to B: A\'s (late, different) reply writes no hint; B gets its own',
        () async {
          social = FakeSocialCloud()
            ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno'); // Ana never turned it on
          final gate = Completer<void>();
          social.readGate = gate;
          auth = FakeAuthRepository(initialUser: kAna);
          store = FakeLocalStore();
          final c = ProviderContainer(
            overrides: cloudOverrides(
              auth: auth,
              cloud: FakeCloud(),
              socialCloud: social,
              store: store,
            ),
          );
          addTearDown(c.dispose);
          c.listen(authStateProvider, (_, _) {});
          c.listen(socialControllerProvider, (_, _) {});
          await settle(); // A's read waits on the gate
          expect(social.readLog, ['read']);
          social.readGate = null; // B's own read does not wait
          auth.nextUser = kBruno;
          await auth.signInWithGoogle();
          await settle();
          expect(c.read(socialControllerProvider).profile?.handle, 'bruno');
          expect(store.socialHints['uid-bruno']?.active, isTrue);
          gate.complete(); // A's answer ("not activated") arrives late
          await settle();
          expect(
            store.socialHints.containsKey('uid-ana'),
            isFalse,
            reason: 'A\'s answer is dropped',
          );
          expect(
            store.socialHints['uid-bruno']?.active,
            isTrue,
            reason: 'B\'s hint is not overwritten with A\'s answer',
          );
          expect(c.read(socialControllerProvider).profile?.handle, 'bruno');
        },
      );
    });

    group('hint after a confirmed action (docs/61 b)', () {
      test('activate remembers "on" and deactivate remembers "off" without another read', () async {
        final c = make(
          seed: (s) {
            s.social.remove('uid-ana');
            s.handles.remove('ana');
          },
        );
        await settle();
        final ctl = c.read(socialControllerProvider.notifier);
        expect(store.socialHints['uid-ana']?.active, isFalse);
        expect(
          await ctl.activate(handle: 'ana', nickname: 'Ana', showPhoto: false, discoverable: true),
          isNull,
        );
        expect(store.socialHints['uid-ana']?.active, isTrue);
        // the follow-up read fails (offline): the hint still tells the truth
        social.offline = true;
        await ctl.deactivate().catchError((_) => null);
        social.offline = false;
        expect(await ctl.deactivate(), isNull);
        expect(store.socialHints['uid-ana']?.active, isFalse);
      });
    });
  });

  group('deactivation and account deletion with REAL friendships', () {
    SocialRepository repoFor(_Rig r, String uid) =>
        SocialRepository(InMemorySocialDataSource(r.cloud, uid: uid));

    _Rig withNetwork() {
      final r = _Rig();
      r.cloud
        ..seedActive('uid-caio', 'caio', nickname: 'Caio')
        ..seedActive('uid-dora', 'dora', nickname: 'Dora');
      return r;
    }

    Future<void> befriend(_Rig r, String a, String b, {String? fromName}) async {
      // a asks b, b accepts: the way the app does it.
      r.cloud.requests['${a}_$b'] = {
        'from': a,
        'to': b,
        'fromName': fromName ?? a.replaceFirst('uid-', ''),
        'toName': b.replaceFirst('uid-', ''),
        'createdAt': r.clock,
      };
      final repo = repoFor(r, b);
      final request = (await repo.receivedRequests()).items.firstWhere((e) => e.fromUid == a);
      await repo.acceptRequest(
        request,
        me: SocialProfile(handle: b.replaceFirst('uid-', ''), nickname: b.replaceFirst('uid-', '')),
      );
    }

    test(
      'deactivate removes Ana\'s pairs and requests; the OTHERS lose her from their lists; theirs stay',
      () async {
        final r = withNetwork();
        await befriend(r, 'uid-bruno', 'uid-ana');
        await befriend(r, 'uid-caio', 'uid-ana');
        await befriend(r, 'uid-bruno', 'uid-caio'); // not Ana's
        r.cloud.seedRequest('uid-dora', 'uid-ana');
        r.cloud.seedRequest('uid-ana', 'uid-dora');
        expect((await repoFor(r, 'uid-bruno').friends()).items.map((f) => f.uid).toSet(), {
          'uid-ana',
          'uid-caio',
        });
        await r.repo.deactivate();
        expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
        expect((await repoFor(r, 'uid-bruno').friends()).items.map((f) => f.uid), ['uid-caio']);
        expect((await repoFor(r, 'uid-caio').friends()).items.map((f) => f.uid), ['uid-bruno']);
        expect(r.cloud.friendships.keys, ['uid-bruno_uid-caio']);
      },
    );

    test(
      'a friendship created BETWEEN the first sweep and closing the door is still swept',
      () async {
        final r = withNetwork();
        await befriend(r, 'uid-bruno', 'uid-ana');
        r.cloud.requests['uid-caio_uid-ana'] = {
          'from': 'uid-caio',
          'to': 'uid-ana',
          'fromName': 'Caio',
          'toName': 'Ana',
          'createdAt': r.clock,
        };
        r.cloud.beforeClose = () {
          // Ana accepts from another device right before the door closes.
          final other = FakeSocialCloud.pairId('uid-ana', 'uid-caio');
          r.cloud.friendships[other] = {
            'members': ['uid-ana', 'uid-caio'],
            'createdAt': r.clock,
            'aName': 'Ana',
            'bName': 'Caio',
          };
          r.cloud.requests.remove('uid-caio_uid-ana');
          r.cloud.beforeClose = null;
        };
        await r.repo.deactivate();
        expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      },
    );

    test(
      'account deletion: friendships created through the app leave no residue; others\' pairs stay',
      () async {
        final r = withNetwork();
        await befriend(r, 'uid-bruno', 'uid-ana');
        await befriend(r, 'uid-ana', 'uid-caio'); // she asked, he accepted
        await befriend(r, 'uid-bruno', 'uid-caio');
        await r.repo.wipeForAccountDeletion();
        expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
        expect(r.cloud.friendships.keys, ['uid-bruno_uid-caio']);
        expect((await repoFor(r, 'uid-bruno').friends()).items.map((f) => f.uid), ['uid-caio']);
      },
    );

    test('AccountController.deleteAccount sweeps real friendships and requests received', () async {
      final social = FakeSocialCloud()
        ..seedActive('uid-ana', 'ana', nickname: 'Ana')
        ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno')
        ..seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana', bName: 'Bruno')
        ..seedRequest('uid-caio', 'uid-ana');
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
      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
      expect(social.leftoversOf('uid-ana'), isEmpty);
      expect(social.friendships, isEmpty);
    });
  });

  group('export with real friendships (D9: uid + nickname)', () {
    test(
      'reads exactly what accepting writes: the other half\'s uid and nickname, no photos',
      () async {
        const draft = AcceptDraft(
          fromUid: 'uid-bruno',
          fromName: 'Bruno',
          fromPhoto: _brunoPhoto,
          myName: 'Ana',
          myPhoto: _photo,
        );
        final op = SocialPayloads.acceptRequest('uid-ana', draft).ops.first;
        final stored = <String, dynamic>{
          for (final e in op.data!.entries)
            e.key: e.value is ServerTimestamp ? DateTime.utc(2026, 10, 5) : e.value,
        };
        final source = FakeExportDataSource({})
          ..social = const RawSocial(social: {'handle': 'ana'});
        source.socialLists[SocialExportKind.friends] = {'uid-ana_uid-bruno': stored};
        source.socialLists[SocialExportKind.requestsReceived] = {
          'uid-caio_uid-ana': {
            'from': 'uid-caio',
            'to': 'uid-ana',
            'fromName': 'Caio',
            'fromPhoto': _brunoPhoto,
            'toName': 'Ana',
            'createdAt': DateTime.utc(2026, 10, 4),
          },
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
        final friend = (social['friends'] as List).single as Map<String, dynamic>;
        expect(friend['uid'], 'uid-bruno');
        expect(friend['nickname'], 'Bruno');
        expect(friend['since'], '2026-10-05T00:00:00.000Z');
        final received = (social['requestsReceived'] as List).single as Map<String, dynamic>;
        expect(received['uid'], 'uid-caio');
        expect(received['nickname'], 'Caio');
        expect(
          jsonEncode(social['friends']) + jsonEncode(social['requestsReceived']),
          isNot(contains('googleusercontent')),
        );
        expect(social['counts']['friends'], 1);
        expect(social['counts']['requestsReceived'], 1);
        expect(kExportSchemaVersion, 2, reason: 'same schema: the lists already existed');
      },
    );
  });

  test('the executor still picks transaction/batch from the payload mode only', () {
    final source = File('lib/data/firestore_social_data_source.dart').readAsStringSync();
    expect('runTransaction('.allMatches(source), hasLength(2));
    expect('_db.batch()'.allMatches(source), hasLength(1));
    // accept / decline / remove / crossed run payloads, never hand-built documents
    for (final name in ['acceptRequest', 'declineRequest', 'removeFriend']) {
      expect(source, contains('SocialPayloads.$name('), reason: name);
    }
    expect(RegExp(r"\.(set|update|delete)\(\s*_db\.collection\('friend").hasMatch(source), isFalse);
  });

  test('no PII in logs: the social data sources and providers never print names', () {
    for (final path in [
      'lib/data/firestore_social_data_source.dart',
      'lib/providers/social_providers.dart',
      'lib/providers/social_lists_providers.dart',
      'lib/repositories/social_repository.dart',
      'lib/screens/friends_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      for (final m in RegExp(r'(debugPrint|print)\(([^;]*)\);').allMatches(source)) {
        expect(m.group(2), isNot(contains('Name')), reason: path);
        expect(m.group(2), isNot(contains('nickname')), reason: path);
        expect(m.group(2), isNot(contains('uid')), reason: path);
      }
    }
  });
}
