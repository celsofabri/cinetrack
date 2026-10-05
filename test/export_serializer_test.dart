import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/export_data_source.dart';
import 'package:cinetrack/export/data_exporter.dart';
import 'package:cinetrack/export/export_serializer.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/services/favorite_mapper.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/fake_export_data_source.dart';

ExportFile _build(
  Map<String, Map<String, dynamic>> docs, {
  Map<String, dynamic>? profile,
  ExportSource source = ExportSource.server,
}) {
  final builder = ExportBuilder();
  for (final e in docs.entries) {
    builder.add(RawDoc(e.key, e.value));
  }
  return builder.build(exportedAt: DateTime.utc(2026, 10, 3, 12), source: source, profile: profile);
}

Map<String, dynamic> _decode(ExportFile file) => jsonDecode(file.json) as Map<String, dynamic>;

/// What a restore does: JSON entry -> Firestore-shaped map (timestamps back
/// to DateTime), then the app's own parser.
FavoriteDoc? _reimport(Map<String, dynamic> entry) {
  final data = Map<String, dynamic>.of(entry['data'] as Map<String, dynamic>);
  for (final f in (entry['timestampFields'] as List).cast<String>()) {
    data[f] = DateTime.parse(data[f] as String);
  }
  return FavoriteMapper.fromMap(entry['key'] as String, data);
}

void _expectSame(FavoriteDoc a, FavoriteDoc b) {
  expect(b.id, a.id);
  expect(b.mediaType, a.mediaType);
  expect(b.title, a.title);
  expect(b.posterPath, a.posterPath);
  expect(b.overview, a.overview);
  expect(b.addedAt.toUtc(), a.addedAt.toUtc());
  expect(b.lastWatchedAt?.toUtc(), a.lastWatchedAt?.toUtc());
  expect(b.watchedMovie, a.watchedMovie);
  expect(b.watchedEpisodes, a.watchedEpisodes);
  expect(
    [for (final s in b.seasonSummaries) s.toJson()],
    [for (final s in a.seasonSummaries) s.toJson()],
  );
}

