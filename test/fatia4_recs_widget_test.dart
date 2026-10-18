import 'dart:io';

import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/widgets/poster_image.dart';
import 'package:cinetrack/widgets/shared_profile_widgets.dart';
import 'package:cinetrack/widgets/sharing_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/fake_shared_profile_cloud.dart';
import 'support/friends_harness.dart';
import 'support/sharing_rig.dart';

/// Fatia 4 — Recomendados on screen: the toggle, its consent dialog and
/// preview on Meu perfil, the preview "Como seus amigos veem", and the
/// section "Recomendados" of a friend's profile (docs/81 RF-R1, RF-F5,
/// RF-F9, cenários "Recomendados"; docs/82 §5.4; docs/83 Fatia 4).

// ---------------------------------------------------------------- owner ---

FavoriteDoc _rec(int id, {bool rec = true, MediaType type = MediaType.movie, String? title}) =>
    FavoriteDoc(
      id: id,
      mediaType: type,
      title: title ?? 'Título $id',
      posterPath: null,
      overview: '',
      addedAt: DateTime.utc(2026, 1, 1).add(Duration(hours: id)),
      recommended: rec,
    );

SharingRig _owner(int recommended, {Set<SharedSection> shared = const {}, int others = 2}) {
  final rig = SharingRig();
  for (var i = 1; i <= recommended; i++) {
    rig.seed(_rec(i, type: i.isEven ? MediaType.tv : MediaType.movie));
  }
  for (var i = 0; i < others; i++) {
    rig.seed(_rec(900 + i, rec: false));
  }
  if (shared.isNotEmpty) rig.seedShared(shared);
  return rig;
}

Widget _ownerApp(SharingRig rig, {double width = 800, double textScale = 1}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: SingleChildScrollView(
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
      child: MaterialApp.router(routerConfig: router),
    ),
  );
}

