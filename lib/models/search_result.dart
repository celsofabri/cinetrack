import 'media_type.dart';

/// A single row from TMDB's /search/multi, before the user decides to
/// favorite it (so it doesn't carry watched-progress fields yet).
class SearchResult {
  final int id;
  final MediaType mediaType;
  final String title;
  final String? posterPath;
  final String overview;

  const SearchResult({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.posterPath,
    required this.overview,
  });

  /// Composite key used to match against favorites — avoids collisions
  /// between a movie and a TV show that happen to share the same TMDB id.
  String get storageKey => '$id-${mediaType.jsonValue}';

  /// Returns null for result types we don't support (e.g. "person").
  static SearchResult? fromTmdb(Map<String, dynamic> json) {
    final mediaType = MediaType.fromTmdb(json['media_type'] as String? ?? '');
    if (mediaType == null) return null;

    final title = mediaType == MediaType.movie
        ? json['title'] as String?
        : json['name'] as String?;
    if (title == null) return null;

    return SearchResult(
      id: json['id'] as int,
      mediaType: mediaType,
      title: title,
      posterPath: json['poster_path'] as String?,
      overview: json['overview'] as String? ?? '',
    );
  }

  /// For endpoints that don't return `media_type` in the payload (the type
  /// is already known from which endpoint was called), unlike `/search/multi`
  /// or `/trending/*` which do.
  factory SearchResult.fromTmdbTyped(Map<String, dynamic> json, MediaType mediaType) {
    final title =
        mediaType == MediaType.movie ? json['title'] as String? : json['name'] as String?;
    return SearchResult(
      id: json['id'] as int,
      mediaType: mediaType,
      title: title ?? '',
      posterPath: json['poster_path'] as String?,
      overview: json['overview'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'mediaType': mediaType.jsonValue,
        'title': title,
        'posterPath': posterPath,
        'overview': overview,
      };

  factory SearchResult.fromJson(Map<dynamic, dynamic> json) => SearchResult(
        id: json['id'] as int,
        mediaType: MediaType.fromJson(json['mediaType'] as String),
        title: json['title'] as String? ?? '',
        posterPath: json['posterPath'] as String?,
        overview: json['overview'] as String? ?? '',
      );
}
