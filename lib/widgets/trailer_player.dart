import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/title_video.dart';
import 'trailer_player_stub.dart'
    if (dart.library.js_interop) 'trailer_player_web.dart'
    as platform;

/// Builds the in-page player of [video] (docs/45). Only ever called after the
/// user opened the trailer dialog, so nothing from YouTube is loaded before.
typedef TrailerPlayerBuilder =
    Widget Function(BuildContext context, TitleVideo video, String title);

/// The in-page player of this platform, or null when there is none (Android,
/// iOS, desktop: the dialog offers "open on YouTube" instead). Overridden in
/// tests.
final trailerPlayerBuilderProvider = Provider<TrailerPlayerBuilder?>(
  (ref) => platform.inlinePlayerSupported ? platform.buildTrailerPlayer : null,
);
