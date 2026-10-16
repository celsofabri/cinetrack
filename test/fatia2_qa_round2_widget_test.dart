import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/sharing_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_profile_texts.dart';
import 'package:cinetrack/widgets/sharing_section.dart';

import 'support/sharing_rig.dart';

Widget _app(SharingRig rig) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: SingleChildScrollView(padding: EdgeInsets.all(16), child: SharingSection()),
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
    child: MaterialApp.router(routerConfig: router),
  );
}

Finder _switch(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(SwitchListTile));

void main() {
  // QA-9 (Q9/Q10/Q18): preview == live Perfil with NON-ZERO series, episodes and completed.
  testWidgets('QA-9 preview grid equals the live profile with series data', (tester) async {
    final rig = SharingRig();
    rig.seed(sharingMovie(1, watched: true));
    rig.seed(
      FavoriteDoc(
        id: 50,
        mediaType: MediaType.tv,
        title: 'Série X',
        posterPath: null,
        overview: '',
        addedAt: DateTime.utc(2026, 1, 1),
        watchedEpisodes: const {'1_1', '1_2'},
      ),
    );
    await rig.store.saveCatalogSeason(
      50,
      SeasonCache(
        seasonNumber: 1,
        episodes: [
          EpisodeCache(episodeNumber: 1, name: 'a', airDate: DateTime.utc(2020), watched: false),
          EpisodeCache(episodeNumber: 2, name: 'b', airDate: DateTime.utc(2020), watched: false),
        ],
      ),
    );
    await tester.pumpWidget(_app(rig));
    await tester.pumpAndSettle();
    await tester.tap(_switch('Estatísticas'));
    await tester.pumpAndSettle();
    final live = ProviderScope.containerOf(
      tester.element(find.byType(SharingSection)),
    ).read(profileStatsProvider);
    expect(live.series, 1);
    expect(live.watchedEpisodes, 2);
    expect(live.completedSeries, 1);
    final grid = find.byKey(const Key('sharing-preview-grid'));
    for (final (label, value) in [
      ('Séries favoritas', live.series),
      ('Episódios assistidos', live.watchedEpisodes),
      ('Séries concluídas', live.completedSeries),
    ]) {
      expect(
        find.descendant(of: grid, matching: find.bySemanticsLabel('$label: $value')),
        findsOneWidget,
        reason: label,
      );
    }
  });

  // QA-10 (Q13/Q14) + QA-11 (Q15): long titles, full sentence in Semantics, tv route.
  testWidgets('QA-10/11 long activity: ellipsis, full sentence in Semantics; tv opens /tv', (
    tester,
  ) async {
    final rig = SharingRig()..seed(sharingMovie(1));
    final long = 'Um título muito longo de série ' * 8;
    rig.seedShared({
      SharedSection.activity,
    }, actSince: kSharingNow.subtract(const Duration(days: 1)));
    final item = ActivityItem(
      type: ActivityType.completedSeries,
      id: 77,
      mediaType: 'tv',
      title: long,
      at: kSharingNow.subtract(const Duration(hours: 2)),
    );
    rig.doc!['activity'] = [item.toJson()];
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(rig));
    await tester.pumpAndSettle();
    final sentence = SharedProfileTexts.activity(item);
    final text = tester.widget<Text>(find.text(sentence));
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(find.bySemanticsLabel(RegExp(RegExp.escape(sentence))), findsOneWidget);
    await tester.tap(find.text(sentence));
    await tester.pumpAndSettle();
    expect(find.text('tv 77'), findsOneWidget);
    handle.dispose();
  });

  test('QA-13 consent dialog texts are the docs/81 literals (Atividades and Estatísticas)', () {
    // The oracle is the spec itself: the row of the "Textos literais" table.
    final spec = File('docs/81-especificacao-perfil-social.md').readAsLinesSync();
    ({String title, String body}) row(String section) {
      final line = spec.firstWhere((l) => l.startsWith('| $section | "'));
      final quoted = RegExp(r'"([^"]*)"').allMatches(line).map((m) => m.group(1)!).toList();
      return (title: quoted[0], body: quoted[1]);
    }

    for (final (name, section) in [
      ('Atividades', SharedSection.activity),
      ('Estatísticas', SharedSection.stats),
    ]) {
      final literal = row(name);
      expect(kSharingDialogs[section]!.title, literal.title, reason: name);
      expect(kSharingDialogs[section]!.body, literal.body, reason: name);
    }
    expect(kSharingDialogs[SharedSection.activity]!.body, contains('até 10'));
    expect(kSharingDialogs[SharedSection.activity]!.body, contains('as 3 últimas'));
  });

  testWidgets('QA-14 the real lifecycle hook flushes on hidden/paused, not on resumed', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    var calls = 0;
    final dispose = c.read(sharedLifecycleHookProvider)(() => calls++);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(calls, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(calls, 3);
    dispose();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(calls, 3, reason: 'removed on dispose');
  });
}
