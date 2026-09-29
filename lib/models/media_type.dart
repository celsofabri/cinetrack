enum MediaType {
  movie,
  tv;

  String get jsonValue => switch (this) {
        MediaType.movie => 'movie',
        MediaType.tv => 'tv',
      };

  static MediaType fromJson(String value) => switch (value) {
        'movie' => MediaType.movie,
        'tv' => MediaType.tv,
        _ => throw ArgumentError('Unknown media type: $value'),
      };

  static MediaType? fromTmdb(String value) => switch (value) {
        'movie' => MediaType.movie,
        'tv' => MediaType.tv,
        _ => null, // e.g. "person" results from /search/multi are ignored
      };
}
