import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/firestore_shared_profile_data_source.dart';
import 'package:cinetrack/data/shared_profile_data_source.dart';
import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/providers/sharing_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/repositories/shared_profile_repository.dart';
import 'package:cinetrack/shared_profile/shared_profile_doc.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:firebase_core/firebase_core.dart';

import 'support/sharing_rig.dart';

/// Owner state and consent toggles (docs/81 RF-P1–P12, docs/82 §7.1, B5),
/// with the fakes' operation log.
Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<ProviderContainer> _start(SharingRig rig) async {
  final c = rig.container();
  addTearDown(c.dispose);
  await _settle();
  return c;
}

SharingController _ctl(ProviderContainer c) => c.read(sharingControllerProvider.notifier);
SharingState _st(ProviderContainer c) => c.read(sharingControllerProvider);

SharedProfileContent _preview(ProviderContainer c, SharedSection s) =>
    c.read(sharedPreviewProvider(s))!;

FirebaseException _fx(String code) => FirebaseException(plugin: 'cloud_firestore', code: code);

void main() {
  group('owner state', () {
    test('active friendships, nothing shared: 1 read, 0 writes, everything off', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = await _start(rig);
      expect(_st(c).phase, SharingPhase.ready);
      expect(_st(c).sections, isEmpty);
      expect(rig.log, ['readOwn']);
      expect(rig.shared.toggles, isEmpty);
      expect(rig.shared.writeAttempts, 0);
      expect(rig.store.sharedHints['uid-ana'], isEmpty);
    });

    test('gate created at session start (as the favorites factory does): the session read '
        'is the probe, no dedicated read (Q1)', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = rig.container();
      addTearDown(c.dispose);
      // The favorites factory keeps the gate alive from the session start.
      c.listen(sharedRulesGateProvider, (_, _) {});
      await _settle();
      expect(c.read(sharedRulesGateProvider).open, isTrue);
      expect(rig.log, ['readOwn']);
      expect(rig.store.sharedRules, isNotEmpty);
    });

    test('same, without friendships: the dedicated probe, the document is not read', () async {
      final rig = SharingRig(active: false);
      final c = rig.container();
      addTearDown(c.dispose);
      c.listen(sharedRulesGateProvider, (_, _) {});
      await _settle();
      expect(c.read(sharedRulesGateProvider).open, isTrue);
      expect(rig.log, ['probe']);
    });

    test('no active friendships: hidden, the document is never read', () async {
      final rig = SharingRig(active: false);
      final c = await _start(rig);
      expect(_st(c).phase, SharingPhase.hidden);
      expect(rig.log, isNot(contains('readOwn')));
    });

    test(
      'local hint shows at once (unconfirmed) and the server read corrects it (2 devices)',
      () async {
        final rig = SharingRig();
        rig.store.sharedHints['uid-ana'] = {};
        rig.store.socialHints['uid-ana'] = (active: true, at: DateTime.now());
        rig.seedShared({SharedSection.stats});
        rig.shared.readGate = Completer<void>();
        final c = rig.container();
        addTearDown(c.dispose);
        await _settle();
        expect(_st(c).phase, SharingPhase.loading);
        expect(_st(c).confirmed, isFalse);
        expect(_st(c).hint, isEmpty, reason: 'old hint: everything off');
        rig.shared.readGate!.complete();
        await _settle();
        expect(_st(c).sections, {SharedSection.stats});
        expect(rig.store.sharedHints['uid-ana'], {'stats'});
      },
    );

    test('offline with nothing confirmed: "offline"; back online: confirmed', () async {
      final rig = SharingRig();
      rig.shared.failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
      final c = await _start(rig);
      expect(_st(c).phase, SharingPhase.offline);
      expect(_ctl(c).blockReason(), 'Sem conexão. Tente de novo quando estiver online.');
      rig.cloud.offline = true;
      await _settle();
      rig.cloud.offline = false;
      await _settle();
      expect(_st(c).phase, SharingPhase.ready);
      expect(_st(c).confirmed, isTrue);
    });

    test('old rules: unavailable, the gate learns it from the session read (no probe)', () async {
      final rig = SharingRig()..shared.oldRules = true;
      final c = await _start(rig);
      expect(_st(c).phase, SharingPhase.unavailable);
      final gate = c.read(sharedRulesGateProvider);
      await _settle();
      expect(gate.open, isFalse);
      expect(gate.lastProbe, RulesProbe.oldRules);
      expect(rig.log, isNot(contains('probe')));
      expect(_ctl(c).blockReason(), 'O perfil compartilhado ainda não está disponível.');
    });

    test('deactivating friendships hides the section and deletes the document', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final c = await _start(rig);
      expect(_st(c).sections, {SharedSection.stats});
      await c.read(socialControllerProvider.notifier).deactivate();
      await _settle();
      expect(rig.doc, isNull);
      expect(_st(c).phase, SharingPhase.hidden);
    });
  });

  group('turning on (RF-P4)', () {
    test('"Estatísticas": one transaction with sharing.stats and stats, no recs', () async {
      final rig = SharingRig()..seed(sharingMovie(1, watched: true));
      final c = await _start(rig);
      await _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      await _settle();
      expect(rig.shared.toggles, hasLength(1));
      final op = rig.shared.toggles.single.ops.single;
      expect(op.op, 'set');
      expect((op.data!['sharing'] as Map), {'stats': true});
      expect(op.data!.containsKey('recs'), isFalse);
      expect(rig.doc!['stats'], isNotNull);
      expect(((rig.doc!['stats'] as Map)['total'] as Map)['watchedMovies'], 1);
      expect(_st(c).sections, {SharedSection.stats});
      expect(_st(c).doc!.updatedAt, kSharingNow);
      expect(rig.shared.writeAttempts, 0, reason: 'the toggle never uses the engine write');
    });

    test('"Atividades": starts empty, actSince = server time', () async {
      final rig = SharingRig()..seed(sharingMovie(1, watched: true, at: kSharingNow));
      final c = await _start(rig);
      await _ctl(c).turnOn(SharedSection.activity, _preview(c, SharedSection.activity));
      await _settle();
      expect(rig.doc!['activity'], isEmpty);
      expect(rig.doc!['actSince'], kSharingNow);
      expect(_st(c).doc!.actSince, kSharingNow);
    });

    test('second section: update in the same document', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.activity});
      final c = await _start(rig);
      await _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      expect(rig.shared.toggles.single.ops.single.op, 'update');
      expect((rig.doc!['sharing'] as Map), {'activity': true, 'stats': true});
    });

    test('offline: nothing changes, nothing queued, "Sem conexão…"', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = await _start(rig);
      final preview = _preview(c, SharedSection.stats);
      rig.cloud.offline = true;
      await _settle();
      await _ctl(c).turnOn(SharedSection.stats, preview);
      expect(rig.shared.toggles, isEmpty);
      expect(rig.doc, isNull);
      expect(_st(c).notice!.text, 'Sem conexão. Tente de novo quando estiver online.');
      expect(_st(c).sections, isEmpty);
    });

    test('quota: the existing message, the toggle shows the server state', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.quotaExceeded));
      final c = await _start(rig);
      await _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      expect(_st(c).notice!.text, 'Muitas operações hoje. Tente de novo amanhã.');
      expect(_st(c).sections, isEmpty);
      expect(_st(c).busy, isNull);
    });

    test('old rules at the transaction: "ainda não está disponível", toggle off', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.oldRules = true;
      await _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      await _settle();
      expect(_st(c).notice!.text, 'O perfil compartilhado ainda não está disponível.');
      expect(_st(c).sections, isEmpty);
    });

    test('friendships turned off on another device: the section goes away', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.social.social.remove('uid-ana');
      rig.shared.socialClosed.add('uid-ana');
      await _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      await _settle();
      expect(rig.doc, isNull);
      expect(_st(c).phase, SharingPhase.hidden);
    });

    test('two toggles at once: "Aguarde a operação anterior terminar."', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.toggleGate = Completer<void>();
      final first = _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      await _settle();
      expect(_st(c).busy, SharedSection.stats);
      await _ctl(c).turnOn(SharedSection.activity, _preview(c, SharedSection.activity));
      expect(_st(c).notice!.text, 'Aguarde a operação anterior terminar.');
      rig.shared.toggleGate!.complete();
      rig.shared.toggleGate = null;
      await first;
      expect(rig.shared.toggles, hasLength(1));
    });

    test('an engine write in flight never blocks a toggle', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final c = await _start(rig);
      rig.shared.writeGate = Completer<void>();
      unawaited(c.read(sharedProfileRepositoryProvider).pulse().catchError((Object _) {}));
      await _settle();
      expect(_ctl(c).blockReason(), isNull);
      await _ctl(c).turnOn(SharedSection.activity, _preview(c, SharedSection.activity));
      expect((rig.doc!['sharing'] as Map), containsPair('activity', true));
      rig.shared.writeGate!.complete();
    });
  });

  group('turning off (RF-P5)', () {
    test('the last section: the document is deleted, message, favorites untouched', () async {
      final rig = SharingRig()..seed(sharingMovie(1, watched: true));
      rig.seedShared({SharedSection.activity});
      final c = await _start(rig);
      final before = Map.of(rig.cloud.server['uid-ana']!);
      await _ctl(c).turnOff(SharedSection.activity);
      expect(rig.doc, isNull);
      expect(rig.shared.toggles.single.ops.single.op, 'delete');
      expect(_st(c).notice!.text, 'Seus amigos não veem mais suas atividades recentes.');
      expect(_st(c).sections, isEmpty);
      expect(rig.cloud.server['uid-ana'], before);
    });

    test('one of two: stats and sharing.stats go, activity and actSince stay', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final since = kSharingNow.subtract(const Duration(days: 1));
      rig.seedShared({SharedSection.stats, SharedSection.activity}, actSince: since);
      final activity = rig.doc!['activity'];
      final c = await _start(rig);
      await _ctl(c).turnOff(SharedSection.stats);
      expect(rig.doc!.containsKey('stats'), isFalse);
      expect((rig.doc!['sharing'] as Map), {'activity': true});
      expect(rig.doc!['actSince'], since);
      expect(rig.doc!['activity'], activity);
      expect(_st(c).notice!.text, 'Seus amigos não veem mais suas estatísticas.');
    });
  });

  group('uncertain result (B5, RF-P7)', () {
    test('turning on with no answer: "uncertain"; reconnecting shows it ON + message', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared
        ..deliverUncertainToggles = true
        ..failNext('toggle', const SocialFailure(SocialFailureKind.uncertain, code: 'timeout'))
        ..failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
      await _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      await _settle();
      expect(_st(c).uncertain, {SharedSection.stats: true});
      expect(_ctl(c).blockReason(), isNotNull, reason: 'disabled while uncertain');
      rig.cloud.offline = true;
      await _settle();
      rig.cloud.offline = false;
      await _settle();
      expect(_st(c).uncertain, isEmpty);
      expect(_st(c).sections, {SharedSection.stats});
      expect(_st(c).notice!.text, 'Compartilhamento ligado.');
    });

    test('turning on that did NOT happen: off, never treated as on', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
      await _ctl(c).turnOn(SharedSection.stats, _preview(c, SharedSection.stats));
      await _settle();
      expect(_st(c).uncertain, isEmpty);
      expect(_st(c).sections, isEmpty);
      expect(_st(c).notice?.text, isNot('Compartilhamento ligado.'));
    });

    test('turning off that did not happen: still on + "Não foi possível desligar…"', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final c = await _start(rig);
      rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
      await _ctl(c).turnOff(SharedSection.stats);
      await _settle();
      expect(_st(c).sections, {SharedSection.stats});
      expect(_st(c).notice!.text, 'Não foi possível desligar. Tente de novo.');
    });

    test('turning off that happened: off + the usual message', () async {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final c = await _start(rig);
      rig.shared
        ..deliverUncertainToggles = true
        ..failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
      await _ctl(c).turnOff(SharedSection.stats);
      await _settle();
      expect(rig.doc, isNull);
      expect(_st(c).sections, isEmpty);
      expect(_st(c).notice!.text, 'Seus amigos não veem mais suas estatísticas.');
    });
  });

  group('Firestore source: toggle error mapping', () {
    FirestoreSharedProfileDataSource source(
      Future<void> Function(
        Future<void> Function(Map<String, dynamic>?, void Function(SocialWrite)) body,
      )
      run,
    ) => FirestoreSharedProfileDataSource(
      uid: 'uid-ana',
      toggleTimeout: const Duration(milliseconds: 50),
      txRunner: (path, body) => run(body),
    );

    SocialWrite plan(Map<String, dynamic>? _) => const SocialWrite(SocialWriteMode.transaction, []);

    Future<SocialFailureKind?> kindOf(Future<void> f) async {
      try {
        await f;
        return null;
      } on SocialFailure catch (e) {
        return e.kind;
      }
    }

    test('unavailable BEFORE the write was planned = offline (nothing sent)', () async {
      final s = source((body) async => throw _fx('unavailable'));
      expect(await kindOf(s.toggle(plan)), SocialFailureKind.offline);
    });

    test('unavailable / deadline-exceeded AFTER the write was applied = uncertain', () async {
      for (final code in ['unavailable', 'deadline-exceeded']) {
        final s = source((body) async {
          await body(null, (_) {});
          throw _fx(code);
        });
        expect(await kindOf(s.toggle(plan)), SocialFailureKind.uncertain, reason: code);
      }
    });

    test('no answer within the timeout = uncertain', () async {
      final s = source((body) => Completer<void>().future);
      expect(await kindOf(s.toggle(plan)), SocialFailureKind.uncertain);
    });

    test('permission-denied = denied; resource-exhausted = quota', () async {
      expect(
        await kindOf(source((b) async => throw _fx('permission-denied')).toggle(plan)),
        SocialFailureKind.denied,
      );
      expect(
        await kindOf(source((b) async => throw _fx('resource-exhausted')).toggle(plan)),
        SocialFailureKind.quotaExceeded,
      );
    });

    test('a recalculation that finds no document = not-found (re-read by the engine)', () async {
      final s = FirestoreSharedProfileDataSource(
        uid: 'uid-ana',
        updater: (path, data) async => throw _fx('not-found'),
      );
      try {
        await SharedProfileRepository(s).pulse();
        fail('should throw');
      } on SharedProfileFailure catch (e) {
        expect(e.kind, SharedProfileFailureKind.notFound);
      }
    });
  });

  test('SharedProfileDoc.parse is defensive', () {
    final doc = SharedProfileDoc.parse({
      'sharing': {'stats': true, 'activity': 'yes', 'future': true},
      'stats': {'total': 'oops'},
      'activity': [
        {'type': 'rated', 'id': 1},
      ],
      'tz': 'x',
    })!;
    expect(doc.sharing, {SharedSection.stats});
    expect(doc.stats, isNull);
    expect(doc.tz, 0);
    expect(doc.activity, isEmpty);
    expect(SharedProfileDoc.parse(null), isNull);
  });
}
