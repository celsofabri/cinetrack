import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/repositories/social_repository.dart';
import 'package:cinetrack/social/invite_code.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/fake_social_cloud.dart';

/// Slice 5 (docs/68), part 1: the invite code, the link, the repository over the
/// in-memory fake (create / replace / revoke / open / use) and the refresh of
/// the friendship halves. The fake mirrors the data rules of `firestore.rules`;
/// the real rules run the very same payloads in `dart_payloads.test.mjs`.

const _photo = 'https://lh3.googleusercontent.com/a/ana';
const _brunoPhoto = 'https://lh4.googleusercontent.com/b';
const _me = SocialProfile(handle: 'ana', nickname: 'Ana', photoUrl: _photo, discoverable: true);

class _Rig {
  DateTime clock = DateTime.utc(2026, 10, 5, 12);
  late final cloud = FakeSocialCloud(now: () => clock);
  late final ds = InMemorySocialDataSource(cloud, uid: 'uid-ana');
  late final repo = SocialRepository(ds, now: () => clock, random: Random(7));

  _Rig() {
    cloud
      ..seedActive('uid-ana', 'ana', nickname: 'Ana', photoUrl: _photo)
      ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno', photoUrl: _brunoPhoto);
  }

  SocialRepository repoFor(String uid, {int pageSize = 400}) => SocialRepository(
    InMemorySocialDataSource(cloud, uid: uid),
    now: () => clock,
    pageSize: pageSize,
  );

