import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';

void main() {
  group('FavoriteItem toJson/fromJson round-trip', () {
    test('round-trips lastWatchedAt when present', () {
      final item = FavoriteItem(
        id: 1,
        mediaType: MediaType.tv,
        title: 'Show',
        posterPath: '/p.jpg',
        overview: 'overview',
        addedAt: DateTime.parse('2024-01-01T00:00:00.000Z'),
        lastWatchedAt: DateTime.parse('2024-02-01T00:00:00.000Z'),
      );

      final restored = FavoriteItem.fromJson(item.toJson());

      expect(restored.lastWatchedAt, item.lastWatchedAt);
      expect(restored.id, item.id);
      expect(restored.title, item.title);
    });

    test('fromJson is null-safe when the lastWatchedAt key is absent (pre-migration data)', () {
      // Simulates a Map saved by a version of the app before this field
      // existed — Hive stores raw Maps, no schema/TypeAdapter, so this is
      // a realistic legacy record.
      final legacyJson = <String, dynamic>{
        'id': 1,
        'mediaType': 'tv',
        'title': 'Show',
        'posterPath': null,
        'overview': '',
        'addedAt': DateTime.now().toIso8601String(),
        'watchedMovie': false,
        // no 'lastWatchedAt' key at all
      };

      final restored = FavoriteItem.fromJson(legacyJson);

      expect(restored.lastWatchedAt, isNull);
    });

    test('toJson/fromJson round-trips a null lastWatchedAt as well', () {
      final item = FavoriteItem(
        id: 1,
        mediaType: MediaType.movie,
        title: 'Movie',
        posterPath: null,
        overview: '',
        addedAt: DateTime.now(),
      );

      final restored = FavoriteItem.fromJson(item.toJson());

      expect(restored.lastWatchedAt, isNull);
    });

    test('copyWith updates lastWatchedAt without touching other fields', () {
      final item = FavoriteItem(
        id: 1,
        mediaType: MediaType.tv,
        title: 'Show',
        posterPath: null,
        overview: '',
        addedAt: DateTime.now(),
      );
      final now = DateTime.now();

      final updated = item.copyWith(lastWatchedAt: now);

      expect(updated.lastWatchedAt, now);
      expect(updated.title, item.title);
      expect(updated.id, item.id);
    });
  });
}
