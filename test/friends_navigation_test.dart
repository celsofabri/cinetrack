import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/router.dart';
import 'package:cinetrack/widgets/app_shell.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/friends_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Auth whose session is never resolved (stream stays in `loading`).
class _NeverEmitsAuth extends FakeAuthRepository {
  @override
  Stream<AppUser?> authStateChanges() => StreamController<AppUser?>().stream;
}

Finder _topBarFriends() =>
    find.descendant(of: find.byType(MobileTopBar), matching: find.byTooltip('Amigos'));

void main() {
  group('redirect: /friends* needs a session (like /profile)', () {
    for (final path in ['/friends', '/friends/add']) {
      testWidgets('signed out: $path goes home', (tester) async {
        final app = await pumpFriends(tester, user: null, start: path);
        expect(app.location, '/');
        expect(find.text('Adicionar amigo'), findsNothing);
      });

      testWidgets('signed in without friendships: $path stays and invites to the Profile', (
        tester,
      ) async {
        final app = await pumpFriends(tester, active: false, start: path);
        expect(app.location, path);
        expect(find.textContaining('ative as amizades no seu Perfil'), findsOneWidget);
      });
    }

    testWidgets('session still loading: /friends does not redirect', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: cloudOverrides(auth: _NeverEmitsAuth(), cloud: FakeCloud()),
      );
      addTearDown(container.dispose);
      final router = container.read(routerProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      router.go('/friends');
      await tester.pump();
      await tester.pump();
      expect(router.routeInformationProvider.value.uri.path, '/friends');
    });

    testWidgets('signed out later (sign out) leaves /friends', (tester) async {
      final app = await pumpFriends(tester, start: '/friends');
      expect(app.location, '/friends');
      await app.auth.signOut();
      await tester.pumpAndSettle();
      expect(app.location, '/');
    });
  });

  group('mobile top bar: Amigos icon', () {
    testWidgets('only signed in AND friendships on; hidden otherwise', (tester) async {
      await pumpFriends(tester);
      expect(_topBarFriends(), findsOneWidget);

      await pumpFriends(tester, active: false);
      expect(_topBarFriends(), findsNothing);

      await pumpFriends(tester, user: null);
      expect(_topBarFriends(), findsNothing);

      await pumpFriends(tester, rulesLive: false); // rules not published: nothing shown
      expect(_topBarFriends(), findsNothing);

      await pumpFriends(
        tester,
        user: const AppUser(uid: 'uid-p', displayName: 'P', isGoogle: false),
      );
      expect(_topBarFriends(), findsNothing);
    });

    testWidgets('opens /friends, keeps Perfil selected, is a 48 px target before the magnifier', (
      tester,
    ) async {
      final app = await pumpFriends(tester);
      final icon = tester.getRect(_topBarFriends());
      expect(icon.width, greaterThanOrEqualTo(48));
      expect(icon.height, greaterThanOrEqualTo(48));
      final lupa = tester.getRect(
        find.descendant(of: find.byType(MobileTopBar), matching: find.byTooltip('Buscar')),
      );
      expect(icon.right, lessThanOrEqualTo(lupa.left));
      await tester.tap(_topBarFriends());
      await tester.pumpAndSettle();
      expect(app.location, '/friends');
      expect(find.text('Pedidos enviados'), findsOneWidget);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 4);
      // the search screen keeps Perfil selected too
      await tester.tap(find.text('Adicionar amigo'));
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 4);
    });

    testWidgets('opening any tab reads the social state ONCE per session (2 documents)', (
      tester,
    ) async {
      final app = await pumpFriends(tester);
      expect(app.reads, ['read']);
      await tester.tap(find.text('Favoritos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Início'));
      await tester.pumpAndSettle();
      expect(app.reads, ['read']);
    });

    for (final width in [320.0, 360.0, 390.0, 768.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        testWidgets('$width px font ${scale}x: logo bar fits with the Amigos icon', (tester) async {
          for (final brightness in [Brightness.light, Brightness.dark]) {
            await pumpFriends(
              tester,
              size: Size(width, 700),
              textScale: scale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
            expect(_topBarFriends(), findsOneWidget);
            final bar = tester.getRect(find.byType(MobileTopBar));
            final icons = tester.getRect(_topBarFriends());
            expect(icons.right, lessThanOrEqualTo(bar.right));
            // the logo (flexible) still leaves room: it never goes negative
            expect(tester.getSize(find.text('CineTrack')).width, greaterThanOrEqualTo(0));
          }
        });
      }
    }
  });

  group('Amigos icon without a server read per session (local hint, docs/59)', () {
    final fresh = DateTime.now().subtract(const Duration(hours: 1));
    final stale = DateTime.now().subtract(const Duration(hours: 25));

    testWidgets('fresh "on" hint: icon at once, ZERO reads until Profile/friends confirms', (
      tester,
    ) async {
      final store = FakeLocalStore()..socialHints['uid-ana'] = (active: true, at: fresh);
      final app = await pumpFriends(tester, store: store);
      expect(_topBarFriends(), findsOneWidget);
      await tester.tap(find.text('Favoritos'));
      await tester.pumpAndSettle();
      expect(app.reads, isEmpty);
      await tester.tap(_topBarFriends());
      await tester.pumpAndSettle();
      expect(app.reads.where((r) => r == 'read'), hasLength(1));
      expect(find.text('Adicionar amigo'), findsOneWidget);
      expect(_topBarFriends(), findsOneWidget);
    });

    testWidgets('fresh "off" hint: no icon and no reads', (tester) async {
      final store = FakeLocalStore()..socialHints['uid-ana'] = (active: false, at: fresh);
      final app = await pumpFriends(tester, store: store, active: false);
      expect(_topBarFriends(), findsNothing);
      expect(app.reads, isEmpty);
    });

    testWidgets('"on" hint but deactivated elsewhere: Profile corrects icon and hint', (
      tester,
    ) async {
      final store = FakeLocalStore()..socialHints['uid-ana'] = (active: true, at: fresh);
      await pumpFriends(tester, store: store, active: false);
      expect(_topBarFriends(), findsOneWidget); // up to the next confirmation
      await tester.tap(find.text('Perfil'));
      await tester.pumpAndSettle();
      expect(_topBarFriends(), findsNothing);
      expect(store.socialHints['uid-ana']!.active, isFalse);
    });

    testWidgets('stale hint (> 24 h) is not trusted: the server is asked, active is never hidden', (
      tester,
    ) async {
      final store = FakeLocalStore()..socialHints['uid-ana'] = (active: false, at: stale);
      final app = await pumpFriends(tester, store: store); // server: active
      expect(app.reads, ['read']);
      expect(_topBarFriends(), findsOneWidget);
      expect(store.socialHints['uid-ana']!.active, isTrue);
      expect(DateTime.now().difference(store.socialHints['uid-ana']!.at).inMinutes, lessThan(5));
    });

    testWidgets('no hint: asks once and remembers the answer', (tester) async {
      final store = FakeLocalStore();
      final app = await pumpFriends(tester, store: store);
      expect(app.reads, ['read']);
      expect(store.socialHints['uid-ana']!.active, isTrue);
    });
  });

  group('desktop top menu: Amigos item', () {
    testWidgets('only with friendships on; opens /friends', (tester) async {
      await pumpFriends(tester, size: const Size(1440, 900), active: false);
      expect(find.byTooltip('Amigos'), findsNothing);
      expect(find.text('Amigos'), findsNothing);

      final app = await pumpFriends(tester, size: const Size(1440, 900));
      expect(find.text('Amigos'), findsOneWidget); // label on wide screens
      await tester.tap(find.text('Amigos'));
      await tester.pumpAndSettle();
      expect(find.text('Pedidos enviados'), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(app.reads.where((r) => r == 'sent:page'), hasLength(1));
    });

    for (final width in [769.0, 800.0, 960.0, 1024.0, 1100.0, 1440.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        testWidgets('$width px font ${scale}x: top menu with Amigos has no overflow', (
          tester,
        ) async {
          await pumpFriends(tester, size: Size(width, 800), textScale: scale);
          expect(tester.takeException(), isNull);
          expect(
            find.byTooltip('Amigos').evaluate().isNotEmpty ||
                find.text('Amigos').evaluate().isNotEmpty,
            isTrue,
          );
        });
      }
    }

    testWidgets('narrow desktop: icon only, with the tooltip', (tester) async {
      await pumpFriends(tester, size: const Size(800, 800));
      expect(find.byTooltip('Amigos'), findsOneWidget);
      expect(find.text('Amigos'), findsNothing);
    });
  });

  group('Profile: card with "Gerenciar amigos"', () {
    testWidgets('opens /friends', (tester) async {
      await pumpFriends(tester, size: const Size(390, 2400), start: '/profile');
      final size = tester.getSize(btn('Gerenciar amigos'));
      expect(size.height, greaterThanOrEqualTo(48));
      await tester.tap(find.text('Gerenciar amigos'));
      await tester.pumpAndSettle();
      expect(find.text('Pedidos enviados'), findsOneWidget);
    });

    testWidgets('not shown while friendships are off', (tester) async {
      await pumpFriends(tester, active: false, start: '/profile');
      await tester.scrollUntilVisible(
        find.text('Ativar amizades'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Gerenciar amigos'), findsNothing);
    });
  });

  testWidgets('a user who never turned friendships on: every screen of the app reads and writes '
      'nothing social beyond the one state read', (tester) async {
    final app = await pumpFriends(tester, active: false);
    await tester.tap(find.text('Favoritos'));
    await tester.pumpAndSettle();
    app.router.go('/profile');
    await tester.pumpAndSettle();
    expect(app.reads, ['read']);
    expect(app.social.log, isEmpty);
    expect(app.social.leftoversOf('uid-ana'), isEmpty);
  });

  test('kAnaGoogle is a Google account (sanity of the harness)', () {
    expect(kAnaGoogle.isGoogle, isTrue);
    expect(kAna.uid, kAnaGoogle.uid);
  });
}
