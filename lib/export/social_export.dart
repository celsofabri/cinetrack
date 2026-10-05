import '../data/export_data_source.dart';
import '../social/social_models.dart';
import 'export_serializer.dart';

/// The `social` section of the export: the user's own friendships setup
/// (handle, "Aparecer na busca", whether the photo is shown) and, per D9,
/// the uid and nickname of the people involved: friends, requests sent and
/// received, blocked people. No photos of other people. Pure Dart.
///
/// Entries keep the id of the Firestore document (`key`) so nothing is
/// ambiguous; a document the app cannot interpret is listed in `issues` and in
/// the list with its field names and types only (no values).
class SocialExport {
  /// The user the export is for (to tell "the other" member of a friendship).
  final String? uid;
  final RawSocial raw;
  final List<ExportIssue> issues = [];

  final Map<SocialExportKind, List<Map<String, Object?>>> _entries = {
    for (final kind in SocialExportKind.values) kind: [],
  };

  SocialExport(this.raw, {this.uid});

  void add(SocialExportKind kind, RawDoc doc) {
    final entry = _interpret(kind, doc);
    if (entry == null) {
      issues.add(ExportIssue('${_collection(kind)}/${doc.id}', ExportIssue.notRecognized));
      _entries[kind]!.add({
        'key': doc.id,
        'uid': null,
        'nickname': null,
        // Names and types only, never values: an unknown document could carry
        // somebody else's data (e.g. a photo URL).
        'fields': {for (final e in doc.data.entries) e.key: _typeName(e.value)},
      });
    } else {
      _entries[kind]!.add(entry);
    }
  }

  static String _collection(SocialExportKind kind) => switch (kind) {
    SocialExportKind.friends => 'friendships',
    SocialExportKind.requestsSent || SocialExportKind.requestsReceived => 'friend_requests',
    SocialExportKind.blocks => 'blocks',
  };

  static String _typeName(Object? v) => switch (v) {
    null => 'null',
    String() => 'string',
    bool() => 'bool',
    int() || double() => 'number',
    DateTime() => 'timestamp',
    List() => 'list',
    Map() => 'map',
    _ => 'other',
  };

  static String? _string(Object? v) => v is String ? v : null;

  static String? _iso(Object? v) => v is DateTime ? v.toUtc().toIso8601String() : null;

  Map<String, Object?>? _interpret(SocialExportKind kind, RawDoc doc) {
    final d = doc.data;
    switch (kind) {
      case SocialExportKind.friends:
        final members = d['members'];
        final me = uid;
        if (me == null || members is! List || members.length != 2 || !members.contains(me)) {
          return null;
        }
        final other = members[0] == me ? members[1] : members[0];
        if (other is! String || other.isEmpty) return null;
        final name = members[0] == other ? d['aName'] : d['bName'];
        return {
          'key': doc.id,
          'uid': other,
          'nickname': _string(name),
          'since': _iso(d['createdAt']),
        };
      case SocialExportKind.requestsSent:
        return _request(doc, otherKey: 'to', nameKey: 'toName');
      case SocialExportKind.requestsReceived:
        return _request(doc, otherKey: 'from', nameKey: 'fromName');
      case SocialExportKind.blocks:
        return {
          'key': doc.id,
          'uid': doc.id,
          'nickname': _string(d['blockedName']),
          'createdAt': _iso(d['createdAt']),
        };
    }
  }

  Map<String, Object?>? _request(RawDoc doc, {required String otherKey, required String nameKey}) {
    final other = doc.data[otherKey];
    if (other is! String || other.isEmpty) return null;
    return {
      'key': doc.id,
      'uid': other,
      'nickname': _string(doc.data[nameKey]),
      'createdAt': _iso(doc.data['createdAt']),
    };
  }

  static Map<String, Object?>? _rawDoc(Map<String, dynamic>? data) => data == null
      ? null
      : {
          'timestampFields': [
            for (final e in data.entries)
              if (e.value is DateTime) e.key,
          ],
          'data': ExportBuilder.encodeValue(data, <bool>[]),
        };

  Map<String, Object?> toJson() {
    final profile = SocialProfile.fromRaw(raw.social, raw.card);
    List<Map<String, Object?>> sorted(SocialExportKind kind) =>
        List.of(_entries[kind]!)..sort((a, b) => '${a['key']}'.compareTo('${b['key']}'));
    return {
      'handle': profile?.handle ?? _string(raw.social?['handle']),
      'discoverable': profile?.discoverable ?? false,
      'photoVisible': profile?.photoVisible ?? false,
      'pointer': _rawDoc(raw.social),
      'card': _rawDoc(raw.card),
      'counts': {
        'friends': _entries[SocialExportKind.friends]!.length,
        'requestsSent': _entries[SocialExportKind.requestsSent]!.length,
        'requestsReceived': _entries[SocialExportKind.requestsReceived]!.length,
        'blocks': _entries[SocialExportKind.blocks]!.length,
      },
      'friends': sorted(SocialExportKind.friends),
      'requestsSent': sorted(SocialExportKind.requestsSent),
      'requestsReceived': sorted(SocialExportKind.requestsReceived),
      'blocks': sorted(SocialExportKind.blocks),
    };
  }
}
