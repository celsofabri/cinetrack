/// One raw Firestore document: its id and ALL its fields exactly as stored
/// (timestamps already converted to [DateTime] at the data source edge, any
/// other value untouched). Unknown/future fields are therefore preserved.
class RawDoc {
  final String id;
  final Map<String, dynamic> data;

  const RawDoc(this.id, this.data);
}

/// One page of `users/{uid}/favorites`, ordered by document id.
class RawPage {
  final List<RawDoc> docs;

  const RawPage(this.docs);
}

enum ExportReadFailureKind {
  /// No (confirmed) connection to the server: timeout, offline.
  unreachable,

  /// Rules / session refused the read.
  denied,
  unknown,
}

/// A read for the export failed. [code] is the provider's error code only
/// (never document data): safe to show or log.
class ExportReadException implements Exception {
  final ExportReadFailureKind kind;
  final String? code;

  const ExportReadException(this.kind, {this.code});

  @override
  String toString() => 'ExportReadException($kind, code: $code)';
}

/// Read-only seam for "Exportar meus dados": raw documents of the signed-in
/// user, page by page. Never writes. Implementations: Firestore (production)
/// and fakes (tests). Bound to a single uid.
abstract class ExportDataSource {
  /// Documents after [cursor] (the last id of the previous page; null for
  /// the first page), at most [limit]. [fromServer] true = read from the
  /// server only (throws [ExportReadException] when it cannot be confirmed);
  /// false = whatever this device has stored.
  Future<RawPage> readPage({String? cursor, required int limit, required bool fromServer});

  /// Raw `users/{uid}` document, or null when it does not exist (or, from
  /// the device, is not stored there).
  Future<Map<String, dynamic>?> readProfile({required bool fromServer});
}
