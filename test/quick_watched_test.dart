import 'dart:async';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/catalog_sync_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/screens/favorites_screen.dart';
import 'package:cinetrack/widgets/favorites_section.dart';
import 'package:cinetrack/services/bulk_watch.dart';
import 'package:cinetrack/services/tmdb_exception.dart';
import 'package:cinetrack/widgets/detail_actions.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

// docs/30: quick watched toggle in "Meus favoritos".

final _past = DateTime(2020);
final _future = DateTime.now().add(const Duration(days: 90));

EpisodeCache _ep(int n, {DateTime? air}) =>
    EpisodeCache(episodeNumber: n, name: 'E$n', airDate: air ?? _past, watched: false);

// Regular seasons: S1 has 3 aired, S2 has 2 aired + 1 future; S0 special (aired).
final _s0 = SeasonCache(seasonNumber: 0, episodes: [_ep(1)]);
final _s1 = SeasonCache(seasonNumber: 1, episodes: [_ep(1), _ep(2), _ep(3)]);
final _s2 = SeasonCache(
  seasonNumber: 2,
  episodes: [
    _ep(1),
    _ep(2),
    _ep(3, air: _future),
  ],
);

const _sum = [
  TvSeasonSummary(seasonNumber: 0, name: 'Especiais', episodeCount: 1),
  TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 3),
  TvSeasonSummary(seasonNumber: 2, name: 'T2', episodeCount: 3),
];

FavoriteDoc _tv({
  int id = 1,
  String title = 'Serie A',
  Set<String> eps = const {},
  List<TvSeasonSummary> summaries = _sum,
  DateTime? lastWatched,
  DateTime? added,
}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.tv,
  title: title,
  posterPath: null,
  overview: '',
  addedAt: added ?? DateTime(2024),
  lastWatchedAt: lastWatched,
  watchedEpisodes: eps,
  seasonSummaries: summaries,
);

FavoriteDoc _movie({int id = 7, String title = 'Filme M', bool watched = false}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.movie,
  title: title,
  posterPath: null,
  overview: '',
  addedAt: DateTime(2024),
  watchedMovie: watched,
);

const _allAired = {'1_1', '1_2', '1_3', '2_1', '2_2'};

class _FailingEpisodes extends InMemoryFavoritesDataSource {
  _FailingEpisodes(super.cloud, {required super.uid});

  @override
  Future<void> setEpisodes(String key, Map<String, bool> changes) =>
      Future.error(StateError('boom'));
}

class _Rig {
  final cloud = FakeCloud();
  final store = FakeLocalStore();
  final api = FakeTmdbApiClient();
  final navigated = <String>[];
  late ProviderContainer container;

  void put(FavoriteDoc doc) => (cloud.server['uid-ana'] ??= {})[doc.key] = doc;
  Set<String> eps(String key) => cloud.view('uid-ana')[key]!.watchedEpisodes;
  FavoriteDoc doc(String key) => cloud.view('uid-ana')[key]!;

  Future<void> seedCatalog(int id, List<SeasonCache> seasons) async {
    for (final s in seasons) {
      await store.saveCatalogSeason(id, s);
    }
    store.fetchedAt[id] = DateTime.now(); // fresh: no TTL refresh unless a test wants it
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 900),
    double textScale = 1,
    Brightness brightness = Brightness.light,
    List<Override> extra = const [],
    FakeAuthRepository? auth,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const FavoritesScreen()),
        GoRoute(
          path: '/other',
          builder: (_, _) => const Scaffold(body: Text('outra tela')),
        ),
        GoRoute(
          path: '/tv/:id',
          builder: (_, s) {
            navigated.add('tv');
            return const Text('DETAIL-TV');
          },
        ),
        GoRoute(
          path: '/movie/:id',
          builder: (_, s) {
            navigated.add('movie');
            return const Text('DETAIL-MOVIE');
          },
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...cloudOverrides(
            auth: auth ?? FakeAuthRepository(initialUser: kAna),
            cloud: cloud,
            store: store,
            api: api,
          ),
          catalogSyncDelayProvider.overrideWithValue((_) async {}),
          ...extra,
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: ThemeData(brightness: brightness, useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
    container = ProviderScope.containerOf(tester.element(find.byType(FavoritesScreen)));
  }
}

