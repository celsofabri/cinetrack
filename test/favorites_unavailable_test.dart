import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/favorites_data_source.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/widgets/auth_gate.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// I2: when a favorite cannot be read (cold cache while offline), toggles
/// must never become a silent no-op and adds must not be lost.
void main() {
  group('repository with unreadable favorites', () {
    late FavoritesHarness h;

    setUp(() {
      h = FavoritesHarness();
      h.cloud.readsUnavailable = true;
    });

    test('toggles surface FavoritesUnavailableException instead of doing nothing', () async {
      await expectLater(
        h.repo.toggleMovieWatched(1),
        throwsA(isA<FavoritesUnavailableException>()),
      );
      await expectLater(
        h.repo.toggleEpisodeWatched(42, 1, 1),
        throwsA(isA<FavoritesUnavailableException>()),
      );
    });

    test('addMovie still saves the favorite (read failure is not "exists")', () async {
      await h.repo.addMovie(id: 1, title: 'M', posterPath: null, overview: '');
      h.cloud.readsUnavailable = false;
      expect(h.cloud.view('user-a')['1-movie'], isA<FavoriteDoc>());
      expect(h.cloud.view('user-a')['1-movie']!.mediaType, MediaType.movie);
    });
  });

  testWidgets('runWrite tells the user when the favorite is unavailable', (tester) async {
    final cloud = FakeCloud()..readsUnavailable = true;
    final auth = FakeAuthRepository(initialUser: kAna);
    await tester.pumpWidget(ProviderScope(
      overrides: cloudOverrides(auth: auth, cloud: cloud),
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              ref.watch(currentUidProvider); // keep the session subscribed, like the app
              return TextButton(
                onPressed: () => runWrite(context, (repo) => repo.toggleMovieWatched(1)),
                child: const Text('marcar'),
              );
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('marcar'));
    await tester.pumpAndSettle();

    expect(find.text(kFavoriteUnavailableMessage), findsOneWidget);
  });
}
