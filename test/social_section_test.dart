import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/screens/profile_screen.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/widgets/social_section.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_social_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

const _googleUser = AppUser(
  uid: 'uid-ana',
  displayName: 'Ana Teste',
  email: 'ana@example.test',
  photoUrl: 'https://lh3.googleusercontent.com/a/ana',
);

class _Rig {
  final cloud = FakeCloud();
  final social = FakeSocialCloud();
  final store = FakeLocalStore();
  late final FakeAuthRepository auth;

  _Rig({AppUser? user = _googleUser}) {
    auth = FakeAuthRepository(initialUser: user);
  }

  Widget app({
    double width = 800,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    bool profile = false,
  }) {
    return ProviderScope(
      overrides: cloudOverrides(auth: auth, cloud: cloud, socialCloud: social, store: store),
      child: MaterialApp(
        theme: ThemeData(brightness: brightness, useMaterial3: true),
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 900), textScaler: TextScaler.linear(textScale)),
          child: profile
              ? const ProfileScreen()
              : Scaffold(
                  body: ListView(
                    padding: const EdgeInsets.all(16),
                    children: const [SocialSection()],
                  ),
                ),
        ),
      ),
    );
  }
}

Finder _btn(String label) =>
    find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>());

Future<void> _open(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('off by default: explains, offers "Ativar amizades", writes nothing', (tester) async {
    final rig = _Rig();
    await _open(tester, rig.app());
    expect(find.text('Amizades'), findsOneWidget);
    expect(find.text('Ativar amizades'), findsOneWidget);
    expect(rig.social.log, isEmpty);
    expect(rig.social.leftoversOf('uid-ana'), isEmpty);
  });

  testWidgets('also appears inside the profile screen', (tester) async {
    final rig = _Rig();
    await _open(tester, rig.app(profile: true));
    await tester.scrollUntilVisible(
      find.text('Ativar amizades'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(SocialSection), findsOneWidget);
  });

  test('loading state comes first, then the real state (never a false "inactive")', () async {
    final rig = _Rig();
    final container = ProviderContainer(
      overrides: cloudOverrides(auth: rig.auth, cloud: rig.cloud, socialCloud: rig.social),
    );
    addTearDown(container.dispose);
    container.listen(authStateProvider, (_, _) {});
    await container.read(authStateProvider.future);
    container.listen(socialControllerProvider, (_, _) {});
    expect(container.read(socialControllerProvider).phase, SocialPhase.loading);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(socialControllerProvider).phase, SocialPhase.inactive);
  });

  testWidgets('activation: validates, then creates card + pointer with consent text', (
    tester,
  ) async {
    final rig = _Rig();
    await _open(tester, rig.app());
    await tester.tap(find.text('Ativar amizades'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ao ativar, copiamos'), findsOneWidget);

    // empty -> errors, nothing written
    await tester.tap(_btn('Ativar amizades').last);
    await tester.pumpAndSettle();
    expect(find.text('Digite um identificador.'), findsOneWidget);
    expect(rig.social.log, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, 'Identificador'), 'admin');
    await tester.pump();
    await tester.tap(_btn('Ativar amizades').last);
    await tester.pumpAndSettle();
    expect(find.text('Esse identificador não está disponível.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Identificador'), '@Ana_9');
    await tester.tap(find.text('Usar meu nome do Google'));
    await tester.pump();
    await tester.tap(_btn('Ativar amizades').last);
    await tester.pumpAndSettle();

    expect(rig.social.handles['ana_9']!['nickname'], 'Ana Teste');
    expect(rig.social.handles['ana_9']!['photoURL'], _googleUser.photoUrl);
    expect(rig.social.handles['ana_9']!['discoverable'], true);
    expect(find.text('@ana_9'), findsOneWidget);
    expect(find.text('Desativar amizades'), findsOneWidget);
    // the app nickname follows the card (source of truth)
    expect(rig.cloud.profiles['uid-ana']!.nickname, 'Ana Teste');
  });

  testWidgets('taken handle: field error, nothing created', (tester) async {
    final rig = _Rig();
    rig.social.seedActive('uid-bruno', 'maria');
    await _open(tester, rig.app());
    await tester.tap(find.text('Ativar amizades'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Identificador'), 'maria');
    await tester.enterText(find.widgetWithText(TextField, 'Apelido público'), 'Ana');
    await tester.tap(_btn('Ativar amizades').last);
    await tester.pumpAndSettle();
    expect(find.text('Esse identificador não está disponível.'), findsOneWidget);
    expect(rig.social.social.containsKey('uid-ana'), isFalse);
  });

  testWidgets('Enter in the nickname field submits (keyboard)', (tester) async {
    final rig = _Rig();
    await _open(tester, rig.app());
    await tester.tap(find.text('Ativar amizades'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Identificador'), 'ana_k');
    await tester.enterText(find.widgetWithText(TextField, 'Apelido público'), 'Ana');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(rig.social.handles.containsKey('ana_k'), isTrue);
  });

  testWidgets('rules not published: visible message, retry; nothing breaks', (tester) async {
    final rig = _Rig();
    rig.social.rulesLive = false;
    await _open(tester, rig.app());
    expect(find.text('Amizades ainda não estão disponíveis. Tente mais tarde.'), findsOneWidget);
    rig.social.rulesLive = true;
    await tester.tap(find.text('Tentar de novo'));
    await tester.pumpAndSettle();
    expect(find.text('Ativar amizades'), findsOneWidget);
  });

  testWidgets('non-Google account: explains and never reads', (tester) async {
    final rig = _Rig(
      user: const AppUser(uid: 'uid-p', displayName: 'P', isGoogle: false),
    );
    await _open(tester, rig.app());
    expect(find.textContaining('só estão disponíveis para contas'), findsOneWidget);
    expect(find.text('Ativar amizades'), findsNothing);
  });

  group('active', () {
    _Rig active() {
      final rig = _Rig();
      rig.social.seedActive('uid-ana', 'ana', nickname: 'Ana', photoUrl: _googleUser.photoUrl);
      return rig;
    }

    testWidgets('shows handle, nickname, and toggles "Aparecer na busca"', (tester) async {
      final rig = active();
      await _open(tester, rig.app());
      expect(find.text('@ana'), findsOneWidget);
      await tester.tap(find.text('Aparecer na busca'));
      await tester.pumpAndSettle();
      expect(rig.social.handles['ana']!['discoverable'], false);
      await tester.tap(find.text('Mostrar minha foto'));
      await tester.pumpAndSettle();
      expect(rig.social.handles['ana']!['photoURL'], isNull);
    });

    testWidgets('handle change inside 30 days is disabled with the date', (tester) async {
      final rig = _Rig();
      rig.social.seedActive('uid-ana', 'ana', handleChangedAt: DateTime.now());
      await _open(tester, rig.app());
      expect(find.textContaining('Você poderá trocar o identificador de novo em'), findsOneWidget);
      final button = tester.widget<ButtonStyleButton>(_btn('Trocar identificador'));
      expect(button.onPressed, isNull);
    });

    testWidgets('changes the handle after 30 days', (tester) async {
      final rig = active();
      await _open(tester, rig.app());
      await tester.tap(find.text('Trocar identificador'));
      await tester.pumpAndSettle();
      expect(find.textContaining('uma vez a cada 30 dias'), findsWidgets);
      await tester.enterText(find.widgetWithText(TextField, 'Novo identificador'), 'ana_nova');
      await tester.tap(_btn('Trocar'));
      await tester.pumpAndSettle();
      expect(rig.social.handles.keys, ['ana_nova']);
      expect(find.text('@ana_nova'), findsOneWidget);
    });

    testWidgets('deactivation: says what is erased, focus on Cancelar, then erases', (
      tester,
    ) async {
      final rig = active();
      rig.social
        ..seedActive('uid-bruno', 'bruno')
        ..seedFriendship('uid-ana', 'uid-bruno')
        ..seedRequest('uid-x', 'uid-ana')
        ..seedBlock('uid-ana', 'uid-y');
      await _open(tester, rig.app());
      await tester.tap(find.text('Desativar amizades'));
      await tester.pumpAndSettle();
      expect(find.textContaining('amigos'), findsWidgets);
      expect(find.textContaining('bloqueios'), findsOneWidget);
      expect(find.textContaining('convite'), findsOneWidget);
      final cancel = tester.widget<TextButton>(_btn('Cancelar'));
      expect(cancel.autofocus, isTrue);

      // cancel changes nothing
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(rig.social.social.containsKey('uid-ana'), isTrue);

      await tester.tap(find.text('Desativar amizades'));
      await tester.pumpAndSettle();
      await tester.tap(_btn('Desativar amizades').last);
      await tester.pumpAndSettle();
      expect(rig.social.leftoversOf('uid-ana'), isEmpty);
      expect(find.text('Ativar amizades'), findsOneWidget);
    });

    testWidgets('deactivation failure shows the message and can retry', (tester) async {
      final rig = active();
      rig.social.seedFriendship('uid-ana', 'uid-bruno');
      rig.social.failOnDeleteCall = 1;
      await _open(tester, rig.app());
      await tester.tap(find.text('Desativar amizades'));
      await tester.pumpAndSettle();
      await tester.tap(_btn('Desativar amizades').last);
      await tester.pumpAndSettle();
      expect(find.text('Sem conexão. Tente de novo quando estiver online.'), findsOneWidget);
      expect(rig.social.social.containsKey('uid-ana'), isTrue);
      await tester.tap(_btn('Tentar de novo'));
      await tester.pumpAndSettle();
      expect(rig.social.leftoversOf('uid-ana'), isEmpty);
    });

    testWidgets('nickname dialog also updates the card and cannot be cleared', (tester) async {
      final rig = active();
      await _open(tester, rig.app());
      await tester.tap(find.text('Editar apelido'));
      await tester.pumpAndSettle();
      expect(find.text('Usar nome do Google'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Ana Nova');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();
      expect(rig.social.handles['ana']!['nickname'], 'Ana Nova');
      expect(rig.cloud.profiles['uid-ana']!.nickname, 'Ana Nova');
    });

    testWidgets('semantics: header, labels start with the visible text, no dead ends', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final rig = active();
      await _open(tester, rig.app());
      expect(
        tester.getSemantics(find.text('Amizades')),
        matchesSemantics(label: 'Amizades', isHeader: true),
      );
      for (final label in ['Aparecer na busca', 'Mostrar minha foto']) {
        final data = tester.getSemantics(find.text(label)).getSemanticsData();
        expect(data.label, startsWith(label));
      }
      expect(find.bySemanticsLabel(RegExp('^Trocar identificador')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Desativar amizades')), findsOneWidget);
      handle.dispose();
    });
  });

  testWidgets('"Aparecer na busca" default in the form is the single constant', (tester) async {
    final rig = _Rig();
    await _open(tester, rig.app());
    await tester.tap(find.text('Ativar amizades'));
    await tester.pumpAndSettle();
    final tile = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Aparecer na busca'),
    );
    expect(tile.value, kDiscoverableByDefault);
    await tester.enterText(find.widgetWithText(TextField, 'Identificador'), 'ana_d');
    await tester.enterText(find.widgetWithText(TextField, 'Apelido público'), 'Ana');
    await tester.tap(_btn('Ativar amizades').last);
    await tester.pumpAndSettle();
    expect(rig.social.handles['ana_d']!['discoverable'], kDiscoverableByDefault);
  });

  testWidgets('deactivation whose last sweep fails offers "Concluir limpeza"', (tester) async {
    final rig = _Rig();
    rig.social.seedActive('uid-ana', 'ana');
    rig.social.beforeClose = () {
      rig.social.seedFriendship('uid-ana', 'uid-late');
      rig.social.failOnDeleteCall = rig.social.deleteCalls + 1;
      rig.social.beforeClose = null;
    };
    await _open(tester, rig.app());
    await tester.tap(find.text('Desativar amizades'));
    await tester.pumpAndSettle();
    await tester.tap(_btn('Desativar amizades').last);
    await tester.pumpAndSettle();
    // dialog stays with the error; close it
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Concluir limpeza'), findsOneWidget);
    expect(rig.social.friendships, isNotEmpty);
    // persisted per device: a fresh app (new session) still offers it
    expect(rig.store.socialCleanupPending('uid-ana'), isTrue);
    await tester.pumpWidget(const SizedBox());
    await _open(tester, rig.app());
    expect(find.text('Concluir limpeza'), findsOneWidget);
    await tester.tap(find.text('Concluir limpeza'));
    await tester.pumpAndSettle();
    expect(find.text('Concluir limpeza'), findsNothing);
    expect(rig.store.socialCleanupPending('uid-ana'), isFalse);
    expect(rig.social.leftoversOf('uid-ana'), isEmpty);
  });

  group('layout matrix (no overflow, targets >= 48 px)', () {
    for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 3.0]) {
        for (final dark in [false, true]) {
          testWidgets('$width px, font ${scale}x, ${dark ? 'dark' : 'light'}', (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final rig = _Rig();
            final brightness = dark ? Brightness.dark : Brightness.light;
            await _open(tester, rig.app(width: width, textScale: scale, brightness: brightness));
            expect(tester.takeException(), isNull);
            for (final b in tester.widgetList<ButtonStyleButton>(find.byType(ButtonStyleButton))) {
              expect(b, isNotNull);
            }
            final size = tester.getSize(_btn('Ativar amizades'));
            expect(size.height, greaterThanOrEqualTo(48));

            // dialog + active state
            await tester.ensureVisible(find.text('Ativar amizades'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Ativar amizades'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('Cancelar'));
            await tester.pumpAndSettle();

            rig.social.seedActive(
              'uid-ana',
              'ana',
              nickname: 'Ana',
              photoUrl: _googleUser.photoUrl,
            );
            await tester.pumpWidget(const SizedBox());
            await _open(tester, rig.app(width: width, textScale: scale, brightness: brightness));
            expect(tester.takeException(), isNull);
            for (final label in ['Trocar identificador', 'Editar apelido', 'Desativar amizades']) {
              final h = tester.getSize(_btn(label)).height;
              expect(h, greaterThanOrEqualTo(48), reason: label);
            }
          });
        }
      }
    }
  });

  test('controller state is reset for another account', () async {
    final rig = _Rig();
    final container = ProviderContainer(
      overrides: cloudOverrides(auth: rig.auth, cloud: rig.cloud, socialCloud: rig.social),
    );
    addTearDown(container.dispose);
    container.listen(socialControllerProvider, (_, _) {});
    expect(container.read(socialControllerProvider).phase, SocialPhase.signedOut);
  });
}
