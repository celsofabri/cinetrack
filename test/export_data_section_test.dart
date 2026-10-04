import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/export_data_source.dart';
import 'package:cinetrack/export/file_saver.dart';
import 'package:cinetrack/providers/export_providers.dart';
import 'package:cinetrack/screens/profile_screen.dart';
import 'package:cinetrack/widgets/export_data_section.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_export_data_source.dart';
import 'support/in_memory_favorites_data_source.dart';

class _FakeSaver implements ExportFileSaver {
  _FakeSaver({this.supported = true});

  final bool supported;
  bool fail = false;
  final saved = <({String name, Uint8List bytes})>[];

  @override
  bool get isSupported => supported;

  @override
  Future<void> save({required String fileName, required Uint8List bytes}) async {
    if (fail) throw StateError('blocked');
    saved.add((name: fileName, bytes: bytes));
  }

  Map<String, dynamic> get lastJson => jsonDecode(utf8.decode(saved.last.bytes));
}

class _Rig {
  final cloud = FakeCloud();
  final auth = FakeAuthRepository(initialUser: kAna);
  final saver = _FakeSaver();
  final sources = <String, FakeExportDataSource>{};

  _Rig() {
    sources['uid-ana'] = FakeExportDataSource(
      {
        '1-movie': fakeMovieDoc(1, watched: true),
        '1396-tv': fakeSeriesDoc(1396, extra: {'recommended': true}),
      },
      profile: {'displayName': 'Ana'},
    );
    sources['uid-bruno'] = FakeExportDataSource({'2-movie': fakeMovieDoc(2)});
  }

  FakeExportDataSource get ana => sources['uid-ana']!;

  Widget app({_FakeSaver? saverOverride}) => ProviderScope(
    overrides: [
      ...cloudOverrides(auth: auth, cloud: cloud),
      exportDataSourceFactoryProvider.overrideWithValue((uid) => sources[uid]!),
      exportFileSaverProvider.overrideWithValue(saverOverride ?? saver),
      exportClockProvider.overrideWithValue(() => DateTime(2026, 10, 3, 9)),
    ],
    child: const MaterialApp(home: ProfileScreen()),
  );
}

Future<void> _open(WidgetTester tester, _Rig rig, {double width = 800}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(rig.app());
  await tester.pumpAndSettle();
}

final _button = find.widgetWithText(FilledButton, 'Exportar meus dados (JSON)');

