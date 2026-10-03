import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../providers/catalog_sync_providers.dart';
import '../providers/providers.dart';
import '../providers/sync_providers.dart';
import '../services/favorite_status.dart';
import 'empty_state.dart';
import 'sync_widgets.dart';
import 'poster_image.dart';
import 'progress_badge.dart';

enum _Filter { all, movies, tv }

/// "Em andamento" = movie not watched, series not started or incomplete (or
/// still being calculated). "Concluídos" = watched movie, series with every
/// aired episode watched. See docs/18.
enum _Group { inProgress, completed }

/// Poster proportion of TMDB (w342: 342x513). The favorites cards use it for
/// the thumbnail box so the whole poster shows, never a square crop.
const double kPosterAspectRatio = 2 / 3;
const double _posterWidth = 88;
const double _posterHeight = _posterWidth / kPosterAspectRatio;

/// Body of FavoritesScreen: the Todos/Filmes/Séries filter, the Em
/// andamento/Concluídos groups (with counters) and the favorites list, newest
/// activity first. The screen's AppBar carries the "Meus favoritos" title.
class FavoritesSection extends ConsumerStatefulWidget {
  const FavoritesSection({super.key});

  @override
  ConsumerState<FavoritesSection> createState() => _FavoritesSectionState();
}

class _FavoritesSectionState extends ConsumerState<FavoritesSection> {
  _Filter _filter = _Filter.all;
  _Group _group = _Group.inProgress;

  @override
  void initState() {
    super.initState();
    // Opening the list re-checks series whose seasons are not on this device
    // yet (also retries earlier failures).
    Future.microtask(() {
      if (mounted) ref.read(catalogSyncProvider.notifier).retry();
    });
  }

  @override
  Widget build(BuildContext context) {
    final favoritesAsync = ref.watch(favoritesListProvider);
    final gate = ref.watch(favoritesGateProvider);
    final sync = ref.watch(catalogSyncProvider);

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
            if (favorites.isEmpty) {
              return const EmptyState(
                icon: Icons.favorite_border,
                title: 'Nenhum favorito ainda',
                message: 'Toque na lupa para buscar um filme ou série e favoritar.',
              );
            }

            final entries = [
              for (final item in favorites)
                if (switch (_filter) {
                  _Filter.all => true,
                  _Filter.movies => item.mediaType == MediaType.movie,
                  _Filter.tv => item.mediaType == MediaType.tv,
                })
                  (
                    item: item,
                    status: FavoriteStatus.of(
                      item,
                      settled: sync.settled.contains(item.id),
                      failed: sync.failed.contains(item.id),
                    ),
                  ),
            ];
            final done = entries.where((e) => e.status.isCompleted).toList();
            final open = entries.where((e) => !e.status.isCompleted).toList();
            final shown = (_group == _Group.completed ? done : open)
              ..sort((a, b) => FavoriteItem.byRecentActivity(a.item, b.item));
            final failedCount =
                entries.where((e) => e.status.state == WatchState.unavailable).length;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: SegmentedButton<_Group>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: _Group.inProgress,
                          label: Text('Em andamento (${open.length})'),
                        ),
                        ButtonSegment(
                          value: _Group.completed,
                          label: Text('Concluídos (${done.length})'),
                        ),
                      ],
                      selected: {_group},
                      onSelectionChanged: (s) => setState(() => _group = s.first),
                    ),
                  ),
                ),
                if (failedCount > 0)
                  _ProgressRetryBanner(
                    count: failedCount,
                    onRetry: () => ref.read(catalogSyncProvider.notifier).retry(),
                  ),
                if (shown.isEmpty)
                  _emptyGroup(entries.isEmpty, _group)
                else
                  _FavoritesGrid(entries: shown),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _emptyGroup(bool filterEmpty, _Group group) {
    if (filterEmpty) {
      return const EmptyState(
        icon: Icons.favorite_border,
        title: 'Nada neste filtro',
        message: 'Troque o filtro acima ou adicione mais itens.',
      );
    }
    return group == _Group.inProgress
        ? const EmptyState(
            icon: Icons.playlist_add_check,
            title: 'Nada em andamento',
            message: 'Tudo o que você favoritou já foi concluído. Veja a aba Concluídos '
                'ou adicione mais títulos.',
          )
        : const EmptyState(
            icon: Icons.check_circle_outline,
            title: 'Nada concluído ainda',
            message: 'Filmes assistidos e séries com todos os episódios já exibidos '
                'assistidos aparecem aqui.',
          );
  }
}

typedef _Entry = ({FavoriteItem item, FavoriteStatus status});

class _ProgressRetryBanner extends StatelessWidget {
  final int count;
  final VoidCallback onRetry;

  const _ProgressRetryBanner({required this.count, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            count == 1
                ? 'Não foi possível calcular o progresso de 1 série.'
                : 'Não foi possível calcular o progresso de $count séries.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRetry,
            child: const Text('Tentar de novo'),
          ),
        ],
      ),
    );
  }
}

/// Responsive list/grid: one column on phones, more as the width grows. Every
/// card has a fixed 2:3 poster box, so thumbnails look the same everywhere.
class _FavoritesGrid extends StatelessWidget {
  final List<_Entry> entries;

  const _FavoritesGrid({required this.entries});

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 460,
        mainAxisExtent: (_posterHeight + 20) * scale,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) =>
          _FavoriteCard(item: entries[index].item, status: entries[index].status),
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  final FavoriteItem item;
  final FavoriteStatus status;

  const _FavoriteCard({required this.item, required this.status});

  @override
  Widget build(BuildContext context) {
    final isMovie = item.mediaType == MediaType.movie;
    final theme = Theme.of(context);

    final Widget statusWidget = isMovie
        ? Text(
            item.watchedMovie ? 'Assistido' : 'Não assistido',
            style: theme.textTheme.bodyMedium,
          )
        : SeriesStatusBadge(status: status);

    return Semantics(
      button: true,
      container: true,
      label: '${item.title}, ${isMovie ? 'filme' : 'série'}',
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(isMovie ? '/movie/${item.id}' : '/tv/${item.id}'),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Exact 2:3 box + contain: the whole poster, no crop.
                PosterImage(
                  posterPath: item.posterPath,
                  width: _posterWidth,
                  height: _posterHeight,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      statusWidget,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
