import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_type.dart';
import '../providers/providers.dart';
import '../widgets/poster_image.dart';

class MovieDetailsScreen extends ConsumerWidget {
  final int movieId;

  const MovieDetailsScreen({super.key, required this.movieId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesListProvider).value ?? [];
    final matches =
        favorites.where((f) => f.id == movieId && f.mediaType == MediaType.movie);
    final item = matches.isEmpty ? null : matches.first;

    if (item == null) {
      return const Scaffold(
        body: Center(child: Text('Este filme não está mais nos seus favoritos.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(item.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remover dos favoritos',
            onPressed: () {
              ref.read(favoritesRepositoryProvider).remove(item.id, MediaType.movie);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PosterImage(posterPath: item.posterPath, width: 120, height: 180),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 12),
                      FilterChip(
                        label: Text(item.watchedMovie ? 'Assistido' : 'Marcar como assistido'),
                        selected: item.watchedMovie,
                        onSelected: (_) => ref
                            .read(favoritesRepositoryProvider)
                            .toggleMovieWatched(item.id),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              item.overview.isEmpty ? 'Sem sinopse disponível.' : item.overview,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
