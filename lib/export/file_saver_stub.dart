import 'dart:typed_data';

import 'file_saver.dart';

/// Android/iOS/desktop: delivery is not implemented (it would need a native
/// plugin for sharing/saving; the web build is the supported path today).
ExportFileSaver createFileSaver() => const _UnsupportedFileSaver();

class _UnsupportedFileSaver implements ExportFileSaver {
  const _UnsupportedFileSaver();

  @override
  bool get isSupported => false;

  @override
  Future<void> save({required String fileName, required Uint8List bytes}) =>
      Future.error(UnsupportedError('File export is only available on the web build'));
}
