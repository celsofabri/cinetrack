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
import 'package:cinetrack/shared_profile/shared_profile_payloads.dart';
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

SharedProfileContent _preview(ProviderContainer c) => c.read(sharedPreviewProvider)!;
SharingMode _mode(ProviderContainer c) => c.read(sharingModeProvider);
Map<String, dynamic> _card(SharingRig rig) => rig.social.handles['ana']!;

SharingRig _rig({bool discoverable = true}) {
  final rig = SharingRig();
  rig.social.handles['ana']!['discoverable'] = discoverable;
  return rig;
}

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

  group('"Aparecer na busca": ligar (RF-SC2)', () {
    test('E0 -> E1: ONE transaction, card discoverable=true + 3 sections, activity [] and '
        'actSince = server time; T-S1; 0 writes before', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1, watched: true));
      final c = await _start(rig);
      expect(_mode(c), SharingMode.off);
      expect(rig.shared.searches, isEmpty);
      expect(await _ctl(c).setSearchSharing(true, content: _preview(c)), isTrue);
      await _settle();
      expect(rig.shared.searches, hasLength(1));
      final ops = rig.shared.searches.single.ops;
      expect(ops, hasLength(2));
      expect(ops[0].path, 'handles/ana');
      expect(ops[0].op, 'update');
      expect(ops[0].data, {'discoverable': true, 'updatedAt': serverTimestamp});
      expect(ops[1].path, 'shared_profiles/uid-ana');
      expect(ops[1].op, 'set');
      expect(ops[1].data!['sharing'], {'stats': true, 'activity': true, 'recs': true});
      expect(ops[1].data!['activity'], isEmpty);
      expect(ops[1].data!['actSince'], serverTimestamp);
      expect(rig.doc!['actSince'], kSharingNow);
      expect(((rig.doc!['stats'] as Map)['total'] as Map)['watchedMovies'], 1);
      expect(rig.doc!['recs'], isNotNull);
      expect(_card(rig)['discoverable'], isTrue);
      expect(_mode(c), SharingMode.on);
      expect(_st(c).notice!.text, kSearchOnDone);
      expect(_st(c).doc!.actSince, kSharingNow);
      expect(rig.shared.writeAttempts, 0, reason: 'never the engine write');
    });

    test('E3 (legacy, card off, Estatísticas shared) -> E1: card on + only the missing '
        'sections; stats untouched', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final before = rig.doc!['stats'];
      final c = await _start(rig);
      expect(_mode(c), SharingMode.legacy);
      await _ctl(c).setSearchSharing(true, content: _preview(c));
      final ops = rig.shared.searches.single.ops;
      expect(ops.map((o) => '${o.op} ${o.path}'), [
        'update handles/ana',
        'update shared_profiles/uid-ana',
      ]);
      expect(ops[1].data!.keys.toSet(), {
        'sharing.activity',
        'sharing.recs',
        'activity',
        'recs',
        'actSince',
        'calc',
        'tz',
        'updatedAt',
      });
      expect(rig.doc!['stats'], before);
      expect(_mode(c), SharingMode.on);
    });

    test('without the previewed content nothing is written (programming guard)', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      expect(await _ctl(c).setSearchSharing(true), isFalse);
      expect(rig.shared.searches, isEmpty);
      expect(_st(c).notice!.text, kSearchOnFailed);
    });

    test(
      'the read after the commit fails: local view with the 3 sections (actSince = now)',
      () async {
        final rig = _rig(discoverable: false)..seed(sharingMovie(1));
        final c = await _start(rig);
        rig.shared.failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
        await _ctl(c).setSearchSharing(true, content: _preview(c));
        await _settle();
        expect(_st(c).doc!.sharing, {...kSharingSections});
        expect(_st(c).doc!.activity, isEmpty);
        expect(_st(c).doc!.actSince, kSharingNow);
        expect(_st(c).doc!.stats, isNotNull);
        expect(_st(c).doc!.recs, isNotNull);
        expect(_mode(c), SharingMode.on);
      },
    );
  });

  group('aviso A: OK acrescenta só o que falta (RF-SC4, §6)', () {
    test(
      'busca ligada, nada compartilhado: OK cria o documento com as 3, cartão intocado',
      () async {
        final rig = _rig()..seed(sharingMovie(1));
        final c = await _start(rig);
        expect(_mode(c), SharingMode.review);
        expect(c.read(sharingNoticeDueProvider), SharingNoticeKind.review);
        expect(rig.shared.searches, isEmpty, reason: 'no write before OK');
        await _ctl(c).setSearchSharing(true, content: _preview(c));
        final ops = rig.shared.searches.single.ops;
        expect(ops.single.op, 'set');
        expect(ops.single.path, 'shared_profiles/uid-ana');
        expect(ops.single.data!['sharing'], {'stats': true, 'activity': true, 'recs': true});
        expect(ops.single.data!['actSince'], serverTimestamp);
        expect(_mode(c), SharingMode.on);
        expect(c.read(sharingNoticeDueProvider), isNull);
      },
    );

    test('só Estatísticas: OK acrescenta activity (actSince novo) e recs; stats intacto', () async {
      final rig = _rig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final stats = rig.doc!['stats'];
      final c = await _start(rig);
      await _ctl(c).setSearchSharing(true, content: _preview(c));
      final op = rig.shared.searches.single.ops.single;
      expect(op.op, 'update');
      expect(op.data!.containsKey('stats'), isFalse);
      expect(op.data!.containsKey('sharing.stats'), isFalse);
      expect(op.data!['sharing.activity'], isTrue);
      expect(op.data!['sharing.recs'], isTrue);
      expect(op.data!['activity'], isEmpty);
      expect(op.data!['actSince'], serverTimestamp);
      expect(rig.doc!['stats'], stats);
      expect(rig.doc!['sharing'], {'stats': true, 'activity': true, 'recs': true});
    });

    test('só Atividades: OK acrescenta stats e recs; actSince e itens mantidos', () async {
      final rig = _rig()..seed(sharingMovie(1));
      final since = kSharingNow.subtract(const Duration(days: 3));
      rig.seedShared({SharedSection.activity}, actSince: since);
      rig.doc!['activity'] = [
        {'type': 'watched', 'id': 1, 'mediaType': 'movie', 'title': 'Filme 1', 'at': kSharingNow},
      ];
      final activity = rig.doc!['activity'];
      final c = await _start(rig);
      await _ctl(c).setSearchSharing(true, content: _preview(c));
      final op = rig.shared.searches.single.ops.single;
      expect(op.data!.containsKey('actSince'), isFalse);
      expect(op.data!.containsKey('activity'), isFalse);
      expect(op.data!['sharing.stats'], isTrue);
      expect(op.data!['sharing.recs'], isTrue);
      expect(rig.doc!['actSince'], since);
      expect(rig.doc!['activity'], activity);
    });

    test('dois aparelhos: Y desatualizado em E2 dá OK depois de X: nada é regravado', () async {
      final rig = _rig()..seed(sharingMovie(1));
      final c = await _start(rig);
      expect(_mode(c), SharingMode.review);
      // X already said OK: the server has the 3 sections.
      rig.seedShared({...kSharingSections});
      final before = Map.of(rig.doc!);
      await _ctl(c).setSearchSharing(true, content: _preview(c));
      expect(rig.shared.searches.single.ops, isEmpty);
      expect(rig.doc, before);
      expect(_mode(c), SharingMode.on);
    });
  });

  group('desligar (RF-SC3)', () {
    test('E1 -> E0: card off + delete; T-S2; favoritos, amigos e convite intactos', () async {
      final rig = _rig()..seed(sharingMovie(1, watched: true));
      rig.seedShared({...kSharingSections});
      rig.social.seedFriendship('uid-ana', 'uid-bia');
      final c = await _start(rig);
      expect(_mode(c), SharingMode.on);
      final favorites = Map.of(rig.cloud.server['uid-ana']!);
      final friendships = Map.of(rig.social.friendships);
      final social = Map.of(rig.social.social['uid-ana']!);
      expect(await _ctl(c).setSearchSharing(false), isTrue);
      final ops = rig.shared.searches.single.ops;
      expect(ops.map((o) => '${o.op} ${o.path}'), [
        'update handles/ana',
        'delete shared_profiles/uid-ana',
      ]);
      expect(ops[0].data, {'discoverable': false, 'updatedAt': serverTimestamp});
      expect(rig.doc, isNull);
      expect(_card(rig)['discoverable'], isFalse);
      expect(_st(c).notice!.text, kSearchOffDone);
      expect(_mode(c), SharingMode.off);
      expect(rig.cloud.server['uid-ana'], favorites);
      expect(rig.social.friendships, friendships);
      expect(rig.social.social['uid-ana'], social);
    });

    test('E3 "Parar de compartilhar": só o delete (o cartão já está desligado)', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      rig.seedShared({SharedSection.recs});
      final c = await _start(rig);
      expect(_mode(c), SharingMode.legacy);
      expect(c.read(sharingNoticeDueProvider), SharingNoticeKind.legacy);
      await _ctl(c).setSearchSharing(false);
      expect(rig.shared.searches.single.ops.map((o) => '${o.op} ${o.path}'), [
        'delete shared_profiles/uid-ana',
      ]);
      expect(_mode(c), SharingMode.off);
    });

    test('E2 sem nada compartilhado: só o cartão', () async {
      final rig = _rig()..seed(sharingMovie(1));
      final c = await _start(rig);
      await _ctl(c).setSearchSharing(false);
      expect(rig.shared.searches.single.ops.map((o) => '${o.op} ${o.path}'), [
        'update handles/ana',
      ]);
      expect(_mode(c), SharingMode.off);
    });

    test('documento já apagado em outro aparelho e cartão desligado: nada é escrito', () async {
      final rig = _rig()..seed(sharingMovie(1));
      rig.seedShared({...kSharingSections});
      final c = await _start(rig);
      rig.shared.docs.remove('uid-ana');
      _card(rig)['discoverable'] = false;
      await _ctl(c).setSearchSharing(false);
      expect(rig.shared.searches.single.ops, isEmpty);
      expect(_mode(c), SharingMode.off);
    });
  });

  group('bloqueios e falhas (RF-SC6)', () {
    test('offline: nothing sent, nothing queued, the existing offline message', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      final preview = _preview(c);
      rig.cloud.offline = true;
      await _settle();
      expect(await _ctl(c).setSearchSharing(true, content: preview), isFalse);
      expect(rig.shared.searches, isEmpty);
      expect(_st(c).notice!.text, SharedProfileFailure.offlineMessage);
      expect(c.read(sharingNoticeDueProvider), isNull);
    });

    test('session read not answered yet: blocked (pending), no notice', () async {
      final rig = _rig()..seed(sharingMovie(1));
      rig.shared.readGate = Completer<void>();
      final c = await _start(rig);
      expect(_mode(c), SharingMode.pending);
      expect(c.read(sharingNoticeDueProvider), isNull);
      expect(_ctl(c).blockReason(), SharedProfileFailure.offlineMessage);
      rig.shared.readGate!.complete();
      await _settle();
      expect(_mode(c), SharingMode.review);
      expect(c.read(sharingNoticeDueProvider), SharingNoticeKind.review);
    });

    test('quota: the existing message, state unchanged; failureText replaces it', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.quotaExceeded));
      expect(await _ctl(c).setSearchSharing(true, content: _preview(c)), isFalse);
      expect(_st(c).notice!.text, 'Muitas operações hoje. Tente de novo amanhã.');
      expect(_mode(c), SharingMode.off);
      expect(_st(c).busy, isFalse);
      rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.offline));
      await _ctl(c).setSearchSharing(true, content: _preview(c), failureText: 'X');
      expect(_st(c).notice!.text, 'X');
    });

    test('old rules at the transaction: "ainda não está disponível"', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.oldRules = true;
      await _ctl(c).setSearchSharing(true, content: _preview(c));
      await _settle();
      expect(_st(c).notice!.text, SharedProfileFailure.unavailableMessage);
      expect(rig.doc, isNull);
    });

    test('one operation at a time', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.toggleGate = Completer<void>();
      final first = _ctl(c).setSearchSharing(true, content: _preview(c));
      await _settle();
      expect(_st(c).busy, isTrue);
      expect(c.read(sharingNoticeDueProvider), isNull);
      expect(await _ctl(c).setSearchSharing(false), isFalse);
      expect(_st(c).notice!.text, 'Aguarde a operação anterior terminar.');
      rig.shared.toggleGate!.complete();
      rig.shared.toggleGate = null;
      await first;
      expect(rig.shared.searches, hasLength(1));
    });

    test('an engine write in flight never blocks the switch', () async {
      final rig = _rig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final c = await _start(rig);
      rig.shared.writeGate = Completer<void>();
      unawaited(c.read(sharedProfileRepositoryProvider).pulse().catchError((Object _) {}));
      await _settle();
      expect(_ctl(c).blockReason(), isNull);
      rig.shared.writeGate!.complete();
    });

    test('a card that is not mine (friendships off elsewhere): denied, nothing written', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      _card(rig)['uid'] = 'uid-other';
      await _ctl(c).setSearchSharing(true, content: _preview(c));
      await _settle();
      expect(rig.shared.searches, isEmpty);
      expect(rig.doc, isNull);
    });
  });

  group('resultado incerto (B5, RF-SC6)', () {
    test(
      'ligar sem resposta: "incerto"; leitura posterior com as 3 seções e card on = T-S1',
      () async {
        final rig = _rig(discoverable: false)..seed(sharingMovie(1));
        final c = await _start(rig);
        rig.shared
          ..deliverUncertainToggles = true
          ..failNext('toggle', const SocialFailure(SocialFailureKind.uncertain, code: 'timeout'))
          ..failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
        expect(await _ctl(c).setSearchSharing(true, content: _preview(c)), isTrue);
        await _settle();
        expect(_st(c).uncertain, isTrue);
        expect(_mode(c), SharingMode.uncertain);
        expect(_ctl(c).blockReason(), isNotNull, reason: 'disabled while uncertain');
        rig.cloud.offline = true;
        await _settle();
        rig.cloud.offline = false;
        await _settle();
        expect(_st(c).uncertain, isNull);
        expect(_mode(c), SharingMode.on);
        expect(_st(c).notice!.text, kSearchOnDone);
      },
    );

    test('ligar que NÃO aconteceu: T-S3, continua desligado', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
      await _ctl(c).setSearchSharing(true, content: _preview(c));
      await _settle();
      expect(_st(c).uncertain, isNull);
      expect(_mode(c), SharingMode.off);
      expect(_st(c).notice!.text, kSearchOnFailed);
    });

    test('desligar que não aconteceu: continua ligado + kSharingOffFailed', () async {
      final rig = _rig()..seed(sharingMovie(1));
      rig.seedShared({...kSharingSections});
      final c = await _start(rig);
      rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
      await _ctl(c).setSearchSharing(false);
      await _settle();
      expect(_mode(c), SharingMode.on);
      expect(_st(c).notice!.text, kSharingOffFailed);
    });

    test(
      'desligar (só o cartão, E2 sem seções) que aconteceu: T-S2 decidido pelo cartão',
      () async {
        final rig = _rig()..seed(sharingMovie(1));
        final c = await _start(rig);
        rig.shared
          ..deliverUncertainToggles = true
          ..failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
        await _ctl(c).setSearchSharing(false);
        await _settle();
        expect(_card(rig)['discoverable'], isFalse);
        expect(_mode(c), SharingMode.off);
        expect(_st(c).notice!.text, kSearchOffDone);
      },
    );

    test('desligar (só o cartão) que NÃO aconteceu: kSharingOffFailed, nunca T-S2', () async {
      final rig = _rig()..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.failNext('toggle', const SocialFailure(SocialFailureKind.uncertain));
      await _ctl(c).setSearchSharing(false);
      await _settle();
      expect(_mode(c), SharingMode.review);
      expect(_st(c).notice!.text, kSharingOffFailed);
    });

    test('(A) uma leitura ANTERIOR ao fim da transação original não resolve o incerto', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared
        ..lateUncertainToggles = true
        ..failNext('toggle', const SocialFailure(SocialFailureKind.uncertain, code: 'timeout'));
      final op = _ctl(c).setSearchSharing(true, content: _preview(c));
      await _settle();
      expect(rig.shared.hasLateToggle, isTrue);
      // A reconnection read happens while the transaction is still running.
      rig.cloud.offline = true;
      await _settle();
      rig.cloud.offline = false;
      await _settle();
      expect(_st(c).uncertain, isTrue, reason: 'that read may predate the commit');
      rig.shared.commitLate();
      await op;
      await _settle();
      expect(_st(c).uncertain, isNull);
      expect(_mode(c), SharingMode.on);
      expect(_st(c).notice!.text, kSearchOnDone);
    });

    test('troca de conta durante a transação: nada do resultado entra na nova sessão', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      final c = await _start(rig);
      rig.shared.toggleGate = Completer<void>();
      final op = _ctl(c).setSearchSharing(true, content: _preview(c));
      await _settle();
      await rig.auth.signOut();
      await _settle();
      rig.shared.toggleGate!.complete();
      await op;
      await _settle();
      expect(_st(c).phase, SharingPhase.hidden);
      expect(_st(c).notice, isNull);
      expect(_st(c).doc, isNull);
    });
  });

  group('estados derivados (docs/95 §4, 1:1)', () {
    SocialState social({bool d = true, bool fromCache = false, SocialPhase? phase}) => SocialState(
      phase: phase ?? SocialPhase.active,
      profile: SocialProfile(handle: 'ana', discoverable: d),
      fromCache: fromCache,
    );
    SharingState sharing(Set<SharedSection>? s, {bool confirmed = true, bool? uncertain}) =>
        SharingState(
          phase: SharingPhase.ready,
          confirmed: confirmed,
          doc: s == null ? null : SharedProfileDoc(sharing: s),
          uncertain: uncertain,
        );
    const all = {SharedSection.stats, SharedSection.activity, SharedSection.recs};
    test('E0..E3, Ep, Ei and hidden', () {
      expect(sharingModeOf(social(d: false), sharing(null)), SharingMode.off);
      expect(sharingModeOf(social(), sharing(all)), SharingMode.on);
      expect(sharingModeOf(social(), sharing(null)), SharingMode.review);
      expect(sharingModeOf(social(), sharing({SharedSection.stats})), SharingMode.review);
      expect(
        sharingModeOf(social(), sharing({SharedSection.stats, SharedSection.recs})),
        SharingMode.review,
      );
      expect(sharingModeOf(social(d: false), sharing({SharedSection.recs})), SharingMode.legacy);
      expect(sharingModeOf(social(d: false), sharing(all)), SharingMode.legacy);
      expect(sharingModeOf(social(), sharing(null, confirmed: false)), SharingMode.pending);
      expect(sharingModeOf(social(fromCache: true), sharing(all)), SharingMode.pending);
      expect(sharingModeOf(social(phase: SocialPhase.loading), sharing(all)), SharingMode.pending);
      expect(sharingModeOf(social(), sharing(all, uncertain: true)), SharingMode.uncertain);
      expect(sharingModeOf(social(), const SharingState()), SharingMode.hidden);
    });
  });

  group('aviso: condição e "visto nesta sessão"', () {
    test('E1 (Caio, tudo compartilhado) e E0 (Davi, amigos por convite): nenhum aviso, nada '
        'escrito', () async {
      final caio = _rig()..seed(sharingMovie(1));
      caio.seedShared({...kSharingSections});
      final c1 = await _start(caio);
      expect(c1.read(sharingNoticeDueProvider), isNull);
      final davi = _rig(discoverable: false)..seed(sharingMovie(1));
      final c2 = await _start(davi);
      expect(c2.read(sharingNoticeDueProvider), isNull);
      expect(davi.shared.searches, isEmpty);
      expect(davi.shared.writeAttempts, 0);
    });

    test('seen in this session (per uid): not due again; a new session shows it again', () async {
      final rig = _rig()..seed(sharingMovie(1));
      final c = await _start(rig);
      expect(c.read(sharingNoticeDueProvider), SharingNoticeKind.review);
      c.read(sharingNoticeSeenProvider.notifier).state = {'uid-other'};
      expect(c.read(sharingNoticeDueProvider), SharingNoticeKind.review);
      c.read(sharingNoticeSeenProvider.notifier).state = {'uid-ana'};
      expect(c.read(sharingNoticeDueProvider), isNull);
      expect(_mode(c), SharingMode.review, reason: 'closing writes nothing');
      final next = await _start(rig);
      expect(next.read(sharingNoticeDueProvider), SharingNoticeKind.review);
    });

    test('legacy E3 keeps being recalculated (only its sections) until the choice', () async {
      final rig = _rig(discoverable: false)..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final c = await _start(rig);
      expect(_mode(c), SharingMode.legacy);
      expect(rig.doc!.containsKey('recs'), isFalse);
      expect(rig.doc!.containsKey('activity'), isFalse);
      expect(rig.doc!['sharing'], {'stats': true});
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

  group('Firestore source: "Aparecer na busca" (two documents, one transaction)', () {
    FirestoreSharedProfileDataSource source(
      Future<void> Function(
        String cardPath,
        String path,
        Future<void> Function(
          Map<String, dynamic>?,
          Map<String, dynamic>?,
          void Function(SocialWrite),
        )
        body,
      )
      run,
    ) => FirestoreSharedProfileDataSource(
      uid: 'uid-ana',
      toggleTimeout: const Duration(milliseconds: 50),
      searchTxRunner: run,
    );

    Future<SocialFailureKind?> kindOf(Future<void> f) async {
      try {
        await f;
        return null;
      } on SocialFailure catch (e) {
        return e.kind;
      }
    }

    SocialWrite empty(Map<String, dynamic>? a, Map<String, dynamic>? b) =>
        const SocialWrite(SocialWriteMode.transaction, []);

    test('reads the card and the own document and applies the planned write', () async {
      String? readCard;
      String? readDoc;
      SocialWrite? applied;
      Map<String, dynamic>? seenCard;
      final s = source((cardPath, path, body) async {
        readCard = cardPath;
        readDoc = path;
        await body({'uid': 'uid-ana', 'discoverable': false}, null, (w) => applied = w);
      });
      await s.searchAndShare('ana', (card, current) {
        seenCard = card;
        return SharedProfilePayloads.searchAndShare(
          'uid-ana',
          handle: 'ana',
          on: false,
          cardDiscoverable: card?['discoverable'] == true,
          current: null,
          now: kSharingNow,
        );
      });
      expect(readCard, 'handles/ana');
      expect(readDoc, 'shared_profiles/uid-ana');
      expect(seenCard, {'uid': 'uid-ana', 'discoverable': false});
      expect(applied!.ops, isEmpty);
    });

    test('unavailable before planning = offline; after applying = uncertain; timeout = '
        'uncertain; permission-denied = denied', () async {
      expect(
        await kindOf(
          source((c, p, b) async => throw _fx('unavailable')).searchAndShare('ana', empty),
        ),
        SocialFailureKind.offline,
      );
      final after = source((c, p, body) async {
        await body(null, null, (_) {});
        throw _fx('unavailable');
      });
      expect(await kindOf(after.searchAndShare('ana', empty)), SocialFailureKind.uncertain);
      expect(
        await kindOf(source((c, p, b) => Completer<void>().future).searchAndShare('ana', empty)),
        SocialFailureKind.uncertain,
      );
      expect(
        await kindOf(
          source((c, p, b) async => throw _fx('permission-denied')).searchAndShare('ana', empty),
        ),
        SocialFailureKind.denied,
      );
    });

    test('a batch-mode plan is refused (never half a consent)', () async {
      final s = source((c, p, body) => body(null, null, (_) {}));
      expect(
        () => s.searchAndShare('ana', (a, b) => const SocialWrite(SocialWriteMode.batch, [])),
        throwsStateError,
      );
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
