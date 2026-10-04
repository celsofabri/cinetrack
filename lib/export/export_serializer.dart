import 'dart:convert';
import 'dart:typed_data';

import '../data/export_data_source.dart';
import '../models/favorite_doc.dart';
import '../models/media_type.dart';
import '../services/favorite_mapper.dart';

/// Name of the export format and its version. Bump [kExportSchemaVersion]
/// when the layout of the file changes.
const kExportSchemaId = 'cinetrack-export';
const kExportSchemaVersion = 1;

/// Must match `version:` in pubspec.yaml (a test enforces it).
const kAppName = 'CineTrack';
const kAppVersion = '0.1.0';

/// Where the exported data came from.
enum ExportSource {
  /// Read from the server: complete.
  server('server'),

  /// Whatever this device had stored: may be incomplete.
  device('device-cache');

  final String jsonValue;

  const ExportSource(this.jsonValue);
}

/// A document the export could not fully handle. Nothing is dropped: the raw
/// document is still in the file unless the reason is [encodeFailed].
class ExportIssue {
  /// The app cannot interpret this document (corrupt or from a newer
  /// version); its raw fields are included as they are.
  static const notRecognized = 'not-recognized-by-app';

  /// Some value has a type JSON cannot represent; it was replaced by a
  /// marker naming its type.
  static const unsupportedValue = 'unsupported-value';

  /// The document could not be serialized and is NOT in the file.
  static const encodeFailed = 'encode-failed';

  final String key;
  final String reason;

  const ExportIssue(this.key, this.reason);

  Map<String, String> toJson() => {'key': key, 'reason': reason};
}

/// Totals shown to the user and written to the file (`counts`).
class ExportSummary {
  final int documents;
  final int movies;
  final int series;
  final int watchedMovies;
  final int watchedEpisodes;
  final List<ExportIssue> issues;

  const ExportSummary({
    required this.documents,
    required this.movies,
    required this.series,
    required this.watchedMovies,
    required this.watchedEpisodes,
    required this.issues,
  });

  int get notRecognized => issues.where((i) => i.reason == ExportIssue.notRecognized).length;

  /// Every document of the source is in the file.
  bool get lossless => !issues.any((i) => i.reason == ExportIssue.encodeFailed);

  Map<String, Object> toJson() => {
    'documents': documents,
    'movies': movies,
    'series': series,
    'watchedMovies': watchedMovies,
    'watchedEpisodes': watchedEpisodes,
    'notRecognized': notRecognized,
  };
}

class ExportFile {
  final String json;
  final ExportSummary summary;

  const ExportFile(this.json, this.summary);

  Uint8List get bytes => Uint8List.fromList(utf8.encode(json));
}

/// `cinetrack-export-YYYY-MM-DD.json` (the user's local date).
String exportFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'cinetrack-export-${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}.json';
}

/// Builds the export file incrementally (one document at a time), so a big
/// collection can be processed page by page. Pure Dart, no Firebase types.
///
/// File layout (schemaVersion 1): header fields, `profile`, `counts`,
/// `issues`, and `favorites`: one entry per Firestore document, written on
/// its own line, as `{"key": "doc id", "timestampFields": [...], "data":
/// {all fields as stored}}`. Timestamps are ISO 8601 UTC strings;
/// `timestampFields` lists which top-level fields were timestamps so a
/// restore can turn them back. Not included on purpose: uid, e-mail, photo.
class ExportBuilder {
  final List<String> _lines = [];
  final List<ExportIssue> _issues = [];
  int _movies = 0;
  int _series = 0;
  int _watchedMovies = 0;
  int _watchedEpisodes = 0;
  int _documents = 0;

  int get documents => _documents;

  void add(RawDoc doc) {
    _documents++;
    final data = doc.data;
    final type = data['mediaType'];
    if (type == MediaType.movie.jsonValue) _movies++;
    if (type == MediaType.tv.jsonValue) _series++;

    final parsed = _tryParse(doc);
    if (parsed == null) {
      _issues.add(ExportIssue(doc.id, ExportIssue.notRecognized));
    } else {
      if (parsed.watchedMovie) _watchedMovies++;
      _watchedEpisodes += parsed.watchedEpisodes.length;
    }

    try {
      final unsupported = <bool>[];
      final encoded = {
        'key': doc.id,
        'timestampFields': [
          for (final e in data.entries)
            if (e.value is DateTime) e.key,
        ],
        'data': {for (final e in data.entries) e.key: encodeValue(e.value, unsupported)},
      };
      _lines.add(jsonEncode(encoded));
      if (unsupported.isNotEmpty) _issues.add(ExportIssue(doc.id, ExportIssue.unsupportedValue));
    } catch (_) {
      _issues.add(ExportIssue(doc.id, ExportIssue.encodeFailed));
    }
  }

  ExportFile build({
    required DateTime exportedAt,
    required ExportSource source,
    required Map<String, dynamic>? profile,
  }) {
    final summary = ExportSummary(
      documents: _documents,
      movies: _movies,
      series: _series,
      watchedMovies: _watchedMovies,
      watchedEpisodes: _watchedEpisodes,
      issues: List.unmodifiable(_issues),
    );
    final complete = source == ExportSource.server && summary.lossless;
    final displayName = profile?['displayName'];
    final header = <String, Object?>{
      'schema': kExportSchemaId,
      'schemaVersion': kExportSchemaVersion,
      'exportedAt': exportedAt.toUtc().toIso8601String(),
      'app': {'name': kAppName, 'version': kAppVersion},
      'source': source.jsonValue,
      'complete': complete,
      'profile': profile == null
          ? null
          : {
              'displayName': displayName is String ? displayName : null,
              'timestampFields': [
                for (final e in profile.entries)
                  if (e.value is DateTime) e.key,
              ],
              'data': encodeValue(profile, <bool>[]),
            },
      'counts': summary.toJson(),
      'issues': [for (final i in _issues) i.toJson()],
    };
    final buffer = StringBuffer('{\n');
    for (final e in header.entries) {
      buffer.write('  ${jsonEncode(e.key)}: ${jsonEncode(e.value)},\n');
    }
    buffer.write('  "favorites": [');
    for (var i = 0; i < _lines.length; i++) {
      buffer.write('${i == 0 ? '' : ','}\n    ${_lines[i]}');
    }
    buffer.write(_lines.isEmpty ? ']\n}\n' : '\n  ]\n}\n');
    return ExportFile(buffer.toString(), summary);
  }

  static FavoriteDoc? _tryParse(RawDoc doc) {
    try {
      return FavoriteMapper.fromMap(doc.id, doc.data);
    } catch (_) {
      return null;
    }
  }

  /// JSON-safe copy of a stored value. [unsupported] gets an entry for each
  /// value of a type JSON cannot hold (replaced by a marker, never dropped
  /// silently).
  static Object? encodeValue(Object? value, List<bool> unsupported) {
    switch (value) {
      case null || bool() || String() || int():
        return value;
      case double():
        if (value.isFinite) return value;
        unsupported.add(true);
        return {'nonFiniteNumber': value.toString()};
      case DateTime():
        return value.toUtc().toIso8601String();
      case Map():
        return {for (final e in value.entries) '${e.key}': encodeValue(e.value, unsupported)};
      case Iterable():
        return [for (final item in value) encodeValue(item, unsupported)];
      default:
        unsupported.add(true);
        return {'unsupportedType': value.runtimeType.toString()};
    }
  }
}
