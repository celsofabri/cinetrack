import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/profile_data_source.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/widgets/account_widgets.dart';
import 'package:cinetrack/widgets/favorites_section.dart';
import 'package:cinetrack/widgets/sync_widgets.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/in_memory_favorites_data_source.dart';

FavoriteDoc _movie(int id) => FavoriteDoc(
      id: id,
      mediaType: MediaType.movie,
      title: 'Filme $id',
      posterPath: null,
      overview: '',
      addedAt: DateTime(2026),
    );

/// The app shell the same way main.dart wires it: screen + banner below.
Widget _shell(
  FakeAuthRepository auth,
  FakeCloud cloud, {
  Widget body = const SizedBox(),
  Duration grace = Duration.zero,
}) =>
    ProviderScope(
      overrides: cloudOverrides(auth: auth, cloud: cloud, grace: grace),
      child: MaterialApp(
        builder: (context, child) => Column(
          children: [Expanded(child: child!), SyncBanner(onOpenProfile: () => profileOpened++)],
        ),
        home: Scaffold(
          appBar: AppBar(actions: const [AccountAction()]),
          body: body,
        ),
      ),
    );

int profileOpened = 0;

Finder _indicator(String label) => find.byTooltip(label);

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold)));

void main() {
  group('indicator', () {
    testWidgets('synced -> offline with pending -> synced again', (tester) async {
      final cloud = FakeCloud();
      await tester.pumpWidget(_shell(FakeAuthRepository(initialUser: kAna), cloud));
      await tester.pumpAndSettle();
      expect(_indicator('Sincronizado'), findsOneWidget);

      cloud.offline = true;
      await tester.pumpAndSettle();
      expect(_indicator('Sem conexão. Mostrando dados deste aparelho.'), findsOneWidget);

      await _container(tester)
          .read(favoritesRepositoryProvider)
          .addMovie(id: 1, title: 'Filme', posterPath: null, overview: '');
      await tester.pumpAndSettle();
      expect(
        _indicator('Sem conexão. Alterações pendentes serão enviadas ao reconectar.'),
        findsOneWidget,
      );

      cloud
        ..offline = false
        ..flush('uid-ana');
      await tester.pumpAndSettle();
      expect(_indicator('Sincronizado'), findsOneWidget);
    });

    testWidgets('not shown when signed out', (tester) async {
      await tester.pumpWidget(_shell(FakeAuthRepository(), FakeCloud()));
      await tester.pumpAndSettle();
      expect(find.byType(SyncIndicator), findsNothing);
      expect(find.byIcon(Icons.cloud_done_outlined), findsNothing);
    });
  });

  group('banner', () {
    testWidgets('a rejected write is explained and can be dismissed (finding I1)', (tester) async {
      await tester.pumpWidget(_shell(FakeAuthRepository(initialUser: kAna), FakeCloud()));
      await tester.pumpAndSettle();
      expect(find.byType(SyncBanner), findsOneWidget);
      expect(find.textContaining('recusou uma alteração'), findsNothing);

      _container(tester).read(syncFailureSinkProvider).reportCode('permission-denied');
      await tester.pumpAndSettle();

      expect(find.textContaining('recusou uma alteração'), findsOneWidget);
      expect(_indicator('Problema ao sincronizar'), findsOneWidget);

      await tester.tap(find.text('Entendi'));
      await tester.pumpAndSettle();
      expect(find.textContaining('recusou uma alteração'), findsNothing);
      expect(_indicator('Sincronizado'), findsOneWidget);
    });

    testWidgets('quota exhausted shows an honest message', (tester) async {
      await tester.pumpWidget(_shell(FakeAuthRepository(initialUser: kAna), FakeCloud()));
      await tester.pumpAndSettle();

      _container(tester).read(syncFailureSinkProvider).reportCode('resource-exhausted');
      await tester.pumpAndSettle();

      expect(find.textContaining('limite diário gratuito'), findsOneWidget);
    });

    testWidgets('revoked session: banner with Entrar; signing in again hides it', (tester) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      await tester.pumpWidget(_shell(auth, FakeCloud()));
      await tester.pumpAndSettle();

      auth.revokeSession();
      await tester.pumpAndSettle();
      expect(find.textContaining('Sessão expirada'), findsOneWidget);
      expect(find.textContaining('alterações pendentes ficam guardadas'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Entrar'));
      await tester.pumpAndSettle();

      expect(auth.signInCalls, 1);
      expect(find.textContaining('Sessão expirada'), findsNothing);
    });

    testWidgets('unauthenticated write error while still signed in also asks to sign in',
        (tester) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      await tester.pumpWidget(_shell(auth, FakeCloud()));
      await tester.pumpAndSettle();

      _container(tester).read(syncFailureSinkProvider).reportCode('unauthenticated');
      await tester.pumpAndSettle();
      expect(find.textContaining('Sessão expirada'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Entrar'));
      await tester.pumpAndSettle();

      expect(auth.signInCalls, 1);
      expect(find.textContaining('Sessão expirada'), findsNothing);
    });

    testWidgets('signing out on purpose shows no expiry banner', (tester) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      await tester.pumpWidget(_shell(auth, FakeCloud()));
      await tester.pumpAndSettle();

      await _container(tester).read(authControllerProvider.notifier).signOut();
      await tester.pumpAndSettle();

      expect(find.textContaining('Sessão expirada'), findsNothing);
    });

    testWidgets('an unfinished account deletion is surfaced with a way to resume', (tester) async {
      profileOpened = 0;
      final cloud = FakeCloud()..profiles['uid-ana'] = const UserProfile(deleting: true);
      await tester.pumpWidget(_shell(FakeAuthRepository(initialUser: kAna), cloud));
      await tester.pumpAndSettle();

      expect(find.textContaining('exclusão da sua conta ficou pela metade'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Concluir'));
      expect(profileOpened, 1);
    });
  });

  group('first load: error is not empty', () {
    testWidgets('offline with nothing cached: spinner, then an error with Tentar novamente',
        (tester) async {
      final cloud = FakeCloud()..offline = true;
      await tester.pumpWidget(_shell(
        FakeAuthRepository(initialUser: kAna),
        cloud,
        body: const SingleChildScrollView(child: FavoritesSection()),
        grace: const Duration(seconds: 5),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Nenhum favorito ainda'), findsNothing);

      await tester.pump(const Duration(seconds: 6));

      expect(find.textContaining('Não foi possível carregar seus favoritos'), findsOneWidget);
      expect(find.text('Nenhum favorito ainda'), findsNothing);

      // Back online: retry shows the real state.
      cloud.offline = false;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();

      expect(find.text('Nenhum favorito ainda'), findsOneWidget);
      expect(find.textContaining('Não foi possível carregar'), findsNothing);
    });

    testWidgets('online and genuinely empty: the normal empty state', (tester) async {
      await tester.pumpWidget(_shell(
        FakeAuthRepository(initialUser: kAna),
        FakeCloud(),
        body: const SingleChildScrollView(child: FavoritesSection()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Nenhum favorito ainda'), findsOneWidget);
    });

    testWidgets('offline but with cached favorites: the list, not an error', (tester) async {
      final cloud = FakeCloud();
      cloud.server['uid-ana'] = {'1-movie': _movie(1)};
      await tester.pumpWidget(_shell(
        FakeAuthRepository(initialUser: kAna),
        cloud,
        body: const SingleChildScrollView(child: FavoritesSection()),
      ));
      await tester.pumpAndSettle();
      cloud.offline = true;
      await tester.pumpAndSettle();

      expect(find.text('Filme 1'), findsOneWidget);
      expect(find.textContaining('Não foi possível carregar'), findsNothing);
    });

    testWidgets('signed out: no loading/error gate, the plain empty state', (tester) async {
      await tester.pumpWidget(_shell(
        FakeAuthRepository(),
        FakeCloud(),
        body: const SingleChildScrollView(child: FavoritesSection()),
        grace: const Duration(seconds: 5),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Nenhum favorito ainda'), findsOneWidget);
    });
  });
}
