import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/export_data_source.dart';
import 'package:cinetrack/data/firestore_export_data_source.dart';
import 'package:cinetrack/export/export_serializer.dart';

FirebaseException _fe(String code) => FirebaseException(plugin: 'cloud_firestore', code: code);

Future<ExportReadException> _caught(Future<void> Function() read) async {
  try {
    await FirestoreExportDataSource.guard(read, const Duration(milliseconds: 50));
  } on ExportReadException catch (e) {
    return e;
  }
  fail('expected ExportReadException');
}

void main() {
  group('Timestamp conversion (what Firestore really returns)', () {
    test('top-level, nested in Map and List become DateTime; others untouched', () {
      final out = FirestoreExportDataSource.convert({
        'addedAt': Timestamp.fromDate(DateTime.utc(2026, 1, 2, 3)),
        'meta': {
          'at': Timestamp.fromDate(DateTime.utc(2026, 5, 6)),
          'deep': [Timestamp.fromDate(DateTime.utc(2026, 7, 8)), 'x', null],
        },
        'list': [
          {'t': Timestamp.fromDate(DateTime.utc(2027))},
        ],
        'nothing': null,
        'nan': double.nan,
        'inf': double.infinity,
        'big': 9007199254740991,
        'ok': true,
        'eps': {'1_1': true},
      });
      DateTime utc(Object? v) => (v as DateTime).toUtc();
      expect(utc(out['addedAt']), DateTime.utc(2026, 1, 2, 3));
      expect(utc(out['meta']['at']), DateTime.utc(2026, 5, 6));
      expect((out['meta']['deep'] as List).map((v) => v is DateTime ? v.toUtc() : v), [
        DateTime.utc(2026, 7, 8),
        'x',
        null,
      ]);
      expect(utc(out['list'][0]['t']), DateTime.utc(2027));
      expect(out['nothing'], isNull);
      expect((out['nan'] as double).isNaN, isTrue);
      expect(out['inf'], double.infinity);
      expect(out['big'], 9007199254740991);
      expect(out['eps'], {'1_1': true});
    });

    test('a Timestamp with nanoseconds keeps at least millisecond precision', () {
      final out = FirestoreExportDataSource.convert({'t': Timestamp(1790000000, 123456789)});
      final t = out['t'] as DateTime;
      expect(t.toUtc().millisecondsSinceEpoch, 1790000000123);
    });

    test('end to end: no Timestamp reaches the file as an unsupported value', () {
      final data = FirestoreExportDataSource.convert({
        'id': 1,
        'mediaType': 'movie',
        'title': 'T',
        'overview': '',
        'addedAt': Timestamp.fromDate(DateTime.utc(2026, 1, 2)),
        'lastWatchedAt': Timestamp.fromDate(DateTime.utc(2026, 3, 4)),
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 3, 5)),
      });
      final builder = ExportBuilder()..add(RawDoc('1-movie', data));
      final file = builder.build(
        exportedAt: DateTime.utc(2026, 10, 3),
        source: ExportSource.server,
        profile: {'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 4, 5)).toDate()},
      );
      expect(file.json.contains('unsupportedType'), isFalse);
      expect(file.json, contains('"addedAt":"2026-01-02T00:00:00.000Z"'));
      expect(file.json, contains('"timestampFields":["addedAt","lastWatchedAt","updatedAt"]'));
      expect(file.summary.issues, isEmpty);
    });
  });

  group('error mapping', () {
    for (final (code, kind) in [
      ('unavailable', ExportReadFailureKind.unreachable),
      ('deadline-exceeded', ExportReadFailureKind.unreachable),
      ('cancelled', ExportReadFailureKind.unreachable),
      ('permission-denied', ExportReadFailureKind.denied),
      ('unauthenticated', ExportReadFailureKind.denied),
      ('internal', ExportReadFailureKind.unknown),
      ('resource-exhausted', ExportReadFailureKind.unknown),
    ]) {
      test('FirebaseException $code -> $kind (code kept, no data)', () async {
        final e = await _caught(() => Future.error(_fe(code)));
        expect(e.kind, kind);
        expect(e.code, code);
      });
    }

    test('a read that never answers becomes unreachable (timeout)', () async {
      final e = await _caught(() => Completer<void>().future);
      expect(e.kind, ExportReadFailureKind.unreachable);
      expect(e.code, 'timeout');
    });

    test('foreign errors are not swallowed', () async {
      await expectLater(
        FirestoreExportDataSource.guard(
          () => Future<void>.error(StateError('x')),
          const Duration(seconds: 1),
        ),
        throwsStateError,
      );
    });
  });
}
