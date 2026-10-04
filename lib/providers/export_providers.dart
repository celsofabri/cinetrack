import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/export_data_source.dart';
import '../data/firestore_export_data_source.dart';
import '../export/data_exporter.dart';
import '../export/export_serializer.dart';
import '../export/file_saver.dart';
import 'providers.dart';
import 'sync_providers.dart';

typedef ExportDataSourceFactory = ExportDataSource Function(String uid);

/// Builds the read-only export source for a uid. Overridden in tests.
final exportDataSourceFactoryProvider = Provider<ExportDataSourceFactory>(
  (ref) =>
      (uid) => FirestoreExportDataSource(uid: uid),
);

/// How the file reaches the user. Overridden in tests.
final exportFileSaverProvider = Provider<ExportFileSaver>((ref) => createPlatformFileSaver());

/// "Now" for the export (file date and `exportedAt`). Overridden in tests.
final exportClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

enum ExportPhase {
  idle,
  running,

  /// The server could not be reached: waiting for the user to choose
  /// between trying again and exporting what this device has.
  needsDeviceChoice,
  success,
  failure,
}

enum ExportFailureKind { unreachable, denied, unknown, emptyDevice, delivery, unsupported }

class ExportState {
  final ExportPhase phase;

  /// Documents read so far (while running).
  final int loaded;
  final ExportSummary? summary;
  final String? fileName;
  final ExportFailureKind? failure;

  /// The delivered file came from this device, not from the server.
  final bool fromDevice;

  /// There were local changes the server had not confirmed when the export
  /// started (a server read may not contain them).
  final bool hadPendingWrites;

  const ExportState({
    this.phase = ExportPhase.idle,
    this.loaded = 0,
    this.summary,
    this.fileName,
    this.failure,
    this.fromDevice = false,
    this.hadPendingWrites = false,
  });

  bool get busy => phase == ExportPhase.running || phase == ExportPhase.needsDeviceChoice;
}

/// Runs "Exportar meus dados". Strictly read-only. The state is reset (and an
/// export in flight is dropped, never delivered) when the account changes.
class ExportController extends Notifier<ExportState> {
  /// Generation of the current `build()`; also bumped by [cancel]. A run
  /// that sees a different number than the one it started with is stale.
  int _generation = 0;

  @override
  ExportState build() {
    _generation++;
    ref.watch(currentUidProvider);
    return const ExportState();
  }

  void cancel() {
    _generation++;
    state = const ExportState();
  }

  /// Back to the initial state (dismisses a result or error).
  void dismiss() {
    if (!state.busy) state = const ExportState();
  }

  Future<void> start({bool fromDevice = false}) async {
    if (state.phase == ExportPhase.running) return;
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;

    final saver = ref.read(exportFileSaverProvider);
    if (!saver.isSupported) {
      state = const ExportState(phase: ExportPhase.failure, failure: ExportFailureKind.unsupported);
      return;
    }

    final generation = ++_generation;
    // Stale = cancelled, or the signed-in account is no longer the one the
    // export started for.
    bool current() => generation == _generation && ref.read(currentUidProvider) == uid;

    final source = ref.read(exportDataSourceFactoryProvider)(uid);
    final from = fromDevice ? ExportSource.device : ExportSource.server;
    final pending = !fromDevice && ref.read(syncStatusProvider).hasPendingWrites;
    final now = ref.read(exportClockProvider);
    state = ExportState(phase: ExportPhase.running, fromDevice: fromDevice);

    try {
      final file = await runExport(
        source: source,
        from: from,
        now: now,
        isCurrent: current,
        onProgress: (loaded) {
          if (current()) state = ExportState(phase: ExportPhase.running, loaded: loaded);
        },
      );
      if (fromDevice && file.summary.documents == 0) {
        // Never hand over an empty file as if it were the user's data.
        state = const ExportState(
          phase: ExportPhase.failure,
          failure: ExportFailureKind.emptyDevice,
        );
        return;
      }
      final fileName = exportFileName(now());
      // Last check before the data leaves the app.
      if (!current()) return;
      try {
        await saver.save(fileName: fileName, bytes: file.bytes);
      } catch (_) {
        if (current()) {
          state = const ExportState(
            phase: ExportPhase.failure,
            failure: ExportFailureKind.delivery,
          );
        }
        return;
      }
      if (!current()) return;
      state = ExportState(
        phase: ExportPhase.success,
        summary: file.summary,
        fileName: fileName,
        fromDevice: fromDevice,
        hadPendingWrites: pending,
      );
    } on ExportCancelled {
      // Superseded: the newer state (idle / other account) is not touched.
    } on ExportReadException catch (e) {
      if (!current()) return;
      if (e.kind == ExportReadFailureKind.unreachable && !fromDevice) {
        state = const ExportState(phase: ExportPhase.needsDeviceChoice);
      } else {
        state = ExportState(
          phase: ExportPhase.failure,
          failure: switch (e.kind) {
            ExportReadFailureKind.unreachable => ExportFailureKind.unreachable,
            ExportReadFailureKind.denied => ExportFailureKind.denied,
            ExportReadFailureKind.unknown => ExportFailureKind.unknown,
          },
        );
      }
    } catch (_) {
      if (current()) {
        state = const ExportState(phase: ExportPhase.failure, failure: ExportFailureKind.unknown);
      }
    }
  }
}

final exportControllerProvider = NotifierProvider<ExportController, ExportState>(
  ExportController.new,
);
