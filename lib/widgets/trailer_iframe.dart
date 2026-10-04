import 'package:web/web.dart' as web;

/// Tokens the YouTube embed needs and nothing more: scripts and its own origin
/// to run the player, presentation (fullscreen), and popups for the "Watch on
/// YouTube" link. No forms, no top navigation, no downloads (docs/45).
const kTrailerSandbox =
    'allow-scripts allow-same-origin allow-presentation allow-popups allow-popups-to-escape-sandbox';
const kTrailerAllow = 'autoplay; encrypted-media; picture-in-picture; fullscreen';
const kTrailerReferrerPolicy = 'strict-origin-when-cross-origin';

/// The `<iframe>` of the trailer. Kept apart from the widget so a browser test
/// can inspect the real element.
web.HTMLIFrameElement buildTrailerIframe({required String src, required String title}) {
  final frame = web.HTMLIFrameElement()
    ..src = src
    ..title = title
    ..allow = kTrailerAllow
    ..allowFullscreen = true
    ..referrerPolicy = kTrailerReferrerPolicy;
  frame.setAttribute('sandbox', kTrailerSandbox);
  frame.style
    ..border = '0'
    ..width = '100%'
    ..height = '100%';
  return frame;
}

/// Owner of the element: [close] blanks the frame (the video stops at once) and
/// removes it from the page. Called when the dialog is dismissed.
class TrailerFrame {
  final web.HTMLIFrameElement element;

  /// Frames created and not closed yet (the browser tests check that it is
  /// empty once a dialog starts closing: no player, no sound, no leak).
  static final Set<TrailerFrame> open = {};

  TrailerFrame({required String src, required String title})
    : element = buildTrailerIframe(src: src, title: title) {
    open.add(this);
  }

  /// Idempotent.
  void close() {
    open.remove(this);
    element.src = 'about:blank';
    element.remove();
  }
}
