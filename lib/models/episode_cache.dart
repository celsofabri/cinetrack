class EpisodeCache {
  final int episodeNumber;
  final String name;
  final DateTime? airDate;
  final bool watched;

  /// Runtime in minutes from TMDB, when known (local catalog only; used by
  /// the "Tempo assistido" statistic). Null/absent in catalogs cached before
  /// this field existed.
  final int? runtime;

  const EpisodeCache({
    required this.episodeNumber,
    required this.name,
    required this.airDate,
    required this.watched,
    this.runtime,
  });

  /// Episodes without a known air date are treated as already aired
  /// (TMDB sometimes omits it for older content).
  bool get hasAired => airDate == null || !airDate!.isAfter(DateTime.now());

  EpisodeCache copyWith({bool? watched}) => EpisodeCache(
        episodeNumber: episodeNumber,
        name: name,
        airDate: airDate,
        watched: watched ?? this.watched,
        runtime: runtime,
      );

  Map<String, dynamic> toJson() => {
        'episodeNumber': episodeNumber,
        'name': name,
        'airDate': airDate?.toIso8601String(),
        'watched': watched,
        'runtime': runtime,
      };

  factory EpisodeCache.fromJson(Map<dynamic, dynamic> json) => EpisodeCache(
        episodeNumber: json['episodeNumber'] as int,
        name: json['name'] as String? ?? '',
        airDate: json['airDate'] == null ? null : DateTime.tryParse(json['airDate'] as String),
        watched: json['watched'] as bool? ?? false,
        runtime: json['runtime'] as int?,
      );

  factory EpisodeCache.fromTmdb(Map<String, dynamic> json) {
    final rawAirDate = json['air_date'] as String?;
    return EpisodeCache(
      episodeNumber: json['episode_number'] as int,
      name: json['name'] as String? ?? '',
      airDate: rawAirDate == null ? null : DateTime.tryParse(rawAirDate),
      watched: false,
      runtime: switch (json['runtime']) {
        final int m when m > 0 => m,
        _ => null,
      },
    );
  }
}
