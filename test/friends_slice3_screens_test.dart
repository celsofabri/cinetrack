import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/providers/social_lists_providers.dart';
import 'package:cinetrack/screens/friends_screen.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/widgets/app_shell.dart';

import 'support/friends_harness.dart';

/// Slice 3 (docs/62): tabs, friends list, received requests, accept /
/// decline / remove, badge and its 320 px fallback. Real router and providers
/// over the in-memory fakes.

bool _tabSelected(WidgetTester tester, String label) {
  final tabs = tester.widget<FriendsTabs>(find.byType(FriendsTabs));
  return tabs.selected == (label == 'Amigos' ? FriendsTab.friends : FriendsTab.requests);
}

Finder _tabLabel(String label) =>
    find.descendant(of: find.byType(FriendsTabs), matching: find.text(label));

Future<void> _goTab(WidgetTester tester, String label) async {
  await tester.tap(_tabLabel(label));
  await tester.pumpAndSettle();
}

bool _anyBadgeVisible(WidgetTester tester) =>
    tester.widgetList<Badge>(find.byType(Badge)).any((b) => b.isLabelVisible);

Finder _topBarIcon([String tooltip = 'Amigos']) =>
    find.descendant(of: find.byType(MobileTopBar), matching: find.byTooltip(tooltip));

