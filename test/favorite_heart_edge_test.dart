import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/widgets/auth_gate.dart';
import 'package:cinetrack/widgets/detail_actions.dart';
import 'package:cinetrack/widgets/discovery_section.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

// docs/29 review items: pending during the progress check, write failure
// feedback, state re-read, login from the heart.

const _show = SearchResult(
  id: 12,
  mediaType: MediaType.tv,
  title: 'Serie Y',
  posterPath: null,
  overview: '',
);
const _movie = SearchResult(
  id: 11,
  mediaType: MediaType.movie,
  title: 'Filme X',
  posterPath: null,
  overview: '',
);
final _list = FutureProvider<List<SearchResult>>((ref) async => [_show, _movie]);

FavoriteDoc _tvDoc({Set<String> eps = const {}}) => FavoriteDoc(
  id: 12,
  mediaType: MediaType.tv,
  title: 'Serie Y',
  posterPath: null,
  overview: '',
  addedAt: DateTime(2026),
  watchedEpisodes: eps,
  seasonSummaries: const [TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 2)],
);

class _FailingRemove extends InMemoryFavoritesDataSource {
  _FailingRemove(super.cloud, {required super.uid});

  @override
  Future<void> remove(String key) => Future.error(StateError('boom'));
}

Future<void> _pump(
  WidgetTester tester,
  FakeCloud cloud, {
  FakeAuthRepository? auth,
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SingleChildScrollView(
            child: DiscoverySection(title: 'Alta', provider: _list),
          ),
        ),
      ),
      GoRoute(path: '/tv/:id', builder: (_, _) => const Text('DETAIL-TV')),
      GoRoute(path: '/movie/:id', builder: (_, _) => const Text('DETAIL-MOVIE')),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...cloudOverrides(
          auth: auth ?? FakeAuthRepository(initialUser: kAna),
          cloud: cloud,
          api: FakeTmdbApiClient(),
        ),
        ...extra,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => PendingIntentRunner(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final heart = find.byTooltip('Remover Serie Y dos favoritos');

  testWidgets('slow progress check: heart is pending at once; repeated taps open ONE dialog', (
    tester,
  ) async {
    final cloud = FakeCloud()..server['uid-ana'] = {'12-tv': _tvDoc()};
    final never = StreamController<List<FavoriteDoc>>(); // docs never arrive
    addTearDown(never.close);
    await _pump(tester, cloud, extra: [favoriteDocsProvider.overrideWith((ref) => never.stream)]);

    final heartAt = tester.getCenter(heart);
    await tester.tap(heart);
    await tester.pump();
    await tester.tapAt(heartAt); // repeated taps while waiting
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(heartAt);
    await tester.pump();
    // Pending right away: spinner instead of the heart, nothing to tap.
    expect(heart, findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Remover dos favoritos?'), findsNothing);

    await tester.pump(const Duration(seconds: 3)); // timeout: assume progress, confirm
    await tester.pumpAndSettle();
    expect(find.text('Remover dos favoritos?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Remover dos favoritos?'), findsNothing);
    expect(cloud.view('uid-ana').keys, ['12-tv']);
    expect(heart, findsOneWidget); // released on cancel
  });

  testWidgets('favoriteDocsProvider error: assumes progress and confirms', (tester) async {
    final cloud = FakeCloud()..server['uid-ana'] = {'12-tv': _tvDoc()};
    await _pump(
      tester,
      cloud,
      extra: [favoriteDocsProvider.overrideWith((ref) => Stream.error(StateError('x')))],
    );
    await tester.tap(heart);
    await tester.pumpAndSettle();
    expect(find.text('Remover dos favoritos?'), findsOneWidget);
    await tester.tap(find.text('Remover'));
    await tester.pumpAndSettle();
    expect(cloud.view('uid-ana'), isEmpty);
  });

  testWidgets('a confirmed removal that fails shows a message and releases the heart', (
    tester,
  ) async {
    final cloud = FakeCloud()
      ..server['uid-ana'] = {
        '12-tv': _tvDoc(eps: {'1_1'}),
      };
    await _pump(
      tester,
      cloud,
      extra: [
        favoritesDataSourceFactoryProvider.overrideWithValue(
          (uid) => _FailingRemove(cloud, uid: uid),
        ),
      ],
    );
    await tester.tap(heart);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remover'));
    await tester.pumpAndSettle();
    expect(find.text(kGenericWriteMessage), findsOneWidget);
    expect(cloud.view('uid-ana').keys, ['12-tv']);
    expect(heart, findsOneWidget);
  });

  testWidgets('removed elsewhere while the dialog is open: confirming is harmless', (tester) async {
    final cloud = FakeCloud()
      ..server['uid-ana'] = {
        '12-tv': _tvDoc(eps: {'1_1'}),
      };
    await _pump(tester, cloud);
    await tester.tap(heart);
    await tester.pumpAndSettle();
    cloud.write('uid-ana', (docs) => docs.remove('12-tv')); // another device
    await tester.pump();
    await tester.tap(find.text('Remover'));
    await tester.pumpAndSettle();
    expect(find.text(kGenericWriteMessage), findsNothing);
    expect(cloud.view('uid-ana'), isEmpty);
    expect(find.byTooltip('Adicionar Serie Y aos favoritos'), findsOneWidget);
  });

  testWidgets('signed out: the heart starts login and the pending favorite is saved afterwards', (
    tester,
  ) async {
    final cloud = FakeCloud();
    final auth = FakeAuthRepository()..nextUser = kAna;
    await _pump(tester, cloud, auth: auth);
    await tester.tap(find.byTooltip('Adicionar Filme X aos favoritos'));
    await tester.pumpAndSettle();
    expect(auth.signInCalls, 1);
    expect(cloud.view('uid-ana').keys, ['11-movie']);
    expect(find.text('DETAIL-MOVIE'), findsNothing);
  });
}
