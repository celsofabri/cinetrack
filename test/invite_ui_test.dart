import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/social/invite_code.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/widgets/share_link.dart';

import 'support/fake_auth_repository.dart';
import 'support/fake_social_cloud.dart';
import 'support/friends_harness.dart';

/// Slice 5 (docs/68): the "Convite por link" section of the profile, the
/// `/invite/:code` screen, the refresh note, and the routes, over the real
/// router and providers with in-memory fakes.

const _code = 'AbCdEfGhIjKlMnOpQrStUv12';
final _base = Uri.parse('https://exemplo.test/cinetrack/');
final _link = 'https://exemplo.test/cinetrack/#/invite/$_code';

final _linkBase = inviteLinkBaseProvider.overrideWithValue(_base);

void _seedInvite(
  FakeSocialCloud s, {
  String owner = 'uid-bruno',
  String handle = 'bruno',
  String nickname = 'Bruno',
  String code = _code,
  Duration expiresIn = const Duration(days: 7),
}) {
  final at = DateTime.now();
  s.social[owner] = {...s.social[owner]!, 'inviteCode': code};
  s.invites[code] = {
    'uid': owner,
    'nickname': nickname,
    'createdAt': at.subtract(const Duration(hours: 1)),
    'expiresAt': at.add(expiresIn),
  };
}