void main() {
  group('file layout', () {
    test('header: versioned schema, ISO exportedAt, app, no uid/e-mail', () {
      final file = _build({'1-movie': fakeMovieDoc(1)}, profile: {'displayName': 'Ana'});
      final json = _decode(file);
      expect(json['schema'], 'cinetrack-export');
      expect(json['schemaVersion'], 2);
      expect(json['exportedAt'], '2026-10-03T12:00:00.000Z');
      expect(json['app'], {'name': 'CineTrack', 'version': kAppVersion});
      expect(json['source'], 'server');
      expect(json['complete'], isTrue);
      expect(json['profile']['displayName'], 'Ana');
      expect(file.json.contains('uid'), isFalse);
      expect(file.json.contains('@'), isFalse);
    });

    test('kAppVersion matches pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!.group(1);
      expect(kAppVersion, version!.split('+').first);
    });

    test('empty collection is a valid, explicit file (complete, 0 documents)', () {
      final file = _build({});
      final json = _decode(file);
      expect(json['favorites'], isEmpty);
      expect(json['counts']['documents'], 0);
      expect(json['complete'], isTrue);
      expect(json['profile'], isNull);
    });

    test('device source is marked incomplete', () {
      final json = _decode(_build({'1-movie': fakeMovieDoc(1)}, source: ExportSource.device));
      expect(json['source'], 'device-cache');
      expect(json['complete'], isFalse);
    });

    test('file name uses the local date, zero padded', () {
      expect(exportFileName(DateTime(2026, 3, 7, 23, 59)), 'cinetrack-export-2026-03-07.json');
      expect(exportFileName(DateTime(2026, 12, 25)), 'cinetrack-export-2026-12-25.json');
    });
  });

  group('documents are exported as stored', () {
    test('round trip of a complex series: every field, eps complete, timestamps ISO', () {
      final doc = fakeSeriesDoc(1396, seasons: 5, perSeason: 22);
      final file = _build({'1396-tv': doc});
      final entry = (_decode(file)['favorites'] as List).single as Map<String, dynamic>;

      expect(entry['key'], '1396-tv');
      expect(entry['timestampFields'], ['addedAt', 'lastWatchedAt', 'updatedAt']);
      final data = entry['data'] as Map<String, dynamic>;
      expect(data['addedAt'], '2026-01-02T03:04:05.000Z');
      expect(data['lastWatchedAt'], '2026-09-30T21:00:00.123Z');
      expect(data['eps'], doc['eps']);
      expect((data['eps'] as Map).length, (doc['eps'] as Map).length);
      expect(data['seasonSummaries'], doc['seasonSummaries']);
      expect(data['overview'], doc['overview']);
      expect(data.keys.toSet(), doc.keys.toSet());
    });

    test('unknown / future fields survive untouched, including nested ones', () {
      final doc = fakeMovieDoc(
        7,
        watched: true,
        extra: {
          'recommended': true,
          'futureNote': {
            'tags': ['a', 'b'],
            'score': 4.5,
            'at': DateTime.utc(2027),
          },
        },
      );
      final entry = (_decode(_build({'7-movie': doc}))['favorites'] as List).single;
      final data = entry['data'] as Map<String, dynamic>;
      expect(data['recommended'], isTrue);
      expect(data['futureNote'], {
        'tags': ['a', 'b'],
        'score': 4.5,
        'at': '2027-01-01T00:00:00.000Z',
      });
    });

    test('null stays null (lastWatchedAt of an unwatched movie)', () {
      final entry = (_decode(_build({'1-movie': fakeMovieDoc(1)}))['favorites'] as List).single;
      expect((entry['data'] as Map).containsKey('lastWatchedAt'), isTrue);
      expect(entry['data']['lastWatchedAt'], isNull);
      expect(entry['timestampFields'], ['addedAt']);
    });

    test('reimporting the file through FavoriteMapper rebuilds the same items', () {
      final docs = {
        '1-movie': fakeMovieDoc(1, watched: true),
        '2-movie': fakeMovieDoc(2),
        '1396-tv': fakeSeriesDoc(1396, seasons: 5, perSeason: 22, extra: {'recommended': true}),
        '60-tv': fakeSeriesDoc(60, seasons: 1, perSeason: 3),
      };
      final file = _build(docs);
      final entries = (_decode(file)['favorites'] as List).cast<Map<String, dynamic>>();
      expect(entries, hasLength(docs.length));
      for (final entry in entries) {
        final original = FavoriteMapper.fromMap(entry['key'] as String, docs[entry['key']]!)!;
        final back = _reimport(entry);
        expect(back, isNotNull);
        _expectSame(original, back!);
      }
    });

    test('counts match what the app reads (movies, series, watched, episodes)', () {
      final docs = {
        '1-movie': fakeMovieDoc(1, watched: true),
        '2-movie': fakeMovieDoc(2),
        '9-tv': fakeSeriesDoc(9, seasons: 1, perSeason: 5), // eps: 1_1 1_3 1_4 -> 3
      };
      final counts = _decode(_build(docs))['counts'] as Map<String, dynamic>;
      expect(counts, {
        'documents': 3,
        'movies': 2,
        'series': 1,
        'watchedMovies': 1,
        'watchedEpisodes': 3,
        'notRecognized': 0,
      });
    });
  });

  group('corrupt or unreadable documents', () {
    test('do not break the export: raw data kept and listed in issues', () {
      final docs = {
        '1-movie': fakeMovieDoc(1),
        'lixo': {'foo': 'bar', 'recommended': true}, // no id / mediaType
        '5-tv': {'id': '5', 'mediaType': 'tv'}, // wrong type for id
        '6-movie': {'id': 6, 'mediaType': 'documentary'}, // unknown media type
        '8-tv': fakeMovieDoc(8), // key does not match content
      };
      final file = _build(docs);
      final json = _decode(file);

      expect((json['favorites'] as List), hasLength(5));
      expect(json['counts']['documents'], 5);
      expect(json['counts']['notRecognized'], 4);
      expect((json['issues'] as List).map((i) => i['key']).toSet(), {
        'lixo',
        '5-tv',
        '6-movie',
        '8-tv',
      });
      expect((json['issues'] as List).every((i) => i['reason'] == 'not-recognized-by-app'), isTrue);
      final raw = (json['favorites'] as List).firstWhere((e) => e['key'] == 'lixo');
      expect(raw['data'], {'foo': 'bar', 'recommended': true});
      expect(json['complete'], isTrue, reason: 'nothing was dropped');
    });

    test('values JSON cannot hold become typed markers and are listed', () {
      final file = _build({
        '1-movie': {...fakeMovieDoc(1), 'weird': Object(), 'nan': double.nan},
      });
      final json = _decode(file);
      final data = (json['favorites'] as List).single['data'] as Map<String, dynamic>;
      expect(data['weird'], {'unsupportedType': 'Object'});
      expect(data['nan'], {'nonFiniteNumber': 'NaN'});
      expect((json['issues'] as List).single, {'key': '1-movie', 'reason': 'unsupported-value'});
    });
  });

  group('pagination (no artificial limit)', () {
    Future<(ExportFile, FakeExportDataSource)> run(int n, {int pageSize = kExportPageSize}) async {
      final source = FakeExportDataSource({
        for (var i = 0; i < n; i++) '${1000 + i}-movie': fakeMovieDoc(1000 + i),
      });
      final file = await runExport(
        source: source,
        from: ExportSource.server,
        now: () => DateTime.utc(2026, 10, 3),
        isCurrent: () => true,
        pageSize: pageSize,
      );
      return (file, source);
    }

    for (final (n, reads) in [(0, 1), (1, 1), (299, 1), (300, 2), (400, 2), (401, 2), (601, 3)]) {
      test('$n documents -> every one exported in $reads page read(s)', () async {
        final (file, source) = await run(n);
        expect(file.summary.documents, n);
        expect((_decode(file)['favorites'] as List), hasLength(n));
        expect(source.calls, hasLength(reads));
        expect(source.calls.every((c) => c.fromServer), isTrue);
        expect(source.profileReads, 1);
      });
    }

    test('1500 documents: nothing lost, no duplicates, cursors advance', () async {
      final (file, source) = await run(1500);
      final keys = [for (final e in _decode(file)['favorites'] as List) e['key']];
      expect(keys.toSet(), hasLength(1500));
      expect(source.calls.map((c) => c.cursor).toSet(), hasLength(source.calls.length));
    });

    test('reports progress per page', () async {
      final source = FakeExportDataSource({
        for (var i = 0; i < 25; i++) '${100 + i}-movie': fakeMovieDoc(100 + i),
      });
      final progress = <int>[];
      await runExport(
        source: source,
        from: ExportSource.server,
        now: DateTime.now,
        isCurrent: () => true,
        onProgress: progress.add,
        pageSize: 10,
      );
      expect(progress, [10, 20, 25]);
    });

    test('a source that never advances fails instead of looping', () async {
      final stuck = _StuckSource();
      await expectLater(
        runExport(
          source: stuck,
          from: ExportSource.server,
          now: DateTime.now,
          isCurrent: () => true,
          pageSize: 2,
        ),
        throwsA(isA<ExportReadException>()),
      );
    });

    test('stops with ExportCancelled when no longer current', () async {
      var current = true;
      final source = FakeExportDataSource({
        for (var i = 0; i < 30; i++) '${100 + i}-movie': fakeMovieDoc(100 + i),
      })..onPage = (call) => current = call < 2;
      await expectLater(
        runExport(
          source: source,
          from: ExportSource.server,
          now: DateTime.now,
          isCurrent: () => current,
          pageSize: 10,
        ),
        throwsA(isA<ExportCancelled>()),
      );
      expect(source.profileReads, 0);
    });
  });
}

class _StuckSource implements ExportDataSource {
  @override
  Future<RawPage> readPage({String? cursor, required int limit, required bool fromServer}) async =>
      RawPage([for (var i = 0; i < limit; i++) RawDoc('1-movie', fakeMovieDoc(1))]);

  @override
  Future<Map<String, dynamic>?> readProfile({required bool fromServer}) async => null;

  @override
  Future<RawSocial?> readSocial({required bool fromServer}) async => null;

  @override
  Future<RawPage> readSocialPage(
    SocialExportKind kind, {
    String? cursor,
    required int limit,
    required bool fromServer,
  }) async => const RawPage([]);
}
