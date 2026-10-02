import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';

import 'fake_auth_repository.dart';
import 'favorites_harness.dart';
import 'in_memory_favorites_data_source.dart';

/// Provider overrides wiring the real providers to fakes: fake auth, an
/// in-memory "cloud" shared by all uids, in-memory season catalog and a
/// fake TMDB client. No Firebase, no network.
List<Override> cloudOverrides({
  required FakeAuthRepository auth,
  required FakeCloud cloud,
  FakeLocalStore? store,
  FakeTmdbApiClient? api,
  List<String>? createdFor,
  Duration grace = Duration.zero,
  Duration stall = Duration.zero,
}) {
  return [
    authRepositoryProvider.overrideWithValue(auth),
    syncGraceProvider.overrideWithValue(grace),
    syncStallProvider.overrideWithValue(stall),
    favoritesDataSourceFactoryProvider.overrideWithValue((uid) {
      createdFor?.add(uid);
      return InMemoryFavoritesDataSource(cloud, uid: uid);
    }),
    profileDataSourceFactoryProvider
        .overrideWithValue((uid) => InMemoryProfileDataSource(cloud, uid: uid)),
    localStoreProvider.overrideWithValue(store ?? FakeLocalStore()),
    tmdbApiKeyProvider.overrideWithValue('test'),
    tmdbApiClientProvider.overrideWithValue(api ?? FakeTmdbApiClient()),
  ];
}
