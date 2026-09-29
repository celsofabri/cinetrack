import 'package:hive_flutter/hive_flutter.dart';

import '../models/discovery_cache_entry.dart';
import '../models/favorite_item.dart';
import '../models/search_result.dart';

/// Thin wrapper around the Hive box so the rest of the app never talks
/// to Hive directly (repository is the only caller).
class LocalStore {
  static const _boxName = 'favorites';

  /// Separate box from `favorites` on purpose — different bounded context
  /// (catalog cache vs. user data). A bug or cache clear here must never be
  /// able to touch the user's favorites.
  static const _discoveryBoxName = 'discovery_cache';

  late final Box<dynamic> _box;
  late final Box<dynamic> _discoveryBox;

  Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<dynamic>(_boxName);
    _discoveryBox = await Hive.openBox<dynamic>(_discoveryBoxName);
  }

  List<FavoriteItem> readAll() {
    return _box.values
        .map((raw) => FavoriteItem.fromJson(Map<dynamic, dynamic>.from(raw as Map)))
        .toList();
  }

  Future<void> save(FavoriteItem item) => _box.put(item.storageKey, item.toJson());

  Future<void> delete(String storageKey) => _box.delete(storageKey);

  FavoriteItem? read(String storageKey) {
    final raw = _box.get(storageKey);
    if (raw == null) return null;
    return FavoriteItem.fromJson(Map<dynamic, dynamic>.from(raw as Map));
  }

  /// Fires whenever any favorite is added/updated/removed, so the UI can
  /// react without polling.
  Stream<void> watch() => _box.watch().map((_) {});

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
}
