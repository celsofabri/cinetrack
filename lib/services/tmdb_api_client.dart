import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/cast_member.dart';
import '../models/catalog.dart';
import '../models/media_type.dart';
import '../models/person.dart';
import '../models/search_result.dart';
import '../models/season_cache.dart';
import '../models/title_video.dart';
import 'tmdb_exception.dart';

class TmdbApiClient {
  static const _baseUrl = 'https://api.themoviedb.org/3';

  /// Base URL for poster/backdrop images; append a size (e.g. "w342") and
  /// the `posterPath` from any model.
  static const imageBaseUrl = 'https://image.tmdb.org/t/p';

  final http.Client _http;
  final String apiKey;

  TmdbApiClient({required this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse('$_baseUrl$path').replace(
        queryParameters: {'api_key': apiKey, 'language': 'pt-BR', ...?query},
      );

  Future<Map<String, dynamic>> _get(Uri uri) async {
    late final http.Response response;
    try {
      response = await _http.get(uri);
    } on SocketException {
      throw TmdbException.network();
    } on http.ClientException {
      // What the browser (web) throws when offline or blocked.
      throw TmdbException.network();
    }

    if (response.statusCode != 200) {
      throw TmdbException.fromStatusCode(response.statusCode);
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<SearchResult>> searchMulti(String query) async {
    if (query.trim().isEmpty) return [];
    final json = await _get(_uri('/search/multi', {'query': query}));
    final results = json['results'] as List? ?? [];
    return results
        .cast<Map<String, dynamic>>()
        .map(SearchResult.fromTmdb)
        .whereType<SearchResult>()
        .toList();
  }

  /// Popular/trending movies and TV shows this week — `media_type` already
  /// comes in the payload, same as `/search/multi`.
  Future<List<SearchResult>> getTrending() async {
    final json = await _get(_uri('/trending/all/week'));
    final results = json['results'] as List? ?? [];
    return results
        .cast<Map<String, dynamic>>()
        .map(SearchResult.fromTmdb)
        .whereType<SearchResult>()
        .toList();
  }

  /// Movies currently in theaters in Brazil — `region` is the one place
  /// this matters, since theatrical release dates vary by country (the
  /// other discovery endpoints are already localized via `language=pt-BR`
  /// on every request).
  Future<List<SearchResult>> getNowPlayingMovies() async {
    final json = await _get(_uri('/movie/now_playing', {'region': 'BR'}));
    final results = json['results'] as List? ?? [];
    return results
        .cast<Map<String, dynamic>>()
        .map((r) => SearchResult.fromTmdbTyped(r, MediaType.movie))
        .toList();
  }

  Future<List<SearchResult>> getOnTheAirTv() async {
    final json = await _get(_uri('/tv/on_the_air'));
    final results = json['results'] as List? ?? [];
    return results
        .cast<Map<String, dynamic>>()
        .map((r) => SearchResult.fromTmdbTyped(r, MediaType.tv))
        .toList();
  }

  /// `sort_by=popularity.desc` keeps `with_genres` from surfacing very
  /// low-popularity/quality items first.
  Future<List<SearchResult>> discoverMoviesByGenre(int genreId) async {
    final json = await _get(_uri('/discover/movie', {
      'with_genres': '$genreId',
      'sort_by': 'popularity.desc',
    }));
    final results = json['results'] as List? ?? [];
    return results
        .cast<Map<String, dynamic>>()
        .map((r) => SearchResult.fromTmdbTyped(r, MediaType.movie))
        .toList();
  }

  Future<List<SearchResult>> discoverTvByGenre(int genreId) async {
    final json = await _get(_uri('/discover/tv', {
      'with_genres': '$genreId',
      'sort_by': 'popularity.desc',
    }));
    final results = json['results'] as List? ?? [];
    return results
        .cast<Map<String, dynamic>>()
        .map((r) => SearchResult.fromTmdbTyped(r, MediaType.tv))
        .toList();
  }

  Future<List<Genre>> getGenres(MediaType type) async {
    final json = await _get(_uri('/genre/${type.jsonValue}/list'));
    final genres = json['genres'] as List? ?? [];
    return genres.cast<Map<String, dynamic>>().map(Genre.fromTmdb).toList();
  }

  /// Full catalog browsing: every movie or TV show (optionally within one
  /// genre), most popular first, one page at a time.
  Future<DiscoverPage> discoverPage(
    MediaType type, {
    int? genreId,
    int page = 1,
  }) async {
    final json = await _get(_uri('/discover/${type.jsonValue}', {
      'sort_by': 'popularity.desc',
      'include_adult': 'false',
      'vote_count.gte': '20', // hides unrated/obscure entries with no poster
      'page': '$page',
      if (genreId != null) 'with_genres': '$genreId',
    }));
    final results = json['results'] as List? ?? [];
    return DiscoverPage(
      results: results
          .cast<Map<String, dynamic>>()
          .map((r) => SearchResult.fromTmdbTyped(r, type))
          .toList(),
      page: json['page'] as int? ?? page,
      totalPages: json['total_pages'] as int? ?? page,
    );
  }

  Future<Map<String, dynamic>> getMovieDetails(int id) => _get(_uri('/movie/$id'));

  Future<Map<String, dynamic>> getTvDetails(int id) => _get(_uri('/tv/$id'));

  Future<SeasonCache> getSeasonEpisodes(int tvId, int seasonNumber) async {
    final json = await _get(_uri('/tv/$tvId/season/$seasonNumber'));
    return SeasonCache.fromTmdb(json);
  }

  /// Videos of a title (`/movie/{id}/videos`, `/tv/{id}/videos`), YouTube ones
  /// only. One request asks for Portuguese, English and language-less videos
  /// (the default `language=pt-BR` alone would hide the English trailers).
  Future<List<TitleVideo>> getTitleVideos(MediaType type, int id) async {
    final json = await _get(_uri('/${type.jsonValue}/$id/videos', {
      'include_video_language': 'pt,en,null',
    }));
    return [
      for (final v in (json['results'] as List? ?? const []).whereType<Map<String, dynamic>>())
        ?TitleVideo.fromTmdb(v),
    ];
  }

  /// Cast of a title, TMDB order, one entry per person. Movies use
  /// `/movie/{id}/credits`; shows use `/tv/{id}/aggregate_credits` (whole run,
  /// with `roles`) instead of `/tv/{id}/credits` (latest season only).
  Future<List<CastMember>> getTitleCast(MediaType type, int id) async {
    final isMovie = type == MediaType.movie;
    final json = await _get(_uri(isMovie ? '/movie/$id/credits' : '/tv/$id/aggregate_credits'));
    final cast = (json['cast'] as List? ?? const []).whereType<Map<String, dynamic>>();
    return CastMember.dedupe([
      for (final c in cast)
        if (isMovie) CastMember.fromMovieCredit(c) else CastMember.fromAggregateCredit(c),
    ].whereType<CastMember>());
  }

  /// `/person/{id}`; [language] overrides the default pt-BR (used to fetch
  /// the English biography when the Portuguese one is empty).
  Future<Map<String, dynamic>> getPerson(int id, {String? language}) =>
      _get(_uri('/person/$id', {'language': ?language}));

  /// Acting credits (movies and shows) of a person, adult ones removed.
  Future<List<PersonCredit>> getPersonCredits(int id) async {
    final json = await _get(_uri('/person/$id/combined_credits'));
    return (json['cast'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PersonCredit.fromTmdb)
        .whereType<PersonCredit>()
        .toList();
  }

  void dispose() => _http.close();
}
