import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/providers/social_lists_providers.dart';
import 'package:cinetrack/screens/friends_screen.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/fake_social_cloud.dart';
import 'support/friends_harness.dart';

/// Slice 4 (docs/65): block from a friend card, a received request and a
/// search result; the "Bloqueados" tab; unblock; "Atualizar" feedback
/// (docs/64 🟢-2). Real router and providers over the in-memory fakes.

Finder _tab(String label) =>
    find.descendant(of: find.byType(FriendsTabs), matching: find.text(label));

bool _selected(WidgetTester tester, FriendsTab tab) =>
    tester.widget<FriendsTabs>(find.byType(FriendsTabs)).selected == tab;

Future<void> _openBlockedTab(WidgetTester tester) async {
  await tester.tap(_tab('Bloqueados'));
  await tester.pumpAndSettle();
}

// Midday UTC: the same calendar day in every time zone the date is shown in.
DateTime _day(int d) => DateTime.utc(2026, 9, d, 15);

void main() {
  group('Bloqueados tab: states', () {
    testWidgets('?tab=bloqueados opens it and reads ONLY the blocked page', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=bloqueados',
        seed: (s) => s.seedBlock('uid-ana', 'uid-x', name: 'Xavier', at: _day(3)),
      );
      expect(_selected(tester, FriendsTab.blocked), isTrue);
      expect(find.text('Pessoas bloqueadas'), findsOneWidget);
      expect(find.text('Xavier'), findsOneWidget);
      expect(find.text('Bloqueado em 03/09/2026'), findsOneWidget);
      expect(app.reads.where((r) => r == 'blocked:page'), hasLength(1));
      expect(app.reads.where((r) => r == 'friends:page' || r == 'received:page'), isEmpty);
    });

    testWidgets('picking the tab changes the address and does not accumulate history', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/friends');
      await _openBlockedTab(tester);
      expect(app.router.routeInformationProvider.value.uri.toString(), '/friends?tab=bloqueados');
      await tester.tap(_tab('Amigos'));
      await tester.pumpAndSettle();
      expect(app.router.routeInformationProvider.value.uri.toString(), '/friends');
    });

    testWidgets('empty: explains what blocking does and where to block; nothing is invented', (
      tester,
    ) async {
      await pumpFriends(tester, start: '/friends?tab=bloqueados');
      expect(find.textContaining('Você não bloqueou ninguém'), findsOneWidget);
      expect(find.textContaining('não é avisado'), findsOneWidget);
      expect(find.textContaining('Só você vê esta lista'), findsOneWidget);
      expect(find.text('Desbloquear'), findsNothing);
    });

    testWidgets('loading shows a skeleton, never a false "empty"', (tester) async {
      final gate = Completer<void>();
      final app = await pumpFriends(tester, start: '/profile');
      app.social.pageGate = gate;
      app.router.go('/friends?tab=bloqueados');
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Você não bloqueou ninguém'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Você não bloqueou ninguém'), findsOneWidget);
    });

    testWidgets('error: honest message and "Tentar de novo" brings the list', (tester) async {
      final app = await pumpFriends(tester, start: '/profile');
      app.social.failures['blockedPage'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      app.social.seedBlock('uid-ana', 'uid-x', name: 'Xavier');
      app.router.go('/friends?tab=bloqueados');
      await tester.pumpAndSettle();
      expect(find.text('Muitas operações hoje. Tente de novo amanhã.'), findsOneWidget);
      await tester.tap(find.text('Tentar de novo'));
      await tester.pumpAndSettle();
      expect(find.text('Xavier'), findsOneWidget);
    });

    testWidgets('offline: the list from the device, flagged; "Desbloquear" is disabled', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/profile');
      app.social.seedBlock('uid-ana', 'uid-x', name: 'Xavier');
      app.social.offline = true;
      app.cloud.offline = true;
      await tester.pump();
      app.router.go('/friends?tab=bloqueados');
      await tester.pumpAndSettle();
      expect(find.textContaining('Mostrando a última lista salva'), findsOneWidget);
      expect(find.text('Xavier'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(btn('Desbloquear')).onPressed, isNull);
    });

    testWidgets('paged: 20 first, "Ver mais" brings the rest', (tester) async {
      final app = await pumpFriends(
        tester,
        size: const Size(390, 20000),
        start: '/friends?tab=bloqueados',
        seed: (s) {
          for (var i = 0; i < 25; i++) {
            s.seedBlock(
              'uid-ana',
              'uid-b$i',
              name: 'Pessoa $i',
              at: _day(1).add(Duration(hours: i)),
            );
          }
        },
      );
      expect(find.text('Desbloquear'), findsNWidgets(20));
      expect(find.text('Pessoa 24'), findsOneWidget, reason: 'newest block first');
      await tester.ensureVisible(find.text('Ver mais'));
      await tester.tap(find.text('Ver mais'));
      await tester.pumpAndSettle();
      expect(find.text('Desbloquear'), findsNWidgets(25));
      expect(app.reads.where((r) => r == 'blocked:page'), hasLength(2));
    });

    testWidgets('friendships off: the gate invites to the Profile, nothing is read', (
      tester,
    ) async {
      final app = await pumpFriends(tester, active: false, start: '/friends?tab=bloqueados');
      expect(find.textContaining('ative as amizades no seu Perfil'), findsOneWidget);
      expect(find.byType(FriendsTabs), findsNothing);
      expect(app.reads.where((r) => r == 'blocked:page'), isEmpty);
    });

    testWidgets('signed out: /friends?tab=bloqueados goes home', (tester) async {
      final app = await pumpFriends(tester, user: null, start: '/friends?tab=bloqueados');
      expect(app.location, '/');
    });

    testWidgets('rules not published: the gate shows the unavailable message, no tab', (
      tester,
    ) async {
      await pumpFriends(tester, rulesLive: false, start: '/friends?tab=bloqueados');
      expect(find.textContaining('Amizades ainda não estão disponíveis'), findsOneWidget);
      expect(find.byType(FriendsTabs), findsNothing);
    });
  });

  group('unblock', () {
    testWidgets('asks first (focus on Cancelar, Esc closes); confirming deletes only the block', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=bloqueados',
        seed: (s) {
          s.seedBlock('uid-ana', 'uid-x', name: 'Xavier');
          s.seedFriendship('uid-ana', 'uid-f', aName: 'Ana', bName: 'Fulano');
        },
      );
      await tester.tap(find.text('Desbloquear'));
      await tester.pumpAndSettle();
      expect(find.text('Desbloquear Xavier?'), findsOneWidget);
      expect(find.textContaining('A amizade e os pedidos de antes não voltam'), findsOneWidget);
      expect(find.textContaining('Ela não será avisada'), findsOneWidget);
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancelar')).autofocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(app.social.blocks['uid-ana'], isNotEmpty);
      await tester.tap(find.text('Desbloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Desbloquear'));
      await tester.pumpAndSettle();
      expect(find.text('Pessoa desbloqueada. A amizade não foi restaurada.'), findsOneWidget);
      expect(find.text('Xavier'), findsNothing);
      expect(app.social.blocks['uid-ana'], isEmpty);
      expect(app.social.friendships.keys, ['uid-ana_uid-f'], reason: 'nothing else touched');
      expect(app.social.log.where((e) => e == 'unblockUser'), hasLength(1));
    });

    testWidgets('shows "Desbloqueando..." and disables the button while the server answers', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=bloqueados',
        seed: (s) => s.seedBlock('uid-ana', 'uid-x', name: 'Xavier'),
      );
      app.social.writeGate = Completer<void>();
      await tester.tap(find.text('Desbloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Desbloquear'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Desbloqueando...'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(btn('Desbloqueando...')).onPressed, isNull);
      expect(find.text('Xavier'), findsOneWidget, reason: 'not gone before the server says so');
      app.social.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Xavier'), findsNothing);
    });

    testWidgets('a failed unblock keeps the person and says why', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=bloqueados',
        seed: (s) => s.seedBlock('uid-ana', 'uid-x', name: 'Xavier'),
      );
      app.social.failures['unblockUser'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      await tester.tap(find.text('Desbloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Desbloquear'));
      await tester.pumpAndSettle();
      expect(find.text('Muitas operações hoje. Tente de novo amanhã.'), findsOneWidget);
      expect(find.text('Xavier'), findsOneWidget);
    });

    testWidgets('semantic labels start with the visible text and name the person', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(
        tester,
        start: '/friends?tab=bloqueados',
        seed: (s) => s.seedBlock('uid-ana', 'uid-x', name: 'Xavier'),
      );
      expect(find.bySemanticsLabel('Desbloquear Xavier'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('block from a friend card', () {
    testWidgets('explains everything first; cancelling writes nothing', (tester) async {
      final app = await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 1));
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      expect(find.text('Bloquear Amigo 0?'), findsOneWidget);
      expect(find.textContaining('deixam de ser amigos'), findsOneWidget);
      expect(
        find.textContaining('pedidos pendentes entre vocês, nos dois sentidos'),
        findsOneWidget,
      );
      expect(find.textContaining('A pessoa não é avisada'), findsOneWidget);
      expect(find.textContaining('não encontra mais você na busca'), findsOneWidget);
      expect(find.textContaining('a amizade não volta'), findsOneWidget);
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancelar')).autofocus,
        isTrue,
      );
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(app.social.blocks, isEmpty);
      expect(app.social.friendships, hasLength(1));
      expect(find.text('Amigo 0'), findsOneWidget);
    });

    testWidgets(
      'confirming: "Bloqueando...", then the friend is gone, honest SnackBar, tab lists them',
      (tester) async {
        final app = await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 2));
        app.social.writeGate = Completer<void>();
        await tester.tap(find.text('Bloquear').first);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Bloqueando...'), findsOneWidget);
        expect(tester.widget<ButtonStyleButton>(btn('Bloqueando...')).onPressed, isNull);
        expect(
          tester.widget<ButtonStyleButton>(btn('Remover amizade').first).onPressed,
          isNull,
          reason: 'remove is locked while blocking',
        );
        expect(find.text('Amigo 0'), findsOneWidget);
        app.social.writeGate!.complete();
        await tester.pumpAndSettle();
        expect(find.text(kBlockedMessage), findsOneWidget);
        expect(find.text('Amigo 0'), findsNothing);
        expect(find.text('Amigo 1'), findsOneWidget);
        expect(app.social.friendships.keys, ['uid-ana_uid-f1']);
        expect(app.social.blocks['uid-ana']!.keys, ['uid-f0']);
        final readsBefore = app.reads.length;
        await _openBlockedTab(tester);
        expect(find.text('Amigo 0'), findsOneWidget);
        expect(app.reads.sublist(readsBefore), ['blocked:page'], reason: 'one page, nothing else');
      },
    );

    testWidgets('a refused block says so generically and reads the list again', (tester) async {
      final app = await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 1));
      app.social.seedBlock('uid-ana', 'uid-f0', name: 'Amigo 0'); // already blocked elsewhere
      final before = app.reads.where((r) => r == 'friends:page').length;
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível bloquear agora'), findsOneWidget);
      expect(find.text('Bloqueando...'), findsNothing);
      expect(app.reads.where((r) => r == 'friends:page').length, before + 1);
    });

    testWidgets('offline: "Bloquear" is disabled (blocking needs the server)', (tester) async {
      final app = await pumpFriends(tester, start: '/profile', seed: (s) => addFriends(s, 1));
      app.cloud.offline = true;
      await tester.pump();
      app.router.go('/friends');
      await tester.pumpAndSettle();
      expect(tester.widget<ButtonStyleButton>(btn('Bloquear')).onPressed, isNull);
      expect(tester.widget<ButtonStyleButton>(btn('Remover amizade')).onPressed, isNull);
    });

    testWidgets('semantic labels start with the visible text and name the person', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 1));
      expect(find.bySemanticsLabel('Bloquear Amigo 0'), findsOneWidget);
      semantics.dispose();
    });
  });

  group('block from a received request', () {
    testWidgets('the request disappears, the badge drops, the sender is in Bloqueados', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => addReceivedRequests(s, 2),
      );
      expect(find.text('Pedidos, 2 pedidos recebidos'), findsNothing); // visible text only
      final bar = tester.widget<FriendsTabs>(find.byType(FriendsTabs));
      expect(bar.pending, 2);
      await tester.tap(find.text('Bloquear').first);
      await tester.pumpAndSettle();
      expect(find.text('Bloquear Remetente 1?'), findsOneWidget, reason: 'newest first');
      await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
      await tester.pumpAndSettle();
      expect(find.text(kBlockedMessage), findsOneWidget);
      expect(find.text('Remetente 1'), findsNothing);
      expect(find.text('Remetente 0'), findsOneWidget);
      expect(tester.widget<FriendsTabs>(find.byType(FriendsTabs)).pending, 1);
      expect(app.social.requests.keys, ['uid-r0_uid-ana']);
      expect(app.social.blocks['uid-ana']!.keys, ['uid-r1']);
    });

    testWidgets('while saving, accept / decline / block are all locked', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => addReceivedRequests(s, 1),
      );
      app.social.writeGate = Completer<void>();
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
      await tester.pump();
      await tester.pump();
      for (final label in ['Aceitar', 'Recusar', 'Bloqueando...']) {
        expect(tester.widget<ButtonStyleButton>(btn(label)).onPressed, isNull, reason: label);
      }
      app.social.writeGate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('block also cancels the request I SENT to that person (Enviados forgets them)', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) {
          addReceivedRequests(s, 1);
          s.requests['uid-ana_uid-r0'] = {
            'from': 'uid-ana',
            'to': 'uid-r0',
            'fromName': 'Ana',
            'toName': 'Remetente 0',
            'createdAt': DateTime.now().subtract(const Duration(days: 1)),
          };
        },
      );
      expect(find.text('Cancelar pedido'), findsOneWidget);
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
      await tester.pumpAndSettle();
      expect(find.text('Cancelar pedido'), findsNothing);
      expect(app.social.requests, isEmpty);
    });
  });

  group('block from a search result', () {
    testWidgets(
      '"Bloquear" is on the card; after blocking the card says so and the person is not found again',
      (tester) async {
        final app = await pumpFriends(tester, start: '/friends/add');
        await searchHandle(tester, 'bruno');
        expect(find.text('Enviar pedido'), findsOneWidget);
        expect(find.text('Bloquear'), findsOneWidget);
        await tester.tap(find.text('Bloquear'));
        await tester.pumpAndSettle();
        expect(find.text('Bloquear Bruno?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Pessoa bloqueada. Ela não foi avisada e não encontra mais você'),
          findsOneWidget,
        );
        expect(find.text('Enviar pedido'), findsNothing);
        expect(app.social.blocks['uid-ana']!.keys, ['uid-bruno']);
        // searching again gives the generic message
        await searchHandle(tester, 'bruno');
        expect(find.text(kSearchNotFoundMessage), findsOneWidget);
        expect(find.text('Bloquear'), findsNothing);
      },
    );

    testWidgets('"Ver bloqueados" opens the tab with the person', (tester) async {
      await pumpFriends(tester, start: '/friends/add');
      await searchHandle(tester, 'bruno');
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ver bloqueados'));
      await tester.pumpAndSettle();
      expect(_selected(tester, FriendsTab.blocked), isTrue);
      expect(find.text('Bruno'), findsOneWidget);
    });

    testWidgets('a failed block keeps the card and the request button', (tester) async {
      final app = await pumpFriends(tester, start: '/friends/add');
      await searchHandle(tester, 'bruno');
      app.social.failures['blockUser'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
      await tester.pumpAndSettle();
      expect(find.text('Muitas operações hoje. Tente de novo amanhã.'), findsWidgets);
      expect(find.text('Enviar pedido'), findsOneWidget);
      expect(app.social.blocks, isEmpty);
    });

    testWidgets('somebody who blocked ME is not found: the same message as a missing handle', (
      tester,
    ) async {
      await pumpFriends(
        tester,
        start: '/friends/add',
        seed: (s) => s.seedBlock('uid-bruno', 'uid-ana', name: 'Ana'),
      );
      await searchHandle(tester, 'bruno');
      final blocked = find.text(kSearchNotFoundMessage).evaluate().length;
      await searchHandle(tester, 'ninguem');
      expect(blocked, 1);
      expect(find.text(kSearchNotFoundMessage), findsOneWidget);
      expect(find.text('Bloquear'), findsNothing);
    });

    testWidgets('a block while the request is being sent is not possible', (tester) async {
      final app = await pumpFriends(tester, start: '/friends/add');
      await searchHandle(tester, 'bruno');
      app.social.failures['sendRequest'] = const SocialFailure(SocialFailureKind.quotaExceeded);
      await tester.tap(find.text('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(tester.widget<ButtonStyleButton>(btn('Bloquear')).onPressed, isNotNull);
    });
  });

  group('search card race: a late answer never lands on ANOTHER person (docs/66 🟡-1)', () {
    void seedCaio(FakeSocialCloud s) => s.seedActive('uid-caio', 'caio', nickname: 'Caio');

    testWidgets('block of Bruno in flight, search Caio: Caio keeps "Enviar pedido"', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/friends/add', seed: seedCaio);
      await searchHandle(tester, 'bruno');
      app.social.writeGate = Completer<void>();
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
      await tester.pump();
      await searchHandle(tester, 'caio');
      expect(find.text('Caio'), findsOneWidget);
      app.social.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(app.social.blocks['uid-ana']!.keys, ['uid-bruno'], reason: 'Bruno WAS blocked');
      expect(find.text('Caio'), findsOneWidget);
      expect(find.textContaining('não encontra mais você na busca'), findsNothing);
      expect(find.text('Enviar pedido'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(btn('Enviar pedido')).onPressed, isNotNull);
      expect(find.text(kBlockedMessage), findsOneWidget, reason: 'the SnackBar is about Bruno');
    });

    testWidgets('request to Bruno in flight, search Caio: Caio is not marked "Pedido enviado"', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/friends/add', seed: seedCaio);
      await searchHandle(tester, 'bruno');
      app.social.writeGate = Completer<void>();
      await tester.tap(find.text('Enviar pedido'));
      await tester.pump();
      await tester.pump();
      await searchHandle(tester, 'caio');
      app.social.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(app.social.requests.keys, ['uid-ana_uid-bruno']);
      expect(find.text('Caio'), findsOneWidget);
      expect(find.text('Pedido enviado'), findsNothing);
      expect(find.text('Enviar pedido'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(btn('Enviar pedido')).onPressed, isNotNull);
    });
  });

  group('"Atualizar" never looks broken (docs/64 🟢-2)', () {
    testWidgets('Amigos: inside the cooldown it reads nothing and SAYS so; after it, it reads', (
      tester,
    ) async {
      var now = DateTime.utc(2026, 10, 5, 12);
      final app = await pumpFriends(
        tester,
        start: '/friends',
        seed: (s) => addFriends(s, 1),
        extraOverrides: [socialClockProvider.overrideWithValue(() => now)],
      );
      final reads = app.reads.where((r) => r == 'friends:page').length;
      await tester.tap(find.text('Atualizar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(kListJustRefreshedMessage), findsOneWidget);
      expect(app.reads.where((r) => r == 'friends:page').length, reads);
      await tester.pump(const Duration(seconds: 1)); // finish the entrance
      await tester.pump(const Duration(seconds: 5)); // the SnackBar times out
      await tester.pumpAndSettle();
      expect(find.text(kListJustRefreshedMessage), findsNothing, reason: 'first one gone');
      now = now.add(const Duration(seconds: 16));
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(find.text(kListJustRefreshedMessage), findsNothing);
      expect(app.reads.where((r) => r == 'friends:page').length, reads + 1);
    });

    testWidgets('Pedidos recebidos and Bloqueados say it too', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/friends?tab=pedidos',
        seed: (s) => addReceivedRequests(s, 1),
      );
      await tester.tap(find.text('Atualizar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(kListJustRefreshedMessage), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 6));
      app.router.go('/friends?tab=bloqueados');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Atualizar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(kListJustRefreshedMessage), findsOneWidget);
    });

    testWidgets('tapping repeatedly does not queue the same message', (tester) async {
      await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 1));
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Atualizar'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.text(kListJustRefreshedMessage), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        find.text(kListJustRefreshedMessage),
        findsNothing,
        reason: 'nothing left in the queue',
      );
    });

    testWidgets('the message is announced (SnackBar is a live region)', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(tester, start: '/friends', seed: (s) => addFriends(s, 1));
      await tester.tap(find.text('Atualizar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.bySemanticsLabel(kListJustRefreshedMessage), findsOneWidget);
      semantics.dispose();
    });
  });

  group('layout with blocks: 320 to 1440 px, fonts 1x to 3x, light and dark', () {
    const longName = 'Maria Eduarda de Albuquerque Cavalcanti Nascimento';
    for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          testWidgets(
            '$width px, font ${scale}x, ${brightness.name}: Bloquear / Desbloquear >= 48 px, no overflow',
            (tester) async {
              await pumpFriends(
                tester,
                size: Size(width, 4000),
                textScale: scale,
                brightness: brightness,
                start: '/friends',
                seed: (s) {
                  addFriends(s, 2, name: (i) => i == 0 ? longName : 'Amigo $i');
                  addReceivedRequests(s, 1, name: (_) => longName);
                  s.seedBlock('uid-ana', 'uid-x', name: longName, at: _day(2));
                  s.seedBlock('uid-ana', 'uid-y', name: 'Yara', at: _day(1));
                },
              );
              expect(tester.takeException(), isNull);
              final y = tester.getTopLeft(find.byType(FriendsTabs)).dy;
              final box = tester.getSize(btn('Bloquear').first);
              expect(box.height, greaterThanOrEqualTo(48));
              expect(box.width, greaterThanOrEqualTo(48));
              await tester.tap(_tab('Pedidos'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(tester.getSize(btn('Bloquear').first).height, greaterThanOrEqualTo(48));
              await tester.tap(_tab('Bloqueados'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              for (final label in ['Desbloquear', 'Atualizar']) {
                final b = tester.getSize(btn(label).first);
                expect(b.height, greaterThanOrEqualTo(48), reason: label);
                expect(b.width, greaterThanOrEqualTo(48), reason: label);
              }
              expect(tester.getTopLeft(find.byType(FriendsTabs)).dy, y, reason: 'tabs do not move');
              for (final tab in FriendsTab.values) {
                final tabBox = tester.getSize(
                  find.ancestor(of: _tab(tab.label), matching: find.byType(InkWell)).first,
                );
                expect(tabBox.height, greaterThanOrEqualTo(48), reason: tab.label);
              }
            },
          );
        }
      }
    }
  });

  group('tab semantics', () {
    testWidgets('three tabs, the selected one flagged; Bloqueados carries no number', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpFriends(
        tester,
        start: '/friends?tab=bloqueados',
        seed: (s) => addReceivedRequests(s, 2),
      );
      final blocked = tester.getSemantics(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Bloqueados'),
      );
      expect(blocked.flagsCollection.isSelected, Tristate.isTrue);
      expect(find.bySemanticsLabel('Pedidos, 2 pedidos recebidos'), findsOneWidget);
      semantics.dispose();
    });
  });
}
