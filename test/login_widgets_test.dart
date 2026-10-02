import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/screens/profile_screen.dart';
import 'package:cinetrack/widgets/account_widgets.dart';
import 'package:cinetrack/widgets/auth_gate.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/in_memory_favorites_data_source.dart';

Widget _app(FakeAuthRepository auth, {Widget? body}) => ProviderScope(
      overrides: cloudOverrides(auth: auth, cloud: FakeCloud()),
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: const [AccountAction()]),
          body: body ?? const SignInInvite(),
        ),
      ),
    );

void main() {
  group('login (FakeAuthRepository)', () {
    testWidgets('signed out shows the invite; successful login shows the avatar', (tester) async {
      final auth = FakeAuthRepository();
      await tester.pumpWidget(_app(auth));
      await tester.pumpAndSettle();

      expect(find.textContaining('Entre para salvar seus favoritos'), findsOneWidget);

      await tester.tap(find.text('Entrar com Google'));
      await tester.pumpAndSettle();

      expect(auth.signInCalls, 1);
      expect(find.text('Entrar com Google'), findsNothing); // invite gone
      expect(find.byTooltip('Perfil de Ana Teste'), findsOneWidget);
    });

    testWidgets('cancelled login: neutral notice, still signed out, can retry', (tester) async {
      final auth = FakeAuthRepository()..nextFailure = const AuthFailure(AuthFailureKind.cancelled);
      await tester.pumpWidget(_app(auth));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Entrar com Google'));
      await tester.pumpAndSettle();

      expect(find.text('Login cancelado.'), findsOneWidget);
      expect(find.text('Entrar com Google'), findsOneWidget); // still offered
      expect(find.byTooltip('Perfil de Ana Teste'), findsNothing);
    });

    testWidgets('blocked popup: explains it and offers "Tentar novamente" that works',
        (tester) async {
      final auth = FakeAuthRepository()
        ..nextFailure = const AuthFailure(AuthFailureKind.popupBlocked);
      await tester.pumpWidget(_app(auth));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Entrar com Google'));
      await tester.pumpAndSettle();

      expect(find.textContaining('bloqueou a janela de login'), findsOneWidget);
      expect(find.text('Tentar novamente'), findsOneWidget);

      auth.nextFailure = null;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();

      expect(auth.signInCalls, 2);
      expect(find.byTooltip('Perfil de Ana Teste'), findsOneWidget);
    });

    testWidgets('offline: shows the connection message and stays signed out', (tester) async {
      final auth = FakeAuthRepository()..nextFailure = const AuthFailure(AuthFailureKind.network);
      await tester.pumpWidget(_app(auth));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Entrar com Google'));
      await tester.pumpAndSettle();

      expect(find.text('Sem conexão. Conecte-se à internet para entrar.'), findsOneWidget);
    });

    testWidgets('double tap does not start a second attempt (button disabled in progress)',
        (tester) async {
      final auth = FakeAuthRepository()..gate = Completer<void>();
      await tester.pumpWidget(_app(auth));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Entrar com Google'));
      await tester.pump();
      expect(find.text('Entrando...'), findsOneWidget);
      await tester.tap(find.text('Entrando...'), warnIfMissed: false);
      await tester.pump();

      expect(auth.signInCalls, 1);

      auth.gate!.complete();
      await tester.pumpAndSettle();
      expect(auth.signInCalls, 1);
    });

    testWidgets('login unavailable (no Firebase): no login UI, no crash', (tester) async {
      await tester.pumpWidget(_app(FakeAuthRepository(available: false)));
      await tester.pumpAndSettle();

      expect(find.text('Entrar com Google'), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('trying to write while login is unavailable explains it', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(FakeAuthRepository(available: false))],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => signInWithFeedback(
                  ProviderScope.containerOf(context),
                  ScaffoldMessenger.maybeOf(context),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pump();

      expect(find.text(kLoginUnavailableMessage), findsOneWidget);
    });
  });

  group('profile', () {
    testWidgets('shows name, e-mail and initials avatar when there is no photo', (tester) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      await tester.pumpWidget(_app(auth, body: const ProfileScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Ana Teste'), findsWidgets);
      expect(find.text('ana@example.test'), findsOneWidget);
      expect(find.text('AT'), findsWidgets);
    });

    testWidgets('sign out asks for confirmation; cancel keeps the session', (tester) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      await tester.pumpWidget(_app(auth, body: const ProfileScreen()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Sair'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sair'));
      await tester.pumpAndSettle();
      expect(find.text('Sair da conta?'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(auth.signOutCalls, 0);
      expect(find.text('Sair da conta?'), findsNothing);
      expect(find.text('Você não está conectado.'), findsNothing);
    });
  });
}
