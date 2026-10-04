import 'episode_cache.dart';

class SeasonCache {
  final int seasonNumber;
  final List<EpisodeCache> episodes;

  const SeasonCache({
    required this.seasonNumber,
    required this.episodes,
  });

  /// Some episode comes from a catalog cached before the image/description
  /// fields existed (docs/45): opening the season downloads it again once.
  bool get needsDetails => episodes.any((e) => !e.detailed);

  SeasonCache copyWithEpisode(EpisodeCache updated) => SeasonCache(
        seasonNumber: seasonNumber,
        episodes: [
          for (final ep in episodes)
            ep.episodeNumber == updated.episodeNumber ? updated : ep,
        ],
      );

  Map<String, dynamic> toJson() => {
        'seasonNumber': seasonNumber,
        'episodes': episodes.map((e) => e.toJson()).toList(),
      };

  factory SeasonCache.fromJson(Map<dynamic, dynamic> json) => SeasonCache(
        seasonNumber: json['seasonNumber'] as int,
        episodes: (json['episodes'] as List)
            .map((e) => EpisodeCache.fromJson(Map<dynamic, dynamic>.from(e as Map)))
            .toList(),
      );

  factory SeasonCache.fromTmdb(Map<String, dynamic> json) => SeasonCache(
        seasonNumber: json['season_number'] as int,
        episodes: (json['episodes'] as List)
            .map((e) => EpisodeCache.fromTmdb(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}
