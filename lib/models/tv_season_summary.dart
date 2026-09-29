/// Lightweight season metadata from `/tv/{id}` — enough to render the
/// season list before we lazily fetch each season's episodes.
class TvSeasonSummary {
  final int seasonNumber;
  final String name;
  final int episodeCount;

  const TvSeasonSummary({
    required this.seasonNumber,
    required this.name,
    required this.episodeCount,
  });

  factory TvSeasonSummary.fromTmdb(Map<String, dynamic> json) => TvSeasonSummary(
        seasonNumber: json['season_number'] as int,
        name: json['name'] as String? ?? 'Temporada ${json['season_number']}',
        episodeCount: json['episode_count'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'seasonNumber': seasonNumber,
        'name': name,
        'episodeCount': episodeCount,
      };

  factory TvSeasonSummary.fromJson(Map<dynamic, dynamic> json) => TvSeasonSummary(
        seasonNumber: json['seasonNumber'] as int,
        name: json['name'] as String? ?? '',
        episodeCount: json['episodeCount'] as int? ?? 0,
      );

  static List<TvSeasonSummary> listFromTvDetails(Map<String, dynamic> tvDetailsJson) {
    final seasons = tvDetailsJson['seasons'] as List? ?? [];
    return seasons
        .cast<Map<String, dynamic>>()
        .map(TvSeasonSummary.fromTmdb)
        .where((s) => s.episodeCount > 0)
        .toList()
      ..sort((a, b) {
        if (a.seasonNumber == 0) return 1;
        if (b.seasonNumber == 0) return -1;
        return a.seasonNumber.compareTo(b.seasonNumber);
      });
  }
}