  String? get code => cloud.social['uid-ana']?['inviteCode'] as String?;
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
  group('InviteCode', () {
    test('24 base62 characters in the format the rules accept', () {
      for (var i = 0; i < 200; i++) {
        final code = InviteCode.generate();
        expect(code, hasLength(InviteCode.length));
        expect(code.length, greaterThanOrEqualTo(22));
        expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(code), isTrue);
        expect(InviteCode.isValid(code), isTrue);
      }
      expect(InviteCode.alphabet, hasLength(62));
      expect(InviteCode.alphabet.split('').toSet(), hasLength(62));
    });

    test('the validity test is the one of firestore.rules', () {
      final rules = File('firestore.rules').readAsStringSync();
      expect(rules, contains(r"c.matches('^[A-Za-z0-9]{22,40}$')"));
      expect(InviteCode.isValid('A' * 22), isTrue);
      expect(InviteCode.isValid('A' * 40), isTrue);
      expect(InviteCode.isValid('A' * 21), isFalse);
      expect(InviteCode.isValid('A' * 41), isFalse);
      expect(InviteCode.isValid('${'A' * 23}_'), isFalse);
      expect(InviteCode.isValid('${'A' * 23}-'), isFalse);
      expect(InviteCode.isValid('${'A' * 23}\n'), isFalse);
      expect(InviteCode.isValid(''), isFalse);
    });

    test('unique over a large sample, and every character shows up (no skewed alphabet)', () {
      final seen = <String>{};
      final chars = <String>{};
      for (var i = 0; i < 20000; i++) {
        final code = InviteCode.generate();
        expect(seen.add(code), isTrue, reason: 'collision at $i');
        chars.addAll(code.split(''));
      }
      expect(chars, InviteCode.alphabet.split('').toSet());
    });

    test('draws exactly 24 values below 62 from the injected source (and nothing else)', () {
      final random = _Spy();
      final code = InviteCode.generate(random: random);
      expect(random.bounds, List.filled(24, 62));
      expect(code, hasLength(24));
    });

    test('a deterministic source gives a deterministic code (so it is injectable for tests)', () {
      expect(InviteCode.generate(random: Random(1)), InviteCode.generate(random: Random(1)));
      expect(InviteCode.generate(random: Random(1)), isNot(InviteCode.generate(random: Random(2))));
    });

    test('never derived from the uid, the clock or a counter: the source file says so', () {
      final src = File('lib/social/invite_code.dart').readAsStringSync();
      final code = src.substring(
        src.indexOf('static String generate'),
        src.indexOf('static String? parse'),
      );
      expect(code, contains('Random.secure()'));
      expect(code, isNot(contains('DateTime')));
      expect(code, isNot(contains('uid')));
      expect(code, isNot(contains('hashCode')));
      expect(code, isNot(contains('Stopwatch')));
    });

    test('two codes made in the same instant for the same user share nothing predictable', () {
      final codes = [for (var i = 0; i < 5; i++) InviteCode.generate()];
      expect(codes.toSet(), hasLength(5));
      for (final c in codes) {
        expect(c.startsWith(codes.first.substring(0, 6)) && c != codes.first, isFalse);
      }
    });

    test('parse: bare code, hash link, path link, with noise around; nothing else', () {
      const c = 'AbCdEfGhIjKlMnOpQrStUv12';
      expect(InviteCode.parse(c), c);
      expect(InviteCode.parse('  $c\n'), c);
      expect(InviteCode.parse('https://x.github.io/cinetrack/#/invite/$c'), c);
      expect(InviteCode.parse('https://x.github.io/cinetrack/invite/$c'), c);
      expect(InviteCode.parse('Vem ser meu amigo! https://x.io/#/invite/$c valeu'), c);
      expect(InviteCode.parse('https://x.io/#/invite/${c.substring(0, 21)}'), isNull);
      expect(InviteCode.parse('https://x.io/#/invite/${'A' * 41}'), isNull);
      expect(InviteCode.parse('banana'), isNull);
      expect(InviteCode.parse(''), isNull);
      expect(InviteCode.parse('https://x.io/#/friends'), isNull);
    });
  });

  group('InviteValidity', () {
    test('options 1, 7 and 30 days; default 7; never over the 30-day cap', () {
      expect(InviteValidity.options, [1, 7, 30]);
      expect(InviteValidity.defaultDays, 7);
      expect(InviteValidity.duration(1), const Duration(days: 1));
      expect(InviteValidity.duration(7), const Duration(days: 7));
      final longest = InviteValidity.duration(30);
      expect(longest, lessThan(const Duration(days: 30)));
      expect(longest, greaterThan(const Duration(days: 29)));
      expect(InviteValidity.duration(99), longest);
      expect(InviteValidity.duration(0), const Duration(days: 1));
    });
  });

  group('InviteLink (hash URLs, base href /cinetrack/)', () {
    const c = 'AbCdEfGhIjKlMnOpQrStUv12';

    test('under the GitHub Pages base href', () {
      expect(
        InviteLink.build(Uri.parse('https://user.github.io/cinetrack/'), c),
        'https://user.github.io/cinetrack/#/invite/$c',
      );
    });

    test('drops any query or old fragment, keeps a port, defaults the path to /', () {
      expect(
        InviteLink.build(Uri.parse('http://localhost:8080/?utm=1#/friends'), c),
        'http://localhost:8080/#/invite/$c',
      );
      expect(InviteLink.build(Uri.parse('https://x.io'), c), 'https://x.io/#/invite/$c');
    });

    test('what the link holds is read back by parse', () {
      final link = InviteLink.build(Uri.parse('https://user.github.io/cinetrack/'), c);
      expect(InviteCode.parse(link), c);
      expect(Uri.parse(link).fragment, '/invite/$c');
      expect(Uri.parse(link).path, '/cinetrack/');
    });
  });

  group('InviteInfo', () {
    final now = DateTime.utc(2026, 10, 5, 12);

    test('expiry, days left (rounded up), missing document', () {
      InviteInfo at(DateTime? e) => InviteInfo(code: 'A' * 24, expiresAt: e);
      expect(at(now.add(const Duration(days: 7))).daysLeft(now), 7);
      expect(at(now.add(const Duration(hours: 1))).daysLeft(now), 1);
      expect(at(now.subtract(const Duration(seconds: 1))).isExpired(now), isTrue);
      expect(at(now).isExpired(now), isTrue, reason: 'the rules need expiresAt > now');
      expect(at(now.subtract(const Duration(days: 1))).daysLeft(now), 0);
      expect(const InviteInfo(code: 'A', missing: true).isExpired(now), isTrue);
      expect(at(null).isExpired(now), isFalse);
    });

    test('fromRaw: no pointer / bad pointer = none; pointer without document = missing', () {
      expect(InviteInfo.fromRaw(null, {'expiresAt': now}), isNull);
      expect(InviteInfo.fromRaw('curto', {'expiresAt': now}), isNull);
      expect(InviteInfo.fromRaw('A' * 24, null)!.missing, isTrue);
      final info = InviteInfo.fromRaw('A' * 24, {'expiresAt': now, 'createdAt': now})!;
      expect((info.missing, info.expiresAt, info.createdAt), (false, now, now));
    });
  });

  group('create / replace / revoke (ONE transaction each)', () {
    test('create writes the invite and the pointer, with the card copy and the expiry', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      final code = r.code!;
      expect(InviteCode.isValid(code), isTrue);
      final invite = r.cloud.invites[code]!;
      expect(invite['uid'], 'uid-ana');
      expect(invite['nickname'], 'Ana');
      expect(invite['photoURL'], _photo);
      expect(invite['createdAt'], r.clock);
      expect(invite['expiresAt'], r.clock.add(const Duration(days: 7)));
      expect(r.cloud.log, ['createInvite']);
      expect(r.cloud.invites, hasLength(1));
    });

    test(
      'the code comes from the injected source (tests) and is never the uid or the time',
      () async {
        final r = _Rig();
        await r.repo.createInvite(me: _me);
        expect(r.code, InviteCode.generate(random: Random(7)));
        expect(r.code, isNot(contains('ana')));
        expect(r.code, isNot(contains('2026')));
      },
    );

    test('validity options reach the document (1, 7, 30 days)', () async {
      for (final days in InviteValidity.options) {
        final r = _Rig();
        await r.repo.createInvite(me: _me, days: days);
        final expires = r.cloud.invites[r.code]!['expiresAt'] as DateTime;
        expect(expires.difference(r.clock), InviteValidity.duration(days));
        expect(expires.difference(r.clock), lessThanOrEqualTo(const Duration(days: 30)));
      }
    });

    test('a user without a photo gets no photoURL key', () async {
      final r = _Rig();
      await r.repo.createInvite(
        me: const SocialProfile(handle: 'ana', nickname: 'Ana'),
      );
      expect(r.cloud.invites[r.code]!.containsKey('photoURL'), isFalse);
    });

    test('a photo outside Google is never copied (the write would fail as a whole)', () async {
      final r = _Rig();
      await r.repo.createInvite(
        me: const SocialProfile(handle: 'ana', nickname: 'Ana', photoUrl: 'https://evil.example/x'),
      );
      expect(r.cloud.invites[r.code]!.containsKey('photoURL'), isFalse);
    });

    test('a second create REPLACES the first: one active invite, the old link is dead', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      final first = r.code!;
      await r.repo.createInvite(me: _me);
      final second = r.code!;
      expect(second, isNot(first));
      expect(r.cloud.invites.keys, [second]);
      expect(r.cloud.leftoversOf('uid-ana').where((e) => e.startsWith('invites/')), hasLength(1));
      expect(await r.repoFor('uid-bruno').openInvite(first), isA<InviteUnavailable>());
      expect(await r.repoFor('uid-bruno').openInvite(second), isA<InviteFound>());
    });

    test('an orphan pointer (the invite document is gone) is replaced without a delete', () async {
      final r = _Rig();
      r.cloud.social['uid-ana'] = {...r.cloud.social['uid-ana']!, 'inviteCode': 'Z' * 24};
      await r.repo.createInvite(me: _me);
      expect(r.cloud.invites, hasLength(1));
      expect(r.code, isNot('Z' * 24));
    });

    test('revoke deletes the invite and the pointer; the link stops working at once', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      final code = r.code!;
      expect(await r.repoFor('uid-bruno').openInvite(code), isA<InviteFound>());
      await r.repo.revokeInvite();
      expect(r.cloud.invites, isEmpty);
      expect(r.cloud.social['uid-ana']!.containsKey('inviteCode'), isFalse);
      expect(await r.repoFor('uid-bruno').openInvite(code), isA<InviteUnavailable>());
      expect(r.cloud.social['uid-ana']!['handle'], 'ana', reason: 'the account is untouched');
    });

    test('revoking with nothing to revoke, or twice, is not an error', () async {
      final r = _Rig();
      await r.repo.revokeInvite();
      await r.repo.createInvite(me: _me);
      await r.repo.revokeInvite();
      await r.repo.revokeInvite();
      expect(r.cloud.invites, isEmpty);
    });

    test('create is possible again after revoking', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      await r.repo.revokeInvite();
      await r.repo.createInvite(me: _me);
      expect(r.cloud.invites, hasLength(1));
    });

    test('friendships off: nothing is written (notActive)', () async {
      final r = _Rig();
      final off = r.repoFor('uid-caio');
      final failure = await _fail(off.createInvite(me: _me));
      expect(failure?.kind, SocialFailureKind.notActive);
      expect(r.cloud.invites, isEmpty);
      expect(r.cloud.log, isEmpty);
    });

    test('without a nickname there is nothing to copy: invalid, nothing written', () async {
      final r = _Rig();
      final failure = await _fail(r.repo.createInvite(me: const SocialProfile(handle: 'ana')));
      expect(failure?.kind, SocialFailureKind.invalid);
      expect(r.cloud.log, isEmpty);
    });

    test('rules not published / denied: a visible failure, nothing lost', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      final before = r.code;
      r.cloud.failures['createInvite'] = const SocialFailure(
        SocialFailureKind.denied,
        code: 'permission-denied',
      );
      final failure = await _fail(r.repo.createInvite(me: _me));
      expect(failure?.kind, SocialFailureKind.inviteFailed);
      expect(failure!.message, contains('data e a hora do aparelho'));
      expect(r.code, before, reason: 'the old invite is still there');
      expect(r.cloud.invites, hasLength(1));

      r.cloud.failures['revokeInvite'] = const SocialFailure(SocialFailureKind.denied);
      expect((await _fail(r.repo.revokeInvite()))?.kind, SocialFailureKind.inviteFailed);
      expect(r.cloud.invites, hasLength(1));
    });

    test('offline: the failure is the usual one and the invite stays', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      r.cloud.offline = true;
      expect((await _fail(r.repo.revokeInvite()))?.kind, SocialFailureKind.offline);
      expect((await _fail(r.repo.createInvite(me: _me)))?.kind, SocialFailureKind.offline);
      expect(r.cloud.invites, hasLength(1));
    });

    test('load() brings the invite along (one extra read only when there is one)', () async {
      final r = _Rig();
      expect((await r.repo.load()).profile!.invite, isNull);
      await r.repo.createInvite(me: _me);
      final invite = (await r.repo.load()).profile!.invite!;
      expect(invite.code, r.code);
      expect(invite.expiresAt, r.clock.add(const Duration(days: 7)));
      expect(invite.isExpired(r.clock), isFalse);
      expect(invite.isExpired(r.clock.add(const Duration(days: 8))), isTrue);
    });
  });

  group('open and use the link (ONE get, ONE generic answer)', () {
    Future<String> inviteOf(_Rig r, {String as = 'uid-ana'}) async {
      final repo = r.repoFor(as);
      await repo.createInvite(
        me: SocialProfile(handle: as.replaceFirst('uid-', ''), nickname: 'Ana'),
      );
      return r.cloud.social[as]!['inviteCode']! as String;
    }

    test('a valid link shows the card with ONE read; no handle is revealed', () async {
      final r = _Rig();
      final code = await inviteOf(r);
      r.cloud.readLog.clear();
      final outcome = await r.repoFor('uid-bruno').openInvite(code);
      expect(r.cloud.readLog, ['lookupInvite']);
      final card = (outcome as InviteFound).card;
      expect((card.uid, card.nickname, card.handle), ('uid-ana', 'Ana', ''));
    });

    test('works with "Aparecer na busca" OFF (the handle card stays hidden)', () async {
      final r = _Rig();
      r.cloud.handles['ana']!['discoverable'] = false;
      final code = await inviteOf(r);
      expect(await r.repoFor('uid-bruno').openInvite(code), isA<InviteFound>());
      expect(
        (await r.repoFor('uid-bruno').search('ana', ownHandle: 'bruno')),
        isA<SearchNotFound>(),
      );
    });

    test('bad format: unavailable WITHOUT touching the server', () async {
      final r = _Rig();
      for (final bad in ['', 'curto', 'A' * 41, '${'A' * 23}_', ' ']) {
        expect(await r.repoFor('uid-bruno').openInvite(bad), isA<InviteUnavailable>());
      }
      expect(r.cloud.readLog, isEmpty);
    });

    test(
      'never existed, revoked, expired, owner blocked me, I blocked the owner, my own: ALL the same',
      () async {
        final r = _Rig();
        final code = await inviteOf(r);
        final bruno = r.repoFor('uid-bruno');
        final answers = <String, InviteOutcome>{};

        answers['never existed'] = await bruno.openInvite('Q' * 24);

        r.clock = r.clock.add(const Duration(days: 8)); // expired
        answers['expired'] = await bruno.openInvite(code);
        r.clock = DateTime.utc(2026, 10, 5, 12);

        r.cloud.seedBlock('uid-ana', 'uid-bruno'); // Ana blocked Bruno
        answers['owner blocked me'] = await bruno.openInvite(code);
        r.cloud.blocks['uid-ana']!.clear();
        r.cloud.seedBlock('uid-bruno', 'uid-ana'); // Bruno blocked Ana
        answers['I blocked the owner'] = await bruno.openInvite(code);
        r.cloud.blocks['uid-bruno']!.clear();

        answers['my own'] = await r.repo.openInvite(code);

        await r.repo.revokeInvite();
        answers['revoked'] = await bruno.openInvite(code);

        expect(answers.keys, hasLength(6));
        for (final e in answers.entries) {
          expect(e.value, isA<InviteUnavailable>(), reason: e.key);
        }
        expect(kInviteUnavailableMessage, 'Este convite não está disponível.');
      },
    );

    test(
      'a signed-in stranger with friendships OFF can still read it (rules need only a login)',
      () async {
        final r = _Rig();
        final code = await inviteOf(r);
        expect(await r.repoFor('uid-caio').openInvite(code), isA<InviteFound>());
      },
    );

    test('offline / quota are real errors (not "unavailable")', () async {
      final r = _Rig();
      final code = await inviteOf(r);
      r.cloud.offline = true;
      expect(
        (await _fail(r.repoFor('uid-bruno').openInvite(code)))?.kind,
        SocialFailureKind.offline,
      );
      r.cloud.offline = false;
      r.cloud.failures['lookupInvite'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      expect(
        (await _fail(r.repoFor('uid-bruno').openInvite(code)))?.kind,
        SocialFailureKind.quotaExceeded,
      );
    });

    test('a card whose nickname cleans to nothing shows as "Usuário"', () async {
      final r = _Rig();
      final code = await inviteOf(r);
      r.cloud.invites[code]!['nickname'] = '​';
      final card = ((await r.repoFor('uid-bruno').openInvite(code)) as InviteFound).card;
      expect(card.nickname, 'Usuário');
    });

    test(
      'using it sends a NORMAL request (never a friendship); the owner still has to accept',
      () async {
        final r = _Rig();
        final code = await inviteOf(r);
        final bruno = r.repoFor('uid-bruno');
        final card = ((await bruno.openInvite(code)) as InviteFound).card;
        final outcome = await bruno.sendRequest(
          card,
          me: const SocialProfile(handle: 'bruno', nickname: 'Bruno'),
        );
        expect(outcome, SendOutcome.requested);
        expect(r.cloud.requests.keys, ['uid-bruno_uid-ana']);
        expect(r.cloud.requests['uid-bruno_uid-ana']!['toName'], 'Ana');
        expect(r.cloud.friendships, isEmpty);
        // she accepts like any other request
        final received = (await r.repo.receivedRequests()).items.single;
        await r.repo.acceptRequest(received, me: _me);
        expect(r.cloud.friendships, hasLength(1));
      },
    );

    test('a request through an invite of somebody who blocked me is the generic notSent', () async {
      final r = _Rig();
      final code = await inviteOf(r);
      final bruno = r.repoFor('uid-bruno');
      final card = ((await bruno.openInvite(code)) as InviteFound).card;
      r.cloud.seedBlock('uid-ana', 'uid-bruno');
      final failure = await _fail(
        bruno.sendRequest(
          card,
          me: const SocialProfile(handle: 'bruno', nickname: 'Bruno'),
        ),
      );
      expect(failure?.kind, SocialFailureKind.notSent);
    });

    test('already asked: alreadySent; they asked first: it becomes a friendship (D4)', () async {
      final r = _Rig();
      final code = await inviteOf(r);
      final bruno = r.repoFor('uid-bruno');
      final card = ((await bruno.openInvite(code)) as InviteFound).card;
      const me = SocialProfile(handle: 'bruno', nickname: 'Bruno');
      await bruno.sendRequest(card, me: me);
      expect((await _fail(bruno.sendRequest(card, me: me)))?.kind, SocialFailureKind.alreadySent);

      final r2 = _Rig();
      final code2 = await inviteOf(r2);
      r2.cloud.seedRequest('uid-ana', 'uid-bruno', fromName: 'Ana', toName: 'Bruno');
      final b2 = r2.repoFor('uid-bruno');
      final card2 = ((await b2.openInvite(code2)) as InviteFound).card;
      expect(await b2.sendRequest(card2, me: me), SendOutcome.becameFriends);
      expect(r2.cloud.friendships, hasLength(1));
    });
  });

  group('card changes follow into the invite copy', () {
    test('nickname and photo are copied in the same transaction as the card', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      await r.repo.updateNickname('Ana Nova');
      expect(r.cloud.handles['ana']!['nickname'], 'Ana Nova');
      expect(r.cloud.invites[r.code]!['nickname'], 'Ana Nova');
      await r.repo.setPhotoVisible(false);
      expect(r.cloud.invites[r.code]!['photoURL'], isNull);
      await r.repo.setPhotoVisible(true, googlePhotoUrl: _photo);
      expect(r.cloud.invites[r.code]!['photoURL'], _photo);
    });

    test('"Aparecer na busca" never touches the invite', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      final before = {...r.cloud.invites[r.code]!};
      await r.repo.setDiscoverable(false);
      expect(r.cloud.invites[r.code], before);
    });

    test(
      'an expired invite is left alone (the rules would refuse the update) and the card still changes',
      () async {
        final r = _Rig();
        await r.repo.createInvite(me: _me);
        r.clock = r.clock.add(const Duration(days: 8));
        await r.repo.updateNickname('Ana Nova');
        expect(r.cloud.handles['ana']!['nickname'], 'Ana Nova');
        expect(r.cloud.invites[r.code]!['nickname'], 'Ana');
      },
    );
  });

  group('refresh of my half in the friendships (D8)', () {
    // Ana ('uid-ana') is member A of pairs with uid-b*, member B of pairs with uid-0*.
    void seedPairs(_Rig r, {int asA = 2, int asB = 2}) {
      for (var i = 0; i < asA; i++) {
        r.cloud
          ..seedActive('uid-b$i', 'b$i', nickname: 'B$i')
          ..seedFriendship('uid-ana', 'uid-b$i', aName: 'Ana Velha', bName: 'B$i');
      }
      for (var i = 0; i < asB; i++) {
        r.cloud
          ..seedActive('uid-0$i', 'z$i', nickname: 'Z$i')
          ..seedFriendship('uid-0$i', 'uid-ana', aName: 'Z$i', bName: 'Ana Velha');
      }
    }

    String? nameOf(_Rig r, String key, {required bool ana}) {
      final doc = r.cloud.friendships[key]!;
      final members = doc['members'] as List;
      final isA = members[0] == 'uid-ana';
      return (ana ? (isA ? doc['aName'] : doc['bName']) : (isA ? doc['bName'] : doc['aName']))
          as String?;
    }

    test('writes only MY half, as A and as B; the other half is untouched; ONE batch', () async {
      final r = _Rig();
      seedPairs(r);
      r.cloud.log.clear();
      final result = await r.repo.refreshFriendHalves();
      expect((result.scanned, result.updated), (4, 4));
      expect(r.cloud.log, ['refreshHalves:4']);
      for (final key in r.cloud.friendships.keys) {
        expect(nameOf(r, key, ana: true), 'Ana');
      }
      expect(nameOf(r, 'uid-ana_uid-b0', ana: false), 'B0');
      expect(nameOf(r, 'uid-0${1}_uid-ana', ana: false), 'Z1');
      expect(r.cloud.friendships['uid-ana_uid-b0']!['aPhoto'], _photo);
      expect(r.cloud.friendships['uid-0${0}_uid-ana']!['bPhoto'], _photo);
    });

    test('idempotent: a second run reads but writes nothing', () async {
      final r = _Rig();
      seedPairs(r);
      await r.repo.refreshFriendHalves();
      r.cloud.log.clear();
      final again = await r.repo.refreshFriendHalves();
      expect((again.scanned, again.updated), (4, 0));
      expect(r.cloud.log, isEmpty);
    });

    test('only the pairs that differ are written; a removed photo becomes null', () async {
      final r = _Rig();
      seedPairs(r, asA: 3, asB: 0);
      await r.repo.refreshFriendHalves();
      r.cloud.handles['ana']!['photoURL'] = null;
      r.cloud.friendships['uid-ana_uid-b1']!['aName'] = 'Ana';
      r.cloud.friendships['uid-ana_uid-b1']!['aPhoto'] = null;
      r.cloud.log.clear();
      final result = await r.repo.refreshFriendHalves();
      expect(result.updated, 2, reason: 'b0 and b2 still carry the old photo, b1 is current');
      expect(r.cloud.friendships['uid-ana_uid-b0']!['aPhoto'], isNull);
    });

    test('300 friends = 3 reads of 100 and 3 batches; the cursor walks the whole list', () async {
      final r = _Rig();
      for (var i = 0; i < 300; i++) {
        final id = 'uid-f${i.toString().padLeft(3, '0')}';
        r.cloud.seedFriendship('uid-ana', id, aName: 'Ana Velha', bName: 'F$i');
      }
      r.cloud.readLog.clear();
      final result = await r.repo.refreshFriendHalves();
      expect((result.scanned, result.updated), (300, 300));
      expect(r.cloud.log, ['refreshHalves:100', 'refreshHalves:100', 'refreshHalves:100']);
      expect(r.cloud.readLog.where((e) => e == 'friends:page'), hasLength(3));
      expect(kRefreshPageSize, 100);
    });

    test('nobody is told: nothing but the friendship documents is written', () async {
      final r = _Rig();
      seedPairs(r);
      final requests = {...r.cloud.requests};
      final handles = {
        for (final e in r.cloud.handles.entries) e.key: {...e.value},
      };
      await r.repo.refreshFriendHalves();
      expect(r.cloud.requests, requests);
      expect(r.cloud.handles, handles);
      expect(r.cloud.blocks, isEmpty);
    });

    test(
      'a pair removed between the read and the write: the page is read again and finishes',
      () async {
        final r = _Rig();
        seedPairs(r);
        var first = true;
        r.cloud.beforeUpdateHalves = () {
          if (!first) return;
          first = false;
          r.cloud.friendships.remove('uid-ana_uid-b0'); // a friend removes me mid-pass
        };
        final result = await r.repo.refreshFriendHalves();
        expect(result.updated, 3);
        expect(
          r.cloud.friendships.containsKey('uid-ana_uid-b0'),
          isFalse,
          reason: 'not resurrected',
        );
        expect(nameOf(r, 'uid-ana_uid-b1', ana: true), 'Ana');
      },
    );

    test('same with the SDK saying not-found', () async {
      final r = _Rig();
      seedPairs(r);
      r.cloud.failures['updateHalves'] = const SocialFailure(
        SocialFailureKind.unknown,
        code: 'not-found',
      );
      r.cloud.beforeUpdateHalves = () => r.cloud.friendships.remove('uid-ana_uid-b0');
      final result = await r.repo.refreshFriendHalves();
      expect(result.updated, 3);
    });

    test(
      'a denial while every pair still exists is REAL: it shows, nothing is swallowed',
      () async {
        final r = _Rig();
        seedPairs(r);
        r.cloud.failures['updateHalves'] = const SocialFailure(
          SocialFailureKind.denied,
          code: 'permission-denied',
        );
        final failure = await _fail(r.repo.refreshFriendHalves());
        expect(failure?.kind, SocialFailureKind.denied);
        expect(r.cloud.log, isEmpty);
      },
    );

    test(
      'a failure in the middle leaves a prefix done and the next run finishes the rest',
      () async {
        final r = _Rig();
        for (var i = 0; i < 250; i++) {
          final id = 'uid-f${i.toString().padLeft(3, '0')}';
          r.cloud.seedFriendship('uid-ana', id, aName: 'Ana Velha', bName: 'F$i');
        }
        var batches = 0;
        r.cloud.beforeUpdateHalves = () {
          batches++;
          if (batches == 2) {
            throw const SocialFailure(SocialFailureKind.offline, code: 'unavailable');
          }
        };
        final failure = await _fail(r.repo.refreshFriendHalves());
        expect(failure?.kind, SocialFailureKind.offline);
        final done = r.cloud.friendships.values.where((d) => d['aName'] == 'Ana').length;
        expect(done, 100, reason: 'the first batch is complete, the second never started');
        r.cloud.beforeUpdateHalves = null;
        r.cloud.log.clear();
        final resumed = await r.repo.refreshFriendHalves();
        expect(resumed.updated, 150, reason: 'only what is missing is written');
        expect(r.cloud.friendships.values.every((d) => d['aName'] == 'Ana'), isTrue);
      },
    );

    test(
      'a page answered from the device (offline) is refused: it could hide stale halves',
      () async {
        final r = _Rig();
        seedPairs(r);
        // read() for the card must work, the pages come "from cache"
        r.cloud.cachedPages = true;
        final failure = await _fail(r.repo.refreshFriendHalves());
        expect(failure?.kind, SocialFailureKind.offline);
        expect(r.cloud.log, isEmpty);
      },
    );

    test('friendships off: nothing to do and nothing written', () async {
      final r = _Rig();
      seedPairs(r);
      final result = await r.repoFor('uid-caio').refreshFriendHalves();
      expect((result.scanned, result.updated), (0, 0));
      expect(r.cloud.log, isEmpty);
    });

    test('cancelled between steps: stops before writing', () async {
      final r = _Rig();
      seedPairs(r);
      final result = await r.repo.refreshFriendHalves(cancelled: () => true);
      expect(result.updated, 0);
      expect(r.cloud.log, isEmpty);
    });

    test(
      'the data rule is mirrored: a write into the other half or with a bad name is refused whole',
      () async {
        final r = _Rig();
        seedPairs(r, asA: 1, asB: 0);
        final failure = await _fail(
          r.ds.updateFriendHalves(const [
            FriendHalfUpdate(pairKey: 'uid-ana_uid-b0', meIsA: false, name: 'Forjado'),
          ]),
        );
        expect(failure?.kind, SocialFailureKind.denied);
        expect(nameOf(r, 'uid-ana_uid-b0', ana: false), 'B0');
      },
    );
  });

  group('deactivate and account deletion with an invite made by the app', () {
    test('deactivate deletes the invite, the pointer and everything else (no orphan)', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      final code = r.code!;
      r.cloud.seedFriendship('uid-ana', 'uid-bruno');
      await r.repo.deactivate();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      expect(r.cloud.invites.containsKey(code), isFalse);
      expect(await r.repoFor('uid-bruno').openInvite(code), isA<InviteUnavailable>());
    });

    test('account deletion deletes the invite too, and a second run is a no-op', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      r.cloud.seedFriendship('uid-ana', 'uid-bruno');
      await r.repo.wipeForAccountDeletion();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      await r.repo.wipeForAccountDeletion();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
    });

    test('the invite of somebody else is never touched', () async {
      final r = _Rig();
      await r.repo.createInvite(me: _me);
      await r
          .repoFor('uid-bruno')
          .createInvite(
            me: const SocialProfile(handle: 'bruno', nickname: 'Bruno'),
          );
      await r.repo.deactivate();
      expect(r.cloud.invites.values.map((i) => i['uid']), ['uid-bruno']);
    });
  });
}

/// A [Random] that only records the bound of every `nextInt`.
class _Spy implements Random {
  final bounds = <int>[];
  final _inner = Random(3);

  @override
  int nextInt(int max) {
    bounds.add(max);
    return _inner.nextInt(max);
  }

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}
