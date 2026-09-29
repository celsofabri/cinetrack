class EpisodeCache {
  final int episodeNumber;
  final String name;
  final DateTime? airDate;
  final bool watched;

  const EpisodeCache({
    required this.episodeNumber,
    required this.name,
    required this.airDate,
    required this.watched,
  });

  /// Episodes without a known air date are treated as already aired
  /// (TMDB sometimes omits it for older content).
  bool get hasAired => airDate == null || !airDate!.isAfter(DateTime.now());

  EpisodeCache copyWith({bool? watched}) => EpisodeCache(
        episodeNumber: episodeNumber,
        name: name,
        airDate: airDate,
        watched: watched ?? this.watched,
      );

  Map<String, dynamic> toJson() => {
        'episodeNumber': episodeNumber,
        'name': name,
        'airDate': airDate?.toIso8601String(),
        'watched': watched,
      };

  factory EpisodeCache.fromJson(Map<dynamic, dynamic> json) => EpisodeCache(
        episodeNumber: json['episodeNumber'] as int,
        name: json['name'] as String? ?? '',
        airDate:
            json['airDate'] == null ? null : DateTime.tryParse(json['airDate'] as String),
        watched: json['watched'] as bool? ?? false,
      );

  factory EpisodeCache.fromTmdb(Map<String, dynamic> json) {
    final rawAirDate = json['air_date'] as String?;
    return EpisodeCache(
      episodeNumber: json['episode_number'] as int,
      name: json['name'] as String? ?? '',
      airDate: rawAirDate == null ? null : DateTime.tryParse(rawAirDate),
      watched: false,
    );
  }
}
