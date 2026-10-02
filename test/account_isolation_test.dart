import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/data/favorites_data_source.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/providers/providers.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Isolation of user data between accounts at the app layer. Rules-level
/// isolation (server side) is covered by `firestore_rules_test/`.
void main() {
  late FakeAuthRepository auth;
  late FakeCloud cloud;
  late List<String> created;
  late ProviderContainer container;

  setUp(() {
    auth = FakeAuthRepository();
    cloud = FakeCloud();
    created = [];
    container = ProviderContainer(
      overrides: cloudOverrides(auth: auth, cloud: cloud, createdFor: created),
    );
    // Keep the session stream subscribed, as the running app does.
    final authSub = container.listen(authStateProvider, (_, __) {});
    addTearDown(authSub.close);
    addTearDown(container.dispose);
  });

  Future<List<FavoriteItem>> favorites() async {
    // Let auth state propagate, then read the current list.
    await container.read(authStateProvider.future);
    await pumpEventQueue();
    final repo = container.read(favoritesRepositoryProvider);
    return repo.watchAll().first;
  }

  Future<void> signInAs(AppUser user) async {
    auth.nextUser = user;
    await container.read(authStateProvider.future);
    await container.read(authControllerProvider.notifier).signIn();
    await pumpEventQueue();
  }

  test('signed out: reads are empty and writes ask for login', () async {
    expect(await favorites(), isEmpty);
    expect(container.read(favoritesDataSourceProvider), isA<SignedOutFavoritesDataSource>());
    await expectLater(
      container
          .read(favoritesRepositoryProvider)
          .addMovie(id: 1, title: 'M', posterPath: null, overview: ''),
      throwsA(isA<AuthRequiredException>()),
    );
  });

  test('switching account recreates the data layer and never shows the previous account', () async {
    await signInAs(kAna);
    await container
        .read(favoritesRepositoryProvider)
        .addMovie(id: 1, title: 'Filme da Ana', posterPath: null, overview: '');
    final anaDataSource = container.read(favoritesDataSourceProvider);
    expect((await favorites()).map((f) => f.title), ['Filme da Ana']);

    await container.read(authControllerProvider.notifier).signOut();
    await pumpEventQueue();
    // Logged out: nothing from Ana on any read path.
    expect(await favorites(), isEmpty);
    expect(cloud.view('uid-ana'), isNotEmpty); // data kept in the cloud

    await signInAs(kBruno);
    final brunoDataSource = container.read(favoritesDataSourceProvider);
    expect(brunoDataSource, isNot(same(anaDataSource)));
    expect(await favorites(), isEmpty);
    expect(created, containsAllInOrder(['uid-ana', 'uid-bruno']));

    await container
        .read(favoritesRepositoryProvider)
        .addMovie(id: 2, title: 'Filme do Bruno', posterPath: null, overview: '');
    expect((await favorites()).map((f) => f.title), ['Filme do Bruno']);
    expect(cloud.view('uid-ana').keys, ['1-movie']); // Bruno's write never reached Ana

    // Ana comes back and finds only her own data.
    await container.read(authControllerProvider.notifier).signOut();
    await signInAs(kAna);
    expect((await favorites()).map((f) => f.title), ['Filme da Ana']);
  });

  test('derived providers (favorites list) are rebuilt for the new account', () async {
    await signInAs(kAna);
    await container
        .read(favoritesRepositoryProvider)
        .addMovie(id: 1, title: 'A', posterPath: null, overview: '');
    final sub = container.listen(favoritesListProvider, (_, __) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(container.read(favoritesListProvider).value!.map((f) => f.title), ['A']);

    await container.read(authControllerProvider.notifier).signOut();
    await signInAs(kBruno);
    await pumpEventQueue();

    expect(container.read(favoritesListProvider).value, isEmpty);
    expect(container.read(continueWatchingProvider), isEmpty);
  });

  // Models the ASSUMED SDK behavior (design premise 5b: the offline write
  // queue is per user). The real SDK is NOT exercised here; this must be
  // confirmed in spike S1 against a real project/emulator.
  test('modelled: Ana offline write is not delivered to Bruno and arrives when Ana is back',
      () async {
    await signInAs(kAna);
    cloud.offline = true;
    await container
        .read(favoritesRepositoryProvider)
        .addMovie(id: 1, title: 'Offline da Ana', posterPath: null, overview: '');
    expect(cloud.server['uid-ana'] ?? {}, isEmpty); // not on the server yet

    await container.read(authControllerProvider.notifier).signOut();
    await signInAs(kBruno);
    cloud.offline = false;
    await container
        .read(favoritesRepositoryProvider)
        .addMovie(id: 2, title: 'Do Bruno', posterPath: null, overview: '');

    expect(cloud.view('uid-bruno').keys, ['2-movie']); // nothing of Ana's
    expect(cloud.server['uid-ana'] ?? {}, isEmpty);

    cloud.flush('uid-ana'); // Ana signs in again and the queue drains
    expect(cloud.server['uid-ana']!.keys, ['1-movie']);
    expect(cloud.view('uid-bruno').keys, ['2-movie']);
  });
}
