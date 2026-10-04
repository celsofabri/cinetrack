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
  });

  /// Same composite key as `FavoriteItem.storageKey`.
  String get key => '$id-${mediaType.jsonValue}';

  FavoriteDoc copyWith({
    bool? watchedMovie,
    DateTime? lastWatchedAt,
    List<TvSeasonSummary>? seasonSummaries,
    Set<String>? watchedEpisodes,
    bool? recommended,
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
      );
}