void main() {
  group('tabs: Amigos | Pedidos', () {
    testWidgets(
      'opens on Amigos and reads ONLY the friends list; Pedidos reads received + sent once',
      (tester) async {
        final app = await pumpFriends(
          tester,
          start: '/friends',
          seed: (s) {
            addFriends(s, 2);
            addReceivedRequests(s, 1);
            addSentRequests(s, 1);
          },
        );
        expect(_tabSelected(tester, 'Amigos'), isTrue);
        expect(app.reads.where((r) => r == 'friends:page'), hasLength(1));
        expect(app.reads.where((r) => r == 'received:page' || r == 'sent:page'), isEmpty);
        await _goTab(tester, 'Pedidos');
        expect(_tabSelected(tester, 'Pedidos'), isTrue);
        expect(app.reads.where((r) => r == 'received:page'), hasLength(1));
        expect(app.reads.where((r) => r == 'sent:page'), hasLength(1));
        // back and forth inside the TTL: no new reads
        await _goTab(tester, 'Amigos');
        await _goTab(tester, 'Pedidos');
        expect(app.reads.where((r) => r == 'friends:page'), hasLength(1));
        expect(app.reads.where((r) => r == 'received:page'), hasLength(1));
      },
    );

    testWidgets('?tab=pedidos opens on Pedidos (received first, then sent)', (tester) async {
      await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) {
          addReceivedRequests(s, 1);
          addSentRequests(s, 1);
        },
      );
      expect(_tabSelected(tester, 'Pedidos'), isTrue);
      final received = tester.getTopLeft(find.text('Pedidos recebidos')).dy;
      final sent = tester.getTopLeft(find.text('Pedidos enviados')).dy;
      expect(received, lessThan(sent));
      expect(find.text('Remetente 0'), findsOneWidget);
    });

    testWidgets('keyboard: arrows move focus AND selection, Home/End jump, Tab leaves the group', (
      tester,
    ) async {
      await pumpFriends(tester, size: const Size(1024, 900), start: '/friends');
      // focus the selected tab by tapping it, then use the keys
      await tester.tap(_tabLabel('Amigos'));
      await tester.pump();
      expect(_tabSelected(tester, 'Amigos'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_tabSelected(tester, 'Pedidos'), isTrue);
      expect(find.text('Pedidos recebidos'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // wraps
      await tester.pumpAndSettle();
      expect(_tabSelected(tester, 'Amigos'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // wraps back
      await tester.pumpAndSettle();
      expect(_tabSelected(tester, 'Pedidos'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(_tabSelected(tester, 'Amigos'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(_tabSelected(tester, 'Pedidos'), isTrue);
      // the focused control is a tab (roving focus), and Enter/Space select it
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_tabSelected(tester, 'Amigos'), isTrue);
    });

    testWidgets('roving focus: Tab skips the tab that is not selected', (tester) async {
      await pumpFriends(tester, size: const Size(1024, 900), start: '/friends');
      final focusNodes = tester
          .widgetList<Focus>(
            find.descendant(of: find.byType(FriendsTabs), matching: find.byType(Focus)),
          )
          .where((f) => f.onKeyEvent != null)
          .toList();
      expect(focusNodes, hasLength(2));
      expect(focusNodes[0].skipTraversal, isFalse); // Amigos (selected)
      expect(focusNodes[1].skipTraversal, isTrue); // Pedidos
    });

    testWidgets('semantics: tab bar with two tabs, the selected one flagged, count in the label', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(tester, start: '/friends', seed: (s) => addReceivedRequests(s, 2));
      expect(find.bySemanticsLabel('Pedidos, 2 pedidos recebidos'), findsOneWidget);
      final amigos = tester.getSemantics(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Amigos'),
      );
      expect(amigos.flagsCollection.isSelected, Tristate.isTrue);
      final pedidos = tester.getSemantics(find.bySemanticsLabel('Pedidos, 2 pedidos recebidos'));
      expect(pedidos.flagsCollection.isSelected, isNot(Tristate.isTrue));
      semantics.dispose();
    });

    testWidgets('48 px targets for both tabs from 320 to 1440 px and fonts 1x to 3x, no overflow', (
      tester,
    ) async {
      for (final width in [320.0, 360.0, 768.0, 1440.0]) {
        for (final scale in [1.0, 2.0, 3.0]) {
          await pumpFriends(
            tester,
            size: Size(width, 2400),
            textScale: scale,
            start: '/friends',
            seed: (s) => addReceivedRequests(s, 3),
          );
          expect(tester.takeException(), isNull, reason: '$width x $scale');
          for (final label in ['Amigos', 'Pedidos']) {
            final box = tester.getSize(
              find.ancestor(of: _tabLabel(label), matching: find.byType(InkWell)).first,
            );
            expect(box.height, greaterThanOrEqualTo(48), reason: '$label $width x $scale');
            expect(box.width, greaterThanOrEqualTo(48), reason: '$label $width x $scale');
          }
        }
      }
    });
  });

  group('Amigos: list, states, remove', () {
    testWidgets('lists friends by name with photo slot and "Amigos desde"', (tester) async {
      await pumpFriends(
        tester,
        start: '/friends',
        seed: (s) => addFriends(s, 3, name: (i) => ['Zeca', 'Aline', 'Bia'][i]),
      );
      final order = [
        for (final n in ['Aline', 'Bia', 'Zeca']) tester.getTopLeft(find.text(n)).dy,
      ];
      expect(order, [...order]..sort());
      expect(find.textContaining('Amigos desde'), findsNWidgets(3));
      expect(find.text('Remover amizade'), findsNWidgets(3));
    });

    testWidgets('loading shows a skeleton (never a false "empty"), then the answer', (
      tester,
    ) async {
      final gate = Completer<void>();
      final app = await pumpFriends(tester, start: '/profile', seed: (s) => addFriends(s, 1));
      app.social.pageGate = gate;
      app.router.go('/friends');
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Você ainda não tem amigos'), findsNothing);
      expect(find.text('Amigo 0'), findsNothing);
      final loadingAvatars = find.byType(CircleAvatar).evaluate().length;
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Amigo 0'), findsOneWidget);
      expect(
        find.byType(CircleAvatar).evaluate().length,
        lessThan(loadingAvatars),
        reason: 'three skeleton rows became one real row',
      );
    });

    testWidgets('empty: explains, offers "Adicionar amigo" and says what a friend sees', (
      tester,
    ) async {
      await pumpFriends(tester, start: '/friends');
      expect(find.textContaining('Você ainda não tem amigos'), findsOneWidget);
      expect(find.textContaining('só o seu cartão'), findsOneWidget);
      expect(find.text('Adicionar amigo'), findsOneWidget);
    });

    testWidgets('error: honest message and "Tentar de novo"', (tester) async {
      final app = await pumpFriends(tester, start: '/profile');
      app.social.failures['friendsPage'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      addFriends(app.social, 1);
      app.router.go('/friends');
      await tester.pumpAndSettle();
      expect(find.text('Muitas operações hoje. Tente de novo amanhã.'), findsOneWidget);
      await tester.tap(find.text('Tentar de novo'));
      await tester.pumpAndSettle();
      expect(find.text('Amigo 0'), findsOneWidget);
    });

    testWidgets('offline: the saved list with the notice; removing is disabled', (tester) async {
      final app = await pumpFriends(tester, start: '/profile', seed: (s) => addFriends(s, 1));
      app.social.offline = true;
      app.cloud.offline = true;
      await tester.pump();
      app.router.go('/friends');
      await tester.pumpAndSettle();
      expect(find.textContaining('Mostrando a última lista salva'), findsOneWidget);
      expect(find.text('Amigo 0'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(btn('Remover amizade')).onPressed, isNull);
    });

    testWidgets('paged: 50 first, "Ver mais" brings the rest, no read before the tap', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        size: const Size(390, 20000),
        start: '/friends',
        seed: (s) => addFriends(s, 60),
      );
      expect(find.text('Remover amizade'), findsNWidgets(50));
      expect(app.reads.where((r) => r == 'friends:page'), hasLength(1));
      await tester.ensureVisible(find.text('Ver mais'));
      await tester.tap(find.text('Ver mais'));
      await tester.pumpAndSettle();
      expect(find.text('Remover amizade'), findsNWidgets(60));
      expect(find.text('Ver mais'), findsNothing);
      expect(app.reads.where((r) => r == 'friends:page'), hasLength(2));
    });

    testWidgets(
      'remove: asks first ("A pessoa não será avisada", focus on Cancelar); confirming deletes',
      (tester) async {
        final app = await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 2));
        await tester.tap(find.text('Remover amizade').first);
        await tester.pumpAndSettle();
        expect(find.text('Remover Amigo 0?'), findsOneWidget);
        expect(find.textContaining('A pessoa não será avisada'), findsOneWidget);
        final cancel = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancelar'));
        expect(cancel.autofocus, isTrue);
        // Esc closes without removing
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(app.social.friendships, hasLength(2));
        await tester.tap(find.text('Remover amizade').first);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Remover amizade'));
        await tester.pumpAndSettle();
        expect(find.text('Amizade removida.'), findsOneWidget);
        expect(app.social.friendships.keys, ['uid-ana_uid-f1']);
        expect(find.text('Amigo 0'), findsNothing);
        expect(app.social.log.where((e) => e == 'removeFriend'), hasLength(1));
      },
    );

    testWidgets('remove that fails keeps the friend and says why', (tester) async {
      final app = await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 1));
      app.social.offline = true;
      // the button is disabled offline, so fail the write instead
      app.social.offline = false;
      app.social.failures['removeFriend'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      await tester.tap(find.text('Remover amizade'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remover amizade'));
      await tester.pumpAndSettle();
      expect(find.text('Muitas operações hoje. Tente de novo amanhã.'), findsOneWidget);
      expect(find.text('Amigo 0'), findsOneWidget);
      expect(app.social.friendships, hasLength(1));
    });

    testWidgets('the semantic label of the remove button starts with the visible text', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 1));
      expect(find.bySemanticsLabel('Remover amizade com Amigo 0'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('Pedidos recebidos: accept, decline', () {
    testWidgets('card with name, date, "Aceitar" and "Recusar" with named semantics', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => addReceivedRequests(s, 2),
      );
      expect(find.text('Remetente 0'), findsOneWidget);
      expect(find.textContaining('Pedido de '), findsNWidgets(2));
      expect(find.text('Aceitar'), findsNWidgets(2));
      expect(find.text('Recusar'), findsNWidgets(2));
      expect(find.bySemanticsLabel('Aceitar pedido de Remetente 0'), findsOneWidget);
      expect(find.bySemanticsLabel('Recusar pedido de Remetente 0'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets(
      'accept: "Salvando..." while it runs (both buttons off), then friend + acknowledgement',
      (tester) async {
        final app = await pumpFriends(
          tester,
          start: '/friends?tab=pedidos',
          seed: (s) => addReceivedRequests(s, 1),
        );
        app.social.writeGate = Completer<void>();
        await tester.tap(find.text('Aceitar'));
        await tester.pump();
        expect(find.text('Salvando...'), findsOneWidget);
        expect(tester.widget<ButtonStyleButton>(btn('Salvando...')).onPressed, isNull);
        expect(tester.widget<ButtonStyleButton>(btn('Recusar')).onPressed, isNull);
        expect(
          app.social.friendships,
          isEmpty,
          reason: 'nothing happens before the server answers',
        );
        app.social.writeGate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('Amizade aceita: Remetente 0.'), findsOneWidget);
        expect(find.text('Remetente 0'), findsNothing);
        expect(find.textContaining('Nenhum pedido recebido'), findsOneWidget);
        expect(app.social.friendships.keys, ['uid-ana_uid-r0']);
        expect(app.social.requests, isEmpty);
        // the friend is already in the Amigos tab, with no list read
        await _goTab(tester, 'Amigos');
        expect(find.text('Remetente 0'), findsOneWidget);
      },
    );

    testWidgets('accept that is refused: generic message, the card goes away (it is gone)', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => addReceivedRequests(s, 1),
      );
      app.social.requests.clear(); // cancelled by the sender meanwhile
      await tester.tap(find.text('Aceitar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível aceitar o pedido'), findsOneWidget);
      expect(find.textContaining('bloque'), findsNothing, reason: 'never says why');
      expect(app.social.friendships, isEmpty);
      expect(find.text('Remetente 0'), findsNothing);
    });

    testWidgets('accept offline: the buttons are disabled with the reason', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/profile',
        seed: (s) => addReceivedRequests(s, 1),
      );
      app.social.offline = true;
      app.cloud.offline = true;
      await tester.pump();
      app.router.go('/friends?tab=pedidos');
      await tester.pumpAndSettle();
      expect(find.textContaining('Mostrando a última lista salva'), findsWidgets);
      expect(tester.widget<ButtonStyleButton>(btn('Aceitar')).onPressed, isNull);
      expect(tester.widget<ButtonStyleButton>(btn('Recusar')).onPressed, isNull);
    });

    testWidgets('decline: silent for the sender, acknowledged for me, no friendship', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => addReceivedRequests(s, 2),
      );
      // newest first: Remetente 1 is on top
      await tester.tap(find.text('Recusar').first);
      await tester.pumpAndSettle();
      expect(find.text('Pedido recusado. A pessoa não foi avisada.'), findsOneWidget);
      expect(find.text('Remetente 1'), findsNothing);
      expect(find.text('Remetente 0'), findsOneWidget);
      expect(app.social.requests.keys, ['uid-r0_uid-ana']);
      expect(app.social.friendships, isEmpty);
      // the only thing that reached the server is the delete
      expect(app.social.log.where((e) => e.contains('Request') || e.contains('accept')), [
        'declineRequest',
      ]);
    });

    testWidgets('empty: says what appears here and that declining is silent', (tester) async {
      await pumpFriends(tester, start: '/friends?tab=pedidos');
      expect(find.textContaining('Nenhum pedido recebido'), findsOneWidget);
      expect(find.textContaining('a pessoa não é avisada'), findsOneWidget);
    });

    testWidgets('capped at 50 with an honest note; "Atualizar" reads the first page again', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        size: const Size(390, 30000),
        start: '/friends?tab=pedidos',
        extraOverrides: [refreshCooldownProvider.overrideWithValue(Duration.zero)],
        seed: (s) => addReceivedRequests(s, 60),
      );
      expect(find.text('Aceitar'), findsNWidgets(20));
      for (var i = 0; i < 2; i++) {
        await tester.ensureVisible(find.text('Ver mais'));
        await tester.tap(find.text('Ver mais'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Aceitar'), findsNWidgets(50));
      expect(find.text('Ver mais'), findsNothing);
      expect(find.textContaining('Mostrando os 50 pedidos mais recentes'), findsOneWidget);
      final before = app.reads.where((r) => r == 'received:page').length;
      await tester.ensureVisible(find.text('Atualizar'));
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(app.reads.where((r) => r == 'received:page'), hasLength(before + 1));
    });
  });

  group('add friend: "já são amigos" and the crossed request', () {
    testWidgets('a person already in the loaded friends list says so, with no send button', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends',
        seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana', bName: 'Bruno'),
      );
      app.router.go('/friends/add');
      await tester.pumpAndSettle();
      await searchHandle(tester, 'bruno');
      expect(find.text('Vocês já são amigos.'), findsOneWidget);
      expect(find.text('Enviar pedido'), findsNothing);
    });

    testWidgets('crossed: "Ver amigos" leads to a list that already has the new friend', (
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
      expect(find.text('Amizade aceita.'), findsOneWidget); // snackbar
      await tester.tap(find.text('Ver amigos'));
      await tester.pumpAndSettle();
      expect(app.location, '/friends');
      expect(find.text('Bruno'), findsOneWidget);
    });
  });

  group('badge on the Amigos icon and its 320 px fallback', () {
    testWidgets(
      'mobile: numeric badge, semantic label "Amigos, N pedidos recebidos", opens Pedidos',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final app = await pumpFriends(tester, seed: (s) => addReceivedRequests(s, 2));
        expect(_topBarIcon('Amigos, 2 pedidos recebidos'), findsOneWidget);
        expect(
          find.descendant(of: find.byType(MobileTopBar), matching: find.text('2')),
          findsOneWidget,
        );
        // an icon button speaks its tooltip: the sentence starts with the visible word
        expect(_topBarIcon('Amigos, 2 pedidos recebidos'), findsOneWidget);
        expect(app.countReads, hasLength(1), reason: 'one aggregate read for the badge');
        await tester.tap(_topBarIcon('Amigos, 2 pedidos recebidos'));
        await tester.pumpAndSettle();
        expect(app.location, '/friends');
        expect(_tabSelected(tester, 'Pedidos'), isTrue);
        expect(find.text('Remetente 0'), findsOneWidget);
        semantics.dispose();
      },
    );

    testWidgets('tapping the badge while /friends is already open on Amigos switches to Pedidos', (
      tester,
    ) async {
      await pumpFriends(tester, start: '/friends', seed: (s) => addReceivedRequests(s, 2));
      expect(_tabSelected(tester, 'Amigos'), isTrue);
      await tester.tap(_topBarIcon('Amigos, 2 pedidos recebidos'));
      await tester.pumpAndSettle();
      expect(_tabSelected(tester, 'Pedidos'), isTrue);
      expect(find.text('Remetente 0'), findsOneWidget);
    });

    testWidgets('one pending request: singular label; none: plain "Amigos" and no number', (
      tester,
    ) async {
      await pumpFriends(tester, seed: (s) => addReceivedRequests(s, 1));
      expect(_topBarIcon('Amigos, 1 pedido recebido'), findsOneWidget);
      await pumpFriends(tester);
      expect(_topBarIcon('Amigos'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(MobileTopBar), matching: find.byType(Badge)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Badge>(
              find.descendant(of: find.byType(MobileTopBar), matching: find.byType(Badge)),
            )
            .isLabelVisible,
        isFalse,
      );
    });

    testWidgets('50 or more shows "50+"', (tester) async {
      await pumpFriends(tester, seed: (s) => addReceivedRequests(s, 55));
      expect(
        find.descendant(of: find.byType(MobileTopBar), matching: find.text('50+')),
        findsOneWidget,
      );
      expect(_topBarIcon('Amigos, 50 ou mais pedidos recebidos'), findsOneWidget);
    });

    testWidgets('accepting and declining update the badge without another aggregate read', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => addReceivedRequests(s, 2),
      );
      expect(_topBarIcon('Amigos, 2 pedidos recebidos'), findsOneWidget);
      await tester.tap(find.text('Aceitar').first);
      await tester.pumpAndSettle();
      expect(_topBarIcon('Amigos, 1 pedido recebido'), findsOneWidget);
      await tester.tap(find.text('Recusar').first);
      await tester.pumpAndSettle();
      expect(_topBarIcon('Amigos'), findsOneWidget);
      // The one aggregate read happened when the bar first showed the badge (before the list);
      // answering requests never asks again.
      expect(app.countReads, hasLength(1));
    });

    testWidgets('Profile: "Gerenciar amigos" carries the badge and the number in its label', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(
        tester,
        size: const Size(390, 2400),
        start: '/profile',
        seed: (s) => addReceivedRequests(s, 3),
      );
      expect(find.bySemanticsLabel('Gerenciar amigos, 3 pedidos recebidos'), findsOneWidget);
      await tester.ensureVisible(find.text('Gerenciar amigos'));
      await tester.tap(find.text('Gerenciar amigos'));
      await tester.pumpAndSettle();
      // (a push does not change the URL: the screen itself is the proof)
      expect(_tabSelected(tester, 'Pedidos'), isTrue);
      expect(find.text('Remetente 0'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('desktop top menu: badge on the Amigos item (label and icon-only forms)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(
        tester,
        size: const Size(1440, 900),
        seed: (s) => addReceivedRequests(s, 2),
      );
      expect(find.text('Amigos'), findsOneWidget); // visible word first
      expect(find.bySemanticsLabel('Amigos, 2 pedidos recebidos'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await pumpFriends(tester, size: const Size(800, 800), seed: (s) => addReceivedRequests(s, 2));
      expect(find.byTooltip('Amigos, 2 pedidos recebidos'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('no friendships / signed out: no badge and no aggregate read', (tester) async {
      final app = await pumpFriends(tester, active: false);
      expect(_anyBadgeVisible(tester), isFalse);
      expect(app.countReads, isEmpty);
      final out = await pumpFriends(tester, user: null);
      expect(_anyBadgeVisible(tester), isFalse);
      expect(out.countReads, isEmpty);
    });

    // 320 px with a 3x font: no room next to the logo and the name (friendsIconFits).
    for (final width in [320.0, 360.0]) {
      testWidgets(
        'fallback at $width px, font 3x: the icon gives way, Perfil gets a dot with the label',
        (tester) async {
          final semantics = tester.ensureSemantics();
          final app = await pumpFriends(
            tester,
            size: Size(width, 800),
            textScale: 3,
            seed: (s) => addReceivedRequests(s, 2),
          );
          expect(tester.takeException(), isNull);
          expect(
            find.descendant(
              of: find.byType(MobileTopBar),
              matching: find.byIcon(Icons.people_outline),
            ),
            findsNothing,
          );
          expect(find.byTooltip('Perfil, 2 pedidos de amizade recebidos'), findsOneWidget);
          final dot = tester.widget<Badge>(
            find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)).first,
          );
          expect(dot.isLabelVisible, isTrue);
          expect(dot.label, isNull, reason: 'a dot, not a number');
          // the way to the requests stays: Perfil -> Gerenciar amigos
          await tester.tap(find.byTooltip('Perfil, 2 pedidos de amizade recebidos'));
          await tester.pumpAndSettle();
          expect(app.location, '/profile');
          semantics.dispose();
        },
      );
    }

    testWidgets('no pending requests at 320 px 3x: no dot', (tester) async {
      await pumpFriends(tester, size: const Size(320, 800), textScale: 3);
      expect(find.byTooltip('Perfil'), findsOneWidget);
      final badges = tester.widgetList<Badge>(
        find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)),
      );
      expect(badges.every((b) => !b.isLabelVisible), isTrue);
    });

    for (final width in [320.0, 360.0, 390.0, 768.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        testWidgets(
          'top bar $width px font ${scale}x with a badge: no overflow, icon inside the bar',
          (tester) async {
            for (final brightness in [Brightness.light, Brightness.dark]) {
              await pumpFriends(
                tester,
                size: Size(width, 700),
                textScale: scale,
                brightness: brightness,
                seed: (s) => addReceivedRequests(s, 12),
              );
              expect(tester.takeException(), isNull);
              final bar = tester.getRect(find.byType(MobileTopBar));
              final icon = _topBarIcon('Amigos, 12 pedidos recebidos');
              if (icon.evaluate().isNotEmpty) {
                expect(tester.getRect(icon).right, lessThanOrEqualTo(bar.right));
                expect(tester.getSize(icon).width, greaterThanOrEqualTo(48));
              }
            }
          },
        );
      }
    }
  });

  group('badge renewal (no listener): navigation and coming back to the front, within the TTL', () {
    testWidgets('after the TTL a navigation asks again ONCE; before it, never', (tester) async {
      var now = DateTime.utc(2026, 10, 5, 12);
      final app = await pumpFriends(
        tester,
        seed: (s) => addReceivedRequests(s, 1),
        extraOverrides: [socialClockProvider.overrideWithValue(() => now)],
      );
      expect(app.countReads, hasLength(1));
      expect(_topBarIcon('Amigos, 1 pedido recebido'), findsOneWidget);
      addReceivedRequests(app.social, 3); // 3 new requests arrive meanwhile (same names reused)
      now = now.add(const Duration(minutes: 9));
      app.router.go('/favorites');
      await tester.pumpAndSettle();
      app.router.go('/');
      await tester.pumpAndSettle();
      expect(app.countReads, hasLength(1), reason: 'inside the TTL: no read');
      now = now.add(const Duration(minutes: 2));
      app.router.go('/favorites');
      await tester.pumpAndSettle();
      expect(app.countReads, hasLength(2), reason: 'past the TTL: one read');
      expect(_topBarIcon('Amigos, 3 pedidos recebidos'), findsOneWidget);
      app.router.go('/');
      await tester.pumpAndSettle();
      expect(app.countReads, hasLength(2));
    });

    testWidgets('coming back to the front past the TTL asks again; before it, not', (tester) async {
      var now = DateTime.utc(2026, 10, 5, 12);
      final app = await pumpFriends(
        tester,
        seed: (s) => addReceivedRequests(s, 1),
        extraOverrides: [socialClockProvider.overrideWithValue(() => now)],
      );
      expect(app.countReads, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 5));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(app.countReads, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 6));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(app.countReads, hasLength(2));
    });

    testWidgets(
      'the badge in Pedidos while viewing Amigos brings you to Pedidos (URL already ?tab=pedidos)',
      (tester) async {
        final app = await pumpFriends(
          tester,
          start: '/friends?tab=pedidos',
          seed: (s) => addReceivedRequests(s, 2),
        );
        await _goTab(tester, 'Amigos');
        expect(_tabSelected(tester, 'Amigos'), isTrue);
        expect(app.router.routeInformationProvider.value.uri.toString(), '/friends');
        await tester.tap(_topBarIcon('Amigos, 2 pedidos recebidos'));
        await tester.pumpAndSettle();
        expect(_tabSelected(tester, 'Pedidos'), isTrue);
      },
    );
  });

  group('Amigos: order and "Atualizar"', () {
    testWidgets(
      'accents sort with their letter (Álvaro before Zé); the Atualizar button respects the cooldown',
      (tester) async {
        final app = await pumpFriends(
          tester,
          start: '/friends',
          seed: (s) => addFriends(s, 3, name: (i) => ['Zé', 'Álvaro', 'Bia'][i]),
        );
        double y(String n) => tester.getTopLeft(find.text(n)).dy;
        expect(y('Álvaro'), lessThan(y('Bia')));
        expect(y('Bia'), lessThan(y('Zé')));
        expect(app.reads.where((r) => r == 'friends:page'), hasLength(1));
        await tester.tap(find.text('Atualizar'));
        await tester.pumpAndSettle();
        expect(
          app.reads.where((r) => r == 'friends:page'),
          hasLength(1),
          reason: 'just read: cooldown',
        );
      },
    );

    testWidgets('Atualizar past the cooldown reads the first page again and shows the news', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends',
        seed: (s) => addFriends(s, 1),
        extraOverrides: [refreshCooldownProvider.overrideWithValue(Duration.zero)],
      );
      addFriends(app.social, 2); // Amigo 1 appears on the server
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(app.reads.where((r) => r == 'friends:page'), hasLength(2));
      expect(find.text('Amigo 1'), findsOneWidget);
    });

    testWidgets('"Ver mais" never reorders what is on screen: the new page goes to the end', (
      tester,
    ) async {
      await pumpFriends(
        tester,
        size: const Size(390, 20000),
        start: '/friends',
        // doc-id order puts f0..f9 first, names run backwards: page 2 would sort BEFORE page 1
        seed: (s) => addFriends(s, 60, name: (i) => 'N${(99 - i).toString().padLeft(2, '0')}'),
      );
      final firstBefore = tester.getTopLeft(find.text('N99')).dy;
      final listed = find.textContaining(RegExp(r'^N\d\d$')).evaluate().length;
      expect(listed, 50);
      await tester.ensureVisible(find.text('Ver mais'));
      await tester.tap(find.text('Ver mais'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('N99')).dy, firstBefore, reason: 'page 1 did not move');
      // the 10 new ones come after the 50 shown, ordered among themselves
      final lastShown = tester.getTopLeft(find.text('N50')).dy;
      expect(tester.getTopLeft(find.text('N40')).dy, greaterThan(lastShown));
    });
  });

  group('layout with data: 320 to 1440 px, fonts 1x to 3x, light and dark', () {
    const longName = 'Maria Eduarda de Albuquerque Cavalcanti Nascimento';
    for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          testWidgets(
            '$width px, font ${scale}x, ${brightness.name}: both tabs, targets >= 48 px',
            (tester) async {
              final app = await pumpFriends(
                tester,
                size: Size(width, 4000),
                textScale: scale,
                brightness: brightness,
                start: '/friends',
                seed: (s) {
                  addFriends(s, 2, name: (i) => i == 0 ? longName : 'Amigo $i');
                  addReceivedRequests(s, 2, name: (i) => i == 0 ? longName : 'Remetente $i');
                  addSentRequests(s, 1);
                },
              );
              expect(tester.takeException(), isNull);
              for (final label in ['Adicionar amigo', 'Remover amizade']) {
                final box = tester.getSize(btn(label).first);
                expect(box.height, greaterThanOrEqualTo(48), reason: label);
                expect(box.width, greaterThanOrEqualTo(48), reason: label);
              }
              await tester.tap(find.text('Pedidos').last);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              for (final label in ['Aceitar', 'Recusar', 'Atualizar']) {
                final box = tester.getSize(btn(label).first);
                expect(box.height, greaterThanOrEqualTo(48), reason: label);
                expect(box.width, greaterThanOrEqualTo(48), reason: label);
              }
              expect(app.location, '/friends');
              final bar = tester.getRect(find.byType(Scaffold).last);
              expect(bar.width, lessThanOrEqualTo(width));
            },
          );
        }
      }
    }

    testWidgets('no layout shift: the tab row keeps its place while the lists load and fill', (
      tester,
    ) async {
      await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 3));
      final y = tester.getTopLeft(find.byType(FriendsTabs)).dy;
      await _goTab(tester, 'Pedidos');
      expect(tester.getTopLeft(find.byType(FriendsTabs)).dy, y);
    });
  });

  group('redirect', () {
    testWidgets('signed out: /friends?tab=pedidos goes home', (tester) async {
      final app = await pumpFriends(tester, user: null, start: '/friends?tab=pedidos');
      expect(app.location, '/');
      expect(find.text('Pedidos recebidos'), findsNothing);
    });
  });
}
