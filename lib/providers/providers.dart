import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/app_user.dart';
import '../account/session_expiry.dart';
import '../auth/auth_failure.dart';
import '../auth/auth_repository.dart';
import '../data/favorites_data_source.dart';
import '../data/firestore_favorites_data_source.dart';
import '../data/sync_status.dart';
import '../models/cast_member.dart';
import '../models/catalog.dart';
import '../models/discovery_category.dart';
import '../models/favorite_doc.dart';
import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/person.dart';
import '../models/search_result.dart';
import '../models/title_details.dart';
import '../models/season_cache.dart';
import '../repositories/discovery_repository.dart';
import '../repositories/favorites_repository.dart';
import '../services/local_store.dart';
import '../services/favorite_status.dart';
import '../services/tmdb_api_client.dart';
import '../services/tmdb_exception.dart';

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

/// Overridden in main() with the Firebase implementation when Firebase is
/// configured. The default keeps the app (and every test) free of Firebase:
/// always signed out, login unavailable.
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return const UnavailableAuthRepository();
});

/// Current session. The first event means "session restored (or none)";
/// the splash waits for it so the signed-out UI never flashes.
final authStateProvider = StreamProvider<AppUser?>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges();
});

final currentUserProvider = Provider<AppUser?>((ref) {
  return ref.watch(authStateProvider).valueOrNull;
});

/// Only the uid: profile-field changes (name/photo) must not rebuild the
/// data layer.
final currentUidProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider.select((state) => state.valueOrNull?.uid));
});

/// Where data sources report writes the server rejected after the UI moved
/// on. One per signed-in account (recreated with the uid, so failures of a
/// previous account never reach the next one).
final syncFailureSinkProvider = Provider<SyncFailureSink>((ref) {
  ref.watch(currentUidProvider);
  final sink = SyncFailureSink();
  ref.onDispose(sink.dispose);
  return sink;
});

typedef FavoritesDataSourceFactory = FavoritesDataSource Function(String uid);

/// Builds the cloud data source for a uid. Overridden in tests with fakes.
final favoritesDataSourceFactoryProvider = Provider<FavoritesDataSourceFactory>((ref) {
  final sink = ref.watch(syncFailureSinkProvider);
  return (uid) => FirestoreFavoritesDataSource(uid: uid, sink: sink);
});

/// The single door to the user's data. Depends on the uid, so it is
/// DISPOSED AND RECREATED when the account changes (dropping listeners and
/// in-memory state of the previous account); signed out = empty source.
final favoritesDataSourceProvider = Provider<FavoritesDataSource>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return const SignedOutFavoritesDataSource();
  return ref.watch(favoritesDataSourceFactoryProvider)(uid);
});

/// Clock of the catalog TTL refresh. Overridden in tests.
final catalogClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Coalescing window of catalog re-emissions (see `FavoritesRepository`).
final catalogDebounceProvider = Provider<Duration>((ref) => const Duration(milliseconds: 300));

final favoritesRepositoryProvider = Provider<FavoritesRepository>((ref) {
  return FavoritesRepository(
    now: ref.watch(catalogClockProvider),
    catalogDebounce: ref.watch(catalogDebounceProvider),
    api: ref.watch(tmdbApiClientProvider),
    store: ref.watch(localStoreProvider),
    dataSource: ref.watch(favoritesDataSourceProvider),
  );
});

/// A write the user attempted while signed out, replayed once login
/// succeeds (and dropped if it fails or is cancelled). Memory only: the web
/// login popup keeps the page alive.
class PendingIntent {
  final Future<void> Function(FavoritesRepository repo) run;

  const PendingIntent(this.run);
}

final pendingIntentProvider = StateProvider<PendingIntent?>((ref) => null);

class AuthActionState {
  final bool signingIn;

  const AuthActionState({this.signingIn = false});
}

/// Login/logout actions with an in-progress flag (the button disables on it,
/// so a double tap never opens a second attempt).
class AuthController extends Notifier<AuthActionState> {
  @override
  AuthActionState build() => const AuthActionState();

  /// Returns null on success (or when ignored because a login is already
  /// running), the [AuthFailure] otherwise. A failure also drops the
  /// pending intent: nothing is saved if login did not happen.
  Future<AuthFailure?> signIn() async {
    if (state.signingIn) return null;
    state = const AuthActionState(signingIn: true);
    try {
      // No await before this call: web needs the popup opened in the tap.
      await ref.read(authRepositoryProvider).signInWithGoogle();
      return null;
    } on AuthFailure catch (failure) {
      ref.read(pendingIntentProvider.notifier).state = null;
      return failure;
    } catch (_) {
      ref.read(pendingIntentProvider.notifier).state = null;
      return const AuthFailure(AuthFailureKind.unknown);
    } finally {
      state = const AuthActionState();
    }
  }

