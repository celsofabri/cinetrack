import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/router.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Auth whose session is never resolved (stream stays in `loading`).
class _NeverEmitsAuth extends FakeAuthRepository {
  @override
  Stream<AppUser?> authStateChanges() => StreamController<AppUser?>().stream;
}

String _location(GoRouter r) => r.routerDelegate.currentConfiguration.uri.path;

void main() {
  Future<GoRouter> pumpApp(WidgetTester tester, FakeAuthRepository auth) async {
    final container = ProviderContainer(
      overrides: cloudOverrides(auth: auth, cloud: FakeCloud()),
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
    return router;
  }

  testWidgets('signed out: /profile redirects to home', (tester) async {
    final router = await pumpApp(tester, FakeAuthRepository());
    router.go('/profile');
    await tester.pump();
    await tester.pump();
    expect(_location(router), '/');
  });

  testWidgets('signed in: /profile is reachable', (tester) async {
    final router = await pumpApp(tester, FakeAuthRepository(initialUser: kAna));
    router.go('/profile');
    await tester.pump();
    await tester.pump();
    expect(_location(router), '/profile');
  });

  testWidgets('session still loading: /profile does not redirect', (tester) async {
    final router = await pumpApp(tester, _NeverEmitsAuth());
    router.go('/profile');
    await tester.pump();
    await tester.pump();
    expect(_location(router), '/profile');
  });

  testWidgets('other routes are public when signed out', (tester) async {
    final router = await pumpApp(tester, FakeAuthRepository());
    router.go('/favorites');
    await tester.pump();
    await tester.pump();
    expect(_location(router), '/favorites');
  });
}
