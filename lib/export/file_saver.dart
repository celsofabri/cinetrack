import 'dart:typed_data';

import 'file_saver_stub.dart' if (dart.library.js_interop) 'file_saver_web.dart' as platform;

/// Hands a file to the user. Implementations never write to the app's own
/// storage or cache and never send the bytes anywhere.
abstract class ExportFileSaver {
  /// False on platforms where no delivery is implemented yet.
  bool get isSupported;

  /// Starts the download/save of [bytes] as [fileName]. Throws on failure.
  Future<void> save({required String fileName, required Uint8List bytes});
}

/// Saver for the current platform (web download; unsupported elsewhere).
ExportFileSaver createPlatformFileSaver() => platform.createFileSaver();
