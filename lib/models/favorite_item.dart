import 'media_type.dart';
import 'search_result.dart';
import 'season_cache.dart';
import 'tv_season_summary.dart';

/// A movie or TV show the user has favorited, plus whatever progress
/// (watched flags) and catalog data (poster, seasons/episodes) we've
/// cached locally so it keeps working offline.
class FavoriteItem {
  final int id;
  final MediaType mediaType;
  final String title;
  final String? posterPath;
  final String overview;
  final DateTime addedAt;
  final bool watchedMovie;
  final List<SeasonCache>? seasons;

  /// Season names/episode counts from `/tv/{id}`, fetched once when the
  /// show is favorited so the season list renders offline even before
  /// any individual season's episodes have been loaded.
  final List<TvSeasonSummary>? seasonSummaries;

  /// Last time an episode was marked/unmarked as watched for this show —
  /// drives "Continue assistindo" ordering. Null means either this is a
  /// movie, or a TV show that predates this field (added before this
  /// version) and hasn't had a toggle since; callers fall back to
  /// [addedAt] in that case.
  final DateTime? lastWatchedAt;

  /// "Recomendo" mark (Minhas recomendações). Absent in older data = false.
  /// Never changes the ordering ([lastActivityAt] ignores it).
  final bool recommended;

  const FavoriteItem({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.posterPath,
    required this.overview,
    required this.addedAt,
    this.watchedMovie = false,
    this.seasons,
    this.seasonSummaries,
    this.lastWatchedAt,
    this.recommended = false,
  });

  /// Most recent interaction with this title: the last time something was
  /// marked/unmarked as watched, or when it was favorited if that is more
  /// recent or there was no watch yet. Orders "Meus favoritos" and "Continue
  /// assistindo". Never null, so a pending server timestamp (read as null
  /// before the server acknowledges it) cannot sink the item.
  DateTime get lastActivityAt {
    final watched = lastWatchedAt;
    return watched != null && watched.isAfter(addedAt) ? watched : addedAt;
  }

  /// Most recent activity first; ties broken by newest favorite, then title.
  static int byRecentActivity(FavoriteItem a, FavoriteItem b) {
    final byActivity = b.lastActivityAt.compareTo(a.lastActivityAt);
    if (byActivity != 0) return byActivity;
    final byAdded = b.addedAt.compareTo(a.addedAt);
    if (byAdded != 0) return byAdded;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }

  /// The catalog-result shape of this title (what the write helpers take).
  SearchResult toSearchResult() => SearchResult(
        id: id,
        mediaType: mediaType,
        title: title,
        posterPath: posterPath,
        overview: overview,
      );

  /// Composite key used in local storage — avoids collisions between a
  /// movie and a TV show that happen to share the same TMDB numeric id.
  String get storageKey => '$id-${mediaType.jsonValue}';

  FavoriteItem copyWith({
    bool? watchedMovie,
    List<SeasonCache>? seasons,
    List<TvSeasonSummary>? seasonSummaries,
    DateTime? lastWatchedAt,
    bool? recommended,
  }) =>
      FavoriteItem(
        id: id,
        mediaType: mediaType,
        title: title,
        posterPath: posterPath,
        overview: overview,
        addedAt: addedAt,
        watchedMovie: watchedMovie ?? this.watchedMovie,
        seasons: seasons ?? this.seasons,
        seasonSummaries: seasonSummaries ?? this.seasonSummaries,
        lastWatchedAt: lastWatchedAt ?? this.lastWatchedAt,
        recommended: recommended ?? this.recommended,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'mediaType': mediaType.jsonValue,
        'title': title,
        'posterPath': posterPath,
        'overview': overview,
        'addedAt': addedAt.toIso8601String(),
        'watchedMovie': watchedMovie,
        'seasons': seasons?.map((s) => s.toJson()).toList(),
        'seasonSummaries': seasonSummaries?.map((s) => s.toJson()).toList(),
        'lastWatchedAt': lastWatchedAt?.toIso8601String(),
        if (recommended) 'recommended': true,
      };

  factory FavoriteItem.fromJson(Map<dynamic, dynamic> json) => FavoriteItem(
        id: json['id'] as int,
        mediaType: MediaType.fromJson(json['mediaType'] as String),
        title: json['title'] as String? ?? '',
        posterPath: json['posterPath'] as String?,
        overview: json['overview'] as String? ?? '',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
        watchedMovie: json['watchedMovie'] as bool? ?? false,
        seasons: (json['seasons'] as List?)
            ?.map((s) => SeasonCache.fromJson(Map<dynamic, dynamic>.from(s as Map)))
            .toList(),
        seasonSummaries: (json['seasonSummaries'] as List?)
            ?.map((s) => TvSeasonSummary.fromJson(Map<dynamic, dynamic>.from(s as Map)))
            .toList(),
        // null-safe: absent key (records saved before this field existed)
        // parses to null via DateTime.tryParse(null ?? '') — never throws.
        lastWatchedAt: DateTime.tryParse(json['lastWatchedAt'] as String? ?? ''),
        recommended: json['recommended'] == true,
      );
}
