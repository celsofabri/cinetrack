import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';

TmdbApiClient buildClient(http.Client httpClient) =>
    TmdbApiClient(apiKey: 'test-key', httpClient: httpClient);

void main() {
  group('TmdbApiClient.searchMulti', () {
    test('parses movie and tv results, ignoring unsupported types', () async {
      final client = buildClient(MockClient((request) async {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'id': 1,
                'media_type': 'movie',
                'title': 'A Movie',
                'poster_path': '/a.jpg',
                'overview': 'overview',
              },
              {
                'id': 2,
                'media_type': 'tv',
                'name': 'A Show',
                'poster_path': null,
                'overview': '',
              },
              {'id': 3, 'media_type': 'person', 'name': 'Someone'},
            ],
          }),
          200,
        );
      }));

      final results = await client.searchMulti('query');

      expect(results, hasLength(2));
      expect(results[0].mediaType, MediaType.movie);
      expect(results[0].title, 'A Movie');
      expect(results[1].mediaType, MediaType.tv);
      expect(results[1].title, 'A Show');
    });

    test('empty query short-circuits without a network call', () async {
      var called = false;
      final client = buildClient(MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      }));

      final results = await client.searchMulti('   ');

      expect(results, isEmpty);
      expect(called, isFalse);
    });

    test('401 maps to TmdbException.unauthorized', () async {
      final client = buildClient(MockClient((request) async => http.Response('', 401)));

      await expectLater(
        client.searchMulti('x'),
        throwsA(isA<TmdbException>().having((e) => e.type, 'type', TmdbErrorType.unauthorized)),
      );
    });

    test('429 maps to TmdbException.rateLimited', () async {
      final client = buildClient(MockClient((request) async => http.Response('', 429)));

      await expectLater(
        client.searchMulti('x'),
        throwsA(isA<TmdbException>().having((e) => e.type, 'type', TmdbErrorType.rateLimited)),
      );
    });
  });
}
