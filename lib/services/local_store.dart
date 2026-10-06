import 'package:hive_flutter/hive_flutter.dart';

import '../models/discovery_cache_entry.dart';
import '../models/search_result.dart';
import '../models/season_cache.dart';
import 'favorite_mapper.dart';

/// Thin wrapper around the Hive boxes so the rest of the app never talks
/// to Hive directly (repositories are the only callers).
///
/// Holds only NON-personal caches: the TMDB discovery cache and the season
/// catalog. The user's favorites/progress live in the cloud (see
/// `FavoritesDataSource`); the legacy `favorites` box is deliberately no
/// longer opened — its bytes stay on disk untouched (rollback of the app
/// shows the old data again).
class LocalStore {
  /// Catalog cache (episodes + air dates per show). Never stores `watched`
  /// flags, so it can be shared by every account on the device.
  static const _seasonCatalogBoxName = 'season_catalog';

  static const _discoveryBoxName = 'discovery_cache';

  late final Box<dynamic> _seasonCatalogBox;
  late final Box<dynamic> _discoveryBox;

  Future<void> init() async {
    await Hive.initFlutter();
    _seasonCatalogBox = await Hive.openBox<dynamic>(_seasonCatalogBoxName);
    _discoveryBox = await Hive.openBox<dynamic>(_discoveryBoxName);
  }

  /// Cached seasons of [tvId] (episodes and dates only, `watched` always
  /// false). Empty when nothing was cached yet.
  List<SeasonCache> readSeasonCatalog(int tvId) {
    final raw = _seasonCatalogBox.get('$tvId');
    if (raw == null) return const [];
    return [
      for (final season in raw as List)
        SeasonCache.fromJson(Map<dynamic, dynamic>.from(season as Map)),
    ];
  }

  /// Adds/replaces one season in the catalog of [tvId], stripping any
  /// `watched` flag first.
  Future<void> saveCatalogSeason(int tvId, SeasonCache season) {
    final seasons = [
      for (final s in readSeasonCatalog(tvId))
        if (s.seasonNumber != season.seasonNumber) s,
      FavoriteMapper.stripWatched(season),
    ];
    return _seasonCatalogBox.put('$tvId', seasons.map((s) => s.toJson()).toList());
  }

  /// Runtime (minutes) of a movie / typical episode runtime of a show
  /// (`episode_run_time`, fallback when an episode has none). Same box, keys
  /// that cannot collide with the show ids used by the catalog.
  int? readMovieRuntime(int id) => _seasonCatalogBox.get('rt:movie:$id') as int?;
  Future<void> saveMovieRuntime(int id, int minutes) =>
      _seasonCatalogBox.put('rt:movie:$id', minutes);
  int? readTvFallbackRuntime(int id) => _seasonCatalogBox.get('rt:tv:$id') as int?;
  Future<void> saveTvFallbackRuntime(int id, int minutes) =>
      _seasonCatalogBox.put('rt:tv:$id', minutes);

  /// When the catalog of [tvId] was last checked against TMDB (drives the
  /// TTL refresh of shows still airing).
  DateTime? readCatalogFetchedAt(int tvId) {
    final raw = _seasonCatalogBox.get('ts:$tvId');
    return raw is String ? DateTime.tryParse(raw) : null;
  }

  Future<void> saveCatalogFetchedAt(int tvId, DateTime at) =>
      _seasonCatalogBox.put('ts:$tvId', at.toIso8601String());

  /// Fires whenever the season catalog changes, so hydrated favorites can
  /// be re-emitted.
  Stream<void> watchSeasonCatalog() => _seasonCatalogBox.watch().map((_) {});

  /// Reads a discovery cache entry (e.g. 'trending', 'novelties',
  /// 'category:Terror') without any opinion on whether it's still valid —
  /// that decision belongs entirely to `DiscoveryRepository`.
  DiscoveryCacheEntry? readDiscoveryCache(String key) {
    final raw = _discoveryBox.get(key);
    if (raw == null) return null;
    return DiscoveryCacheEntry.fromJson(Map<dynamic, dynamic>.from(raw as Map));
  }

  Future<void> saveDiscoveryCache(String key, List<SearchResult> items) => _discoveryBox.put(
        key,
        DiscoveryCacheEntry(items: items, fetchedAt: DateTime.now()).toJson(),
      );

  static const _purgeFlagKey = '_purge_firestore_cache';

  /// True when an account deletion asked for the Firestore local database to
  /// be wiped at the next start.
  bool get firestoreCachePurgePending => _discoveryBox.get(_purgeFlagKey) == true;

  Future<void> markFirestoreCachePurge() => _discoveryBox.put(_purgeFlagKey, true);

  Future<void> clearFirestoreCachePurgeFlag() => _discoveryBox.delete(_purgeFlagKey);

  /// Friendships were turned off on this device but the final cleanup sweep
  /// (friends, requests, blocks) did not finish. Per device and per uid; it
  /// only drives the "Concluir limpeza" offer (account deletion always sweeps).
  bool socialCleanupPending(String uid) => _discoveryBox.get('socialCleanup:$uid') == true;

  Future<void> setSocialCleanupPending(String uid, bool pending) => pending
      ? _discoveryBox.put('socialCleanup:$uid', true)
      : _discoveryBox.delete('socialCleanup:$uid');

  /// The nickname / photo of [uid] changed and the copies kept in the
  /// friendships (D8) were not all refreshed yet: drives the resume of the
  /// refresh (docs/68). Per device and per uid; a boolean, no personal data.
  bool socialRefreshPending(String uid) => _discoveryBox.get('socialRefresh:$uid') == true;

  Future<void> setSocialRefreshPending(String uid, bool pending) => pending
      ? _discoveryBox.put('socialRefresh:$uid', true)
      : _discoveryBox.delete('socialRefresh:$uid');

  /// Last answer the server gave about "friendships on?" for [uid] and when
  /// (docs/59): lets the Amigos icon appear without reading the server on
  /// every session. A boolean per uid, no personal data. Null = never known.
  ({bool active, DateTime at})? socialHint(String uid) {
    final raw = _discoveryBox.get('socialHint:$uid');
    if (raw is! String) return null;
    final parts = raw.split(':');
    final ms = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (ms == null || (parts[0] != 'a' && parts[0] != 'n')) return null;
    return (active: parts[0] == 'a', at: DateTime.fromMillisecondsSinceEpoch(ms));
  }

  Future<void> setSocialHint(String uid, bool? active, {DateTime? at}) => active == null
      ? _discoveryBox.delete('socialHint:$uid')
      : _discoveryBox.put(
          'socialHint:$uid',
          '${active ? 'a' : 'n'}:${(at ?? DateTime.now()).millisecondsSinceEpoch}',
        );
}
