import 'media_type.dart';
import 'tv_season_summary.dart';

/// What is persisted per favorite in the user's cloud space
/// (`users/{uid}/favorites/{key}`): the favorite itself plus its progress
/// flags. Catalog data (episode names, air dates) is NOT here — it is
/// re-downloadable from TMDB and lives in the local `season_catalog` cache.
class FavoriteDoc {
  final int id;
  final MediaType mediaType;
  final String title;
  final String? posterPath;
  final String overview;
  final DateTime addedAt;
  final DateTime? lastWatchedAt;
  final bool watchedMovie;
  final List<TvSeasonSummary> seasonSummaries;

  /// Watched episodes, as `"{season}_{episode}"` keys (see
  /// `FavoriteMapper.episodeKey`). Only watched episodes are present.
  final Set<String> watchedEpisodes;

  /// "Recomendo": the user really likes this title (Minhas recomendações,
  /// private for now). Optional in the document: absent = false. Only `true`
  /// is ever written (see `FavoriteMapper.toMap`).
  final bool recommended;

  /// When each episode was marked by the current mark (`epsAt` in the
  /// document, docs/82 §4.2), keyed like [watchedEpisodes]. Private to the
  /// owner. Only marks made by this version carry a date; an entry whose key
  /// is NOT in [watchedEpisodes] is an orphan (left by an older app that
  /// unmarked the episode) and never counts. Empty for old documents.
  final Map<String, DateTime> watchedAt;

  const FavoriteDoc({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.posterPath,
    required this.overview,
    required this.addedAt,
    this.lastWatchedAt,
    this.watchedMovie = false,
    this.seasonSummaries = const [],
    this.watchedEpisodes = const {},
    this.recommended = false,
    this.watchedAt = const {},
  });

  /// Date of the CURRENT mark of episode [key], or null (no date, or orphan).
  DateTime? markedAt(String key) => watchedEpisodes.contains(key) ? watchedAt[key] : null;

  /// Dates whose episode is no longer marked (see [watchedAt]).
  Set<String> get orphanDates => {
        for (final k in watchedAt.keys)
          if (!watchedEpisodes.contains(k)) k,
      };

  /// Same composite key as `FavoriteItem.storageKey`.
  String get key => '$id-${mediaType.jsonValue}';

  FavoriteDoc copyWith({
    bool? watchedMovie,
    DateTime? lastWatchedAt,
    List<TvSeasonSummary>? seasonSummaries,
    Set<String>? watchedEpisodes,
    bool? recommended,
    Map<String, DateTime>? watchedAt,
  }) =>
      FavoriteDoc(
        id: id,
        mediaType: mediaType,
        title: title,
        posterPath: posterPath,
        overview: overview,
        addedAt: addedAt,
        lastWatchedAt: lastWatchedAt ?? this.lastWatchedAt,
        watchedMovie: watchedMovie ?? this.watchedMovie,
        seasonSummaries: seasonSummaries ?? this.seasonSummaries,
        watchedEpisodes: watchedEpisodes ?? this.watchedEpisodes,
        recommended: recommended ?? this.recommended,
        watchedAt: watchedAt ?? this.watchedAt,
      );
}
