import '../data/export_data_source.dart';
import 'export_serializer.dart';

/// The export was abandoned (user cancelled or the account changed): nothing
/// must be delivered.
class ExportCancelled implements Exception {
  const ExportCancelled();
}

/// Documents per round trip. Small enough to keep memory and latency low,
/// large enough that 1000+ documents take a handful of reads.
const kExportPageSize = 300;

/// Reads every favorite page by page (no cap on the total) and builds the
/// file. Read-only. [isCurrent] is checked after every await: when it turns
/// false the work stops with [ExportCancelled]. [onProgress] receives the
/// number of documents read so far.
Future<ExportFile> runExport({
  required ExportDataSource source,
  required ExportSource from,
  required DateTime Function() now,
  required bool Function() isCurrent,
  void Function(int loaded)? onProgress,
  int pageSize = kExportPageSize,
}) async {
  final fromServer = from == ExportSource.server;
  final builder = ExportBuilder();
  String? cursor;
  while (true) {
    final page = await source.readPage(cursor: cursor, limit: pageSize, fromServer: fromServer);
    if (!isCurrent()) throw const ExportCancelled();
    page.docs.forEach(builder.add);
    onProgress?.call(builder.documents);
    // Lets the UI repaint between pages even if the source answers instantly.
    await Future<void>.delayed(Duration.zero);
    if (!isCurrent()) throw const ExportCancelled();
    if (page.docs.length < pageSize) break;
    final next = page.docs.last.id;
    if (next == cursor) {
      // The source did not advance: stop instead of looping forever.
      throw const ExportReadException(ExportReadFailureKind.unknown, code: 'cursor-stuck');
    }
    cursor = next;
  }
  final profile = await source.readProfile(fromServer: fromServer);
  if (!isCurrent()) throw const ExportCancelled();
  return builder.build(exportedAt: now(), source: from, profile: profile);
}
