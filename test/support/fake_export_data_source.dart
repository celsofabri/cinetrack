import 'dart:async';

import 'package:cinetrack/data/export_data_source.dart';

/// Raw-document fake of the export source: keeps maps (so unknown fields
/// survive), pages by id like Firestore's `orderBy(documentId)`, and can be
/// scripted to fail or to stall.
class FakeExportDataSource implements ExportDataSource {
  final Map<String, Map<String, dynamic>> docs;
  Map<String, dynamic>? profile;

  /// When set, server reads throw it (device reads still work).
  ExportReadException? serverFailure;

  /// Documents the device has (defaults to [docs]).
  Map<String, Map<String, dynamic>>? deviceDocs;

  /// Holds each page until completed (to test progress / account switch).
  Completer<void>? gate;

  /// Runs once per page, after the gate.
  void Function(int call)? onPage;

  final calls = <({String? cursor, int limit, bool fromServer})>[];
  int profileReads = 0;

  FakeExportDataSource(this.docs, {this.profile});

  @override
  Future<RawPage> readPage({String? cursor, required int limit, required bool fromServer}) async {
    calls.add((cursor: cursor, limit: limit, fromServer: fromServer));
    if (gate != null) await gate!.future;
    onPage?.call(calls.length);
    if (fromServer && serverFailure != null) throw serverFailure!;
    final source = fromServer ? docs : (deviceDocs ?? docs);
    final ids = source.keys.toList()..sort();
    final remaining = cursor == null ? ids : ids.where((id) => id.compareTo(cursor) > 0).toList();
    return RawPage([
      for (final id in remaining.take(limit)) RawDoc(id, Map<String, dynamic>.of(source[id]!)),
    ]);
  }

  @override
  Future<Map<String, dynamic>?> readProfile({required bool fromServer}) async {
    profileReads++;
    if (fromServer && serverFailure != null) throw serverFailure!;
    return profile;
  }
}

/// A realistic series document, as Firestore stores it (plus [extra] fields).
Map<String, dynamic> fakeSeriesDoc(
  int id, {
  int seasons = 3,
  int perSeason = 12,
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'mediaType': 'tv',
  'title': 'Série $id',
  'posterPath': '/p$id.jpg',
  'overview': 'Sinopse com acentuação, "aspas" e emoji 🎬.',
  'addedAt': DateTime.utc(2026, 1, 2, 3, 4, 5),
  'lastWatchedAt': DateTime.utc(2026, 9, 30, 21, 0, 0, 123),
  'updatedAt': DateTime.utc(2026, 9, 30, 21, 0, 1),
  'watchedMovie': false,
  'seasonSummaries': [
    for (var s = 1; s <= seasons; s++)
      {'seasonNumber': s, 'name': 'Temporada $s', 'episodeCount': perSeason},
  ],
  'eps': {
    for (var s = 1; s <= seasons; s++)
      for (var e = 1; e <= perSeason; e++)
        if ((s + e) % 3 != 0) '${s}_$e': true,
  },
  ...extra,
};

Map<String, dynamic> fakeMovieDoc(int id, {bool watched = false, Map<String, dynamic>? extra}) => {
  'id': id,
  'mediaType': 'movie',
  'title': 'Filme $id',
  'posterPath': null,
  'overview': '',
  'addedAt': DateTime.utc(2026, 2, 3),
  'lastWatchedAt': watched ? DateTime.utc(2026, 3, 4) : null,
  'watchedMovie': watched,
  ...?extra,
};
