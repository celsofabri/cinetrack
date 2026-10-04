import 'dart:ui' show CheckedState, SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/widgets/episode_tile.dart';
import 'package:cinetrack/widgets/poster_image.dart';

// docs/45 item 2: episode layout (image, number + name, description, date,
// duration, watched state, 48 px check, future episodes disabled).

final _long = List.filled(
  14,
  'Uma descrição bem longa do episódio que não cabe em três linhas.',
).join(' ');

EpisodeCache _ep({
  int n = 3,
  String name = 'O Nome',
  DateTime? air,
  bool watched = false,
  int? runtime = 45,
  String? still = '/still.jpg',
  String overview = 'Resumo curto.',
}) => EpisodeCache(
  episodeNumber: n,
  name: name,
  airDate: air ?? DateTime(2024, 2, 1),
  watched: watched,
  runtime: runtime,
  stillPath: still,
  overview: overview,
  detailed: true,
);

Future<void> _pump(
  WidgetTester tester,
  EpisodeCache ep, {
  double width = 390,
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool busy = false,
  VoidCallback? onToggle,
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: EpisodeTile(episode: ep, busy: busy, onToggle: onToggle ?? () {}),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows image slot, "E3 · name", date and duration, description', (tester) async {
    await _pump(tester, _ep());
    expect(find.text('E3 · O Nome'), findsOneWidget);
    expect(find.text('01/02/2024 · 45 min'), findsOneWidget);
    expect(find.text('Resumo curto.'), findsOneWidget);
    final image = tester.widget<PosterImage>(find.byType(PosterImage));
    expect(image.posterPath, '/still.jpg');
    expect(image.imageSize, 'w300'); // TMDB still size, not a poster crop
    expect(image.height, closeTo(image.width * 9 / 16, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('no image and no description: placeholder keeps the same box, muted text', (
    tester,
  ) async {
    await _pump(tester, _ep(still: null, overview: '', runtime: null));
    expect(find.byIcon(Icons.tv_outlined), findsOneWidget); // placeholder, not a hole
    expect(find.text('Sem descrição disponível.'), findsOneWidget);
    expect(find.text('01/02/2024'), findsOneWidget);
    expect(find.text('Ler mais'), findsNothing);

    // Same image box with and without the still (no layout shift).
    final noImage = tester.getSize(find.byType(PosterImage));
    await _pump(tester, _ep());
    expect(tester.getSize(find.byType(PosterImage)), noImage);
  });

  testWidgets('empty name falls back to "Episódio N"', (tester) async {
    await _pump(tester, _ep(name: ''));
    expect(find.text('E3 · Episódio 3'), findsOneWidget);
  });

  testWidgets('long description: 3 lines, "Ler mais" expands, "Mostrar menos" collapses', (
    tester,
  ) async {
    await _pump(tester, _ep(overview: _long, still: null));
    final text = find.text(_long);
    final collapsed = tester.getSize(text).height;
    expect(find.text('Ler mais'), findsOneWidget);

    await tester.tap(find.text('Ler mais'));
    await tester.pump();
    expect(tester.getSize(text).height, greaterThan(collapsed));
    expect(find.text('Mostrar menos'), findsOneWidget);

    await tester.tap(find.text('Mostrar menos'));
    await tester.pump();
    expect(tester.getSize(text).height, collapsed);
  });

  testWidgets('a short description has no expand control', (tester) async {
    await _pump(tester, _ep(still: null));
    expect(find.text('Ler mais'), findsNothing);
  });

  testWidgets('watched: clear state (check + "Assistido" text), toggle callback', (tester) async {
    var toggles = 0;
    await _pump(tester, _ep(watched: true), onToggle: () => toggles++);
    expect(find.text('Assistido'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await tester.tap(find.byType(Checkbox));
    expect(toggles, 1);
    await tester.tap(find.text('E3 · O Nome')); // the whole row toggles
    expect(toggles, 2);
  });

  testWidgets('future episode is disabled, says when it premieres, and does not toggle', (
    tester,
  ) async {
    var toggles = 0;
    final future = DateTime.now().add(const Duration(days: 30));
    await _pump(tester, _ep(air: future), onToggle: () => toggles++);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
    expect(find.text('Em breve'), findsOneWidget);
    expect(find.textContaining('Estreia em'), findsOneWidget);
    await tester.tap(find.text('E3 · O Nome'));
    expect(toggles, 0);
  });

  testWidgets('busy: spinner instead of the check, no second tap', (tester) async {
    var toggles = 0;
    await _pump(tester, _ep(), busy: true, onToggle: () => toggles++);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(find.text('E3 · O Nome'));
    expect(toggles, 0);
  });

  testWidgets('semantics: check named by what it does, expand button, 48 px targets', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _ep(overview: _long, still: null));
    final check = tester.getSemantics(find.byType(Checkbox)).getSemanticsData();
    expect(check.label, 'Marcar episódio 3, O Nome, como assistido');
    expect(check.flagsCollection.isChecked, CheckedState.isFalse);
    expect(check.hasAction(SemanticsAction.tap), isTrue);
    expect(tester.getSize(find.byType(Checkbox)).height, greaterThanOrEqualTo(48));
    final more = tester.getSemantics(find.text('Ler mais')).getSemanticsData();
    expect(more.label, startsWith('Ler mais'));
    expect(
      tester.getSize(find.widgetWithText(TextButton, 'Ler mais')).height,
      greaterThanOrEqualTo(48),
    );

    await _pump(tester, _ep(watched: true));
    expect(
      tester.getSemantics(find.byType(Checkbox)).getSemanticsData().label,
      'Assistido: desmarcar episódio 3, O Nome',
    );
    handle.dispose();
  });

  testWidgets('adaptive: image beside the text on wide, above on narrow', (tester) async {
    await _pump(tester, _ep(), width: 1024);
    final wideImage = tester.getTopLeft(find.byType(PosterImage));
    final wideTitle = tester.getTopLeft(find.text('E3 · O Nome'));
    expect(wideImage.dy, lessThan(wideTitle.dy + 1)); // same band
    expect(wideImage.dx, lessThan(wideTitle.dx));

    await _pump(tester, _ep(), width: 320);
    final narrowImage = tester.getBottomLeft(find.byType(PosterImage));
    final narrowTitle = tester.getTopLeft(find.text('E3 · O Nome'));
    expect(narrowImage.dy, lessThanOrEqualTo(narrowTitle.dy)); // image is above
  });

  group('no overflow', () {
    for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 3.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('$width px, font ${scale}x, ${brightness.name}', (tester) async {
            await _pump(
              tester,
              _ep(
                name: 'Um nome de episódio realmente comprido para forçar quebra',
                overview: _long,
              ),
              width: width,
              scale: scale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('Ler mais'));
            await tester.pump();
            expect(tester.takeException(), isNull);
            await _pump(
              tester,
              _ep(watched: true, still: null, overview: ''),
              width: width,
              scale: scale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });
}
