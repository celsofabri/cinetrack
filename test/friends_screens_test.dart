import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/friends_harness.dart';

void main() {
  group('/friends (Enviados)', () {
    testWidgets('empty: explains, offers "Adicionar amigo", no placeholders for later slices', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/friends?tab=pedidos');
      expect(find.text('Pedidos enviados'), findsOneWidget);
      expect(find.textContaining('Você não tem pedidos pendentes'), findsOneWidget);
      expect(find.textContaining('sem aviso'), findsOneWidget);
      expect(find.text('Adicionar amigo'), findsOneWidget);
      expect(find.textContaining('Recebidos'), findsNothing);
      expect(find.textContaining('Bloqueados'), findsNothing);
      expect(find.textContaining('em breve'), findsNothing);
      expect(app.social.log, isEmpty); // nothing was written
    });

    testWidgets('lists the sent requests, newest first, with date and a named cancel', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) {
          s.requests['uid-ana_uid-bruno'] = {
            'from': 'uid-ana',
            'to': 'uid-bruno',
            'fromName': 'Ana',
            'toName': 'Bruno',
            'createdAt': DateTime(2026, 9, 1),
          };
          s.requests['uid-ana_uid-c'] = {
            'from': 'uid-ana',
            'to': 'uid-c',
            'fromName': 'Ana',
            'toName': 'Caio',
            'createdAt': DateTime(2026, 9, 20),
          };
        },
      );
      expect(find.text('Caio'), findsOneWidget);
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.text('Enviado em 20/09/2026'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Caio')).dy < tester.getTopLeft(find.text('Bruno')).dy,
        isTrue,
      );
      expect(find.bySemanticsLabel('Cancelar pedido para Bruno'), findsOneWidget);
      expect(app.reads.where((r) => r == 'sent:page'), hasLength(1));
      semantics.dispose();
    });

    testWidgets('cancel asks first (focus on "Manter pedido"); confirming deletes', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => s.seedRequest('uid-ana', 'uid-bruno', toName: 'Bruno'),
      );
      await tester.tap(find.text('Cancelar pedido'));
      await tester.pumpAndSettle();
      expect(find.text('Cancelar o pedido para Bruno?'), findsOneWidget);
      expect(tester.widget<TextButton>(btn('Manter pedido')).autofocus, isTrue);
      await tester.tap(find.text('Manter pedido'));
      await tester.pumpAndSettle();
      expect(app.social.requests, hasLength(1));
      expect(find.text('Bruno'), findsOneWidget);

      await tester.tap(find.text('Cancelar pedido'));
      await tester.pumpAndSettle();
      await tester.tap(btn('Cancelar pedido').last);
      await tester.pumpAndSettle();
      expect(app.social.requests, isEmpty);
      expect(find.text('Bruno'), findsNothing);
      expect(find.text('Pedido cancelado.'), findsOneWidget);
      expect(find.textContaining('Você não tem pedidos pendentes'), findsOneWidget);
    });

    testWidgets('a cancel that fails keeps the item and says why', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => s.seedRequest('uid-ana', 'uid-bruno', toName: 'Bruno'),
      );
      app.social.failures['cancelRequest'] = const SocialFailure(SocialFailureKind.offline);
      await tester.tap(find.text('Cancelar pedido'));
      await tester.pumpAndSettle();
      await tester.tap(btn('Cancelar pedido').last);
      await tester.pumpAndSettle();
      expect(find.text('Sem conexão. Tente de novo quando estiver online.'), findsWidgets);
      expect(find.text('Bruno'), findsOneWidget);
    });

    testWidgets('paged: 20 first, "Ver mais" brings the rest, no extra reads before the tap', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        size: const Size(800, 6000),
        start: '/friends?tab=pedidos',
        seed: (s) => addSentRequests(s, 25),
      );
      expect(find.textContaining('Enviado em'), findsNWidgets(20));
      expect(find.text('Ver mais'), findsOneWidget);
      expect(app.reads.where((r) => r == 'sent:page'), hasLength(1));
      await tester.tap(find.text('Ver mais'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enviado em'), findsNWidgets(25));
      expect(find.text('Ver mais'), findsNothing);
      expect(app.reads.where((r) => r == 'sent:page'), hasLength(2));
    });

    testWidgets('error: honest message and "Tentar de novo"', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => s.failures['sentPage'] = const SocialFailure(SocialFailureKind.quotaExceeded),
      );
      expect(find.text('Muitas operações hoje. Tente de novo amanhã.'), findsOneWidget);
      await tester.tap(find.text('Tentar de novo'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Você não tem pedidos pendentes'), findsOneWidget);
      expect(app.reads.where((r) => r == 'sent:page'), hasLength(2));
    });

    testWidgets('offline: the saved list with the notice, cancel disabled', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => s.seedRequest('uid-ana', 'uid-bruno', toName: 'Bruno'),
      );
      // Leave and come back while offline (the first copy was fresh: TTL 0 forces a re-read).
      app.social.offline = true;
      app.cloud.offline = true;
      await tester.pump();
      app.container.read(sentRequestsControllerProvider.notifier).reload();
      await tester.pumpAndSettle();
      expect(find.textContaining('Mostrando a última lista salva'), findsOneWidget);
      expect(find.text('Bruno'), findsOneWidget);
      expect(tester.widget<TextButton>(btn('Cancelar pedido')).onPressed, isNull);
    });

    testWidgets('leaving and returning within the TTL does not read again', (tester) async {
      final app = await pumpFriends(tester, start: '/friends?tab=pedidos');
      expect(app.reads.where((r) => r == 'sent:page'), hasLength(1));
      app.router.go('/profile');
      await tester.pumpAndSettle();
      app.router.go('/friends?tab=pedidos');
      await tester.pumpAndSettle();
      expect(app.reads.where((r) => r == 'sent:page'), hasLength(1));
    });

    testWidgets('friendships off: invitation to turn them on in the Profile', (tester) async {
      final app = await pumpFriends(tester, active: false, start: '/friends');
      expect(find.textContaining('ative as amizades no seu Perfil'), findsOneWidget);
      expect(find.text('Adicionar amigo'), findsNothing);
      expect(app.reads.where((r) => r == 'sent:page'), isEmpty);
      await tester.tap(find.text('Ir para o Perfil'));
      await tester.pumpAndSettle();
      expect(app.location, '/profile');
    });

    testWidgets('rules not published: visible message and retry (nothing lost)', (tester) async {
      final app = await pumpFriends(tester, rulesLive: false, start: '/friends');
      expect(find.text('Amizades ainda não estão disponíveis. Tente mais tarde.'), findsOneWidget);
      app.social.rulesLive = true;
      await tester.tap(find.text('Tentar de novo'));
      await tester.pumpAndSettle();
      expect(find.text('Adicionar amigo'), findsOneWidget);
    });

    testWidgets('non-Google account: explains', (tester) async {
      await pumpFriends(
        tester,
        user: const AppUser(uid: 'uid-p', displayName: 'P', isGoogle: false),
        start: '/friends',
      );
      expect(find.textContaining('só estão disponíveis para contas'), findsOneWidget);
    });

    testWidgets('"Adicionar amigo" opens the search with the back path to /friends', (
      tester,
    ) async {
      await pumpFriends(tester, start: '/friends?tab=pedidos');
      await tester.tap(find.text('Adicionar amigo'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget); // the search screen
      await tester.tap(find.byTooltip('Voltar para Amigos'));
      await tester.pumpAndSettle();
      expect(find.text('Adicionar amigo'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('/friends/add (search and send)', () {
    testWidgets('opening and typing read NOTHING; one get per search', (tester) async {
      final app = await pumpFriends(tester, start: '/friends/add');
      final afterOpen = [...app.reads];
      expect(afterOpen, ['read']); // only the once-per-session social state
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'bru');
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'bruno');
      await tester.pump();
      expect(app.reads, afterOpen);
      await tester.testTextInput.receiveAction(TextInputAction.search); // Enter
      await tester.pumpAndSettle();
      expect(app.reads, [...afterOpen, 'lookup:bruno']);
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.text('@bruno'), findsOneWidget);
    });

    testWidgets('the field has focus on open; Tab reaches "Buscar"; Enter on it searches', (
      tester,
    ) async {
      final app = await pumpFriends(tester, size: const Size(1024, 800), start: '/friends/add');
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.autofocus, isTrue);
      expect(field.focusNode!.hasFocus, isTrue);
      expect(field.textInputAction, TextInputAction.search);
      await tester.enterText(find.byType(TextField), 'bruno');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(field.focusNode!.hasFocus, isFalse);
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        find.descendant(of: btn('Buscar'), matching: find.byElementPredicate((e) => e == focused)),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(app.reads, contains('lookup:bruno'));
      expect(find.text('@bruno'), findsOneWidget);
    });

    testWidgets('live validation: format errors in pt-BR, "Buscar" disabled until valid', (
      tester,
    ) async {
      await pumpFriends(tester, start: '/friends/add');
      expect(tester.widget<ButtonStyleButton>(btn('Buscar')).onPressed, isNull);
      expect(find.textContaining('Use pelo menos'), findsNothing);
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump();
      expect(find.text('Use pelo menos 3 caracteres.'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(btn('Buscar')).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'a b');
      await tester.pump();
      expect(find.textContaining('Use só letras minúsculas'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '@Bruno ');
      await tester.pump();
      expect(find.textContaining('Use '), findsNothing);
      expect(tester.widget<ButtonStyleButton>(btn('Buscar')).onPressed, isNotNull);
    });

    testWidgets('missing / hidden / blocked / yourself / reserved: IDENTICAL text, nothing else', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends/add',
        seed: (s) => s
          ..seedActive('uid-oculta', 'oculta', discoverable: false)
          ..seedActive('uid-blk', 'blk_me')
          ..seedBlock('uid-blk', 'uid-ana'),
      );
      for (final handle in ['ninguem', 'oculta', 'blk_me', 'ana', 'admin']) {
        await searchHandle(tester, handle);
        expect(
          find.text('Não encontramos ninguém com esse apelido'),
          findsOneWidget,
          reason: handle,
        );
        expect(find.text('Enviar pedido'), findsNothing, reason: handle);
        expect(find.textContaining('bloque'), findsNothing, reason: handle);
        expect(find.textContaining('oculto'), findsNothing, reason: handle);
        expect(find.textContaining('indispon'), findsNothing, reason: handle);
      }
      // yourself and reserved never even reached the server
      expect(app.reads.where((r) => r.startsWith('lookup:')), [
        'lookup:ninguem',
        'lookup:oculta',
        'lookup:blk_me',
      ]);
    });

    testWidgets('found: card with photo slot, nickname, @handle; "Enviar pedido" sends', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final app = await pumpFriends(tester, start: '/friends/add');
      await searchHandle(tester, 'bruno');
      expect(find.bySemanticsLabel('Enviar pedido para @bruno'), findsOneWidget);
      await tester.tap(find.text('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(app.social.requests.keys, ['uid-ana_uid-bruno']);
      expect(find.text('Pedido enviado'), findsOneWidget);
      expect(find.text('Pedido enviado.'), findsOneWidget); // snackbar
      expect(find.text('Enviar pedido'), findsNothing);
      await tester.tap(find.text('Ver pedidos enviados'));
      await tester.pumpAndSettle();
      expect(app.location, '/friends');
      expect(find.text('Bruno'), findsOneWidget); // already in the list, no extra read
      expect(app.reads.where((r) => r == 'sent:page'), hasLength(1));
      semantics.dispose();
    });

    testWidgets('editing the text drops the old result (it belongs to what was searched)', (
      tester,
    ) async {
      await pumpFriends(tester, start: '/friends/add');
      await searchHandle(tester, 'bruno');
      expect(find.text('Enviar pedido'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'bruna');
      await tester.pump();
      expect(find.text('Enviar pedido'), findsNothing);
    });

    testWidgets('already sent: known from the loaded list (no button), or on the send itself', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => s.seedRequest('uid-ana', 'uid-bruno', toName: 'Bruno'),
      );
      app.router.go('/friends/add');
      await tester.pumpAndSettle();
      await searchHandle(tester, 'bruno');
      expect(find.text('Você já enviou um pedido para essa pessoa.'), findsOneWidget);
      expect(find.text('Enviar pedido'), findsNothing);

      // Without the list in memory the transaction finds the duplicate.
      final cold = await pumpFriends(
        tester,
        start: '/friends/add',
        seed: (s) => s.seedRequest('uid-ana', 'uid-bruno', toName: 'Bruno'),
      );
      await searchHandle(tester, 'bruno');
      await tester.tap(find.text('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(find.text('Você já enviou um pedido para essa pessoa.'), findsOneWidget);
      expect(cold.social.requests, hasLength(1));
    });

    testWidgets('they already asked me (D4): it becomes a friendship, nothing pending is left', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends/add',
        seed: (s) => s.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno', toName: 'Ana'),
      );
      await searchHandle(tester, 'bruno');
      await tester.tap(find.text('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Vocês agora são amigos'), findsOneWidget);
      expect(find.textContaining('chegam em breve'), findsNothing);
      expect(find.text('Enviar pedido'), findsNothing);
      expect(app.social.requests, isEmpty);
      expect(app.social.friendships.keys, ['uid-ana_uid-bruno']);
    });

    testWidgets('limit of 50: explains, writes nothing', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends/add',
        seed: (s) => addSentRequests(s, 50),
      );
      await searchHandle(tester, 'bruno');
      await tester.tap(find.text('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(find.textContaining('limite de 50 pedidos'), findsOneWidget);
      expect(app.social.requests, hasLength(50));
    });

    testWidgets('a refusal by the rules shows one generic message and never the reason', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/friends/add');
      await searchHandle(tester, 'bruno');
      app.social.seedBlock('uid-bruno', 'uid-ana'); // they block me after I searched
      await tester.tap(find.text('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(
        find.text('Não foi possível enviar o pedido. Tente de novo mais tarde.'),
        findsOneWidget,
      );
      expect(find.textContaining('bloque'), findsNothing);
      expect(app.social.requests, isEmpty);
      // the button is still there to try again
      expect(find.text('Enviar pedido'), findsOneWidget);
    });

    testWidgets('search error (not "not found"): honest message and retry', (tester) async {
      final app = await pumpFriends(tester, start: '/friends/add');
      app.social.failures['lookup'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      await searchHandle(tester, 'bruno');
      expect(find.text('Muitas operações hoje. Tente de novo amanhã.'), findsOneWidget);
      await tester.tap(find.text('Tentar de novo'));
      await tester.pumpAndSettle();
      expect(find.text('@bruno'), findsOneWidget);
    });

    testWidgets('offline: search and send are disabled with the reason', (tester) async {
      final app = await pumpFriends(tester, start: '/friends/add');
      await searchHandle(tester, 'bruno');
      app.cloud.offline = true;
      await tester.pumpAndSettle();
      expect(find.text('Sem conexão. Tente de novo quando estiver online.'), findsWidgets);
      expect(tester.widget<ButtonStyleButton>(btn('Buscar')).onPressed, isNull);
      expect(tester.widget<ButtonStyleButton>(btn('Enviar pedido')).onPressed, isNull);
    });

    testWidgets('friendships off: invitation, no field', (tester) async {
      await pumpFriends(tester, active: false, start: '/friends/add');
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('ative as amizades no seu Perfil'), findsOneWidget);
    });
  });

  group('layout: 320-1440 px, font 1x/2x/3x, light/dark, targets >= 48 px', () {
    final longName = 'N' * 40;
    for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          testWidgets('$width px, font ${scale}x, ${brightness.name}', (tester) async {
            final size = Size(width, 3000);
            final app = await pumpFriends(
              tester,
              size: size,
              textScale: scale,
              brightness: brightness,
              start: '/friends?tab=pedidos',
              seed: (s) {
                addSentRequests(s, 3, name: (i) => i == 0 ? longName : 'Pessoa $i');
                s.seedActive('uid-long', 'long', nickname: longName);
              },
            );
            expect(tester.takeException(), isNull);
            for (final label in ['Adicionar amigo', 'Cancelar pedido']) {
              // The list is lazy: very large fonts push the sent requests below the fold.
              for (var i = 0; i < 40 && find.text(label).evaluate().isEmpty; i++) {
                await tester.drag(find.byType(ListView).first, const Offset(0, -300));
                await tester.pump();
              }
              final size = tester.getSize(btn(label).first);
              expect(size.height, greaterThanOrEqualTo(48), reason: label);
              expect(size.width, greaterThanOrEqualTo(48), reason: label);
            }
            final bar = tester.getRect(find.byType(Scaffold).last);
            expect(bar.width, lessThanOrEqualTo(width));

            app.router.go('/friends/add');
            await tester.pumpAndSettle();
            await searchHandle(tester, 'long');
            expect(tester.takeException(), isNull);
            expect(find.text('@long'), findsOneWidget);
            final send = tester.getSize(btn('Enviar pedido'));
            expect(send.height, greaterThanOrEqualTo(48));
            await tester.ensureVisible(find.text('Enviar pedido'));
            await tester.tap(find.text('Enviar pedido'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('the result area keeps its height: no layout shift between states', (tester) async {
      await pumpFriends(tester, start: '/friends/add');
      double top() => tester.getTopLeft(find.text('Buscar')).dy;
      final before = top();
      await searchHandle(tester, 'ninguem');
      expect(top(), before);
      await searchHandle(tester, 'bruno');
      expect(top(), before);
    });
  });
}