Future<void> _open(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Finder _switch(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(SwitchListTile));

Finder _inDialog(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

List<String> _titles(Finder scope) => [
  for (final t
      in find
          .descendant(of: scope, matching: find.byType(SharedRecTile))
          .evaluate()
          .map((e) => e.widget as SharedRecTile))
    t.item.title,
];

// --------------------------------------------------------------- friend ---

final kNow = DateTime.utc(2026, 10, 15, 15);
const kBruno = 'uid-bruno';

/// The top route (a push does not change the address bar in go_router 14).
String here(FriendsApp app) => app.router.state.uri.path;

Map<String, Object?> recItem(int i, {String? title, Object? poster}) => {
  'id': 500 + i,
  'mediaType': i.isEven ? 'tv' : 'movie',
  'title': title ?? 'Rec $i',
  'poster': ?poster,
};

Map<String, Object?> recsOf(int listed, {int? count}) => {
  'count': count ?? listed,
  'items': [for (var i = 0; i < listed; i++) recItem(i)],
};

Map<String, dynamic> brunoDoc({Object? recs, bool activity = true, bool stats = false}) => {
  'v': 1,
  'calc': 1,
  'updatedAt': kNow.subtract(const Duration(hours: 2)),
  'tz': -180,
  'sharing': {'activity': ?(activity ? true : null), 'recs': ?(recs != null ? true : null)},
  if (activity) 'actSince': DateTime.utc(2026, 10, 1),
  if (activity)
    'activity': [
      for (var i = 0; i < 3; i++)
        {
          'type': 'watched_movie',
          'id': 100 + i,
          'mediaType': 'movie',
          'title': 'Filme $i',
          'at': kNow.subtract(Duration(hours: i + 1)),
        },
    ],
  'recs': ?recs,
};

Future<FriendsApp> _friend(
  WidgetTester tester,
  Map<String, dynamic> doc, {
  Size size = const Size(390, 3000),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final shared = FakeSharedProfileCloud()..docs[kBruno] = doc;
  final app = await pumpFriends(
    tester,
    size: size,
    textScale: textScale,
    brightness: brightness,
    shared: shared,
    seed: (social) => social.seedFriendship('uid-ana', kBruno, aName: 'Ana', bName: 'Bruno'),
    extraOverrides: [sharedProfileClockProvider.overrideWithValue(() => kNow)],
  );
  app.router.go('/friends/u/$kBruno');
  await tester.pumpAndSettle();
  return app;
}

void main() {
  group('Meu perfil: toggle, consent and preview', () {
    test('the consent text of "Recomendados" is the docs/81 literal', () {
      final spec = File('docs/81-especificacao-perfil-social.md').readAsLinesSync();
      final line = spec.firstWhere((l) => l.startsWith('| Recomendados | "'));
      final quoted = RegExp(r'"([^"]*)"').allMatches(line).map((m) => m.group(1)!).toList();
      expect(kSharingDialogs[SharedSection.recs]!.title, quoted[0]);
      expect(kSharingDialogs[SharedSection.recs]!.body, quoted[1]);
      expect(quoted[0], 'Compartilhar seus recomendados com amigos?');
    });

    testWidgets('dialog: literal texts, preview = number + titles in the order of the tab; '
        'Cancelar writes nothing; Compartilhar = 1 transaction', (tester) async {
      final rig = _owner(3);
      await _open(tester, _ownerApp(rig));
      await tester.tap(_switch('Recomendados'));
      await tester.pumpAndSettle();
      expect(find.text('Compartilhar seus recomendados com amigos?'), findsOneWidget);
      expect(find.text(kSharingDialogs[SharedSection.recs]!.body), findsOneWidget);
      expect(_inDialog(find.text('Recomendações: 3')), findsOneWidget);
      expect(_titles(find.byType(AlertDialog)), ['Título 3', 'Título 2', 'Título 1']);
      expect(_inDialog(find.textContaining('e mais')), findsNothing);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(rig.shared.toggles, isEmpty);
      expect(tester.widget<SwitchListTile>(_switch('Recomendados')).value, isFalse);

      await tester.tap(_switch('Recomendados'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compartilhar'));
      await tester.pumpAndSettle();
      expect(rig.shared.toggles, hasLength(1));
      expect(tester.widget<SwitchListTile>(_switch('Recomendados')).value, isTrue);
      expect((rig.doc!['recs'] as Map)['count'], 3);
    });

    testWidgets('dialog with 51 recommended: 50 titles and "e mais 1"; with 50: no "e mais"', (
      tester,
    ) async {
      for (final n in [51, 50]) {
        final rig = _owner(n);
        await _open(tester, _ownerApp(rig));
        await tester.tap(_switch('Recomendados'));
        await tester.pumpAndSettle();
        expect(_inDialog(find.text('Recomendações: $n')), findsOneWidget, reason: '$n');
        expect(_titles(find.byType(AlertDialog)), hasLength(50), reason: '$n');
        expect(
          _inDialog(find.text('e mais 1')),
          n == 51 ? findsOneWidget : findsNothing,
          reason: '$n',
        );
        expect(_inDialog(find.textContaining('e mais')), n == 51 ? findsOneWidget : findsNothing);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('nothing recommended yet: "Recomendações: 0" and the empty line; can share', (
      tester,
    ) async {
      final rig = _owner(0);
      await _open(tester, _ownerApp(rig));
      await tester.tap(_switch('Recomendados'));
      await tester.pumpAndSettle();
      expect(_inDialog(find.text('Recomendações: 0')), findsOneWidget);
      expect(
        _inDialog(find.text('Você ainda não marcou nenhum título com Recomendo.')),
        findsOneWidget,
      );
      await tester.tap(find.text('Compartilhar'));
      await tester.pumpAndSettle();
      expect(rig.doc!['recs'], {'count': 0, 'items': <Object?>[]});
    });

    testWidgets('"Como seus amigos veem" with only Recomendados on shows the written list', (
      tester,
    ) async {
      final rig = _owner(2, shared: {SharedSection.recs});
      await _open(tester, _ownerApp(rig));
      expect(find.text('Recomendações: 2'), findsNothing, reason: 'collapsed by default');
      await tester.tap(find.text('Como seus amigos veem'));
      await tester.pumpAndSettle();
      expect(find.text('Recomendações: 2'), findsOneWidget);
      expect(_titles(find.byType(SharingSection)), ['Título 2', 'Título 1']);
      expect(find.text('No total'), findsNothing, reason: 'statistics are not shared');
      // Opens the title, as for friends.
      await tester.tap(find.text('Título 2'));
      await tester.pumpAndSettle();
      expect(find.text('tv 2'), findsOneWidget);
    });

    testWidgets('preview with statistics AND recommended: both', (tester) async {
      final rig = _owner(2, shared: {SharedSection.stats, SharedSection.recs});
      await _open(tester, _ownerApp(rig));
      await tester.tap(find.text('Como seus amigos veem'));
      await tester.pumpAndSettle();
      expect(find.text('No total'), findsOneWidget);
      expect(find.text('Recomendações: 2'), findsOneWidget);
    });

    testWidgets('turning off: no confirmation, the message, the preview loses the list', (
      tester,
    ) async {
      final rig = _owner(2, shared: {SharedSection.stats, SharedSection.recs});
      await _open(tester, _ownerApp(rig));
      await tester.tap(find.text('Como seus amigos veem'));
      await tester.pumpAndSettle();
      expect(find.text('Recomendações: 2'), findsOneWidget);
      await tester.tap(_switch('Recomendados'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Seus amigos não veem mais seus recomendados.'), findsOneWidget);
      expect(find.text('Recomendações: 2'), findsNothing);
      expect(find.text('No total'), findsOneWidget);
      expect(rig.doc!.containsKey('recs'), isFalse);
      expect(tester.widget<SwitchListTile>(_switch('Recomendados')).value, isFalse);
    });

    for (final scale in [1.0, 3.0]) {
      testWidgets('320 px ${scale}x: the 51-title dialog fits, scrolls and shares', (tester) async {
        final rig = _owner(51);
        await _open(tester, _ownerApp(rig, width: 320, textScale: scale));
        await tester.tap(_switch('Recomendados'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          _inDialog(find.text('e mais 1')),
          300,
          scrollable: _inDialog(find.byType(Scrollable)).first,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Compartilhar'));
        await tester.pumpAndSettle();
        expect(rig.shared.toggles, hasLength(1));
      });
    }
  });

  group('friend profile: "Recomendados"', () {
    testWidgets('shared: "Recomendações: N", titles in order, kind, tap opens the title', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final app = await _friend(tester, brunoDoc(recs: recsOf(3)));
      expect(find.text('Recomendados'), findsOneWidget);
      expect(find.text('Recomendações: 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Recomendações: 3'), findsOneWidget);
      expect(_titles(find.byType(Scaffold).first), ['Rec 0', 'Rec 1', 'Rec 2']);
      expect(find.text('Série'), findsNWidgets(2));
      expect(find.text('Filme'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Rec 1, filme')), findsOneWidget);
      expect(find.textContaining('e mais'), findsNothing);
      expect(find.textContaining('não compartilha recomendados'), findsNothing);
      await tester.tap(find.text('Rec 1'));
      await tester.pumpAndSettle();
      expect(here(app), '/movie/501');
      semantics.dispose();
    });

    testWidgets('a series opens /tv/<id>', (tester) async {
      final app = await _friend(tester, brunoDoc(recs: recsOf(1)));
      await tester.tap(find.text('Rec 0'));
      await tester.pumpAndSettle();
      expect(here(app), '/tv/500');
    });

    for (final (count, footer) in [(50, null), (51, 'e mais 1'), (75, 'e mais 25')]) {
      testWidgets('count $count with 50 listed: 50 titles, ${footer ?? 'no "e mais"'}', (
        tester,
      ) async {
        await _friend(
          tester,
          brunoDoc(recs: recsOf(50, count: count)),
          size: const Size(390, 9000),
        );
        expect(find.byType(SharedRecTile), findsNWidgets(50));
        expect(find.text('Recomendações: $count'), findsOneWidget);
        if (footer == null) {
          expect(find.textContaining('e mais'), findsNothing);
        } else {
          expect(find.text(footer), findsOneWidget);
        }
      });
    }

    testWidgets('absent: "Bruno não compartilha recomendados com amigos.", no number', (
      tester,
    ) async {
      await _friend(tester, brunoDoc());
      expect(find.text('Bruno não compartilha recomendados com amigos.'), findsOneWidget);
      expect(find.textContaining('Recomendações:'), findsNothing);
      expect(find.byType(SharedRecTile), findsNothing);
    });

    testWidgets('only Recomendados shared: both other "não compartilha" phrases + the list', (
      tester,
    ) async {
      await _friend(tester, brunoDoc(recs: recsOf(2), activity: false));
      expect(find.text('Bruno não compartilha estatísticas com amigos.'), findsOneWidget);
      expect(find.text('Bruno não compartilha atividades com amigos.'), findsOneWidget);
      expect(find.text('Recomendações: 2'), findsOneWidget);
      expect(find.textContaining('No CineTrack desde'), findsNothing);
    });

    testWidgets('shared with none: "Recomendações: 0" and "ainda não tem recomendados"', (
      tester,
    ) async {
      await _friend(tester, brunoDoc(recs: recsOf(0)));
      expect(find.text('Recomendações: 0'), findsOneWidget);
      expect(find.text('Bruno ainda não tem recomendados.'), findsOneWidget);
    });

    testWidgets('tolerant: unknown count = "—", malformed items ignored, bad poster = icon', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _friend(
        tester,
        brunoDoc(
          recs: {
            'items': [
              recItem(1, poster: '/ok.jpg'),
              {'id': 'x', 'mediaType': 'movie', 'title': 'Quebrado'},
              recItem(2, poster: 'javascript:alert(1)'),
              {'id': 9, 'mediaType': 'podcast', 'title': 'Tipo novo'},
              {...recItem(3), 'rating': 4},
            ],
            'newField': true,
          },
        ),
      );
      expect(find.text('Recomendações: —'), findsOneWidget);
      expect(find.bySemanticsLabel('Recomendações: sem informação'), findsOneWidget);
      expect(_titles(find.byType(Scaffold).first), ['Rec 1', 'Rec 2', 'Rec 3']);
      expect(find.text('Quebrado'), findsNothing);
      expect(find.text('Tipo novo'), findsNothing);
      expect(find.textContaining('e mais'), findsNothing);
      final posters = tester.widgetList<PosterImage>(
        find.descendant(of: find.byType(SharedRecTile), matching: find.byType(PosterImage)),
      );
      expect([for (final p in posters) p.posterPath], ['/ok.jpg', null, null]);
      expect(
        [for (final p in posters) p.placeholderIcon],
        [Icons.movie_outlined, Icons.live_tv_outlined, Icons.movie_outlined],
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('title without poster and a 300-character title: ellipsis, full title read', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final long = 'L' * 300;
      await _friend(
        tester,
        brunoDoc(
          recs: {
            'count': 1,
            'items': [recItem(1, title: long)],
          },
        ),
        size: const Size(320, 3000),
      );
      final text = tester.widget<Text>(find.text(long));
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(find.bySemanticsLabel('$long, filme'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('focus: Voltar → Atualizar → each activity → each recommended → Remover → '
        'Bloquear', (tester) async {
      await _friend(tester, brunoDoc(recs: recsOf(2)));
      String focused() {
        final focus = FocusManager.instance.primaryFocus?.context;
        if (focus == null) return '?';
        final texts = find.descendant(
          of: find.byElementPredicate((e) => e == focus),
          matching: find.byType(Text),
        );
        final words = [for (final t in tester.widgetList<Text>(texts)) t.data ?? ''];
        return words.isEmpty ? '?' : words.first;
      }

      final order = [focused()];
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        order.add(focused());
      }
      expect(order, [
        'Voltar',
        'Atualizar',
        'Assistiu Filme 0',
        'Assistiu Filme 1',
        'Assistiu Filme 2',
        'Rec 0',
        'Rec 1',
        'Remover amizade',
        'Bloquear',
      ]);
    });

    for (final width in [320.0, 375.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        final brightness = scale == 2.0 ? Brightness.dark : Brightness.light;
        testWidgets('layout $width px, ${scale}x, ${brightness.name}: 51 long titles fit', (
          tester,
        ) async {
          await _friend(
            tester,
            brunoDoc(
              recs: {
                'count': 51,
                'items': [
                  for (var i = 0; i < 50; i++) recItem(i, title: 'Um título bem comprido $i ' * 8),
                ],
              },
            ),
            size: Size(width, 900),
            textScale: scale,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Bloquear'), findsOneWidget);
        });
      }
    }
  });
}
