import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/widgets/app_splash.dart';

Widget _app() => const MaterialApp(
      home: AppSplash(
        hold: Duration(milliseconds: 500),
        fade: Duration(milliseconds: 400),
        child: Scaffold(body: Center(child: Text('Home'))),
      ),
    );

double _splashOpacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

void main() {
  testWidgets(
      'shows the splash over the app at first, then fades it out '
      'and removes it', (tester) async {
    await tester.pumpWidget(_app());

    expect(find.text('Home'), findsOneWidget); // app is already built underneath
    expect(find.byType(Image), findsOneWidget);
    expect(_splashOpacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 500)); // hold elapsed
    await tester.pump(const Duration(milliseconds: 200)); // mid-fade
    expect(_splashOpacity(tester), 0); // target opacity animating to 0
    expect(find.byType(Image), findsOneWidget); // still mounted while fading

    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing); // removed after the fade
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('does not block taps on the app while fading', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: AppSplash(
        child: Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () => taps++, child: const Text('Go')),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Go'));

    expect(taps, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('keeps the splash while not ready (session unknown) and fades once ready',
      (tester) async {
    Widget app({required bool ready}) => MaterialApp(
          home: AppSplash(
            hold: const Duration(milliseconds: 100),
            fade: const Duration(milliseconds: 100),
            ready: ready,
            child: const Scaffold(body: Text('Home')),
          ),
        );

    await tester.pumpWidget(app(ready: false));
    await tester.pump(const Duration(seconds: 2)); // hold long gone
    expect(_splashOpacity(tester), 1); // still covering the app

    await tester.pumpWidget(app(ready: true));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
  });

  _splashTimeoutTests();
}

void _splashTimeoutTests() {
  testWidgets('fades anyway after maxWait if the session never becomes known', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: AppSplash(
        hold: Duration(milliseconds: 100),
        fade: Duration(milliseconds: 100),
        maxWait: Duration(seconds: 3),
        ready: false, // auth stream never emits
        child: Scaffold(body: Text('Home')),
      ),
    ));

    await tester.pump(const Duration(milliseconds: 2900));
    expect(_splashOpacity(tester), 1); // still waiting, cap not reached

    await tester.pump(const Duration(milliseconds: 200)); // cap reached
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });
}
