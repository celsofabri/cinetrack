import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'share_link_stub.dart' if (dart.library.js_interop) 'share_link_web.dart' as platform;

/// Opens the system share sheet with a link; true when it was shared. Overridden
/// in tests.
typedef ShareLink =
    Future<bool> Function({required String title, required String text, required String url});

/// The platform's share, or null when there is none (then the invite section
/// only offers "Copiar").
final shareLinkProvider = Provider<ShareLink?>(
  (ref) => platform.shareSupported ? platform.shareLink : null,
);

/// The page the app is served from (`Uri.base`: it honours `<base href>`, so
/// under GitHub Pages it is `https://host/cinetrack/`). The invite link is
/// built from it. Overridden in tests.
final inviteLinkBaseProvider = Provider<Uri>((ref) => Uri.base);
