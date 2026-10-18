import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/sharing_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_builder.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_profile_validator.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/sharing_rig.dart';

/// Fatia 4 — Recomendados (docs/81 RF-R1–R3, RF-P2–P5, D9, D16; docs/82
/// §4.1, §4.4, §5.4, §15 item 4; docs/83 "Recomendados só com opt-in"):
/// the toggle (controller), `recs` in the engine, the lenient reader.

/// A favorite marked "Recomendo" (or not) with explicit dates, so the order
/// of the tab (`FavoriteItem.byRecentActivity`) is not trivial.
FavoriteDoc recDoc(
  int id, {
  MediaType type = MediaType.movie,
  bool rec = true,
  DateTime? added,
  DateTime? watched,
  String? title,
  String? poster,
}) => FavoriteDoc(
  id: id,
  mediaType: type,
  title: title ?? 'Título $id',
  posterPath: poster ?? '/r$id.jpg',
  overview: 'Sinopse privada $id',
  addedAt: added ?? DateTime.utc(2026, 1, 1).add(Duration(hours: id)),
  watchedMovie: type == MediaType.movie && watched != null,
  lastWatchedAt: watched,
  recommended: rec,
);

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<ProviderContainer> _start(SharingRig rig) async {
  final c = rig.container();
  addTearDown(c.dispose);
  c.listen(recommendedListProvider, (_, _) {});
  await _settle();
  return c;
}

SharingController _ctl(ProviderContainer c) => c.read(sharingControllerProvider.notifier);
SharingState _st(ProviderContainer c) => c.read(sharingControllerProvider);
SharedProfileContent _preview(ProviderContainer c, SharedSection s) =>
    c.read(sharedPreviewProvider(s))!;

Map<String, dynamic> _recs(SharingRig rig) => rig.doc!['recs'] as Map<String, dynamic>;
List<int> _ids(SharingRig rig) => [
  for (final i in _recs(rig)['items'] as List) (i as Map)['id'] as int,
];

/// A mixed set: two series, movies watched after being added, ties on the
/// activity date broken by `addedAt` and then by title, one not recommended.
SharingRig _mixed() {
  final rig = SharingRig();
  rig.seed(recDoc(1, added: DateTime.utc(2026, 3, 1)));
  rig.seed(recDoc(2, added: DateTime.utc(2026, 2, 1), watched: DateTime.utc(2026, 9, 1)));
  rig.seed(recDoc(3, type: MediaType.tv, added: DateTime.utc(2026, 5, 1)));
  rig.seed(recDoc(4, added: DateTime.utc(2026, 4, 1), rec: false));
  rig.seed(recDoc(5, added: DateTime.utc(2026, 6, 1), title: 'B'));
  rig.seed(recDoc(6, added: DateTime.utc(2026, 6, 1), title: 'a'));
  rig.seed(recDoc(7, added: DateTime.utc(2026, 1, 1), watched: DateTime.utc(2026, 6, 1)));
  return rig;
}

