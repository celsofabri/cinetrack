import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// True when the browser has the Web Share API (`navigator.share`, mostly
/// phones). No dependency: it is one call of the standard API.
final shareSupported = (web.window.navigator as JSObject).hasProperty('share'.toJS).toDart;

/// Opens the system share sheet. False when the user closed it or it failed:
/// nothing to report, the link can still be copied.
Future<bool> shareLink({required String title, required String text, required String url}) async {
  try {
    await web.window.navigator.share(web.ShareData(title: title, text: text, url: url)).toDart;
    return true;
  } catch (_) {
    return false;
  }
}
