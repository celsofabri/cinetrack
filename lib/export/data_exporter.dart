import '../data/export_data_source.dart';
import '../social/social_models.dart';
import 'export_serializer.dart';
import 'social_export.dart';

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
/// number of documents read so far. [uid] (the exported user) is needed to
/// tell who "the other" is in a friendship; without it friendships are listed
/// as not recognized (raw data kept).
Future<ExportFile> runExport({
  required ExportDataSource source,
  required ExportSource from,
  required DateTime Function() now,
  required bool Function() isCurrent,
  String? uid,
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
  final social = await source.readSocial(fromServer: fromServer);
  if (!isCurrent()) throw const ExportCancelled();
  // The lists are read even WITHOUT the pointer (docs/71 G6): a deactivation whose last
  // sweep failed ("Concluir limpeza" pending) or an interrupted account deletion can leave
  // friendships, requests or blocks behind, and they are the user's data too. Costs 4
  // reads for an account that never turned friendships on; with the rules not published
  // yet those reads are denied and simply mean "nothing".
  final hasPointer = social != null && social.social != null;
  final section = SocialExport(social ?? const RawSocial(), uid: uid);
  var residue = false;
  for (final kind in SocialExportKind.values) {
    String? socialCursor;
    while (true) {
      final RawPage page;
      try {
        page = await source.readSocialPage(
          kind,
          cursor: socialCursor,
          limit: pageSize,
          fromServer: fromServer,
        );
      } on ExportReadException catch (e) {
        if (!hasPointer && e.kind == ExportReadFailureKind.denied) break;
        rethrow;
      }
      if (!isCurrent()) throw const ExportCancelled();
      for (final doc in page.docs) {
        section.add(kind, doc);
        residue = true;
      }
      if (page.docs.length < pageSize) break;
      final next = page.docs.last.id;
      if (next == socialCursor) {
        throw const ExportReadException(ExportReadFailureKind.unknown, code: 'cursor-stuck');
      }
      socialCursor = next;
    }
  }
  // Without pointer and without residue there is nothing social: no section (as before).
  if (hasPointer || residue) builder.social = section;
  return builder.build(exportedAt: now(), source: from, profile: profile);
}
