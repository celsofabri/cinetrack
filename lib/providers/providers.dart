import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/catalog.dart';
import '../models/discovery_category.dart';
import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/search_result.dart';
import '../models/season_cache.dart';
import '../repositories/discovery_repository.dart';
import '../repositories/favorites_repository.dart';
import '../services/local_store.dart';
import '../services/progress_calculator.dart';
import '../services/tmdb_api_client.dart';

/// Overridden in main() with the instance created (and initialized)
/// before runApp, since opening the Hive box is async.
final localStoreProvider = Provider<LocalStore>((ref) {
  throw UnimplementedError('localStoreProvider must be overridden in main()');
});

/// Overridden in main() once the TMDB_API_KEY has been read from .env.
final tmdbApiKeyProvider = Provider<String>((ref) {
  throw UnimplementedError('tmdbApiKeyProvider must be overridden in main()');
});

final tmdbApiClientProvider = Provider<TmdbApiClient>((ref) {
  final client = TmdbApiClient(apiKey: ref.watch(tmdbApiKeyProvider));
  ref.onDispose(client.dispose);
  return client;
});

final favoritesRepositoryProvider = Provider<FavoritesRepository>((ref) {
  return FavoritesRepository(
    api: ref.watch(tmdbApiClientProvider),
    store: ref.watch(localStoreProvider),
  );
});

final favoritesListProvider = StreamProvider<List<FavoriteItem>>((ref) {
  return ref.watch(favoritesRepositoryProvider).watchAll();
});

final searchResultsProvider =
    FutureProvider.family<List<SearchResult>, String>((ref, query) {
  return ref.watch(tmdbApiClientProvider).searchMulti(query);
});

typedef SeasonKey = ({int tvId, int seasonNumber});

final seasonProvider = FutureProvider.family<SeasonCache, SeasonKey>((ref, key) {
  return ref
      .watch(favoritesRepositoryProvider)
      .loadSeason(key.tvId, key.seasonNumber);
});

final discoveryRepositoryProvider = Provider<DiscoveryRepository>((ref) {
  return DiscoveryRepository(
    api: ref.watch(tmdbApiClientProvider),
    store: ref.watch(localStoreProvider),
  );
});

final trendingProvider = FutureProvider<List<SearchResult>>((ref) {
  return ref.watch(discoveryRepositoryProvider).getTrending();
});

final noveltiesProvider = FutureProvider<List<SearchResult>>((ref) {
  return ref.watch(discoveryRepositoryProvider).getNovelties();
});

final categoryProvider =
    FutureProvider.family<List<SearchResult>, DiscoveryCategory>((ref, category) {
  return ref.watch(discoveryRepositoryProvider).getCategory(category);
});

/// Pure derivation over `favoritesListProvider` — no network call, no cache
/// of its own, no state to desync: recomputes whenever the favorites Hive
/// box changes (the existing Stream already handles that). Zero surface
/// for the `seasonProvider` class of bug.
final continueWatchingProvider = Provider<List<FavoriteItem>>((ref) {
  final favorites = ref.watch(favoritesListProvider).valueOrNull ?? const [];
  final inProgress = favorites.where((item) {
    if (item.mediaType != MediaType.tv) return false;
    final progress = ProgressCalculator.compute(item.seasons ?? const []);
    return progress.isStarted && !progress.isCompleted;
  }).toList()
    ..sort((a, b) => (b.lastWatchedAt ?? b.addedAt).compareTo(a.lastWatchedAt ?? a.addedAt));
  return inProgress;
});

/// Genre list per media type for the catalog filter (rarely changes, so it
/// stays cached for the session).
final genresProvider = FutureProvider.family<List<Genre>, MediaType>((ref, type) {
  return ref.watch(tmdbApiClientProvider).getGenres(type);
});
