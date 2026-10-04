import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import '../models/title_video.dart';
import 'trailer_iframe.dart';

const inlinePlayerSupported = true;

Widget buildTrailerPlayer(BuildContext context, TitleVideo video, String title) =>
    _YoutubeIframe(video: video, title: title);

int _viewSeq = 0;

/// The YouTube player as an `<iframe>` on the privacy-enhanced domain
/// (`youtube-nocookie.com`). Created only when this widget is built, which
/// happens after the user opened the dialog; removing the widget removes the
/// iframe (and stops the video). Nothing about the user is put in the URL.
class _YoutubeIframe extends StatefulWidget {
  final TitleVideo video;
  final String title;

  const _YoutubeIframe({required this.video, required this.title});

  @override
  State<_YoutubeIframe> createState() => _YoutubeIframeState();
}

class _YoutubeIframeState extends State<_YoutubeIframe> {
  late final String _viewType = 'cinetrack-trailer-${_viewSeq++}';

  @override
  void initState() {
    super.initState();
    final src = widget.video.embedUri.toString();
    final title = 'Trailer de ${widget.title}';
    final frame = _frame = TrailerFrame(src: src, title: title);
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) => frame.element);
  }

  TrailerFrame? _frame;
  Animation<double>? _routeAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Stop the video when the dialog STARTS closing (X, Esc, tap outside,
    // browser back): the exit animation must not keep playing sound.
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = animation?..addStatusListener(_onRouteStatus);
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse || status == AnimationStatus.dismissed) {
      _frame?.close();
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    // Safety net: whatever way the player leaves the tree, the frame goes too.
    _frame?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
