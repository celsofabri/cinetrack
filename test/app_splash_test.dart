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
  testWidgets('shows the splash over the app at first, then fades it out '
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
}
