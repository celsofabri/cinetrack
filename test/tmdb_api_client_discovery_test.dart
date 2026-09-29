import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';

/// QA note: the 4 discovery methods below were, until this file, only
/// exercised through a hand-written fake `TmdbApiClient` subclass in
/// discovery_repository_test.dart — real HTTP parsing (`_get` + JSON →
/// SearchResult, including the `title`-vs-`name` branch in
/// `SearchResult.fromTmdbTyped`) was never actually run. This file closes
/// that gap with realistic TMDB response shapes, mirroring the existing
/// `searchMulti` tests in tmdb_api_client_test.dart.
TmdbApiClient _client(http.Client httpClient) =>
    TmdbApiClient(apiKey: 'test-key', httpClient: httpClient);

void main() {
  group('TmdbApiClient.getTrending', () {
    test('parses a realistic /trending/all/week payload (media_type present)', () async {
      final client = _client(MockClient((request) async {
        expect(request.url.path, '/3/trending/all/week');
        return http.Response(
          jsonEncode({
            'results': [
              {
                'id': 550,
                'media_type': 'movie',
                'title': 'Fight Club',
                'poster_path': '/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg',
                'overview': 'A ticking-time-bomb insomniac...',
              },
              {
                'id': 1396,
                'media_type': 'tv',
                'name': 'Breaking Bad',
                'poster_path': '/ggFHVNu6YYI5L9pCfOacjizRGt.jpg',
                'overview': 'When Walter White...',
              },
            ],
          }),
          200,
        );
      }));

      final results = await client.getTrending();

      expect(results, hasLength(2));
      expect(results[0].mediaType, MediaType.movie);
      expect(results[0].title, 'Fight Club');
      expect(results[1].mediaType, MediaType.tv);
      expect(results[1].title, 'Breaking Bad');
    });
  });

  group('TmdbApiClient.getNowPlayingMovies', () {
    test('requests region=BR and maps `title` via fromTmdbTyped(movie)', () async {
      final client = _client(MockClient((request) async {
        expect(request.url.path, '/3/movie/now_playing');
        expect(request.url.queryParameters['region'], 'BR');
        return http.Response(
          jsonEncode({
            'results': [
              {
                'id': 100,
                'title': 'Um Filme em Cartaz',
                'poster_path': '/x.jpg',
                'overview': 'Sinopse',
                // no media_type in this endpoint's payload, by design
              },
            ],
          }),
          200,
        );
      }));

      final results = await client.getNowPlayingMovies();

      expect(results.single.mediaType, MediaType.movie);
      expect(results.single.title, 'Um Filme em Cartaz');
    });
  });

  group('TmdbApiClient.getOnTheAirTv', () {
    test('maps `name` (not `title`) via fromTmdbTyped(tv)', () async {
      final client = _client(MockClient((request) async {
        expect(request.url.path, '/3/tv/on_the_air');
        return http.Response(
          jsonEncode({
            'results': [
              {
                'id': 200,
                'name': 'Uma Série em Exibição',
                'poster_path': null,
                'overview': '',
              },
            ],
          }),
          200,
        );
      }));

      final results = await client.getOnTheAirTv();

      expect(results.single.mediaType, MediaType.tv);
      expect(results.single.title, 'Uma Série em Exibição');
      // Regression guard for the exact bug class this endpoint is prone to:
      // if fromTmdbTyped ever read `title` instead of `name` for tv, this
      // would silently become ''.
      expect(results.single.title, isNot(''));
    });
  });

  group('TmdbApiClient.discoverMoviesByGenre / discoverTvByGenre', () {
    test('discoverMoviesByGenre sends with_genres and sort_by=popularity.desc', () async {
      final client = _client(MockClient((request) async {
        expect(request.url.path, '/3/discover/movie');
        expect(request.url.queryParameters['with_genres'], '27');
        expect(request.url.queryParameters['sort_by'], 'popularity.desc');
        return http.Response(
          jsonEncode({
            'results': [
              {'id': 300, 'title': 'Filme de Terror', 'poster_path': null, 'overview': ''},
            ],
          }),
          200,
        );
      }));

      final results = await client.discoverMoviesByGenre(27);

      expect(results.single.mediaType, MediaType.movie);
      expect(results.single.title, 'Filme de Terror');
    });

    test('discoverTvByGenre maps `name` and sends with_genres', () async {
      final client = _client(MockClient((request) async {
        expect(request.url.path, '/3/discover/tv');
        expect(request.url.queryParameters['with_genres'], '28');
        return http.Response(
          jsonEncode({
            'results': [
              {'id': 400, 'name': 'Série de Ação', 'poster_path': null, 'overview': ''},
            ],
          }),
          200,
        );
      }));

      final results = await client.discoverTvByGenre(28);

      expect(results.single.mediaType, MediaType.tv);
      expect(results.single.title, 'Série de Ação');
    });

    test('a 429 on discoverMoviesByGenre maps to TmdbException.rateLimited', () async {
      final client = _client(MockClient((request) async => http.Response('', 429)));

      await expectLater(
        client.discoverMoviesByGenre(27),
        throwsA(isA<TmdbException>().having((e) => e.type, 'type', TmdbErrorType.rateLimited)),
      );
    });
  });

  group('TmdbApiClient catalog (getGenres / discoverPage)', () {
    test('getGenres parses /genre/tv/list', () async {
      final client = _client(MockClient((request) async {
        expect(request.url.path, '/3/genre/tv/list');
        return http.Response(
          jsonEncode({
            'genres': [
              {'id': 10759, 'name': 'Action & Adventure'},
              {'id': 16, 'name': 'Animação'},
            ],
          }),
          200,
        );
      }));

      final genres = await client.getGenres(MediaType.tv);

      expect(genres.map((g) => (g.id, g.name)), [(10759, 'Action & Adventure'), (16, 'Animação')]);
    });

    test('discoverPage sends genre, page and quality filters and parses paging', () async {
      final client = _client(MockClient((request) async {
        expect(request.url.path, '/3/discover/movie');
        expect(request.url.queryParameters['with_genres'], '27');
        expect(request.url.queryParameters['page'], '3');
        expect(request.url.queryParameters['sort_by'], 'popularity.desc');
        expect(request.url.queryParameters['include_adult'], 'false');
        return http.Response(
          jsonEncode({
            'page': 3,
            'total_pages': 900,
            'results': [
              {'id': 1, 'title': 'Scary', 'poster_path': null, 'overview': ''},
            ],
          }),
          200,
        );
      }));

      final page = await client.discoverPage(MediaType.movie, genreId: 27, page: 3);

      expect(page.results.single.title, 'Scary');
      expect(page.page, 3);
      expect(page.totalPages, 900);
      expect(page.hasMore, isTrue);
    });

    test('discoverPage omits with_genres for "all" and stops at TMDB\'s 500-page cap', () async {
      final client = _client(MockClient((request) async {
        expect(request.url.queryParameters.containsKey('with_genres'), isFalse);
        return http.Response(
          jsonEncode({'page': 500, 'total_pages': 1000, 'results': []}),
          200,
        );
      }));

      final page = await client.discoverPage(MediaType.tv, page: 500);

      expect(page.hasMore, isFalse);
    });
  });
}
