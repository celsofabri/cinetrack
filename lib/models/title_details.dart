import 'media_type.dart';
import 'search_result.dart';
import 'tv_season_summary.dart';

/// Read-only catalog data of a movie/show fetched from TMDB (`/movie/{id}`
/// or `/tv/{id}`), used to render the details of a title the user has NOT
/// favorited. Never persisted: favorites keep their own saved shape.
class TitleDetails {
  final int id;
  final MediaType mediaType;
  final String title;
  final String? posterPath;
  final String overview;

  /// Release (movie) or first air (show) year, null when TMDB has none.
  final int? year;

  /// TMDB average (0-10); null when there are no votes.
  final double? voteAverage;
  final List<String> genres;

  /// Seasons of a show (empty for movies).
  final List<TvSeasonSummary> seasonSummaries;

  const TitleDetails({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.posterPath,
    required this.overview,
    this.year,
    this.voteAverage,
    this.genres = const [],
    this.seasonSummaries = const [],
  });

  factory TitleDetails.fromTmdb(Map<String, dynamic> json, MediaType mediaType) {
    final isMovie = mediaType == MediaType.movie;
    final rawDate = (isMovie ? json['release_date'] : json['first_air_date']) as String?;
    final year =
        rawDate == null || rawDate.length < 4 ? null : int.tryParse(rawDate.substring(0, 4));
    final votes = json['vote_count'] as int?;
    final average = (json['vote_average'] as num?)?.toDouble();
    return TitleDetails(
      id: json['id'] as int,
      mediaType: mediaType,
      title: ((isMovie ? json['title'] : json['name']) as String?) ?? '',
      posterPath: json['poster_path'] as String?,
      overview: json['overview'] as String? ?? '',
      year: year,
      voteAverage: (average == null || average <= 0 || votes == 0) ? null : average,
      genres: [
        for (final g in json['genres'] as List? ?? const [])
          if ((g as Map)['name'] is String) g['name'] as String,
      ],
      seasonSummaries: isMovie ? const [] : TvSeasonSummary.listFromTvDetails(json),
    );
  }

  /// The shape the favorites repository accepts to favorite this title.
  SearchResult toSearchResult() => SearchResult(
        id: id,
        mediaType: mediaType,
        title: title,
        posterPath: posterPath,
        overview: overview,
      );
}
