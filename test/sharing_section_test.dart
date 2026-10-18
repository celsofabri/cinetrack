import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/screens/profile_screen.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/widgets/privacy_summary.dart';
import 'package:cinetrack/widgets/sharing_section.dart';

import 'support/sharing_rig.dart';

/// "O que seus amigos veem" on Meu perfil (docs/81 RF-P, estados de UI,
/// layout e acessibilidade; docs/82 §7.1, §10).
Widget _app(
  SharingRig rig, {
  double width = 800,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool profile = false,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: profile
              ? const ProfileScreen()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: const SharingSection(),
                ),
        ),
      ),
      GoRoute(
        path: '/movie/:id',
        builder: (context, state) => Text('movie ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/tv/:id',
        builder: (context, state) => Text('tv ${state.pathParameters['id']}'),
      ),
    ],
  );
  return ProviderScope(
    overrides: rig.overrides(),
    child: MediaQuery(
      data: MediaQueryData(size: Size(width, 900), textScaler: TextScaler.linear(textScale)),
      child: MaterialApp.router(
        theme: ThemeData(brightness: brightness, useMaterial3: true),
        routerConfig: router,
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Finder _switch(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(SwitchListTile));

bool _on(WidgetTester tester, String label) => tester.widget<SwitchListTile>(_switch(label)).value;

ActivityItem _activity(int i) => ActivityItem(
  type: ActivityType.watchedMovie,
  id: 100 + i,
  mediaType: 'movie',
  title: 'Filme $i',
  at: kSharingNow.subtract(Duration(hours: i)),
);

SharingRig _rigWith(Set<SharedSection> sections, {List<ActivityItem>? activity}) {
  final rig = SharingRig();
  for (var i = 1; i <= 4; i++) {
    rig.seed(sharingMovie(i, watched: i.isEven));
  }
  if (sections.isNotEmpty) {
    rig.seedShared(sections, actSince: kSharingNow.subtract(const Duration(days: 2)));
    if (activity != null) rig.doc!['activity'] = [for (final a in activity) a.toJson()];
  }
  return rig;
}

void main() {
  testWidgets('without active friendships the profile has no new section and reads nothing', (
    tester,
  ) async {
    final rig = SharingRig(active: false);
    await _open(tester, _app(rig, profile: true));
    expect(find.text('O que seus amigos veem'), findsNothing);
    expect(rig.log, isNot(contains('readOwn')));
  });

  testWidgets('everything off by default: 3 toggles, the card text, 1 read, 0 writes', (
    tester,
  ) async {
    final rig = _rigWith({});
    final handle = tester.ensureSemantics();
    await _open(tester, _app(rig));
    expect(find.text('O que seus amigos veem'), findsOneWidget);
    expect(_on(tester, 'Estatísticas'), isFalse);
    expect(_on(tester, 'Atividades recentes'), isFalse);
    expect(_on(tester, 'Recomendados'), isFalse, reason: 'D2: off by default');
    expect(find.text(kSharingAllOff), findsOneWidget);
    expect(rig.log, ['readOwn']);
    expect(rig.shared.toggles, isEmpty);
    expect(
      tester.getSemantics(_switch('Estatísticas')),
      isSemantics(
        label: 'Compartilhar estatísticas com amigos',
        hasToggledState: true,
        isToggled: false,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(_switch('Atividades recentes')),
      isSemantics(
        label: 'Compartilhar atividades recentes com amigos',
        hasToggledState: true,
        isToggled: false,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(_switch('Recomendados')),
      isSemantics(
        label: 'Compartilhar recomendados com amigos',
        hasToggledState: true,
        isToggled: false,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('consent dialog: literal texts, preview = live profile numbers, Cancelar/Esc', (
    tester,
  ) async {
    final rig = _rigWith({});
    await _open(tester, _app(rig));
    await tester.tap(_switch('Estatísticas'));
    await tester.pumpAndSettle();
    expect(find.text(kSharingDialogs[SharedSection.stats]!.title), findsOneWidget);
    expect(find.text(kSharingDialogs[SharedSection.stats]!.body), findsOneWidget);
    expect(
      kSharingDialogs[SharedSection.stats]!.body,
      'Seus amigos mútuos vão ver seus números (favoritos, filmes e episódios assistidos, séries '
      'assistidas e concluídas e tempo assistido), os totais deste mês e deste ano e desde quando '
      'você está no CineTrack, no seu perfil e nas comparações entre amigos. Você pode desligar '
      'quando quiser: desligar apaga na hora.',
    );
    final live = ProviderScope.containerOf(
      tester.element(find.byType(SharingSection)),
    ).read(profileStatsProvider);
    final grid = find.byKey(const Key('sharing-preview-grid'));
    for (final (label, value) in [
      ('Favoritos', live.favorites),
      ('Filmes favoritos', live.movies),
      ('Séries favoritas', live.series),
      ('Filmes assistidos', live.watchedMovies),
      ('Episódios assistidos', live.watchedEpisodes),
      ('Séries concluídas', live.completedSeries),
    ]) {
      expect(
        find.descendant(of: grid, matching: find.bySemanticsLabel('$label: $value')),
        findsOneWidget,
      );
    }
    expect(find.descendant(of: grid, matching: find.textContaining('Recomendações')), findsNothing);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(_on(tester, 'Estatísticas'), isFalse);
    // Esc closes it too, nothing written.
    await tester.tap(_switch('Atividades recentes'));
    await tester.pumpAndSettle();
    expect(find.text(kSharingDialogs[SharedSection.activity]!.title), findsOneWidget);
    expect(find.text(kSharingDialogs[SharedSection.activity]!.body), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(rig.shared.toggles, isEmpty);
  });

  testWidgets('"Calculando…" while the data is not confirmed (pending writes)', (tester) async {
    final rig = _rigWith({});
    await _open(tester, _app(rig));
    rig.cloud.stuck = true;
    rig.cloud.write('uid-ana', (_) {});
    await tester.pumpAndSettle();
    await tester.tap(_switch('Estatísticas'));
    await tester.pumpAndSettle();
    final button = find.ancestor(of: find.text('Calculando…'), matching: find.byType(FilledButton));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    rig.cloud.stuck = false;
    rig.cloud.flush('uid-ana');
    await tester.pumpAndSettle();
    expect(find.text('Compartilhar'), findsOneWidget);
  });

  testWidgets('Compartilhar: on, "Atualizado agora", preview opens; off: message, no dialog', (
    tester,
  ) async {
    final rig = _rigWith({});
    await _open(tester, _app(rig));
    await tester.tap(_switch('Estatísticas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compartilhar'));
    await tester.pumpAndSettle();
    expect(_on(tester, 'Estatísticas'), isTrue);
    expect(rig.shared.toggles, hasLength(1));
    expect(find.text('Atualizado agora'), findsOneWidget);
    expect(find.text(kSharingAllOff), findsNothing);
    await tester.tap(find.text('Como seus amigos veem'));
    await tester.pumpAndSettle();
    expect(find.text('No total'), findsOneWidget);
    expect(find.text('Este mês'), findsOneWidget);
    expect(find.text('Este ano'), findsOneWidget);
    expect(find.text('No CineTrack desde 02/03/2025'), findsOneWidget);

    await tester.tap(_switch('Estatísticas'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Seus amigos não veem mais suas estatísticas.'), findsOneWidget);
    expect(_on(tester, 'Estatísticas'), isFalse);
    expect(rig.doc, isNull);
  });

  testWidgets('uncertain: "Ainda não confirmado…", disabled, then the real state', (tester) async {
    final rig = _rigWith({});
    await _open(tester, _app(rig));
    rig.shared
      ..failNext('toggle', const SocialFailure(SocialFailureKind.uncertain))
      ..failNext('readOwn', const SocialFailure(SocialFailureKind.offline))
      ..deliverUncertainToggles = true;
    await tester.tap(_switch('Estatísticas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compartilhar'));
    await tester.pump();
    await tester.pump();
    expect(find.text(kSharingUncertain), findsOneWidget);
    expect(tester.widget<SwitchListTile>(_switch('Estatísticas')).onChanged, isNull);
    rig.cloud.offline = true;
    await tester.pump();
    rig.cloud.offline = false;
    await tester.pumpAndSettle();
    expect(find.text(kSharingUncertain), findsNothing);
    expect(_on(tester, 'Estatísticas'), isTrue);
    expect(find.text('Compartilhamento ligado.'), findsOneWidget);
  });

  testWidgets('offline with nothing confirmed: toggles disabled + "Sem conexão…"', (tester) async {
    final rig = _rigWith({});
    rig.shared.failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
    await _open(tester, _app(rig));
    expect(find.text('Sem conexão. Tente de novo quando estiver online.'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(_switch('Estatísticas')).onChanged, isNull);
  });

  testWidgets('offline after confirming: tapping does not move the toggle, "Sem conexão…"', (
    tester,
  ) async {
    final rig = _rigWith({});
    await _open(tester, _app(rig));
    rig.cloud.offline = true;
    await tester.pumpAndSettle();
    await tester.tap(_switch('Estatísticas'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(_on(tester, 'Estatísticas'), isFalse);
    expect(find.text('Sem conexão. Tente de novo quando estiver online.'), findsOneWidget);
  });

  testWidgets('"Atividades recentes": 3 of 10, tap opens the title', (tester) async {
    final rig = _rigWith(
      {SharedSection.activity},
      activity: [for (var i = 1; i <= 10; i++) _activity(i)],
    );
    await _open(tester, _app(rig));
    expect(find.text('Assistiu Filme 1'), findsOneWidget);
    expect(find.text('Assistiu Filme 3'), findsOneWidget);
    expect(find.text('Assistiu Filme 4'), findsNothing);
    expect(find.text('há 1 h'), findsOneWidget);
    await tester.tap(find.text('Assistiu Filme 1'));
    await tester.pumpAndSettle();
    expect(find.text('movie 101'), findsOneWidget);
  });

  testWidgets('"Atividades recentes" on with nothing yet: "Suas próximas atividades…"', (
    tester,
  ) async {
    final empty = _rigWith({SharedSection.activity}, activity: const []);
    await _open(tester, _app(empty));
    expect(find.text(kSharingNoActivity), findsOneWidget);
  });

  testWidgets(
    'focus order: Estatísticas, Atividades, Recomendados, Como seus amigos veem, each activity',
    (
    tester,
  ) async {
    final rig = _rigWith(
      {SharedSection.stats, SharedSection.activity},
      activity: [for (var i = 1; i <= 3; i++) _activity(i)],
    );
    await _open(tester, _app(rig));
    final order = <String>[];
    for (var i = 0; i < 7; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus == null) continue;
      final texts = find.descendant(
        of: find.byElementPredicate((e) => e == focus),
        matching: find.byType(Text),
      );
      final words = [for (final t in tester.widgetList<Text>(texts)) t.data ?? ''];
      order.add(words.isEmpty ? '?' : words.first);
    }
    expect(order.take(7).toList(), [
      'Estatísticas',
      'Atividades recentes',
      'Recomendados',
      'Como seus amigos veem',
      'Assistiu Filme 1',
      'Assistiu Filme 2',
      'Assistiu Filme 3',
    ]);
  });

  group('layout matrix (no overflow, no exception)', () {
    for (final width in [320.0, 375.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('$width px, ${scale}x, ${brightness.name}', (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final rig = _rigWith(
              {SharedSection.stats, SharedSection.activity},
              activity: [
                for (var i = 1; i <= 3; i++)
                  _activity(i).copyWith(title: 'Um título muito longo de filme $i ' * 6),
              ],
            );
            await _open(tester, _app(rig, width: width, textScale: scale, brightness: brightness));
            await tester.tap(find.text('Como seus amigos veem'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(_switch('Atividades recentes'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });

  testWidgets('the consent dialog fits 320 px at 3x', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rig = _rigWith({});
    await _open(tester, _app(rig, width: 320, textScale: 3));
    await tester.tap(_switch('Estatísticas'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    // "Compartilhar" is reachable by scrolling the dialog, and works.
    await tester.scrollUntilVisible(
      find.text('Compartilhar'),
      200,
      scrollable: find
          .descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable))
          .first,
    );
    await tester.tap(find.text('Compartilhar'));
    await tester.pumpAndSettle();
    expect(rig.shared.toggles, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('PrivacySummary tells what friends see and that turning off deletes', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: SharingRig().overrides(),
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: PrivacySummary())),
        ),
      ),
    );
    expect(
      find.textContaining(
        'Por padrão, quem vira seu amigo vê só o seu cartão (apelido e foto). Em "O que seus '
        'amigos veem", no perfil, você escolhe, por seção, mostrar também a amigos mútuos suas '
        'estatísticas (números totais, deste mês e deste ano, tempo assistido e desde quando está '
        'no CineTrack), suas atividades recentes (títulos que favoritou, assistiu ou concluiu, só a '
        'partir de quando ligar) e seus recomendados (até 50 títulos que marcou com Recomendo, na '
        'ordem da sua aba, que segue o que você assistiu ou favoritou por último, e quantos são); '
        'para isso guardamos uma cópia só do que você ligou, e desligar apaga na hora.',
      ),
      findsOneWidget,
    );
  });
}