/// Records what is copied (the platform channel of the clipboard).
List<String> _recordClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
    call,
  ) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  // The profile is a lazy list: bring the item into existence first.
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 300, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _show(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

int _lookups(FriendsApp app) => app.social.readLog.where((e) => e == 'lookupInvite').length;

void main() {
  group('profile: "Convite por link"', () {
    testWidgets('no invite yet: explains, offers a validity (7 days) and creates the link', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/profile', extraOverrides: [_linkBase]);
      await _show(tester, find.text('Convite por link'));
      expect(
        find.textContaining('Funciona mesmo com "Aparecer na busca" desligado'),
        findsOneWidget,
      );
      expect(find.text('7 dias'), findsOneWidget);
      expect(app.social.invites, isEmpty);

      await _tap(tester, btn('Criar link de convite'));
      final code = app.social.social['uid-ana']!['inviteCode'] as String;
      expect(InviteCode.isValid(code), isTrue);
      expect(find.text(_link.replaceFirst(_code, code)), findsOneWidget);
      expect(find.text(code), findsOneWidget);
      expect(find.textContaining('Válido até'), findsOneWidget);
      expect(find.textContaining('faltam 7 dias'), findsOneWidget);
      expect(find.text('Link criado.'), findsOneWidget);
      expect(btn('Revogar convite'), findsOneWidget);
      expect(btn('Copiar link'), findsOneWidget);
      expect(btn('Copiar código'), findsOneWidget);
      expect(btn('Compartilhar'), findsNothing, reason: 'no Web Share here');
      // the invite document carries the card, not more
      final doc = app.social.invites[code]!;
      expect(doc.keys.toSet(), {'uid', 'nickname', 'photoURL', 'createdAt', 'expiresAt'});
    });

    testWidgets('validity 30 days: the longest option keeps the margin under the cap', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/profile', extraOverrides: [_linkBase]);
      await _show(tester, find.text('Convite por link'));
      await tester.tap(find.text('7 dias'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 dias').last);
      await tester.pumpAndSettle();
      await _tap(tester, btn('Criar link de convite'));
      final doc = app.social.invites.values.single;
      final left = (doc['expiresAt'] as DateTime).difference(DateTime.now());
      expect(left, lessThan(const Duration(days: 30)));
      expect(left, greaterThan(const Duration(days: 29)));
    });

    testWidgets(
      'copy link / copy code: the clipboard gets exactly it, with an announced SnackBar',
      (tester) async {
        final copied = _recordClipboard(tester);
        final handle = tester.ensureSemantics();
        final app = await pumpFriends(
          tester,
          start: '/profile',
          seed: (s) => _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana'),
          extraOverrides: [_linkBase],
        );
        await _show(tester, find.text('Convite por link'));
        await _tap(tester, btn('Copiar link'));
        expect(copied, [_link]);
        expect(find.text('Link copiado.'), findsOneWidget);
        expect(tester.getSemantics(find.text('Link copiado.')), isNotNull);
        await _tap(tester, btn('Copiar código'));
        expect(copied.last, _code);
        expect(find.text('Código copiado.'), findsOneWidget);
        expect(app.social.log, isEmpty, reason: 'copying writes nothing');
        handle.dispose();
      },
    );

    testWidgets('Web Share appears only when the platform has it, and shares the link', (
      tester,
    ) async {
      final calls = <String>[];
      await pumpFriends(
        tester,
        start: '/profile',
        seed: (s) => _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana'),
        extraOverrides: [
          _linkBase,
          shareLinkProvider.overrideWithValue(({
            required title,
            required text,
            required url,
          }) async {
            calls.add(url);
            return true;
          }),
        ],
      );
      await _show(tester, find.text('Convite por link'));
      await _tap(tester, btn('Compartilhar'));
      expect(calls, [_link]);
    });

    testWidgets(
      'revoke asks first (focus on Cancelar); cancelling changes nothing; confirming kills the link',
      (tester) async {
        final app = await pumpFriends(
          tester,
          start: '/profile',
          seed: (s) => _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana'),
          extraOverrides: [_linkBase],
        );
        await _tap(tester, btn('Revogar convite'));
        expect(find.text('Revogar o convite?'), findsOneWidget);
        expect(tester.widget<TextButton>(btn('Cancelar')).autofocus, isTrue);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(app.social.invites, hasLength(1));

        await _tap(tester, btn('Revogar convite'));
        await tester.tap(find.widgetWithText(FilledButton, 'Revogar'));
        await tester.pumpAndSettle();
        expect(app.social.invites, isEmpty);
        expect(app.social.social['uid-ana']!.containsKey('inviteCode'), isFalse);
        expect(find.text('Convite revogado. O link parou de funcionar.'), findsOneWidget);
        expect(btn('Criar link de convite'), findsOneWidget);
      },
    );

    testWidgets(
      '"Novo link" asks first, then replaces: one active invite and the old link is dead',
      (tester) async {
        final app = await pumpFriends(
          tester,
          start: '/profile',
          seed: (s) => _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana'),
          extraOverrides: [_linkBase],
        );
        await _tap(tester, btn('Novo link'));
        expect(find.text('Criar um novo link?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Criar novo link'));
        await tester.pumpAndSettle();
        expect(app.social.invites.keys, isNot(contains(_code)));
        expect(app.social.invites, hasLength(1));
        expect(find.textContaining('O anterior parou de funcionar'), findsOneWidget);
      },
    );

    testWidgets('an expired invite says so and only offers a new link or removing it', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/profile',
        seed: (s) => _seedInvite(
          s,
          owner: 'uid-ana',
          handle: 'ana',
          nickname: 'Ana',
          expiresIn: const Duration(days: -1),
        ),
        extraOverrides: [_linkBase],
      );
      await _show(tester, find.text('Convite por link'));
      expect(find.textContaining('Este convite expirou'), findsOneWidget);
      expect(btn('Copiar link'), findsNothing);
      expect(btn('Copiar código'), findsNothing);
      expect(find.text(_code), findsNothing);
      expect(btn('Novo link'), findsOneWidget);
      await _tap(tester, btn('Remover convite'));
      await tester.tap(find.widgetWithText(FilledButton, 'Revogar'));
      await tester.pumpAndSettle();
      expect(app.social.invites, isEmpty);
    });

    testWidgets(
      'a pointer whose document is gone is treated as "no invite" (a new one can be made)',
      (tester) async {
        final app = await pumpFriends(
          tester,
          start: '/profile',
          seed: (s) => s.social['uid-ana'] = {...s.social['uid-ana']!, 'inviteCode': 'Z' * 24},
          extraOverrides: [_linkBase],
        );
        await _show(tester, find.text('Convite por link'));
        await _tap(tester, btn('Criar link de convite'));
        expect(app.social.invites, hasLength(1));
      },
    );

    testWidgets('offline: creating / revoking are disabled with the reason; copying still works', (
      tester,
    ) async {
      final copied = _recordClipboard(tester);
      final app = await pumpFriends(
        tester,
        start: '/profile',
        seed: (s) => _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana'),
        extraOverrides: [_linkBase],
      );
      app.cloud.offline = true;
      app.social.offline = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await _show(tester, find.text('Convite por link'));
      expect(find.textContaining('Criar e revogar convites exige internet'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(btn('Novo link')).onPressed, isNull);
      expect(tester.widget<TextButton>(btn('Revogar convite')).onPressed, isNull);
      await _tap(tester, btn('Copiar link'));
      expect(copied, [_link]);
    });

    testWidgets('a refused write is visible and loses nothing (rules not published)', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/profile', extraOverrides: [_linkBase]);
      await _show(tester, find.text('Convite por link'));
      app.social.failures['createInvite'] = const SocialFailure(
        SocialFailureKind.denied,
        code: 'permission-denied',
      );
      await _tap(tester, btn('Criar link de convite'));
      expect(find.textContaining('Verifique a data e a hora do aparelho'), findsOneWidget);
      expect(app.social.invites, isEmpty);
      expect(btn('Criar link de convite'), findsOneWidget, reason: 'can try again');
    });

    testWidgets('the invite could not be READ: error with retry, never "criar link"', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/profile',
        seed: (s) {
          _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana');
          s.failures['inviteRead'] = const SocialFailure(SocialFailureKind.unknown);
        },
        extraOverrides: [_linkBase],
      );
      await _show(tester, find.text('Convite por link'));
      expect(find.text('Não foi possível ler o seu convite agora.'), findsOneWidget);
      expect(btn('Criar link de convite'), findsNothing);
      expect(btn('Novo link'), findsNothing);
      expect(app.social.invites, hasLength(1), reason: 'the active invite is untouched');
      await _tap(tester, btn('Tentar de novo'));
      await _show(tester, find.text('Convite por link'));
      expect(find.text('Não foi possível ler o seu convite agora.'), findsNothing);
      expect(btn('Copiar link'), findsOneWidget);
    });

    testWidgets('friendships off: no invite section at all, nothing is read or written', (
      tester,
    ) async {
      final app = await pumpFriends(tester, start: '/profile', active: false);
      expect(find.text('Convite por link'), findsNothing);
      expect(app.social.log, isEmpty);
      expect(_lookups(app), 0);
    });

    for (final width in [320.0, 390.0, 768.0, 1440.0]) {
      for (final scale in [1.0, 3.0]) {
        for (final brightness in Brightness.values) {
          testWidgets(
            '$width px, font ${scale}x, ${brightness.name}: section fits, targets >= 48 px',
            (tester) async {
              await pumpFriends(
                tester,
                size: Size(width, 900),
                textScale: scale,
                brightness: brightness,
                start: '/profile',
                seed: (s) => _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana'),
                extraOverrides: [
                  _linkBase,
                  shareLinkProvider.overrideWithValue(
                    ({required title, required text, required url}) async => true,
                  ),
                ],
              );
              await _show(tester, find.text('Convite por link'));
              expect(tester.takeException(), isNull);
              for (final label in [
                'Copiar link',
                'Copiar código',
                'Compartilhar',
                'Novo link',
                'Revogar convite',
              ]) {
                await _show(tester, btn(label));
                final size = tester.getSize(btn(label));
                expect(size.height, greaterThanOrEqualTo(48), reason: label);
                expect(size.width, greaterThanOrEqualTo(48), reason: label);
                expect(
                  tester.getRect(btn(label)).right,
                  lessThanOrEqualTo(width + 0.5),
                  reason: label,
                );
              }
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    testWidgets(
      'semantics: header, buttons read their visible text, link and code are selectable text',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pumpFriends(
          tester,
          start: '/profile',
          seed: (s) => _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana'),
          extraOverrides: [_linkBase],
        );
        await _show(tester, find.text('Convite por link'));
        expect(tester.getSemantics(find.text('Convite por link')).flagsCollection.isHeader, isTrue);
        for (final label in ['Copiar link', 'Copiar código', 'Novo link', 'Revogar convite']) {
          expect(tester.getSemantics(btn(label)).label, startsWith(label));
        }
        expect(find.byType(SelectableText), findsNWidgets(2));
        handle.dispose();
      },
    );
  });

  group('refresh note (nickname / photo going to the friends)', () {
    testWidgets('shown while it runs, gone when done; nothing above it moves', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/profile',
        seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana Velha', bName: 'Bruno'),
        extraOverrides: [_linkBase],
      );
      await _show(tester, find.text('Editar apelido'));
      final before = tester.getTopLeft(find.text('Editar apelido'));
      app.social.writeGate = Completer<void>();
      await _tap(tester, find.text('Editar apelido'));
      await tester.enterText(find.byType(TextField), 'Ana Nova');
      await tester.tap(find.text('Salvar'));
      // a spinner is running: pumpAndSettle would never settle
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Atualizando seu nome e foto para os amigos...'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Editar apelido')), before);
      app.social.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Atualizando seu nome e foto para os amigos...'), findsNothing);
      expect(app.social.friendships['uid-ana_uid-bruno']!['aName'], 'Ana Nova');
    });

    testWidgets('a failure says so quietly and "Tentar de novo" finishes it', (tester) async {
      final app = await pumpFriends(
        tester,
        start: '/profile',
        seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana Velha', bName: 'Bruno'),
        extraOverrides: [_linkBase],
      );
      app.social.failures['updateHalves'] = const SocialFailure(SocialFailureKind.offline);
      await _tap(tester, find.text('Editar apelido'));
      await tester.enterText(find.byType(TextField), 'Ana Nova');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();
      await _show(tester, find.textContaining('ainda não chegou a todos os amigos'));
      expect(app.social.friendships['uid-ana_uid-bruno']!['aName'], 'Ana Velha');
      await _tap(tester, btn('Tentar de novo'));
      expect(find.textContaining('ainda não chegou'), findsNothing);
      expect(app.social.friendships['uid-ana_uid-bruno']!['aName'], 'Ana Nova');
    });
  });

  group('/invite/:code', () {
    Future<FriendsApp> open(
      WidgetTester tester, {
      String code = _code,
      void Function(FakeSocialCloud s)? seed,
      AppUser? user = kAnaGoogle,
      bool active = true,
      Size size = const Size(390, 844),
      double textScale = 1,
      Brightness brightness = Brightness.light,
    }) => pumpFriends(
      tester,
      size: size,
      textScale: textScale,
      brightness: brightness,
      user: user,
      active: active,
      start: '/invite/$code',
      seed: (s) {
        _seedInvite(s);
        seed?.call(s);
      },
      extraOverrides: [_linkBase],
    );

    testWidgets('shows the card with ONE read of the invite and sends a NORMAL request', (
      tester,
    ) async {
      final app = await open(tester);
      expect(app.location, '/invite/$_code');
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.text('convidou você para ser amigo'), findsOneWidget);
      expect(_lookups(app), 1);
      expect(
        app.social.readLog.where((e) => e.startsWith('lookup:')),
        isEmpty,
        reason: 'no handle search',
      );
      expect(app.social.log, isEmpty, reason: 'opening writes nothing');

      await tester.tap(btn('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pedido enviado.'), findsWidgets);
      expect(app.social.requests.keys, ['uid-ana_uid-bruno']);
      expect(app.social.friendships, isEmpty, reason: 'never a friendship by itself');
      expect(btn('Ver pedidos enviados'), findsOneWidget);
    });

    testWidgets('works when the owner is hidden from the search', (tester) async {
      final app = await open(tester, seed: (s) => s.handles['bruno']!['discoverable'] = false);
      expect(find.text('Bruno'), findsOneWidget);
      expect(btn('Enviar pedido'), findsOneWidget);
      expect(_lookups(app), 1);
    });

    testWidgets('every reason it cannot be used shows the SAME single message and no button', (
      tester,
    ) async {
      final reasons = <String, ({String code, void Function(FakeSocialCloud)? seed})>{
        'malformed': (code: 'curto', seed: null),
        'never existed': (code: 'Q' * 24, seed: null),
        'revoked': (
          code: _code,
          seed: (s) {
            s.invites.remove(_code);
            s.social['uid-bruno'] = {...s.social['uid-bruno']!}..remove('inviteCode');
          },
        ),
        'expired': (
          code: _code,
          seed: (s) =>
              s.invites[_code]!['expiresAt'] = DateTime.now().subtract(const Duration(days: 1)),
        ),
        'owner blocked me': (code: _code, seed: (s) => s.seedBlock('uid-bruno', 'uid-ana')),
        'I blocked the owner': (code: _code, seed: (s) => s.seedBlock('uid-ana', 'uid-bruno')),
        'my own': (
          code: 'M' * 24,
          seed: (s) =>
              _seedInvite(s, owner: 'uid-ana', handle: 'ana', nickname: 'Ana', code: 'M' * 24),
        ),
      };
      final screens = <String, List<String>>{};
      for (final e in reasons.entries) {
        final app = await open(tester, code: e.value.code, seed: e.value.seed);
        expect(find.text(kInviteUnavailableMessage), findsOneWidget, reason: e.key);
        expect(btn('Enviar pedido'), findsNothing, reason: e.key);
        expect(app.social.requests, isEmpty, reason: e.key);
        screens[e.key] = [
          for (final t in tester.widgetList<Text>(find.byType(Text)))
            if (t.data != null) t.data!,
        ]..sort();
        await tester.pumpWidget(const SizedBox());
      }
      final first = screens.values.first;
      for (final e in screens.entries) {
        // the visible texts are identical (the app bar / tab bar are the same too)
        expect(
          e.value.where((t) => t.contains('convite') || t.contains('Bruno') || t.contains('Ana')),
          first.where((t) => t.contains('convite') || t.contains('Bruno') || t.contains('Ana')),
          reason: e.key,
        );
      }
    });

    testWidgets('a bad code does not even reach the server', (tester) async {
      final app = await open(tester, code: 'curto');
      expect(_lookups(app), 0);
      expect(find.text(kInviteUnavailableMessage), findsOneWidget);
    });

    testWidgets('already friends / already asked: said without sending (free, from memory)', (
      tester,
    ) async {
      final app = await open(
        tester,
        seed: (s) => s.seedFriendship('uid-ana', 'uid-bruno', bName: 'Bruno'),
      );
      // the friends list is not in memory yet: the answer comes from the attempt, generic
      await tester.tap(btn('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível enviar o pedido'), findsOneWidget);
      expect(app.social.requests, isEmpty);
      // once the list is in memory the screen says it up front
      app.router.go('/friends');
      await tester.pumpAndSettle();
      app.router.go('/invite/$_code');
      await tester.pumpAndSettle();
      expect(find.text('Vocês já são amigos.'), findsOneWidget);
      expect(btn('Enviar pedido'), findsNothing);
    });

    testWidgets('they asked me first: the request becomes a friendship (D4)', (tester) async {
      final app = await open(
        tester,
        seed: (s) => s.seedRequest('uid-bruno', 'uid-ana', fromName: 'Bruno', toName: 'Ana'),
      );
      await tester.tap(btn('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(find.textContaining('já tinha pedido a sua amizade'), findsOneWidget);
      expect(app.social.friendships, hasLength(1));
      expect(app.social.requests, isEmpty);
    });

    testWidgets('already asked: says so', (tester) async {
      final app = await open(tester);
      await tester.tap(btn('Enviar pedido'));
      await tester.pumpAndSettle();
      app.router.go('/friends?tab=pedidos');
      await tester.pumpAndSettle();
      app.router.go('/invite/$_code');
      await tester.pumpAndSettle();
      expect(find.text('Você já enviou um pedido para essa pessoa.'), findsOneWidget);
      expect(btn('Enviar pedido'), findsNothing);
    });

    testWidgets('50 pending requests: stops with the limit message and no retry button', (
      tester,
    ) async {
      final app = await open(tester, seed: (s) => addSentRequests(s, 50));
      await tester.tap(btn('Enviar pedido'));
      await tester.pumpAndSettle();
      expect(find.textContaining('limite de 50 pedidos'), findsOneWidget);
      expect(btn('Enviar pedido'), findsNothing);
      expect(app.social.requests, hasLength(50));
    });

    testWidgets(
      'signed out: invites to sign in, reads nothing; after the Google sign-in the SAME screen continues',
      (tester) async {
        final auth = FakeAuthRepository(initialUser: null);
        auth.nextUser = kAnaGoogle;
        final app = await pumpFriends(
          tester,
          user: null,
          authOverride: auth,
          start: '/invite/$_code',
          seed: _seedInvite,
          extraOverrides: [_linkBase],
        );
        expect(app.location, '/invite/$_code', reason: 'a public route: no redirect to /');
        expect(find.textContaining('Você recebeu um convite de amizade'), findsOneWidget);
        expect(find.text('Bruno'), findsNothing, reason: 'nothing about the owner before login');
        expect(app.social.readLog, isEmpty);
        await tester.tap(btn('Entrar com o Google'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(app.location, '/invite/$_code');
        expect(find.text('Bruno'), findsOneWidget);
        expect(btn('Enviar pedido'), findsOneWidget);
        expect(_lookups(app), 1);
      },
    );

    testWidgets(
      'friendships off: asks to turn them on, reads nothing; activating continues to the card',
      (tester) async {
        final app = await open(tester, active: false);
        expect(find.textContaining('ative as amizades'), findsOneWidget);
        expect(_lookups(app), 0);
        await tester.tap(btn('Ativar amizades'));
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextField, 'Identificador'), 'ana_9');
        await tester.tap(find.text('Usar meu nome do Google'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Ativar amizades').last);
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(app.location, '/invite/$_code');
        expect(find.text('Bruno'), findsOneWidget);
        expect(btn('Enviar pedido'), findsOneWidget);
        expect(_lookups(app), 1);
      },
    );

    testWidgets('a non-Google account is told so and reads nothing', (tester) async {
      final app = await open(
        tester,
        user: const AppUser(uid: 'uid-p', displayName: 'P', isGoogle: false),
      );
      expect(
        find.textContaining('só estão disponíveis para contas que entraram com o Google'),
        findsOneWidget,
      );
      expect(_lookups(app), 0);
    });

    testWidgets('offline: a real error with a retry (never "invalid")', (tester) async {
      final app = await open(
        tester,
        seed: (s) => s.failures['lookupInvite'] = const SocialFailure(SocialFailureKind.offline),
      );
      expect(find.textContaining('Sem conexão'), findsWidgets);
      expect(find.text(kInviteUnavailableMessage), findsNothing);
      await tester.tap(btn('Tentar de novo'));
      await tester.pumpAndSettle();
      expect(find.text('Bruno'), findsOneWidget);
      expect(_lookups(app), 2);
    });

    testWidgets('keyboard: Tab reaches "Enviar pedido" and Enter sends it', (tester) async {
      final app = await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      var guard = 0;
      while (FocusManager.instance.primaryFocus?.context
                  ?.findAncestorWidgetOfExactType<FilledButton>() ==
              null &&
          guard++ < 30) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(app.social.requests.keys, ['uid-ana_uid-bruno']);
    });

    testWidgets('semantics: the button reads its visible text first; states are live regions', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);
      expect(tester.getSemantics(btn('Enviar pedido')).label, startsWith('Enviar pedido'));
      expect(tester.getSemantics(btn('Enviar pedido')).label, contains('Bruno'));
      handle.dispose();
    });

    testWidgets('the generated link opens the screen (the fragment is the route)', (tester) async {
      final app = await open(tester, code: 'curto');
      final fragment = Uri.parse(InviteLink.build(_base, _code)).fragment;
      expect(fragment, '/invite/$_code');
      app.router.go(fragment);
      await tester.pumpAndSettle();
      expect(app.location, '/invite/$_code');
      expect(find.text('Bruno'), findsOneWidget);
    });

    for (final width in [320.0, 390.0, 768.0, 1440.0]) {
      for (final scale in [1.0, 3.0]) {
        for (final brightness in Brightness.values) {
          testWidgets(
            '$width px, font ${scale}x, ${brightness.name}: card and unavailable fit, target >= 48 px',
            (tester) async {
              await open(tester, size: Size(width, 900), textScale: scale, brightness: brightness);
              expect(tester.takeException(), isNull);
              final send = tester.getSize(btn('Enviar pedido'));
              expect(send.height, greaterThanOrEqualTo(48));
              await tester.pumpWidget(const SizedBox());
              await open(
                tester,
                code: 'curto',
                size: Size(width, 900),
                textScale: scale,
                brightness: brightness,
              );
              expect(tester.takeException(), isNull);
              expect(find.text(kInviteUnavailableMessage), findsOneWidget);
            },
          );
        }
      }
    }

    testWidgets('"Tenho um convite" in Adicionar amigo: a pasted link or code opens the screen', (
      tester,
    ) async {
      final app = await pumpFriends(
        tester,
        start: '/friends/add',
        seed: _seedInvite,
        extraOverrides: [_linkBase],
      );
      await tester.tap(btn('Tenho um convite'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'banana');
      await tester.tap(btn('Abrir convite'));
      await tester.pumpAndSettle();
      expect(find.text('Cole o link ou o código do convite.'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Vem! $_link');
      await tester.tap(btn('Abrir convite'));
      await tester.pumpAndSettle();
      // pushed on top of "Adicionar amigo" (back returns there)
      expect(find.text('convidou você para ser amigo'), findsOneWidget);
      expect(find.text('Bruno'), findsOneWidget);
      expect(app.social.readLog.where((e) => e == 'lookupInvite'), hasLength(1));
    });
  });
}
