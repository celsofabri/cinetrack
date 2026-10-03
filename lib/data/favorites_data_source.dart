import '../models/favorite_doc.dart';
import '../models/tv_season_summary.dart';
import 'sync_status.dart';

/// Thrown by write operations when nobody is signed in. The UI reacts by
/// starting the login flow (and replaying the action afterwards).
class AuthRequiredException implements Exception {
  const AuthRequiredException();

  @override
  String toString() => 'AuthRequiredException: sign in to save your data';
}

/// Thrown by [FavoritesDataSource.get] when the document can be neither read
/// from the local cache nor from the server (e.g. cold cache while offline).
/// "Unknown" is different from "does not exist": callers must not treat it as
/// a missing favorite when that would silently drop the user's action.
class FavoritesUnavailableException implements Exception {
  const FavoritesUnavailableException();

  @override
  String toString() => 'FavoritesUnavailableException: favorite could not be read right now';
}

/// Storage seam for the signed-in user's favorites. `FavoritesRepository`
/// depends only on this interface; implementations: Firestore (production),
/// signed-out (empty) and an in-memory fake (tests).
///
/// Writes are *intent based* (one field path each), never a rewrite of the
/// whole object, so concurrent edits from two devices merge per field.
/// Implementations must not block on server acknowledgement (offline
/// writes are queued by the backend) — a returned Future means "accepted
/// locally".
abstract class FavoritesDataSource {
  /// Emits the full list now and after every change.
  Stream<List<FavoriteDoc>> watchAll();

  /// Relation to the server (pending writes / data from cache). Never emits
  /// errors: failures of the main stream are reported through the
  /// `SyncFailureSink` the implementation was given.
  Stream<SyncMeta> watchSyncMeta();

  /// Returns null when the favorite does not exist. Throws
  /// [FavoritesUnavailableException] when that cannot be determined.
  Future<FavoriteDoc?> get(String key);

  /// Creates the favorite. Callers check [get] first (idempotent add).
  Future<void> add(FavoriteDoc doc);

  Future<void> remove(String key);

  /// Marks/unmarks a movie and stamps `lastWatchedAt` (recent-activity order).
  Future<void> setWatchedMovie(String key, bool watched);

  /// Applies per-episode changes (`true` = watched, `false` = unwatched) as
  /// field-level updates and stamps `lastWatchedAt`. An empty map only
  /// stamps `lastWatchedAt`.
  Future<void> setEpisodes(String key, Map<String, bool> changes);

  Future<void> setSeasonSummaries(String key, List<TvSeasonSummary> summaries);
}

/// Data source used while nobody is signed in (or cloud sync is off):
/// reads are empty and every write asks for login. Never exposes any
/// user's data — this is the "deslogado = vazio" isolation layer.
class SignedOutFavoritesDataSource implements FavoritesDataSource {
  const SignedOutFavoritesDataSource();

  @override
  Stream<List<FavoriteDoc>> watchAll() => Stream.value(const <FavoriteDoc>[]);

  @override
  Stream<SyncMeta> watchSyncMeta() => Stream.value(SyncMeta.settled);

  @override
  Future<FavoriteDoc?> get(String key) async => null;

  @override
  Future<void> add(FavoriteDoc doc) => Future.error(const AuthRequiredException());

  @override
  Future<void> remove(String key) => Future.error(const AuthRequiredException());

  @override
  Future<void> setWatchedMovie(String key, bool watched) =>
      Future.error(const AuthRequiredException());

  @override
  Future<void> setEpisodes(String key, Map<String, bool> changes) =>
      Future.error(const AuthRequiredException());

  @override
  Future<void> setSeasonSummaries(String key, List<TvSeasonSummary> summaries) =>
      Future.error(const AuthRequiredException());
}
