import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/main.dart' show CineTrackApp;
import 'package:cinetrack/router.dart';
import 'package:cinetrack/widgets/app_shell.dart';
import 'package:cinetrack/widgets/sync_widgets.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/in_memory_favorites_data_source.dart';

void main() {
  Future<(ProviderContainer, FakeAuthRepository)> pumpApp(
    WidgetTester tester, {
    required Size size,
    FakeAuthRepository? auth,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = auth ?? FakeAuthRepository();
    final container = ProviderContainer(
      overrides: cloudOverrides(auth: fake, cloud: FakeCloud()),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const CineTrackApp()),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    return (container, fake);
  }

  String location(ProviderContainer c) =>
      c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

  testWidgets('390px: NavigationBar + logo, no top-menu buttons', (tester) async {
    await pumpApp(tester, size: const Size(390, 800));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(MobileTopBar), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    expect(find.descendant(of: find.byType(MobileTopBar), matching: find.text('CineTrack')),
        findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    for (final label in ['Início', 'Explorar', 'Recomendo', 'Favoritos', 'Entrar']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
          findsOneWidget,
          reason: label);
    }
    // Busca left the tab bar (5 destinations) and became the magnifier on top.
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('Busca')),
        findsNothing);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations, hasLength(5));
    expect(find.descendant(of: find.byType(MobileTopBar), matching: find.byIcon(Icons.search)),
        findsOneWidget);
    final bar = tester.getRect(find.byType(NavigationBar));
    expect(bar.bottom, 800);
    expect(bar.height, greaterThanOrEqualTo(48));
  });

  testWidgets('768px is mobile, 769px is desktop', (tester) async {
    await pumpApp(tester, size: const Size(768, 900));
    expect(find.byType(NavigationBar), findsOneWidget);
    await pumpApp(tester, size: const Size(769, 900));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('1024px: top menu, no NavigationBar', (tester) async {
    await pumpApp(tester, size: const Size(1024, 800));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(MobileTopBar), findsNothing);
    expect(find.text('Explorar'), findsOneWidget);
    expect(find.text('Meus favoritos'), findsOneWidget);
  });

  testWidgets('tapping a tab navigates and marks it selected', (tester) async {
    final (c, _) = await pumpApp(tester, size: const Size(390, 800));
    NavigationBar bar() => tester.widget(find.byType(NavigationBar));
    expect(bar().selectedIndex, 0);

    await tester
        .tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Explorar')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(location(c), '/catalog');
    expect(bar().selectedIndex, 1);

    await tester
        .tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Favoritos')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(location(c), '/favorites');
    expect(bar().selectedIndex, 3);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('signed out: Entrar starts login straight from the tap', (tester) async {
    final (c, auth) = await pumpApp(tester, size: const Size(390, 800));
    await tester
        .tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Entrar')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(auth.signInCalls, 1);
    expect(location(c), '/');
  });

  testWidgets('signed in: Perfil goes to /profile', (tester) async {
    final (c, auth) = await pumpApp(tester,
        size: const Size(390, 800), auth: FakeAuthRepository(initialUser: kAna));
    expect(find.text('Entrar'), findsNothing);
    await tester
        .tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Perfil')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(auth.signInCalls, 0);
    expect(location(c), '/profile');
    expect((tester.widget(find.byType(NavigationBar)) as NavigationBar).selectedIndex, 4);
  });

  testWidgets('detail route hides the tab bar, keeps back button and logo', (tester) async {
    final (c, _) = await pumpApp(tester, size: const Size(390, 800));
    c.read(routerProvider).push('/movie/1');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(Image), findsWidgets);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('SyncBanner sits above the tab bar without overlapping it', (tester) async {
    final (_, auth) = await pumpApp(tester,
        size: const Size(390, 800), auth: FakeAuthRepository(initialUser: kAna));
    auth.revokeSession();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(SyncBanner), findsOneWidget);
    final banner = tester.getRect(find.text('Entrar').first);
    expect(find.text('Entrar'), findsWidgets);
    final bannerBox = tester.getRect(
        find.descendant(of: find.byType(SyncBanner), matching: find.byType(Material)).first);
    final bar = tester.getRect(find.byType(NavigationBar));
    expect(bannerBox.bottom, lessThanOrEqualTo(bar.top));
    expect(banner.top, lessThan(bar.top));
  });

  for (final w in [320.0, 360.0, 390.0, 768.0, 769.0]) {
    for (final path in ['/', '/catalog', '/search', '/favorites', '/recommendations']) {
      testWidgets('no layout exceptions at ${w.toInt()}px on $path', (tester) async {
        final (c, _) = await pumpApp(tester, size: Size(w, 700));
        c.read(routerProvider).go(path);
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
