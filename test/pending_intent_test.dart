import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/widgets/auth_gate.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

const _movie = SearchResult(
    id: 11, mediaType: MediaType.movie, title: 'Filme', posterPath: null, overview: '');
const _show =
    SearchResult(id: 12, mediaType: MediaType.tv, title: 'Serie', posterPath: null, overview: '');

Widget _app(FakeAuthRepository auth, FakeCloud cloud, {FakeTmdbApiClient? api}) => ProviderScope(
      overrides: cloudOverrides(auth: auth, cloud: cloud, api: api),
      child: MaterialApp(
        builder: (context, child) => PendingIntentRunner(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => runWrite(context, (repo) => repo.addResult(_movie)),
                  child: const Text('favoritar filme'),
                ),
                TextButton(
                  onPressed: () => runWrite(context, (repo) => repo.addResult(_show)),
                  child: const Text('favoritar serie'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('signed out -> login -> the pending favorite is saved on the new account',
      (tester) async {
    final auth = FakeAuthRepository()..nextUser = kAna;
    final cloud = FakeCloud();
    await tester.pumpWidget(_app(auth, cloud));
    await tester.pumpAndSettle();

    await tester.tap(find.text('favoritar filme'));
    await tester.pumpAndSettle();

    expect(auth.signInCalls, 1);
    expect(cloud.view('uid-ana').keys, ['11-movie']);
  });

  testWidgets('signed out -> login cancelled -> nothing is saved, intent dropped', (tester) async {
    final auth = FakeAuthRepository()..nextFailure = const AuthFailure(AuthFailureKind.cancelled);
    final cloud = FakeCloud();
    await tester.pumpWidget(_app(auth, cloud));
    await tester.pumpAndSettle();

    await tester.tap(find.text('favoritar filme'));
    await tester.pumpAndSettle();
    expect(cloud.server, isEmpty);

    // A later, unrelated login must not resurrect the cancelled intent.
    auth
      ..nextFailure = null
      ..nextUser = kBruno;
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    await container.read(authControllerProvider.notifier).signIn();
    await tester.pumpAndSettle();

    expect(cloud.view('uid-bruno'), isEmpty);
    expect(cloud.view('uid-ana'), isEmpty);
  });

  testWidgets('a TV show intent also executes after login (no TMDB call before login)',
      (tester) async {
    final auth = FakeAuthRepository();
    final cloud = FakeCloud();
    final api = FakeTmdbApiClient();
    await tester.pumpWidget(_app(auth, cloud, api: api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('favoritar serie'));
    await tester.pumpAndSettle();

    expect(cloud.view('uid-ana').keys, ['12-tv']);
    expect(api.tvDetailsCalls, 1); // only after the favorite was accepted
  });

  testWidgets('signed in: writes go straight through, no login prompt', (tester) async {
    final auth = FakeAuthRepository(initialUser: kAna);
    final cloud = FakeCloud();
    await tester.pumpWidget(_app(auth, cloud));
    await tester.pumpAndSettle();

    await tester.tap(find.text('favoritar filme'));
    await tester.pumpAndSettle();

    expect(auth.signInCalls, 0);
    expect(cloud.view('uid-ana').keys, ['11-movie']);
  });
}
