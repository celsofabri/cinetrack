import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/tmdb_api_client.dart';

class PosterImage extends StatelessWidget {
  final String? posterPath;
  final double width;
  final double height;

  /// `cover` fills the box (may crop an image that is not exactly 2:3);
  /// `contain` always shows the whole poster. Lists of favorites use
  /// `contain` inside a 2:3 box.
  final BoxFit fit;

  /// Shown when there is no image or it fails (people use a person icon).
  final IconData placeholderIcon;

  /// TMDB image size segment: posters use w342; profile photos only come in
  /// w45 / w185 / h632 / original.
  final String imageSize;

  const PosterImage({
    super.key,
    required this.posterPath,
    this.width = 92,
    this.height = 138,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.movie_outlined,
    this.imageSize = 'w342',
  });

  @override
  Widget build(BuildContext context) {
    final path = posterPath;
    final placeholder = Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        placeholderIcon,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

    if (path == null || path.isEmpty) return placeholder;

    final url = '${TmdbApiClient.imageBaseUrl}/$imageSize$path';

    // On web, cached_network_image re-fetches through its own XHR cache each
    // time a scrolled-off tile is rebuilt, and a failed/throttled request
    // silently leaves the placeholder. Image.network goes through Flutter's
    // in-memory ImageCache plus the browser HTTP cache (TMDB sends
    // max-age + CORS *), so posters survive scrolling away and back.
    final Widget image = kIsWeb
        ? Image.network(
            url,
            width: width,
            height: height,
            fit: fit,
            gaplessPlayback: true,
            webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
            loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
            errorBuilder: (_, __, ___) => placeholder,
          )
        : CachedNetworkImage(
            imageUrl: url,
            width: width,
            height: height,
            fit: fit,
            placeholder: (_, __) => placeholder,
            errorWidget: (_, __, ___) => placeholder,
          );

    return ClipRRect(borderRadius: BorderRadius.circular(8), child: image);
  }
}
