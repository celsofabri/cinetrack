import 'search_result.dart';

/// A TMDB genre. Movies and TV have separate taxonomies (different ids,
/// and some genres exist for only one type), so a list is always per type.
class Genre {
  final int id;
  final String name;

  const Genre({required this.id, required this.name});

  factory Genre.fromTmdb(Map<String, dynamic> json) =>
      Genre(id: json['id'] as int, name: json['name'] as String);
}

/// One page of `/discover/{movie,tv}`.
class DiscoverPage {
  final List<SearchResult> results;
  final int page;
  final int totalPages;

  const DiscoverPage({
    required this.results,
    required this.page,
    required this.totalPages,
  });

  /// TMDB serves at most 500 pages per query, whatever `total_pages` says.
  bool get hasMore => page < totalPages && page < 500;
}
