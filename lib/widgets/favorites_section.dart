import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../providers/providers.dart';
import '../providers/sync_providers.dart';
import '../services/progress_calculator.dart';
import 'empty_state.dart';
import 'sync_widgets.dart';
import 'poster_image.dart';
import 'progress_badge.dart';

enum _Filter { all, movies, tv }

/// Body of FavoritesScreen: the Todos/Filmes/Séries filter plus the
/// favorites list. The screen's AppBar carries the "Meus favoritos" title.
class FavoritesSection extends ConsumerStatefulWidget {
  const FavoritesSection({super.key});

  @override
  ConsumerState<FavoritesSection> createState() => _FavoritesSectionState();
}

class _FavoritesSectionState extends ConsumerState<FavoritesSection> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final favoritesAsync = ref.watch(favoritesListProvider);
    final gate = ref.watch(favoritesGateProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SegmentedButton<_Filter>(
              segments: const [
                ButtonSegment(value: _Filter.all, label: Text('Todos')),
                ButtonSegment(value: _Filter.movies, label: Text('Filmes')),
                ButtonSegment(value: _Filter.tv, label: Text('Séries')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
        ),
        favoritesAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => const FavoritesLoadError(),
          data: (favorites) {
            // Empty but never confirmed by the server: loading or "could
            // not load", never the misleading "Nenhum favorito ainda".
            if (favorites.isEmpty && gate == FavoritesGate.loading) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (favorites.isEmpty && gate == FavoritesGate.unconfirmed) {
              return const FavoritesLoadError();
            }
            final filtered = favorites.where((f) {
              return switch (_filter) {
                _Filter.all => true,
                _Filter.movies => f.mediaType == MediaType.movie,
                _Filter.tv => f.mediaType == MediaType.tv,
              };
            }).toList()
              ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

            if (filtered.isEmpty) {
              return EmptyState(
                icon: Icons.favorite_border,
                title: favorites.isEmpty
                    ? 'Nenhum favorito ainda'
                    : 'Nada neste filtro',
                message: favorites.isEmpty
                    ? 'Toque na lupa para buscar um filme ou série e favoritar.'
                    : 'Troque o filtro acima ou adicione mais itens.',
              );
            }

            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filtered.length,
              itemBuilder: (context, index) =>
                  _FavoriteTile(item: filtered[index]),
            );
          },
        ),
      ],
    );
  }
}

class _FavoriteTile extends StatelessWidget {
  final FavoriteItem item;

  const _FavoriteTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final isMovie = item.mediaType == MediaType.movie;
    final progress =
        isMovie ? null : ProgressCalculator.compute(item.seasons ?? const []);

    return ListTile(
      leading: PosterImage(posterPath: item.posterPath, width: 56, height: 84),
      title: Text(item.title),
      subtitle: isMovie
          ? Text(item.watchedMovie ? 'Assistido' : 'Não assistido')
          : ProgressBadge(
              watched: progress!.watchedCount,
              total: progress.totalCount,
            ),
      onTap: () =>
          context.push(isMovie ? '/movie/${item.id}' : '/tv/${item.id}'),
    );
  }
}
