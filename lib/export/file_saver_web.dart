import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_saver.dart';

ExportFileSaver createFileSaver() => const _WebFileSaver();

/// Browser download through a Blob and a temporary anchor. The bytes stay in
/// memory only (the object URL is revoked shortly after); nothing is stored
/// by the app and nothing is sent anywhere.
class _WebFileSaver implements ExportFileSaver {
  const _WebFileSaver();

  @override
  bool get isSupported => true;

  @override
  Future<void> save({required String fileName, required Uint8List bytes}) async {
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'application/json'));
    final url = web.URL.createObjectURL(blob);
    try {
      final anchor = web.HTMLAnchorElement()
        ..href = url
        ..download = fileName
        ..style.display = 'none';
      web.document.body!.append(anchor);
      anchor.click();
      anchor.remove();
    } finally {
      // The browser has already taken what it needs once click() returns;
      // the delay is only a margin for slower browsers.
      Future<void>.delayed(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
    }
  }
}
