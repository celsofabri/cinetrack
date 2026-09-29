import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/tmdb_api_client.dart';

class PosterImage extends StatelessWidget {
  final String? posterPath;
  final double width;
  final double height;

  const PosterImage({
    super.key,
    required this.posterPath,
    this.width = 92,
    this.height = 138,
  });

  @override
  Widget build(BuildContext context) {
    final path = posterPath;
    final placeholder = Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.movie_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

    if (path == null || path.isEmpty) return placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: '${TmdbApiClient.imageBaseUrl}/w342$path',
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }
}
