import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/export/data_exporter.dart';
import 'package:cinetrack/export/export_serializer.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:cinetrack/repositories/social_repository.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/social/social_validation.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_export_data_source.dart';
import 'support/fake_social_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

const _photo = 'https://lh3.googleusercontent.com/a/ana';
const _me = SocialProfile(handle: 'ana', nickname: 'Ana', photoUrl: _photo, discoverable: true);

class _Rig {
  DateTime clock = DateTime.utc(2026, 10, 5, 12);
  late final cloud = FakeSocialCloud(now: () => clock);
  late final ds = InMemorySocialDataSource(cloud, uid: 'uid-ana');
  late final repo = SocialRepository(ds, now: () => clock);

  _Rig() {
    cloud
      ..seedActive('uid-ana', 'ana', nickname: 'Ana', photoUrl: _photo)
      ..seedActive(
        'uid-bruno',
        'bruno',
        nickname: 'Bruno',
        photoUrl: 'https://lh4.googleusercontent.com/b',
      );
  }

  Future<FriendCard> bruno() async =>
      ((await repo.search('bruno', ownHandle: 'ana')) as SearchFound).card;
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
  group('search (one get, one generic answer)', () {
    test('finds a discoverable person with ONE read; handle is normalized', () async {
      final r = _Rig();
      final outcome = await r.repo.search('  @Bruno ', ownHandle: 'ana');
      expect(outcome, isA<SearchFound>());
      final card = (outcome as SearchFound).card;
      expect((card.uid, card.handle, card.nickname), ('uid-bruno', 'bruno', 'Bruno'));
      expect(card.photoUrl, 'https://lh4.googleusercontent.com/b');
      expect(r.cloud.readLog, ['lookup:bruno']);
    });

    test('missing, hidden, blocked either way, yourself, reserved: the SAME answer', () async {
      final r = _Rig();
      r.cloud
        ..seedActive('uid-oculta', 'oculta', discoverable: false)
        ..seedActive('uid-bloqueou', 'bloqueou')
        ..seedActive('uid-bloqueado', 'bloqueado')
        ..seedBlock('uid-bloqueou', 'uid-ana')
        ..seedBlock('uid-ana', 'uid-bloqueado');
      for (final handle in [
        'ninguem',
        'oculta',
        'bloqueou',
        'bloqueado',
        'ana', // yourself
        'admin', // reserved
      ]) {
        final outcome = await r.repo.search(handle, ownHandle: 'ana');
        expect(outcome, isA<SearchNotFound>(), reason: handle);
      }
      // nothing is read for yourself or a reserved handle
      expect(r.cloud.readLog, [
        'lookup:ninguem',
        'lookup:oculta',
        'lookup:bloqueou',
        'lookup:bloqueado',
      ]);
    });

    test('the card of your own uid under another handle is "not found" too', () async {
      final r = _Rig();
      r.cloud.seedActive('uid-ana', 'ana_velho'); // stale own handle on this device
      final outcome = await r.repo.search('ana_velho', ownHandle: 'ana');
      expect(outcome, isA<SearchNotFound>());
    });

    test('rules not published: the search says "not found" (the screen is gated before)', () async {
      final r = _Rig()..cloud.rulesLive = false;
      expect(await r.repo.search('bruno', ownHandle: 'ana'), isA<SearchNotFound>());
    });

    test('transport problems are NOT "not found": offline, quota', () async {
      final r = _Rig();
      r.cloud.offline = true;
      expect((await _fail(r.repo.search('bruno')))!.kind, SocialFailureKind.offline);
      r.cloud.offline = false;
      r.cloud.failures['lookup'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      expect((await _fail(r.repo.search('bruno')))!.kind, SocialFailureKind.quotaExceeded);
    });

    test('invalid format throws with the pt-BR reason and reads nothing', () async {
      final r = _Rig();
      for (final bad in ['', 'ab', 'a b', '_ana', 'ana_', 'Ânia', 'x' * 21]) {
        final f = await _fail(r.repo.search(bad));
        expect(f?.kind, SocialFailureKind.invalid, reason: bad);
      }
      expect(r.cloud.readLog, isEmpty);
    });

    test(
      'the card is cleaned for display: invisible characters, foreign photo, empty name',
      () async {
        final r = _Rig();
        r.cloud
          ..seedActive(
            'uid-x',
            'xis',
            nickname: 'X\u200Bis\u202E',
            photoUrl: 'https://evil.example/p',
          )
          ..seedActive('uid-y', 'yara', nickname: '\u200B\u3000');
        final x = ((await r.repo.search('xis')) as SearchFound).card;
        expect(x.nickname, 'Xis');
        expect(x.photoUrl, isNull);
        final y = ((await r.repo.search('yara')) as SearchFound).card;
        expect(y.nickname, '@yara');
      },
    );

    test('validators: reserved handles are searchable text, the rest follow the rules', () {
      expect(Handle.searchErrorFor('admin'), isNull);
      expect(Handle.errorFor('admin'), isNotNull);
      expect(Handle.searchErrorFor('ab'), isNotNull);
    });
  });

  group('send request', () {
    test('creates friend_requests/{me}_{to} with both names and photos', () async {
      final r = _Rig();
      await r.repo.sendRequest(await r.bruno(), me: _me);
      final doc = r.cloud.requests['uid-ana_uid-bruno']!;
      expect(doc['from'], 'uid-ana');
      expect(doc['to'], 'uid-bruno');
      expect(doc['fromName'], 'Ana');
      expect(doc['fromPhoto'], _photo);
      expect(doc['toName'], 'Bruno');
      expect(doc['toPhoto'], 'https://lh4.googleusercontent.com/b');
      expect(r.cloud.requests, hasLength(1));
    });

    test('without photos the keys are simply absent', () async {
      final r = _Rig();
      r.cloud.seedActive('uid-c', 'caio', nickname: 'Caio');
      final card = ((await r.repo.search('caio')) as SearchFound).card;
      await r.repo.sendRequest(
        card,
        me: const SocialProfile(handle: 'ana', nickname: 'Ana'),
      );
      final doc = r.cloud.requests['uid-ana_uid-c']!;
      expect(doc.containsKey('fromPhoto'), isFalse);
      expect(doc.containsKey('toPhoto'), isFalse);
    });

    test('duplicate: "já enviou", and no second document is created', () async {
      final r = _Rig();
      final card = await r.bruno();
      await r.repo.sendRequest(card, me: _me);
      final created = r.cloud.requests['uid-ana_uid-bruno']!['createdAt'];
      r.clock = r.clock.add(const Duration(hours: 1));
      final f = await _fail(r.repo.sendRequest(card, me: _me));
      expect(f!.kind, SocialFailureKind.alreadySent);
      expect(r.cloud.requests, hasLength(1));
      expect(r.cloud.requests['uid-ana_uid-bruno']!['createdAt'], created);
    });

    test(
      'crossed request (D4): becomes a friendship; their request is consumed (slice 3)',
      () async {
        final r = _Rig();
        r.cloud.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno', toName: 'Ana');
        final outcome = await r.repo.sendRequest(await r.bruno(), me: _me);
        expect(outcome, SendOutcome.becameFriends);
        expect(r.cloud.requests, isEmpty, reason: 'no request left in either direction');
        expect(r.cloud.friendships.keys, ['uid-ana_uid-bruno']);
        final pair = r.cloud.friendships['uid-ana_uid-bruno']!;
        expect(pair['members'], ['uid-ana', 'uid-bruno']);
        expect(pair['aName'], 'Ana');
        expect(pair['bName'], 'Bruno', reason: 'their half is exactly what THEIR request said');
      },
    );

    test('limit of 50 pending requests: refused before any write; 49 still works', () async {
      final r = _Rig();
      for (var i = 0; i < 49; i++) {
        r.cloud.seedRequest('uid-ana', 'uid-t$i');
      }
      await r.repo.sendRequest(await r.bruno(), me: _me); // the 50th
      expect(r.cloud.requests, hasLength(50));
      r.cloud.seedActive('uid-c', 'caio');
      final card = ((await r.repo.search('caio')) as SearchFound).card;
      final f = await _fail(r.repo.sendRequest(card, me: _me));
      expect(f!.kind, SocialFailureKind.limitReached);
      expect(f.message, contains('50'));
      expect(r.cloud.requests, hasLength(50));
    });

    test('a refusal by the rules is ONE generic message, whatever the reason', () async {
      final r = _Rig();
      final card = await r.bruno();
      // they blocked me after I searched / they have no social any more: same text
      r.cloud.seedBlock('uid-bruno', 'uid-ana');
      final blocked = await _fail(r.repo.sendRequest(card, me: _me));
      r.cloud.blocks.clear();
      r.cloud.social.remove('uid-bruno');
      final gone = await _fail(r.repo.sendRequest(card, me: _me));
      expect(blocked!.kind, SocialFailureKind.notSent);
      expect(gone!.kind, SocialFailureKind.notSent);
      expect(blocked.message, gone.message);
      expect(blocked.message, isNot(contains('bloque')));
      expect(r.cloud.requests, isEmpty);
    });

    test('offline: failure, nothing created; no nickname: asks for one', () async {
      final r = _Rig();
      final card = await r.bruno();
      r.cloud.offline = true;
      expect((await _fail(r.repo.sendRequest(card, me: _me)))!.kind, SocialFailureKind.offline);
      r.cloud.offline = false;
      final f = await _fail(r.repo.sendRequest(card, me: const SocialProfile(handle: 'ana')));
      expect(f!.kind, SocialFailureKind.invalid);
      expect(r.cloud.requests, isEmpty);
    });

    test('the count read happens once per send (not a list)', () async {
      final r = _Rig();
      await r.repo.sendRequest(await r.bruno(), me: _me);
      expect(r.cloud.readLog.where((e) => e == 'count'), hasLength(1));
      expect(r.cloud.readLog.where((e) => e == 'sent:page'), isEmpty);
    });
  });

  group('cancel and list', () {
    test('cancel deletes only my request to that person; repeating is harmless', () async {
      final r = _Rig();
      r.cloud
        ..seedRequest('uid-ana', 'uid-bruno')
        ..seedRequest('uid-bruno', 'uid-ana')
        ..seedRequest('uid-ana', 'uid-c');
      await r.repo.cancelRequest('uid-bruno');
      await r.repo.cancelRequest('uid-bruno');
      expect(r.cloud.requests.keys, unorderedEquals(['uid-bruno_uid-ana', 'uid-ana_uid-c']));
    });

    test('sent list: newest first, pages of N with a look-ahead, only my requests', () async {
      final r = _Rig();
      for (var i = 0; i < 5; i++) {
        r.cloud.requests['uid-ana_uid-t$i'] = {
          'from': 'uid-ana',
          'to': 'uid-t$i',
          'fromName': 'Ana',
          'toName': 'Pessoa $i',
          'createdAt': r.clock.add(Duration(days: i)),
        };
      }
      r.cloud.seedRequest('uid-bruno', 'uid-ana'); // received: not listed
      final p1 = await r.repo.sentRequests(pageSize: 2);
      expect(p1.items.map((e) => e.toName), ['Pessoa 4', 'Pessoa 3']);
      expect(p1.hasMore, isTrue);
      final p2 = await r.repo.sentRequests(cursor: p1.cursor, pageSize: 2);
      expect(p2.items.map((e) => e.toName), ['Pessoa 2', 'Pessoa 1']);
      expect(p2.hasMore, isTrue);
      final p3 = await r.repo.sentRequests(cursor: p2.cursor, pageSize: 2);
      expect(p3.items.map((e) => e.toName), ['Pessoa 0']);
      expect(p3.hasMore, isFalse);
    });

    test('mapping is tolerant: missing name, foreign photo, id as fallback for the uid', () async {
      final r = _Rig();
      r.cloud.requests['uid-ana_uid-z'] = {
        'from': 'uid-ana',
        'toName': '\u200B',
        'toPhoto': 'https://evil.example/x',
        'createdAt': r.clock,
      };
      final page = await r.repo.sentRequests();
      expect(page.items.single.toUid, 'uid-z');
      expect(page.items.single.toName, 'Usuário');
      expect(page.items.single.toPhoto, isNull);
    });

    test('offline: the device copy is flagged; nothing cached: offline failure', () async {
      final r = _Rig();
      r.cloud.seedRequest('uid-ana', 'uid-bruno', toName: 'Bruno');
      r.cloud.offline = true;
      final page = await r.repo.sentRequests();
      expect(page.fromCache, isTrue);
      expect(page.items, hasLength(1));
      r.cloud.cacheAvailable = false;
      expect((await _fail(r.repo.sentRequests()))!.kind, SocialFailureKind.offline);
    });
  });

  group('SentRequestsController (cache + TTL, no listener)', () {
    late FakeSocialCloud social;
    ProviderContainer make({Duration ttl = const Duration(minutes: 5), FakeLocalStore? store}) {
      social = FakeSocialCloud();
      social.seedActive('uid-ana', 'ana', nickname: 'Ana');
      social.seedActive('uid-bruno', 'bruno', nickname: 'Bruno');
      final auth = FakeAuthRepository(initialUser: kAna);
      final c = ProviderContainer(
        overrides: [
          ...cloudOverrides(auth: auth, cloud: FakeCloud(), socialCloud: social, store: store),
          sentRequestsTtlProvider.overrideWithValue(ttl),
        ],
      );
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      c.listen(syncStatusProvider, (_, _) {});
      c.listen(socialControllerProvider, (_, _) {});
      c.listen(sentRequestsControllerProvider, (_, _) {});
      return c;
    }

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('nothing is read until a screen asks; reopening within the TTL reads nothing', () async {
      final c = make();
      await settle();
      expect(social.readLog.where((e) => e == 'sent:page'), isEmpty);
      final controller = c.read(sentRequestsControllerProvider.notifier);
      await controller.ensureLoaded();
      await controller.ensureLoaded();
      await controller.ensureLoaded();
      expect(social.readLog.where((e) => e == 'sent:page'), hasLength(1));
      expect(c.read(sentRequestsControllerProvider).phase, SentPhase.loaded);
    });

    test('after the TTL the next open reads once more', () async {
      final c = make(ttl: Duration.zero);
      await settle();
      final controller = c.read(sentRequestsControllerProvider.notifier);
      await controller.ensureLoaded();
      await controller.ensureLoaded();
      expect(social.readLog.where((e) => e == 'sent:page'), hasLength(2));
    });

    test('sending adds to the list and cancelling removes, with no extra list read', () async {
      final c = make();
      await settle();
      final controller = c.read(sentRequestsControllerProvider.notifier);
      await controller.ensureLoaded();
      const card = FriendCard(uid: 'uid-bruno', handle: 'bruno', nickname: 'Bruno');
      expect((await controller.send(card)).failure, isNull);
      expect(c.read(sentRequestsControllerProvider).items.map((e) => e.toUid), ['uid-bruno']);
      expect(social.requests, hasLength(1));
      expect((await controller.send(card)).failure!.kind, SocialFailureKind.alreadySent);
      expect(await controller.cancel('uid-bruno'), isNull);
      expect(c.read(sentRequestsControllerProvider).items, isEmpty);
      expect(social.requests, isEmpty);
      expect(social.readLog.where((e) => e == 'sent:page'), hasLength(1));
    });

    test('deactivate then activate in the same session: the old list is gone (docs/60)', () async {
      final c = make();
      await settle();
      final ctl = c.read(socialControllerProvider.notifier);
      final sent = c.read(sentRequestsControllerProvider.notifier);
      await sent.ensureLoaded();
      const card = FriendCard(uid: 'uid-bruno', handle: 'bruno', nickname: 'Bruno');
      expect((await sent.send(card)).failure, isNull);
      expect(c.read(sentRequestsControllerProvider).items, hasLength(1));

      expect(await ctl.deactivate(), isNull);
      expect(social.requests, isEmpty); // the server deleted it
      expect(
        await ctl.activate(handle: 'ana', nickname: 'Ana', showPhoto: false, discoverable: true),
        isNull,
      );
      await settle();
      expect(c.read(sentRequestsControllerProvider).phase, SentPhase.idle);
      await c.read(sentRequestsControllerProvider.notifier).ensureLoaded();
      expect(c.read(sentRequestsControllerProvider).items, isEmpty);
      // and the same person can be asked again (no stale "já enviou")
      expect((await c.read(sentRequestsControllerProvider.notifier).send(card)).failure, isNull);
      expect(social.requests.keys, ['uid-ana_uid-bruno']);
    });

    test('signing out drops the list too', () async {
      final c = make();
      await settle();
      await c.read(sentRequestsControllerProvider.notifier).ensureLoaded();
      expect(c.read(sentRequestsControllerProvider).phase, SentPhase.loaded);
      await c.read(authControllerProvider.notifier).signOut();
      await settle();
      expect(c.read(sentRequestsControllerProvider).phase, SentPhase.idle);
    });

    test('a list that came from the device is not treated as fresh', () async {
      final c = make();
      await settle();
      social.offline = true;
      final controller = c.read(sentRequestsControllerProvider.notifier);
      await controller.ensureLoaded();
      expect(c.read(sentRequestsControllerProvider).fromCache, isTrue);
      social.offline = false;
      await controller.ensureLoaded();
      expect(c.read(sentRequestsControllerProvider).fromCache, isFalse);
    });

    test('a failed first page is an error with retry; a failed cancel keeps the item', () async {
      final c = make();
      await settle();
      social.failures['sentPage'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      final controller = c.read(sentRequestsControllerProvider.notifier);
      await controller.ensureLoaded();
      expect(c.read(sentRequestsControllerProvider).phase, SentPhase.error);
      await controller.reload();
      expect(c.read(sentRequestsControllerProvider).phase, SentPhase.loaded);
      social.seedRequest('uid-ana', 'uid-bruno');
      await controller.reload();
      social.offline = true;
      expect((await controller.cancel('uid-bruno'))!.kind, SocialFailureKind.offline);
      expect(c.read(sentRequestsControllerProvider).items, hasLength(1));
    });

    test(
      'deleting the account removes the local "limpeza pendente" key of that uid (docs/58)',
      () async {
        final store = FakeLocalStore()..socialCleanup.add('uid-ana');
        final c = make(store: store);
        await settle();
        expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
        expect(store.socialCleanup, isEmpty);
      },
    );
  });

  group('account deletion and export cover the sent requests', () {
    test('wipeForAccountDeletion removes requests sent through the app; others stay', () async {
      final r = _Rig();
      await r.repo.sendRequest(await r.bruno(), me: _me);
      r.cloud.seedActive('uid-c', 'caio');
      await r.repo.sendRequest(((await r.repo.search('caio')) as SearchFound).card, me: _me);
      r.cloud.seedRequest('uid-bruno', 'uid-c'); // unrelated
      expect(r.cloud.leftoversOf('uid-ana'), contains('friend_requests/uid-ana_uid-bruno'));
      await r.repo.wipeForAccountDeletion();
      expect(r.cloud.leftoversOf('uid-ana'), isEmpty);
      expect(r.cloud.requests.keys, ['uid-bruno_uid-c']);
    });

    test('export reads what slice 2 writes: uid and nickname of the recipient, no photo', () async {
      final draft = const SendRequestDraft(
        toUid: 'uid-bruno',
        fromHandle: 'ana',
        fromName: 'Ana',
        fromPhoto: _photo,
        toName: 'Bruno',
        toPhoto: 'https://lh4.googleusercontent.com/b',
      );
      final op = SocialPayloads.sendRequest('uid-ana', draft).ops.single;
      final stored = <String, dynamic>{
        for (final e in op.data!.entries)
          e.key: e.value is ServerTimestamp ? DateTime.utc(2026, 10, 5) : e.value,
      };
      final source = FakeExportDataSource({})..social = const RawSocial(social: {'handle': 'ana'});
      source.socialLists[SocialExportKind.requestsSent] = {'uid-ana_uid-bruno': stored};
      final file = await runExport(
        source: source,
        from: ExportSource.server,
        now: () => DateTime.utc(2026, 10, 5),
        isCurrent: () => true,
        uid: 'uid-ana',
      );
      final social =
          (jsonDecode(file.json) as Map<String, dynamic>)['social'] as Map<String, dynamic>;
      final sent = (social['requestsSent'] as List).single as Map<String, dynamic>;
      expect(sent['uid'], 'uid-bruno');
      expect(sent['nickname'], 'Bruno');
      expect(sent['createdAt'], '2026-10-05T00:00:00.000Z');
      expect(jsonEncode(sent), isNot(contains('googleusercontent')));
      expect(social['counts']['requestsSent'], 1);
      expect(kExportSchemaVersion, 2);
    });
  });

  test(
    'the executor picks transaction/batch from the payload mode, never per method (docs/58)',
    () {
      final source = File('lib/data/firestore_social_data_source.dart').readAsStringSync();
      expect('runTransaction('.allMatches(source), hasLength(2)); // _execute + _executePlanned
      expect('_db.batch()'.allMatches(source), hasLength(1)); // _commit only
      expect(source, contains('switch (write.mode)'));
      expect(source, contains('write.mode == SocialWriteMode.transaction'));
      // writes never build documents outside SocialPayloads
      expect(RegExp(r"\.(set|update)\(\s*_(handle|social)\(").hasMatch(source), isFalse);
    },
  );
}