void main() {
  group('toggle "Recomendados" (RF-P2–P5, D2)', () {
    test('off by default: the preview exists but nothing is written; 0 writes', () async {
      final rig = _mixed();
      final c = await _start(rig);
      expect(_st(c).sections, isEmpty);
      expect(kSharingSections, [SharedSection.stats, SharedSection.activity, SharedSection.recs]);
      expect(rig.doc, isNull);
      expect(rig.shared.toggles, isEmpty);
      expect(rig.shared.writeAttempts, 0);
    });

    test('turning on: one transaction with sharing.recs + recs (count and items in the order '
        'of the tab), nothing else', () async {
      final rig = _mixed();
      final c = await _start(rig);
      final tab = [for (final i in c.read(recommendedListProvider)) i.id];
      expect(tab, hasLength(6));
      await _ctl(c).turnOn(SharedSection.recs, _preview(c, SharedSection.recs));
      await _settle();
      final op = rig.shared.toggles.single.ops.single;
      expect(op.op, 'set');
      expect(op.data!['sharing'], {'recs': true});
      expect(op.data!.keys, isNot(contains('stats')));
      expect(op.data!.keys, isNot(contains('activity')));
      expect(op.data!.keys, isNot(contains('actSince')));
      expect(_recs(rig)['count'], 6);
      expect(_ids(rig), tab, reason: 'the same order as "Minhas recomendações"');
      expect(_st(c).sections, {SharedSection.recs});
      expect(_st(c).doc!.recs!.count, 6);
      expect(rig.shared.writeAttempts, 0, reason: 'the toggle never uses the engine write');
    });

    test('a projection: each item has ONLY id, mediaType, title, poster (no overview, '
        'dates, progress)', () async {
      final rig = _mixed();
      final c = await _start(rig);
      await _ctl(c).turnOn(SharedSection.recs, _preview(c, SharedSection.recs));
      for (final item in _recs(rig)['items'] as List) {
        expect((item as Map).keys.toSet(), {'id', 'mediaType', 'title', 'poster'});
      }
      expect(_recs(rig).keys.toSet(), {'count', 'items'});
    });

    test('51 recommended: 50 items, count 51; 50: 50 and 50', () async {
      for (final n in [50, 51]) {
        final rig = SharingRig();
        for (var i = 1; i <= n; i++) {
          rig.seed(recDoc(i));
        }
        final c = await _start(rig);
        await _ctl(c).turnOn(SharedSection.recs, _preview(c, SharedSection.recs));
        expect(_recs(rig)['count'], n, reason: '$n');
        expect(_recs(rig)['items'] as List, hasLength(50), reason: '$n');
        expect(_ids(rig).first, n, reason: 'most recent first');
        c.dispose();
      }
    });

    test('turning on as a second section: update, the other section untouched', () async {
      final rig = _mixed();
      rig.seedShared({SharedSection.stats});
      final before = rig.doc!['stats'];
      final c = await _start(rig);
      await _ctl(c).turnOn(SharedSection.recs, _preview(c, SharedSection.recs));
      expect(rig.shared.toggles.single.ops.single.op, 'update');
      expect(rig.doc!['sharing'], {'stats': true, 'recs': true});
      expect(rig.doc!['stats'], before);
      expect(_recs(rig)['count'], 6);
    });

    test('server read after turning on fails: the local view still has the recs', () async {
      final rig = _mixed();
      final c = await _start(rig);
      final preview = _preview(c, SharedSection.recs);
      rig.shared.failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
      await _ctl(c).turnOn(SharedSection.recs, preview);
      await _settle();
      expect(_st(c).sections, {SharedSection.recs});
      expect(_st(c).doc!.recs, preview.recs);
    });

    test('turning off (RF-R3): recs gone from the server, "recommended" of every favorite '
        'unchanged, the message', () async {
      final rig = _mixed();
      rig.seedShared({SharedSection.stats, SharedSection.recs});
      final c = await _start(rig);
      final flags = {for (final d in rig.cloud.server['uid-ana']!.values) d.key: d.recommended};
      await _ctl(c).turnOff(SharedSection.recs);
      await _settle();
      expect(rig.doc!.containsKey('recs'), isFalse);
      expect(rig.doc!['sharing'], {'stats': true});
      expect(rig.doc!['stats'], isNotNull);
      expect(_st(c).doc!.recs, isNull);
      expect(_st(c).notice!.text, 'Seus amigos não veem mais seus recomendados.');
      expect({for (final d in rig.cloud.server['uid-ana']!.values) d.key: d.recommended}, flags);
    });

    test('turning off the last section deletes the document', () async {
      final rig = _mixed();
      rig.seedShared({SharedSection.recs});
      final c = await _start(rig);
      await _ctl(c).turnOff(SharedSection.recs);
      expect(rig.doc, isNull);
      expect(_st(c).sections, isEmpty);
    });

    test('offline: nothing changes, nothing queued, "Sem conexão…"', () async {
      final rig = _mixed();
      final c = await _start(rig);
      final preview = _preview(c, SharedSection.recs);
      rig.cloud.offline = true;
      await _settle();
      await _ctl(c).turnOn(SharedSection.recs, preview);
      expect(rig.shared.toggles, isEmpty);
      expect(_st(c).notice!.text, 'Sem conexão. Tente de novo quando estiver online.');
    });

    test('uncertain turning on, confirmed later: ON + "Compartilhamento ligado."', () async {
      final rig = _mixed();
      final c = await _start(rig);
      rig.shared
        ..deliverUncertainToggles = true
        ..failNext('toggle', const SocialFailure(SocialFailureKind.uncertain, code: 'timeout'))
        ..failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
      await _ctl(c).turnOn(SharedSection.recs, _preview(c, SharedSection.recs));
      await _settle();
      expect(_st(c).uncertain, {SharedSection.recs: true});
      rig.cloud.offline = true;
      await _settle();
      rig.cloud.offline = false;
      await _settle();
      expect(_st(c).uncertain, isEmpty);
      expect(_st(c).sections, {SharedSection.recs});
      expect(_st(c).notice!.text, 'Compartilhamento ligado.');
    });

    test(
      'uncertain turning off that did not happen: still ON + "Não foi possível desligar…"',
      () async {
        final rig = _mixed();
        rig.seedShared({SharedSection.recs});
        final c = await _start(rig);
        rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
        await _ctl(c).turnOff(SharedSection.recs);
        await _settle();
        expect(_st(c).sections, {SharedSection.recs});
        expect(rig.doc!['recs'], isNotNull);
        expect(_st(c).notice!.text, 'Não foi possível desligar. Tente de novo.');
      },
    );

    test('uncertain turning off that happened: off + the usual message', () async {
      final rig = _mixed();
      rig.seedShared({SharedSection.stats, SharedSection.recs});
      final c = await _start(rig);
      rig.shared
        ..deliverUncertainToggles = true
        ..failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
      await _ctl(c).turnOff(SharedSection.recs);
      await _settle();
      expect(rig.doc!.containsKey('recs'), isFalse);
      expect(_st(c).sections, {SharedSection.stats});
      expect(_st(c).notice!.text, 'Seus amigos não veem mais seus recomendados.');
    });

    test('one toggle at a time: "Aguarde a operação anterior terminar."', () async {
      final rig = _mixed();
      final c = await _start(rig);
      rig.shared.toggleGate = Completer<void>();
      final first = _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      await _settle();
      await _ctl(c).turnOn(SharedSection.recs, _preview(c, SharedSection.recs));
      expect(_st(c).notice!.text, 'Aguarde a operação anterior terminar.');
      rig.shared.toggleGate!.complete();
      await first;
      expect(rig.shared.toggles, hasLength(1));
    });
  });

  group('local hint of the toggles (sharedHint:<uid>)', () {
    test('account deletion forgets the hint of the deleted uid only', () async {
      final rig = _mixed()..seedShared({SharedSection.recs});
      rig.store.sharedHints['uid-other'] = {'stats'};
      final c = await _start(rig);
      expect(rig.store.sharedHints['uid-ana'], {'recs'});
      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
      await _settle();
      expect(rig.store.sharedHints.containsKey('uid-ana'), isFalse);
      expect(rig.store.sharedHints['uid-other'], {'stats'});
    });

    test(
      'deactivating friendships forgets the hint (reactivating never shows old sections)',
      () async {
        final rig = _mixed()..seedShared({SharedSection.stats, SharedSection.recs});
        final c = await _start(rig);
        expect(rig.store.sharedHints['uid-ana'], {'stats', 'recs'});
        await c.read(socialControllerProvider.notifier).deactivate();
        await _settle();
        expect(rig.doc, isNull);
        expect(rig.store.sharedHints.containsKey('uid-ana'), isFalse);
      },
    );
  });

  group('engine (RF-R2, RF-S5–S8)', () {
    ProviderContainer start(FakeAsync async, SharingRig rig) {
      final c = rig.container();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      return c;
    }

    void recommend(SharingRig rig, String key, bool value) => rig.cloud.write('uid-ana', (docs) {
      docs[key] = docs[key]!.copyWith(recommended: value);
    });

    test('recommending updates recs in ONE coalesced write (count and order)', () {
      fakeAsync((async) {
        final rig = _mixed()..seedShared({SharedSection.recs});
        final c = start(async, rig);
        async.elapse(const Duration(minutes: 1));
        expect(rig.writes, 0, reason: 'equal at session start');
        recommend(rig, '4-movie', true);
        async.elapse(const Duration(seconds: 2));
        recommend(rig, '1-movie', false);
        async.elapse(const Duration(milliseconds: 4900));
        expect(rig.writes, 0, reason: 'W = 5 s after the last change');
        async.elapse(const Duration(milliseconds: 100));
        expect(rig.writes, 1);
        final data = rig.shared.writes.single.ops.single.data!;
        expect(data.keys.toSet(), {'recs', 'calc', 'tz', 'updatedAt'});
        expect(_recs(rig)['count'], 6);
        expect(_ids(rig), isNot(contains(1)));
        expect(_ids(rig), contains(4));
        expect(rig.doc!.containsKey('activity'), isFalse);
        c.dispose();
      });
    });

    test('removing a recommended title from Favoritos updates recs', () {
      fakeAsync((async) {
        final rig = _mixed()..seedShared({SharedSection.recs});
        final c = start(async, rig);
        rig.cloud.write('uid-ana', (docs) => docs.remove('2-movie'));
        async.elapse(const Duration(seconds: 6));
        expect(rig.writes, 1);
        expect(_recs(rig)['count'], 5);
        expect(_ids(rig), isNot(contains(2)));
        c.dispose();
      });
    });

    test('"só grava se mudou": watching a title that is not recommended = 0 writes', () {
      fakeAsync((async) {
        final rig = _mixed()..seedShared({SharedSection.recs});
        final c = start(async, rig);
        rig.cloud.write('uid-ana', (docs) {
          docs['4-movie'] = docs['4-movie']!.copyWith(watchedMovie: true, lastWatchedAt: rig.now);
        });
        async.elapse(const Duration(minutes: 1));
        expect(rig.writes, 0);
        expect(rig.shared.writeAttempts, 0);
        c.dispose();
      });
    });

    test('only statistics shared: recommending writes NO recs (and nothing at all)', () {
      fakeAsync((async) {
        final rig = _mixed()..seedShared({SharedSection.stats});
        final c = start(async, rig);
        recommend(rig, '4-movie', true);
        async.elapse(const Duration(minutes: 1));
        expect(rig.shared.writeAttempts, 0);
        expect(rig.doc!.containsKey('recs'), isFalse);
        c.dispose();
      });
    });

    test('nothing shared (friendships active): recommending = 0 writes, 0 attempts', () {
      fakeAsync((async) {
        final rig = _mixed();
        final c = start(async, rig);
        recommend(rig, '4-movie', true);
        async.elapse(const Duration(minutes: 1));
        expect(rig.shared.writeAttempts, 0);
        expect(rig.shared.toggles, isEmpty);
        expect(rig.doc, isNull);
        c.dispose();
      });
    });

    test('recommending is not an activity (RF-A5): activity unchanged, 0 writes', () {
      fakeAsync((async) {
        final rig = _mixed()
          ..seedShared({
            SharedSection.activity,
          }, actSince: kSharingNow.subtract(const Duration(days: 1)));
        final c = start(async, rig);
        async.elapse(const Duration(minutes: 1));
        expect(rig.writes, 0);
        recommend(rig, '4-movie', true);
        recommend(rig, '1-movie', false);
        async.elapse(const Duration(minutes: 1));
        expect(rig.writes, 0);
        expect(rig.doc!['activity'], isEmpty);
        c.dispose();
      });
    });
  });

  group('builder and validator (D9, D16)', () {
    test('items never carry a poster outside the TMDB format; long titles cut', () {
      final c = SharedProfileBuilder.build(
        [recDoc(1, poster: 'https://evil.example/p.jpg'), recDoc(2, title: 'x' * 400)],
        catalog: (_) => const [],
        sections: {SharedSection.recs},
        now: kSharingNow,
        tzMinutes: kSaoPaulo,
      );
      expect(SharedProfileValidator.violations(c, now: kSharingNow), isEmpty);
      final byId = {for (final i in c.recs!.items) i.id: i};
      expect(byId[1]!.poster, isNull);
      expect(byId[2]!.title.length, kMaxSharedTitle);
      expect(c.recs!.count, 2);
      expect(c.stats, isNull);
      expect(c.activity, isNull);
    });
  });

  group('lenient reader (RF-F9)', () {
    Map<String, Object?> item(int i, {Object? poster = '/p.jpg'}) => {
      'id': i,
      'mediaType': i.isEven ? 'tv' : 'movie',
      'title': 'T$i',
      'poster': poster,
    };

    test('not a map = not shared; count missing = unknown ("—") and no "e mais"', () {
      expect(SharedRecsReading.read(null), isNull);
      expect(SharedRecsReading.read('x'), isNull);
      final r = SharedRecsReading.read({
        'items': [item(1)],
      })!;
      expect(r.count, isNull);
      expect(r.more, 0);
      expect(r.items.single.id, 1);
    });

    test('malformed items are ignored, the rest kept in order; bad poster dropped', () {
      final r = SharedRecsReading.read({
        'count': 7,
        'items': [
          item(1),
          {'id': 'x', 'mediaType': 'movie', 'title': 'bad id'},
          {'id': 3, 'mediaType': 'book', 'title': 'bad type'},
          {'id': 4, 'mediaType': 'tv'},
          'not a map',
          item(6, poster: '/../../etc.jpg?x=1'),
          item(7, poster: 42),
          {...item(8), 'extra': true, 'rating': 5},
        ],
        'future': 'ignored',
      })!;
      expect([for (final i in r.items) i.id], [1, 6, 7, 8]);
      expect(r.items[1].poster, isNull);
      expect(r.items[2].poster, isNull);
      expect(r.items[0].poster, '/p.jpg');
      expect(r.count, 7);
      expect(r.more, 3);
    });

    test('at most 50 shown, whatever the document holds; 50/51 "e mais"', () {
      final many = SharedRecsReading.read({
        'count': 60,
        'items': [for (var i = 1; i <= 60; i++) item(i)],
      })!;
      expect(many.items, hasLength(50));
      expect(many.items.last.id, 50);
      expect(many.more, 10);
      SharedRecsReading of(int count) => SharedRecsReading.read({
        'count': count,
        'items': [for (var i = 1; i <= 50; i++) item(i)],
      })!;
      expect(of(50).more, 0);
      expect(of(51).more, 1);
      expect(of(49).more, 0, reason: 'a count smaller than the list never goes negative');
    });

    test('QA-F4-1 reader: blank title (decision 6), id < 1 ignored; negative count = unknown', () {
      final r = SharedRecsReading.read({
        'count': 5,
        'items': [
          {'id': 1, 'mediaType': 'movie', 'title': 'Ok'},
          {'id': 2, 'mediaType': 'movie', 'title': '   '},
          {'id': 3, 'mediaType': 'tv', 'title': ''},
          {'id': 0, 'mediaType': 'movie', 'title': 'zero'},
          {'id': -4, 'mediaType': 'tv', 'title': 'neg'},
        ],
      })!;
      expect([for (final i in r.items) i.id], [1]);
      expect(r.more, 4);
      final neg = SharedRecsReading.read({
        'count': -3,
        'items': [
          {'id': 1, 'mediaType': 'movie', 'title': 'Ok'},
        ],
      })!;
      expect(neg.count, isNull);
      expect(neg.more, 0);
      // CR2: the friend-side reader caps titles like the owner's validator.
      final long = SharedRecsReading.read({
        'count': 1,
        'items': [
          {'id': 1, 'mediaType': 'movie', 'title': 'x' * 301},
        ],
      })!;
      expect(long.items.single.title.length, kMaxSharedTitle);
      expect(long.items.single.title, 'x' * 300);
    });

    test('the friend view: recs present = shared, absent = null', () {
      final shared = FriendSharedView.parse({
        'recs': {
          'count': 1,
          'items': [item(1)],
        },
      });
      expect(shared.recs!.count, 1);
      expect(FriendSharedView.parse({'stats': <String, Object?>{}}).recs, isNull);
    });
  });
}