  Future<void> signOut() async {
    ref.read(pendingIntentProvider.notifier).state = null;
    ref.read(sessionExpiryProvider.notifier).expectSignOut();
    await ref.read(authRepositoryProvider).signOut();
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthActionState>(AuthController.new);

/// Raw documents (cloud shape): the profile statistics need the watched
/// flags even for seasons whose catalog is not cached on this device.
final favoriteDocsProvider = StreamProvider<List<FavoriteDoc>>((ref) {
  return ref.watch(favoritesRepositoryProvider).watchDocs();
});

final favoritesListProvider = StreamProvider<List<FavoriteItem>>((ref) {
  return ref.watch(favoritesRepositoryProvider).watchAll();
});

final searchResultsProvider = FutureProvider.family<List<SearchResult>, String>((ref, query) {
  return ref.watch(tmdbApiClientProvider).searchMulti(query);
});

typedef SeasonKey = ({int tvId, int seasonNumber});

final seasonProvider = FutureProvider.family<SeasonCache, SeasonKey>((ref, key) {
  return ref.watch(favoritesRepositoryProvider).loadSeason(key.tvId, key.seasonNumber);
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
  // Started and not yet caught up. A series whose seasons are still being
  // downloaded (new device) has no known progress and is left out until the
  // catalog reconciliation fills it (docs/18).
  return [
    for (final item in favorites)
      if (FavoriteStatus.of(item).state == WatchState.inProgress) item,
  ]..sort(FavoriteItem.byRecentActivity);
});

/// Genre list per media type for the catalog filter (rarely changes, so it
/// stays cached for the session).
final genresProvider = FutureProvider.family<List<Genre>, MediaType>((ref, type) {
  return ref.watch(tmdbApiClientProvider).getGenres(type);
});

typedef TitleKey = ({int id, MediaType type});

/// TMDB details of a title, for the details screens when it is not (yet)
/// favorited. Auto-disposed so reopening the screen refetches after an error.
final titleDetailsProvider =
    FutureProvider.autoDispose.family<TitleDetails, TitleKey>((ref, key) async {
  final api = ref.watch(tmdbApiClientProvider);
  final json = key.type == MediaType.movie
      ? await api.getMovieDetails(key.id)
      : await api.getTvDetails(key.id);
  return TitleDetails.fromTmdb(json, key.type);
});

/// Keeps a successful result for the whole session (back navigation and
/// reopening reuse it without a TMDB call); a failure is dropped at once so
/// the next read, or "Tentar novamente", asks again.
Future<T> _cacheOnSuccess<T>(Ref ref, Future<T> Function() load) async {
  final link = ref.keepAlive();
  try {
    return await load();
  } catch (_) {
    link.close();
    rethrow;
  }
}

/// Cast of a movie/show (docs/19): one call, session cache, independent of
/// the title details so a failure never blocks the rest of the screen.
final titleCastProvider = FutureProvider.autoDispose.family<List<CastMember>, TitleKey>((ref, key) {
  final api = ref.watch(tmdbApiClientProvider);
  return _cacheOnSuccess(ref, () => api.getTitleCast(key.type, key.id));
});

/// A person: pt-BR first; when the biography is empty, one more call in
/// English. A missing English version means "no biography"; any other
/// failure of that call is an error (never cached as an empty biography).
final personProvider = FutureProvider.autoDispose.family<PersonProfile, int>((ref, id) {
  final api = ref.watch(tmdbApiClientProvider);
  return _cacheOnSuccess(ref, () async {
    final json = await api.getPerson(id);
    // Same adult filter as the credits: such a profile is not shown.
    if (json['adult'] == true) throw TmdbException.notFound();
    String? fallback;
    if (((json['biography'] as String?) ?? '').trim().isEmpty) {
      try {
        final en = await api.getPerson(id, language: 'en-US');
        fallback = en['biography'] as String?;
      } on TmdbException catch (e) {
        // "No English version" is a real answer (cached); a network/429/5xx
        // failure is not, so it surfaces as an error the user can retry.
        if (e.type != TmdbErrorType.notFound) rethrow;
      }
    }
    return PersonProfile.fromTmdb({...json, 'id': id}, fallbackBiography: fallback);
  });
});

/// Filmography of a person, fetched apart from [personProvider] so a failure
/// here leaves the profile visible.
final personFilmographyProvider = FutureProvider.autoDispose.family<Filmography, int>((ref, id) {
  final api = ref.watch(tmdbApiClientProvider);
  return _cacheOnSuccess(ref, () async => Filmography.fromCredits(await api.getPersonCredits(id)));
});
