import 'package:flutter/widgets.dart';

import '../models/title_video.dart';

/// No in-page player outside the web build: the trailer dialog falls back to
/// opening YouTube (docs/45, option c).
const inlinePlayerSupported = false;

Widget buildTrailerPlayer(BuildContext context, TitleVideo video, String title) =>
    throw UnsupportedError('No in-page trailer player on this platform');