Finder _markTv(String title) =>
    find.byTooltip('Marcar como assistido: todos os episódios de $title');
Finder _unmarkTv(String title) =>
    find.byTooltip('Assistido: desmarcar todos os episódios de $title');

void main() {
  group('movie: direct toggle', () {
    testWidgets('marks and unmarks without a dialog, never opens the details', (tester) async {
      final r = _Rig()..put(_movie());
      await r.pump(tester);
      expect(find.text('Marcar como assistido'), findsOneWidget);

      await tester.tap(find.byTooltip('Marcar como assistido: Filme M'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(r.doc('7-movie').watchedMovie, isTrue);
      expect(r.doc('7-movie').lastWatchedAt, isNotNull);
      expect(r.navigated, isEmpty);
      // moved to "Concluídos" at once
      expect(find.text('Em andamento (0)'), findsOneWidget);
      expect(find.text('Concluídos (1)'), findsOneWidget);
      await tester.tap(find.text('Concluídos (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Assistido'), findsOneWidget); // chip label (icon + text)

      await tester.tap(find.byTooltip('Assistido: desmarcar Filme M'));
      await tester.pumpAndSettle();
      expect(r.doc('7-movie').watchedMovie, isFalse);
      expect(find.text('Concluídos (0)'), findsOneWidget);
      expect(r.navigated, isEmpty);
    });

    testWidgets('card tap still opens the details', (tester) async {
      final r = _Rig()..put(_movie());
      await r.pump(tester);
      await tester.tap(find.text('Filme M'));
      await tester.pumpAndSettle();
      expect(find.text('DETAIL-MOVIE'), findsOneWidget);
    });

    testWidgets('semantics: button, selected state and 48 px target', (tester) async {
      final handle = tester.ensureSemantics();
      final r = _Rig()
        ..put(_movie())
        ..put(_movie(id: 8, title: 'Filme V', watched: true));
      await r.pump(tester);
      final off = find.byTooltip('Marcar como assistido: Filme M');
      final on = find.byTooltip('Assistido: desmarcar Filme V');
      // The Tooltip wraps the visual chip (36 px); the padded tap target is the
      // FilterChip itself (48 px).
      final offChip = find.ancestor(of: off, matching: find.byType(FilterChip));
      expect(tester.getSize(offChip).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(offChip).width, greaterThanOrEqualTo(48));
      final offData = tester.getSemantics(off).getSemanticsData();
      expect(offData.hasAction(SemanticsAction.tap), isTrue);
      expect(offData.flagsCollection.isSelected, Tristate.isFalse);
      // The "Concluídos" movie is in the other tab: check it there.
      await tester.tap(find.textContaining('Concluídos ('));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(on).getSemanticsData().flagsCollection.isSelected,
        Tristate.isTrue,
      );
      handle.dispose();
    });

    testWidgets('double tap while pending writes once', (tester) async {
      final r = _Rig()..put(_movie());
      await r.pump(tester);
      final at = tester.getCenter(find.byTooltip('Marcar como assistido: Filme M'));
      await tester.tap(find.byTooltip('Marcar como assistido: Filme M'));
      await tester.tapAt(at); // same frame: pending/absorbed or already moved
      await tester.pumpAndSettle();
      expect(r.doc('7-movie').watchedMovie, isTrue);
    });
  });

  group('series: confirmation', () {
    testWidgets('Cancelar changes nothing; Confirmar marks only aired regular episodes', (
      tester,
    ) async {
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester);
      expect(find.text('Em andamento (1)'), findsOneWidget);

      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      expect(find.text('Marcar a série inteira como assistida?'), findsOneWidget);
      expect(find.textContaining('Isso vai marcar 5 episódios de 2 temporadas'), findsOneWidget);
      expect(find.textContaining('desfazer por 30 segundos'), findsOneWidget);
      expect(r.navigated, isEmpty);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), isEmpty);
      expect(r.doc('1-tv').lastWatchedAt, isNull);

      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      // no special (S0), no future episode (2_3)
      expect(r.eps('1-tv'), _allAired);
      expect(r.doc('1-tv').lastWatchedAt, isNotNull);
      // left "Em andamento" at once, now in "Concluídos"
      expect(find.text('Em andamento (0)'), findsOneWidget);
      expect(find.text('Concluídos (1)'), findsOneWidget);
      expect(find.text('Desfazer'), findsOneWidget);
      expect(r.navigated, isEmpty);
    });

    testWidgets('partially watched series: counts only what is missing', (tester) async {
      final r = _Rig()..put(_tv(eps: {'1_1', '1_2'}));
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Isso vai marcar 3 episódios de 2 temporadas'), findsOneWidget);
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), _allAired);
    });

    testWidgets('incomplete catalog: loads the missing seasons first ("Preparando…")', (
      tester,
    ) async {
      final r = _Rig()..put(_tv());
      r.api
        ..seasonsByNumber[0] = _s0
        ..seasonsByNumber[1] = _s1
        ..seasonsByNumber[2] = _s2;
      final gate = r.api.seasonGate = Completer<void>(); // TMDB is slow
      await r.pump(tester, settle: false);
      expect(r.store.readSeasonCatalog(1), isEmpty);

      await tester.tap(_markTv('Serie A'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Preparando…'), findsOneWidget);
      expect(find.text('Marcar tudo'), findsNothing); // cannot confirm yet
      expect(r.eps('1-tv'), isEmpty);

      gate.complete();
      await tester.pumpAndSettle();
      expect(r.api.seasonCalls, greaterThanOrEqualTo(3));
      expect(find.textContaining('Isso vai marcar 5 episódios de 2 temporadas'), findsOneWidget);
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), _allAired);
    });

    testWidgets('network failure: message + Tentar novamente, never a partial mark', (
      tester,
    ) async {
      final r = _Rig()..put(_tv());
      r.api
        ..seasonsByNumber[0] = _s0
        ..seasonsByNumber[1] = _s1
        ..seasonsByNumber[2] = _s2;
      // the background sync would also consume errors: pump with it failing too
      r.api.seasonError = TmdbException.network();
      await r.pump(tester);
      expect(find.textContaining('Calculando'), findsNothing);

      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      expect(find.text('Não foi possível preparar'), findsOneWidget);
      expect(find.textContaining('Sem conexão com a internet. Nada foi alterado.'), findsOneWidget);
      expect(find.text('Marcar tudo'), findsNothing);
      expect(r.eps('1-tv'), isEmpty);

      // network back: retry works and then asks for confirmation
      r.api.seasonError = null;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Isso vai marcar 5 episódios de 2 temporadas'), findsOneWidget);
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), _allAired);
    });

    testWidgets('failure then Cancelar leaves everything untouched', (tester) async {
      final r = _Rig()..put(_tv());
      r.api.seasonError = TmdbException.network();
      await r.pump(tester);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(r.eps('1-tv'), isEmpty);
      expect(_markTv('Serie A'), findsOneWidget); // button is usable again
    });

    testWidgets('a show with nothing aired says so and writes nothing', (tester) async {
      final r = _Rig()
        ..put(
          _tv(summaries: const [TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 1)]),
        );
      await r.seedCatalog(1, [
        SeasonCache(seasonNumber: 1, episodes: [_ep(1, air: _future)]),
      ]);
      await r.pump(tester);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      expect(find.text('Nada para marcar'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), isEmpty);
    });

    testWidgets('a write that fails shows a message and no Desfazer', (tester) async {
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(
        tester,
        extra: [
          favoritesDataSourceFactoryProvider.overrideWithValue(
            (uid) => _FailingEpisodes(r.cloud, uid: uid),
          ),
        ],
      );
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(find.text(kGenericWriteMessage), findsOneWidget);
      expect(find.text('Desfazer'), findsNothing);
      expect(r.eps('1-tv'), isEmpty);
    });
  });

  group('series: unmark everything', () {
    testWidgets('a fully watched series confirms, warns it erases progress and clears', (
      tester,
    ) async {
      final r = _Rig()..put(_tv(eps: {..._allAired, '0_1'}));
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester);
      await tester.tap(find.textContaining('Concluídos ('));
      await tester.pumpAndSettle();
      await tester.tap(_unmarkTv('Serie A'));
      await tester.pumpAndSettle();
      expect(find.text('Desmarcar a série inteira?'), findsOneWidget);
      expect(find.textContaining('apagar o seu progresso'), findsOneWidget);
      expect(find.textContaining('desmarcar 6 episódios de 3 temporadas'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), {..._allAired, '0_1'});

      await tester.tap(_unmarkTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desmarcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), isEmpty);
      expect(find.text('Concluídos (0)'), findsOneWidget);
      expect(find.text('Em andamento (1)'), findsOneWidget);
    });
  });

  group('series: Desfazer (30 s)', () {
    Future<_Rig> marked(WidgetTester tester, {Set<String> eps = const {'1_1'}}) async {
      final r = _Rig()..put(_tv(eps: eps));
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      return r;
    }

    testWidgets('restores exactly the previous episodes (also the ones already watched)', (
      tester,
    ) async {
      final r = await marked(tester);
      expect(r.eps('1-tv'), _allAired);
      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), {'1_1'});
      expect(find.text('Progresso restaurado.'), findsOneWidget);
      expect(find.text('Em andamento (1)'), findsOneWidget);
    });

    testWidgets('undo of an unmark restores the progress', (tester) async {
      final r = _Rig()..put(_tv(eps: {..._allAired, '0_1'}));
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester);
      await tester.tap(find.textContaining('Concluídos ('));
      await tester.pumpAndSettle();
      await tester.tap(_unmarkTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desmarcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), isEmpty);
      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), {..._allAired, '0_1'});
    });

    testWidgets('does NOT restore when the document changed meanwhile', (tester) async {
      final r = await marked(tester);
      // another device unmarks one episode inside the window
      r.cloud.write('uid-ana', (docs) {
        docs['1-tv'] = docs['1-tv']!.copyWith(watchedEpisodes: {..._allAired}..remove('2_2'));
      });
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      expect(find.text('Algo mudou, não foi possível desfazer.'), findsOneWidget);
      expect(r.eps('1-tv'), {..._allAired}..remove('2_2'));
    });

    testWidgets('the window is 30 s: still there at 29 s, gone after 30 s', (tester) async {
      expect(kUndoWindow, const Duration(seconds: 30));
      await marked(tester);
      await tester.pump(const Duration(seconds: 29));
      expect(find.text('Desfazer'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('only the last whole-series action keeps its Desfazer', (tester) async {
      final r = _Rig()
        ..put(_tv(id: 1, title: 'Serie A'))
        ..put(_tv(id: 2, title: 'Serie B'));
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.seedCatalog(2, [_s0, _s1, _s2]);
      await r.pump(tester);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      await tester.tap(_markTv('Serie B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsOneWidget);
      await tester.tap(find.text('Desfazer'));
      await tester.pumpAndSettle();
      expect(r.eps('2-tv'), isEmpty);
      expect(r.eps('1-tv'), _allAired); // A is not undone any more
    });

    testWidgets('leaving Favoritos discards the Desfazer', (tester) async {
      await marked(tester);
      expect(find.text('Desfazer'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('outra tela'))));
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('account switch discards the Desfazer', (tester) async {
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      final auth = FakeAuthRepository(initialUser: kAna);
      await r.pump(tester, auth: auth);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsOneWidget);
      await r.container.read(authRepositoryProvider).signOut();
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('semantics: the action is a labelled button reachable by keyboard focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await marked(tester);
      final node = tester.getSemantics(find.text('Desfazer'));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });
  });

  group('server acknowledgement and freshness', () {
    Future<_Rig> seeded(WidgetTester tester) async {
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester);
      return r;
    }

    Future<void> confirmMark(WidgetTester tester) async {
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
    }

    testWidgets('online: shows "salvando…" first, then marked + Desfazer', (tester) async {
      final r = await seeded(tester);
      r.cloud.stuck = true; // the server has not answered yet
      await confirmMark(tester);
      await tester.pump(kAckSettle + const Duration(milliseconds: 50));
      expect(find.textContaining('salvando…'), findsOneWidget);
      expect(find.text('Desfazer'), findsNothing); // nothing promised yet
      r.cloud.stuck = false;
      r.cloud.flush('uid-ana'); // server acknowledges
      await tester.pumpAndSettle();
      expect(find.textContaining('salvando…'), findsNothing);
      expect(find.textContaining('5 episódios marcados como assistidos.'), findsOneWidget);
      expect(find.text('Desfazer'), findsOneWidget);
    });

    testWidgets('offline: optimistic, honest text, Desfazer available', (tester) async {
      final r = await seeded(tester);
      r.cloud.offline = true;
      await tester.pump();
      await confirmMark(tester);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('neste aparelho. Sincroniza quando houver conexão.'),
        findsOneWidget,
      );
      expect(find.text('Desfazer'), findsOneWidget);
      expect(r.eps('1-tv'), _allAired);
    });

    testWidgets('connected but unacknowledged for too long: kept, flagged, Desfazer', (
      tester,
    ) async {
      final r = await seeded(tester);
      r.cloud.stuck = true;
      await confirmMark(tester);
      await tester.pump(kAckSettle);
      await tester.pump(kAckWait + const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('Aguardando confirmação do servidor.'), findsOneWidget);
      expect(find.text('Desfazer'), findsOneWidget);
    });

    testWidgets('the server refuses the write: failure message, no Desfazer', (tester) async {
      final r = await seeded(tester);
      r.cloud.stuck = true;
      await confirmMark(tester);
      await tester.pump(kAckSettle + const Duration(milliseconds: 50));
      r.container.read(syncFailureSinkProvider).reportCode('resource-exhausted');
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.textContaining('Não foi possível salvar a alteração em Serie A'), findsOneWidget);
      expect(find.text('Desfazer'), findsNothing);
      expect(find.textContaining('salvando…'), findsNothing);
    });

    testWidgets('permission-denied (checked against the session) is not shown as saved', (
      tester,
    ) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester, auth: auth);
      r.cloud.stuck = true;
      await confirmMark(tester);
      await tester.pump(kAckSettle + const Duration(milliseconds: 50));
      // The server refuses: the local write rolls back (pending drops) first...
      auth.verifyGate = Completer<void>();
      r.cloud.stuck = false;
      r.cloud.pending.remove('uid-ana');
      r.cloud.write('uid-ana', (_) {});
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Desfazer'), findsNothing);
      // ...and only then the failure is recorded, after the session check.
      r.container.read(syncFailureSinkProvider).reportCode('permission-denied');
      await tester.pump(const Duration(milliseconds: 300));
      auth.verifyGate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível salvar a alteração em Serie A'), findsOneWidget);
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('a refusal faster than the settle window is still caught', (tester) async {
      final r = await seeded(tester);
      await confirmMark(tester);
      await tester.pump(const Duration(milliseconds: 20));
      r.container.read(syncFailureSinkProvider).reportCode('permission-denied');
      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível salvar a alteração em Serie A'), findsOneWidget);
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('the card is usable while the server answer is awaited', (tester) async {
      final r = await seeded(tester);
      r.cloud.stuck = true;
      await confirmMark(tester);
      await tester.pump(kAckSettle + const Duration(milliseconds: 50));
      expect(find.textContaining('salvando…'), findsOneWidget);
      // The card (now under "Concluídos") has its button back, not a spinner.
      await tester.tap(find.textContaining('Concluídos ('));
      await tester.pump();
      expect(_unmarkTv('Serie A'), findsOneWidget);
      await tester.pump(kAckWait + kAckSettle);
    });

    testWidgets('leaving the screen while "salvando…" is shown removes that snackbar', (
      tester,
    ) async {
      final r = await seeded(tester);
      r.cloud.stuck = true;
      await confirmMark(tester);
      await tester.pump(kAckSettle + const Duration(milliseconds: 50));
      expect(find.textContaining('salvando…'), findsOneWidget);
      // Same app (the ScaffoldMessenger survives), only the route changes.
      GoRouter.of(tester.element(find.byType(FavoritesScreen))).go('/other');
      await tester.pump();
      // route transition, then the snackbar's exit animation
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('outra tela'), findsOneWidget);
      expect(find.textContaining('salvando…'), findsNothing);
      await tester.pump(kAckWait + const Duration(seconds: 1));
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('account switched while waiting for the server: no Desfazer', (tester) async {
      final auth = FakeAuthRepository(initialUser: kAna);
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester, auth: auth);
      r.cloud.stuck = true;
      await confirmMark(tester);
      await tester.pump(kAckSettle + const Duration(milliseconds: 50));
      auth.nextUser = const AppUser(uid: 'uid-bruno', displayName: 'B', email: 'b@example.test');
      await auth.signInWithGoogle();
      await tester.pump(kAckWait + const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('Cancelar in "Preparando…" stops the download and writes nothing', (tester) async {
      final r = _Rig()..put(_tv());
      r.api
        ..seasonsByNumber[0] = _s0
        ..seasonsByNumber[1] = _s1
        ..seasonsByNumber[2] = _s2;
      final gate = r.api.seasonGate = Completer<void>();
      await r.pump(tester, settle: false);
      await tester.tap(_markTv('Serie A'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Preparando…'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(_markTv('Serie A'), findsOneWidget); // UI usable at once
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(r.eps('1-tv'), isEmpty);
      expect(find.text('Desfazer'), findsNothing);
    });

    testWidgets('a catalog past its TTL is refreshed before planning (new aired episode)', (
      tester,
    ) async {
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      r.store.fetchedAt[1] = DateTime(2020); // stale; S2 still lists a future episode
      r.api.seasonsByNumber[2] = SeasonCache(
        seasonNumber: 2,
        episodes: [_ep(1), _ep(2), _ep(3), _ep(4)], // 2_3 aired since, 2_4 is new
      );
      await r.pump(tester);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Isso vai marcar 7 episódios de 2 temporadas'), findsOneWidget);
      expect(r.api.tvDetailsCalls, greaterThanOrEqualTo(1));
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), {..._allAired, '2_3', '2_4'});
    });

    testWidgets('keyboard: Enter confirms a mark, Esc cancels', (tester) async {
      final r = await seeded(tester);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(r.eps('1-tv'), isEmpty);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), _allAired);
    });
  });

  group('guards', () {
    testWidgets('account switched while the dialog is open: nothing is written', (tester) async {
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      r.cloud.server['uid-bruno'] = {
        '1-tv': _tv(eps: {'1_1', '1_2'}),
      };
      final auth = FakeAuthRepository(initialUser: kAna);
      await r.pump(tester, auth: auth);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      expect(find.text('Marcar tudo'), findsOneWidget);
      auth.nextUser = const AppUser(
        uid: 'uid-bruno',
        displayName: 'Bruno',
        email: 'b@example.test',
      );
      await auth.signInWithGoogle();
      await tester.pump();
      await tester.pump();
      if (find.text('Marcar tudo').evaluate().isNotEmpty) {
        await tester.tap(find.text('Marcar tudo'));
      }
      await tester.pumpAndSettle();
      expect(r.cloud.view('uid-bruno')['1-tv']!.watchedEpisodes, {'1_1', '1_2'});
      expect(r.eps('1-tv'), isEmpty);
    });

    test('final eps size above the rules cap is refused before any write', () async {
      final h = FavoritesHarness();
      await h.seedShow(
        seasons: [
          SeasonCache(seasonNumber: 1, episodes: [h.episode(1)]),
        ],
      );
      final key = '42-tv';
      h.cloud.server['user-a']![key] = h.cloud.server['user-a']![key]!.copyWith(
        watchedEpisodes: {for (var i = 0; i < kMaxBulkEpisodes; i++) '9_$i'},
      );
      final plan = SeriesBulkPlan(docKey: key, watched: true, keys: {'1_1'}, seasonCount: 1);
      await expectLater(
        h.repo.applySeriesBulk(plan, uid: 'user-a'),
        throwsA(isA<BulkTooLargeException>()),
      );
      expect(h.cloud.view('user-a')[key]!.watchedEpisodes.length, kMaxBulkEpisodes);
    });
  });

  group('double tap and effects', () {
    testWidgets('double tap on a series opens one dialog and writes once', (tester) async {
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester);
      final at = tester.getCenter(_markTv('Serie A'));
      await tester.tap(_markTv('Serie A'));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.eps('1-tv'), _allAired);
    });

    testWidgets('order by recent activity and Perfil statistics update', (tester) async {
      final r = _Rig()
        ..put(_tv(id: 1, title: 'Serie A', lastWatched: DateTime(2026, 1)))
        ..put(_tv(id: 2, title: 'Serie B', lastWatched: DateTime(2026, 2)));
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.seedCatalog(2, [_s0, _s1, _s2]);
      await r.pump(tester);
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Serie B'), lessThan(y('Serie A'))); // B is more recent
      expect(r.container.read(profileStatsProvider).watchedEpisodes, 0);

      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      expect(r.container.read(profileStatsProvider).watchedEpisodes, 5);
      expect(r.container.read(profileStatsProvider).completedSeries, 1);
      expect(r.doc('1-tv').lastWatchedAt!.isAfter(DateTime(2026, 2)), isTrue);
      // Serie A is now in "Concluídos", B stays
      expect(find.text('Serie A'), findsNothing);
      expect(find.text('Serie B'), findsOneWidget);
    });
  });

  group('labelled chip', () {
    testWidgets('text in both states, series done, no navigation, semantics', (tester) async {
      final handle = tester.ensureSemantics();
      final r = _Rig()
        ..put(_movie())
        ..put(_movie(id: 8, title: 'Filme V', watched: true))
        ..put(_tv());
      await r.pump(tester);
      expect(find.text('Marcar como assistido'), findsNWidgets(2)); // movie + series
      final chip = find.ancestor(
        of: find.text('Marcar como assistido').first,
        matching: find.byType(FilterChip),
      );
      expect(tester.getSize(chip.first).height, greaterThanOrEqualTo(32));
      final sem = tester.getSemantics(find.byTooltip('Marcar como assistido: Filme M'));
      expect(sem.label, 'Marcar como assistido: Filme M');
      expect(sem.getSemanticsData().flagsCollection.isSelected, Tristate.isFalse);
      await tester.tap(find.byTooltip('Marcar como assistido: Filme M'));
      await tester.pumpAndSettle();
      expect(r.navigated, isEmpty);
      expect(find.text('DETAIL-MOVIE'), findsNothing);
      await tester.tap(find.textContaining('Concluídos ('));
      await tester.pumpAndSettle();
      expect(find.text('Assistido'), findsNWidgets(2));
      final on = tester.getSemantics(find.byTooltip('Assistido: desmarcar Filme V'));
      expect(on.label, 'Assistido: desmarcar Filme V');
      expect(on.getSemanticsData().flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('completed series shows "Assistido" and unmarks', (tester) async {
      final r = _Rig()..put(_tv());
      await r.seedCatalog(1, [_s0, _s1, _s2]);
      await r.pump(tester);
      await tester.tap(_markTv('Serie A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marcar tudo'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Concluídos ('));
      await tester.pumpAndSettle();
      expect(find.text('Assistido'), findsOneWidget);
      expect(_unmarkTv('Serie A'), findsOneWidget);
      expect(r.navigated, isEmpty);
    });
  });

  group('layout', () {
    for (final scale in [1.0, 2.0, 3.0]) {
      for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
        for (final dark in [false, true]) {
          testWidgets(
            '${width.toInt()} px, ${dark ? 'dark' : 'light'}, font ${scale.toInt()}x: no overflow',
            (tester) async {
              final r = _Rig()
                ..put(_tv(title: 'Uma série com um título bastante longo para quebrar linhas'))
                ..put(_movie(title: 'Um filme com um título igualmente longo e cheio de palavras'));
              await r.seedCatalog(1, [_s0, _s1, _s2]);
              await r.pump(
                tester,
                size: Size(width, 900),
                textScale: scale,
                brightness: dark ? Brightness.dark : Brightness.light,
              );
              expect(tester.takeException(), isNull);
              expect(find.text('Marcar como assistido'), findsWidgets);
              for (final b in find.byType(FilterChip).evaluate()) {
                final size = tester.getSize(find.byWidget(b.widget));
                expect(size.width, greaterThanOrEqualTo(48));
                expect(size.height, greaterThanOrEqualTo(48));
              }
              // The watched chips of two neighbouring cards (each card also has
              // its own "Recomendo" chip, which may wrap to a second line).
              final chips = find.widgetWithText(FilterChip, 'Marcar como assistido');
              if (width >= 768) {
                // Neighbours in the same row: chips anchored at the same base.
                expect(tester.getBottomLeft(chips.at(0)).dy, tester.getBottomLeft(chips.at(1)).dy);
              }
            },
          );
        }
      }
    }
  });
}
