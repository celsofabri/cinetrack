@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:cinetrack/models/title_video.dart';
import 'package:cinetrack/widgets/trailer_iframe.dart';

// docs/45: the REAL <iframe>. Run with `flutter test --platform chrome
// test/trailer_iframe_browser_test.dart` (the default VM run skips it).

const _video = TitleVideo(key: 'dQw4w9WgXcQ', name: 'x', type: 'Trailer', official: true);

/// All iframes, whether the platform view sits in the page or in the shadow
/// root of the Flutter glass pane.
List<web.HTMLIFrameElement> _frames() {
  final found = <web.HTMLIFrameElement>[];
  void scan(web.NodeList list) {
    for (var i = 0; i < list.length; i++) {
      found.add(list.item(i)! as web.HTMLIFrameElement);
    }
  }

  scan(web.document.querySelectorAll('iframe'));
  final shadow = web.document.querySelector('flt-glass-pane')?.shadowRoot;
  if (shadow != null) scan(shadow.querySelectorAll('iframe'));
  return found;
}

void main() {
  test('the iframe has the nocookie src, sandbox, allow, referrer policy and a title', () {
    final f = buildTrailerIframe(src: _video.embedUri.toString(), title: 'Trailer de Matrix');
    expect(f.src, startsWith('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?'));
    expect(f.src, isNot(contains('youtube.com/embed')));
    expect(f.getAttribute('sandbox'), kTrailerSandbox);
    expect(f.getAttribute('sandbox'), isNot(contains('allow-top-navigation')));
    expect(f.getAttribute('sandbox'), isNot(contains('allow-forms')));
    expect(f.allow, contains('fullscreen'));
    expect(f.allowFullscreen, isTrue);
    expect(f.referrerPolicy, 'strict-origin-when-cross-origin');
    expect(f.title, 'Trailer de Matrix');
  });

  test('closing removes the element from the page and stops the video', () {
    expect(_frames().length, 0); // nothing exists before the dialog builds the player
    final frame = TrailerFrame(src: _video.embedUri.toString(), title: 'Trailer de Matrix');
    web.document.body!.append(frame.element);
    expect(_frames().length, 1);

    frame.close();
    expect(_frames().length, 0);
    expect(frame.element.src, 'about:blank');
  });
}