Future<void> _confirm(WidgetTester tester) async {
  await tester.scrollUntilVisible(_button, 200, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(_button);
  await tester.pumpAndSettle();
  await tester.tap(_button);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Exportar'));
  // Dialog exit animation (pumpAndSettle cannot be used while a spinner runs).
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('button and confirmation', () {
    testWidgets('own section with a safe, accessible button (>= 48 px)', (tester) async {
      final rig = _Rig();
      await _open(tester, rig);

      expect(find.text('Seus dados'), findsOneWidget);
      expect(_button, findsOneWidget);
      expect(tester.getSize(_button).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSemantics(_button),
        isSemantics(label: 'Exportar meus dados (JSON)', isButton: true, isEnabled: true),
      );
      // Before "Excluir minha conta e dados" (export first, then delete).
      expect(
        tester.getTopLeft(_button).dy,
        lessThan(tester.getTopLeft(find.text('Excluir minha conta e dados')).dy),
      );
      expect(rig.ana.calls, isEmpty, reason: 'nothing is read until the user confirms');
    });

    testWidgets('signed out: no export button', (tester) async {
      final rig = _Rig();
      rig.auth.revokeSession();
      await _open(tester, rig);
      expect(_button, findsNothing);
    });

    testWidgets('the dialog warns about personal data, focus starts on Cancelar', (tester) async {
      final rig = _Rig();
      await _open(tester, rig);
      await tester.tap(_button);
      await tester.pumpAndSettle();

      expect(find.textContaining('guarde em lugar seguro'), findsOneWidget);
      expect(find.textContaining('Nada é enviado a terceiros'), findsOneWidget);
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancelar')).autofocus,
        isTrue,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pumpAndSettle();
      expect(rig.ana.calls, isEmpty);
      expect(rig.saver.saved, isEmpty);
    });
  });

  group('success', () {
    testWidgets('reads from the server, delivers one correctly named file, shows the result', (
      tester,
    ) async {
      final rig = _Rig();
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();

      expect(rig.saver.saved, hasLength(1));
      expect(rig.saver.saved.single.name, 'cinetrack-export-2026-10-03.json');
      final json = rig.saver.lastJson;
      expect(json['counts']['documents'], 2);
      expect(json['profile']['displayName'], 'Ana');
      expect(json['source'], 'server');
      final recommended = (json['favorites'] as List).firstWhere((e) => e['key'] == '1396-tv');
      expect(recommended['data']['recommended'], isTrue);
      expect(rig.ana.calls.every((c) => c.fromServer), isTrue);

      expect(
        find.textContaining('2 itens no arquivo cinetrack-export-2026-10-03.json'),
        findsOneWidget,
      );
      expect(find.textContaining('guarde o arquivo em lugar seguro'), findsOneWidget);
      expect(find.textContaining('pode estar incompleto'), findsNothing);
      expect(_button, findsOneWidget);
      expect(tester.widget<FilledButton>(_button).onPressed, isNotNull);

      await tester.tap(find.text('Fechar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no arquivo'), findsNothing);
    });

    testWidgets('an account with no favorites exports an explicit empty file', (tester) async {
      final rig = _Rig();
      rig.ana.docs.clear();
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();

      expect(rig.saver.lastJson['favorites'], isEmpty);
      expect(rig.saver.lastJson['complete'], isTrue);
      expect(find.textContaining('0 itens no arquivo'), findsOneWidget);
    });

    testWidgets('corrupt documents are reported to the user and kept in the file', (tester) async {
      final rig = _Rig();
      rig.ana.docs['zzz'] = {'foo': 1};
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();

      expect(rig.saver.lastJson['favorites'], hasLength(3));
      expect(find.textContaining('1 item não puderam ser interpretados'), findsOneWidget);
    });
  });

  group('progress', () {
    testWidgets('shows loading, blocks a second run, can be cancelled without delivering', (
      tester,
    ) async {
      final rig = _Rig();
      rig.ana.gate = Completer<void>();
      await _open(tester, rig);
      await _confirm(tester);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('Lendo seus dados'), findsOneWidget);
      expect(tester.widget<FilledButton>(_button).onPressed, isNull);

      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pumpAndSettle();
      rig.ana.gate!.complete();
      await tester.pumpAndSettle();

      expect(rig.saver.saved, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(_button).onPressed, isNotNull);
    });

    testWidgets('a big account shows the running count page by page', (tester) async {
      final rig = _Rig();
      rig.sources['uid-ana'] = FakeExportDataSource({
        for (var i = 0; i < 1000; i++) '${100000 + i}-movie': fakeMovieDoc(100000 + i),
      });
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();

      expect(rig.saver.lastJson['counts']['documents'], 1000);
      expect(rig.sources['uid-ana']!.calls.length, 4);
      expect(find.textContaining('1000 itens no arquivo'), findsOneWidget);
    });
  });

  group('errors and offline', () {
    testWidgets('a rejected read shows an error, writes nothing and can be retried', (
      tester,
    ) async {
      final rig = _Rig();
      rig.ana.serverFailure = const ExportReadException(
        ExportReadFailureKind.denied,
        code: 'permission-denied',
      );
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('O servidor recusou a leitura'), findsOneWidget);
      expect(rig.saver.saved, isEmpty);

      rig.ana.serverFailure = null;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(rig.saver.saved, hasLength(1));
      expect(find.textContaining('O servidor recusou'), findsNothing);
    });

    testWidgets('unexpected error is generic and says the data is intact', (tester) async {
      final rig = _Rig();
      rig.ana.serverFailure = const ExportReadException(ExportReadFailureKind.unknown);
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('continuam intactos'), findsOneWidget);
    });

    testWidgets('offline: asks before using device data, then exports it flagged incomplete', (
      tester,
    ) async {
      final rig = _Rig();
      rig.ana.serverFailure = const ExportReadException(ExportReadFailureKind.unreachable);
      rig.ana.deviceDocs = {'1-movie': fakeMovieDoc(1)};
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('pode estar incompleto'), findsOneWidget);
      expect(rig.saver.saved, isEmpty, reason: 'nothing delivered before the user chooses');
      expect(tester.widget<FilledButton>(_button).onPressed, isNull);

      await tester.tap(find.text('Exportar dados deste aparelho'));
      await tester.pumpAndSettle();

      expect(rig.saver.saved, hasLength(1));
      expect(rig.saver.lastJson['source'], 'device-cache');
      expect(rig.saver.lastJson['complete'], isFalse);
      expect(rig.saver.lastJson['counts']['documents'], 1);
      expect(
        find.textContaining('Este arquivo usa os dados guardados neste aparelho'),
        findsOneWidget,
      );
    });

    testWidgets('offline: "Tentar de novo" goes back to the server', (tester) async {
      final rig = _Rig();
      rig.ana.serverFailure = const ExportReadException(ExportReadFailureKind.unreachable);
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();

      rig.ana.serverFailure = null;
      await tester.tap(find.text('Tentar de novo'));
      await tester.pumpAndSettle();

      expect(rig.saver.lastJson['source'], 'server');
      expect(rig.saver.lastJson['complete'], isTrue);
    });

    testWidgets('offline with nothing on the device: no file, never an empty "complete" one', (
      tester,
    ) async {
      final rig = _Rig();
      rig.ana.serverFailure = const ExportReadException(ExportReadFailureKind.unreachable);
      rig.ana.deviceDocs = {};
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exportar dados deste aparelho'));
      await tester.pumpAndSettle();

      expect(rig.saver.saved, isEmpty);
      expect(find.textContaining('Não há dados guardados neste aparelho'), findsOneWidget);
    });

    testWidgets('offline: Cancelar returns to the start', (tester) async {
      final rig = _Rig();
      rig.ana.serverFailure = const ExportReadException(ExportReadFailureKind.unreachable);
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pumpAndSettle();

      expect(find.textContaining('pode estar incompleto'), findsNothing);
      expect(tester.widget<FilledButton>(_button).onPressed, isNotNull);
    });

    testWidgets('download blocked by the browser is an error, data intact', (tester) async {
      final rig = _Rig()..saver.fail = true;
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível baixar o arquivo'), findsOneWidget);
    });
  });

  group('account switch', () {
    testWidgets('switching account during the read discards the result', (tester) async {
      final rig = _Rig();
      rig.ana.gate = Completer<void>();
      await _open(tester, rig);
      await _confirm(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      rig.auth.switchSessionTo(kBruno);
      await tester.pump();
      rig.ana.gate!.complete();
      await tester.pumpAndSettle();

      expect(rig.saver.saved, isEmpty, reason: 'Ana\'s data must never be delivered to Bruno');
      expect(find.textContaining('no arquivo'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(rig.sources['uid-bruno']!.calls, isEmpty);
    });

    testWidgets('the new account starts from a clean state and exports its own data', (
      tester,
    ) async {
      final rig = _Rig();
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('no arquivo'), findsOneWidget);

      rig.auth.switchSessionTo(kBruno);
      await tester.pumpAndSettle();
      expect(find.textContaining('no arquivo'), findsNothing, reason: 'no stale result');

      await _confirm(tester);
      await tester.pumpAndSettle();
      expect(rig.saver.saved, hasLength(2));
      expect(rig.saver.lastJson['counts']['documents'], 1);
      expect((rig.saver.lastJson['favorites'] as List).single['key'], '2-movie');
    });

    testWidgets('switching right at the last page also discards the result', (tester) async {
      final rig = _Rig();
      rig.ana.onPage = (_) => rig.auth.switchSessionTo(kBruno);
      await _open(tester, rig);
      await _confirm(tester);
      await tester.pumpAndSettle();
      expect(rig.saver.saved, isEmpty);
    });
  });

  group('unsupported platform', () {
    testWidgets('explains instead of offering a button that cannot work', (tester) async {
      final rig = _Rig();
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(rig.app(saverOverride: _FakeSaver(supported: false)));
      await tester.pumpAndSettle();

      expect(_button, findsNothing);
      expect(find.textContaining('disponível na versão web'), findsOneWidget);
    });
  });

  group('layout', () {
    for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
      testWidgets('no overflow at ${width.toInt()} px in every state (2x text at 320)', (
        tester,
      ) async {
        final rig = _Rig();
        tester.view.physicalSize = Size(width, 2600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...cloudOverrides(auth: rig.auth, cloud: rig.cloud),
              exportDataSourceFactoryProvider.overrideWithValue((uid) => rig.sources[uid]!),
              exportFileSaverProvider.overrideWithValue(rig.saver),
              exportClockProvider.overrideWithValue(() => DateTime(2026, 10, 3)),
            ],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(width == 320 ? 2 : 1)),
                child: child!,
              ),
              home: const ProfileScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // offline choice card (the widest set of actions)
        rig.ana.serverFailure = const ExportReadException(ExportReadFailureKind.unreachable);
        await _confirm(tester);
        await tester.pumpAndSettle();
        expect(find.text('Exportar dados deste aparelho', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);

        // success with notes
        rig.ana.deviceDocs = {
          'zzz': {'foo': 1},
        };
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -2500));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Exportar dados deste aparelho'));
        await tester.pumpAndSettle();
        expect(find.textContaining('no arquivo', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);

        // error
        rig.saver.fail = true;
        rig.ana.serverFailure = null;
        await _confirm(tester);
        await tester.pumpAndSettle();
        expect(find.textContaining('Não foi possível baixar', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('touch targets, 3x text and dark theme', () {
    for (final dark in [false, true]) {
      for (final (width, scale) in [(320.0, 3.0), (1024.0, 1.0)]) {
        testWidgets('${dark ? 'dark' : 'light'} ${width.toInt()} px x$scale: buttons >= 48 px, '
            'no overflow, in loading/offline/success/error', (tester) async {
          final rig = _Rig();
          tester.view.physicalSize = Size(width, 6000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                ...cloudOverrides(auth: rig.auth, cloud: rig.cloud),
                exportDataSourceFactoryProvider.overrideWithValue((uid) => rig.sources[uid]!),
                exportFileSaverProvider.overrideWithValue(rig.saver),
                exportClockProvider.overrideWithValue(() => DateTime(2026, 10, 3)),
              ],
              child: MaterialApp(
                // Desktop platform: no automatic 48 px tap-target padding.
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                  platform: TargetPlatform.macOS,
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const Scaffold(
                  body: SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: ExportDataSection(),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          void expectTargets() {
            expect(tester.takeException(), isNull);
            final buttons = find.descendant(
              of: find.byType(Card),
              matching: find.byWidgetPredicate(
                (w) => w is TextButton || w is FilledButton || w is OutlinedButton,
              ),
            );
            for (final b in [...buttons.evaluate(), ...find.byType(FilledButton).evaluate()]) {
              final size = tester.getSize(find.byElementPredicate((e) => e == b));
              expect(size.height, greaterThanOrEqualTo(48), reason: '${b.widget}');
            }
          }

          // loading
          rig.ana.gate = Completer<void>();
          await _confirm(tester);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          final cancel = find.widgetWithText(TextButton, 'Cancelar');
          expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
          expect(tester.getSize(cancel).width, greaterThanOrEqualTo(48));
          expect(tester.takeException(), isNull);
          await tester.tap(cancel);
          await tester.pumpAndSettle();
          rig.ana.gate!.complete();
          rig.ana.gate = null;

          // offline
          rig.ana.serverFailure = const ExportReadException(ExportReadFailureKind.unreachable);
          await _confirm(tester);
          await tester.pumpAndSettle();
          expectTargets();
          await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
          await tester.pumpAndSettle();

          // success
          rig.ana.serverFailure = null;
          await _confirm(tester);
          await tester.pumpAndSettle();
          expect(find.textContaining('no arquivo', skipOffstage: false), findsOneWidget);
          expectTargets();

          // error
          rig.saver.fail = true;
          await _confirm(tester);
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Não foi possível baixar', skipOffstage: false),
            findsOneWidget,
          );
          expectTargets();
        });
      }
    }
  });
}
