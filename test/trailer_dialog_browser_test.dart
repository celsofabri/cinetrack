@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/title_video.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/widgets/trailer_dialog.dart';
import 'package:cinetrack/widgets/trailer_iframe.dart';

// docs/45 re-review: the REAL player in the REAL dialog, in Chrome. Run with
// `flutter test --platform chrome test/trailer_dialog_browser_test.dart`.

const _video = TitleVideo(key: 'dQw4w9WgXcQ', name: 'x', type: 'Trailer', official: true);
const TitleKey _key = (id: 603, type: MediaType.movie);

Future<void> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [titleTrailerProvider.overrideWith((ref, key) async => _video)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showTrailerDialog(context, titleKey: _key, title: 'Matrix'),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The engine does not mount platform views under `flutter test`, so the test
/// plays its part: it puts the real element (made by the real player) in the page.
web.HTMLIFrameElement? _attached;

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('abrir'));
  await tester.pump(); // route pushed
  await tester.pump(const Duration(milliseconds: 400)); // entered, provider resolved
  await tester.pump();
  expect(find.byType(TrailerDialog), findsOneWidget);
  expect(TrailerFrame.open.length, 1, reason: 'the real player made its iframe');
  _attached = TrailerFrame.open.single.element;
  web.document.body!.append(_attached!);
  expect(_pageFrames(), 1);
}

int _pageFrames() => web.document.querySelectorAll('iframe').length;

/// Right after the close gesture, in the MIDDLE of the exit animation: the
/// dialog is still on screen, the video must already be gone.
void _expectStopped(WidgetTester tester) {
  expect(find.byType(TrailerDialog), findsOneWidget, reason: 'still animating out');
  expect(TrailerFrame.open, isEmpty);
  expect(_pageFrames(), 0);
  expect(_attached!.src, 'about:blank');
  expect(_attached!.isConnected, isFalse);
}

void main() {
  tearDown(() {
    for (final f in TrailerFrame.open.toList()) {
      f.close();
    }
  });

  testWidgets('X stops the video at the START of the close', (tester) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.tap(find.byTooltip('Fechar trailer'));
    await tester.pump(); // pop begins
    await tester.pump(const Duration(milliseconds: 40)); // mid-animation
    _expectStopped(tester);
    await tester.pumpAndSettle();
    expect(find.byType(TrailerDialog), findsNothing);
    expect(_pageFrames(), 0);
  });

  testWidgets('Esc stops the video at the start of the close', (tester) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    _expectStopped(tester);
    await tester.pumpAndSettle();
  });

  testWidgets('a tap outside stops the video at the start of the close', (tester) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    _expectStopped(tester);
    await tester.pumpAndSettle();
  });

  testWidgets('the system back (route pop) stops it too', (tester) async {
    await _pumpHost(tester);
    await _open(tester);
    Navigator.of(tester.element(find.byType(TrailerDialog))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    _expectStopped(tester);
    await tester.pumpAndSettle();
  });

  testWidgets('open and close 3 times: nothing leaks', (tester) async {
    await _pumpHost(tester);
    for (var i = 0; i < 3; i++) {
      await _open(tester);
      await tester.tap(find.byTooltip('Fechar trailer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      _expectStopped(tester);
      await tester.pumpAndSettle();
      expect(TrailerFrame.open, isEmpty);
      expect(_pageFrames(), 0);
    }
  });

  testWidgets('safety net: the player removed without the route closing also closes', (
    tester,
  ) async {
    await _pumpHost(tester);
    await _open(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox())); // whole tree gone
    await tester.pump();
    expect(TrailerFrame.open, isEmpty);
    expect(_attached!.src, 'about:blank');
  });
}
