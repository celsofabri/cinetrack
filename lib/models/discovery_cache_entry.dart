import 'search_result.dart';

/// A cached discovery section (e.g. "trending", "novelties",
/// "category:Terror") plus when it was fetched — the single source of
/// truth `DiscoveryRepository` consults to decide "is this still valid?".
/// No provider is allowed to make that call on its own (see
/// docs/adr/adr-002-cache-descoberta-ttl.md).
class DiscoveryCacheEntry {
  final List<SearchResult> items;
  final DateTime fetchedAt;

  const DiscoveryCacheEntry({required this.items, required this.fetchedAt});

  Map<String, dynamic> toJson() => {
        'items': items.map((i) => i.toJson()).toList(),
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory DiscoveryCacheEntry.fromJson(Map<dynamic, dynamic> json) => DiscoveryCacheEntry(
        items: (json['items'] as List? ?? [])
            .map((i) => SearchResult.fromJson(Map<dynamic, dynamic>.from(i as Map)))
            .toList(),
        fetchedAt: DateTime.tryParse(json['fetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
