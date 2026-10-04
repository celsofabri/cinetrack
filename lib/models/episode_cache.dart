class EpisodeCache {
  final int episodeNumber;
  final String name;
  final DateTime? airDate;
  final bool watched;

  /// Runtime in minutes from TMDB, when known (local catalog only; used by
  /// the "Tempo assistido" statistic). Null/absent in catalogs cached before
  /// this field existed.
  final int? runtime;

  /// TMDB `still_path` (episode image), when TMDB has one. Optional: catalogs
  /// cached before the episode layout (docs/45) do not have it.
  final String? stillPath;

  /// TMDB `overview` of the episode ('' when it has none or in old catalogs).
  final String overview;

  /// True when this episode came from a TMDB season response that carried the
  /// image/description fields. False for old cached catalogs, which is how a
  /// season is recognized as needing a one-time re-download (a legitimately
  /// empty `overview` / missing still cannot tell old from new).
  final bool detailed;

  const EpisodeCache({
    required this.episodeNumber,
    required this.name,
    required this.airDate,
    required this.watched,
    this.runtime,
    this.stillPath,
    this.overview = '',
    this.detailed = false,
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
        stillPath: stillPath,
        overview: overview,
        detailed: detailed,
      );

  Map<String, dynamic> toJson() => {
        'episodeNumber': episodeNumber,
        'name': name,
        'airDate': airDate?.toIso8601String(),
        'watched': watched,
        'runtime': runtime,
        // Written only when present, so a catalog that was never enriched is
        // stored exactly as before.
        if (stillPath != null) 'stillPath': stillPath,
        if (overview.isNotEmpty) 'overview': overview,
        if (detailed) 'detailed': true,
      };

  factory EpisodeCache.fromJson(Map<dynamic, dynamic> json) => EpisodeCache(
        episodeNumber: json['episodeNumber'] as int,
        name: json['name'] as String? ?? '',
        airDate: json['airDate'] == null ? null : DateTime.tryParse(json['airDate'] as String),
        watched: json['watched'] as bool? ?? false,
        runtime: json['runtime'] as int?,
        stillPath: json['stillPath'] as String?,
        overview: json['overview'] as String? ?? '',
        detailed: json['detailed'] == true,
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
      stillPath: switch (json['still_path']) {
        final String p when p.isNotEmpty => p,
        _ => null,
      },
      overview: json['overview'] as String? ?? '',
      detailed: true,
    );
  }
}
