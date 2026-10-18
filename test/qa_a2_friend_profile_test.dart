// QA extra (hotfix A2, docs/92 rodada 2): the WHOLE friend profile with a manipulated
// document. Runs on the VM and with --platform chrome (CI).
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_shared_profile_cloud.dart';
import 'support/friends_harness.dart';

final kNow = DateTime.utc(2026, 10, 15, 15);
const kBruno = 'uid-bruno';
final inf = double.parse('Infinity');
final huge = double.parse('1e300');

Map<String, Object?> period(String key, Object? v) => {
  'key': key,
  for (final m in [
    'watchedMovies',
    'watchedEpisodes',
    'watchedSeries',
    'completedSeries',
    'minutes',
  ])
    m: v,
  'estimated': 0,
  'unknown': 0,
};

Map<String, dynamic> doc({required bool bad}) => {
  'v': 1,
  'calc': 1,
  'updatedAt': kNow.subtract(const Duration(hours: 2)),
  'tz': bad ? inf : -180,
  'sharing': {'stats': true, 'activity': true, 'recs': true},
  'actSince': DateTime.utc(2026, 10, 1),
  'stats': {
    'total': bad
        ? {
            'favorites': inf,
            'movies': huge,
            'series': double.parse('3.5'),
            'watchedMovies': -1,
            'watchedEpisodes': 1000001,
            'watchedSeries': inf,
            'completedSeries': huge,
            'minutes': inf,
            'estimated': 0,
            'unknown': 0,
          }
        : {
            'favorites': 54,
            'movies': 20,
            'series': 34,
            'watchedMovies': 12,
            'watchedEpisodes': 300,
            'watchedSeries': 10,
            'completedSeries': 3,
            'minutes': 20000,
            'estimated': 0,
            'unknown': 0,
          },
    'year': period('2026', bad ? huge : 40),
    'month': period('2026-10', bad ? inf : 12),
    'undatedMovies': bad ? inf : 2,
    'undatedEpisodes': bad ? huge : 3,
    'datedFrom': DateTime.utc(2026, 10, 11, 22, 10),
    'memberSince': DateTime.utc(2025, 3, 2, 10),
  },
  'activity': [
    {
      'type': 'watched_movie',
      'id': bad ? inf : 100,
      'mediaType': 'movie',
      'title': 'Absurdo A',
      'at': kNow.subtract(const Duration(hours: 1)),
    },
    {
      'type': 'watched_movie',
      'id': bad ? huge : 101,
      'mediaType': 'movie',
      'title': 'Absurdo B',
      'at': kNow.subtract(const Duration(hours: 2)),
    },
    {
      'type': 'watched_episodes',
      'id': 200,
      'mediaType': 'tv',
      'title': 'Serie',
      'at': kNow.subtract(const Duration(hours: 3)),
      'count': bad ? inf : 2,
      'season': bad ? huge : 1,
      'episode': bad ? double.parse('2.5') : 3,
    },
  ],
  'recs': {
    'count': bad ? inf : 3,
    'items': [
      {'id': bad ? inf : 7, 'mediaType': 'tv', 'title': 'Rec Absurda'},
      {'id': bad ? 1000000000 : 8, 'mediaType': 'movie', 'title': 'Rec Acima'},
      {'id': 9, 'mediaType': 'movie', 'title': 'Rec Boa'},
    ],
  },
};

Future<void> open(WidgetTester tester, Map<String, dynamic> d) async {
  final shared = FakeSharedProfileCloud()..docs[kBruno] = d;
  final app = await pumpFriends(
    tester,
    size: const Size(390, 3000),
    shared: shared,
    seed: (social) => social.seedFriendship('uid-ana', kBruno, aName: 'Ana', bName: 'Bruno'),
    extraOverrides: [sharedProfileClockProvider.overrideWithValue(() => kNow)],
  );
  app.router.go('/friends/u/$kBruno');
  await tester.pumpAndSettle();
}

List<String> texts(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

void main() {
  testWidgets('QA: manipulated friend document, whole profile renders', (tester) async {
    await open(tester, doc(bad: true));
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    final all = texts(tester);
    expect(
      all.where((t) => t.contains('Infinity') || t.contains('e+') || t.contains('NaN')),
      isEmpty,
    );
    expect(find.text('Tempo assistido: —'), findsNWidgets(3));
    expect(find.text('Absurdo A'), findsNothing);
    expect(find.textContaining('Absurdo'), findsNothing);
    expect(find.textContaining('Serie'), findsOneWidget);
    // count/season/episode refused: no "T0E0" (docs/92 rodada 2).
    expect(find.text('Assistiu um episódio de Serie'), findsOneWidget);
    expect(find.textContaining('T0E0'), findsNothing);
    expect(find.text('Recomendações: —'), findsOneWidget);
    expect(find.text('Rec Absurda'), findsNothing);
    expect(find.text('Rec Acima'), findsNothing);
    expect(find.text('Rec Boa'), findsOneWidget);
    expect(find.textContaining('e mais'), findsNothing);
    expect(find.textContaining('contam só no total'), findsNothing);
  });

  testWidgets('QA: normal friend document unchanged', (tester) async {
    await open(tester, doc(bad: false));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Absurdo A'), findsOneWidget);
    expect(find.text('Recomendações: 3'), findsOneWidget);
    expect(find.text('Rec Absurda'), findsOneWidget);
    expect(find.textContaining('Assistiu 2 episódios de Serie'), findsOneWidget);
  });
}
