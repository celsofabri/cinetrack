import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../providers/catalog_sync_providers.dart';
import '../providers/providers.dart';
import '../providers/sync_providers.dart';
import '../services/favorite_status.dart';
import 'detail_actions.dart';
import 'empty_state.dart';
import 'series_bulk_flow.dart';
import 'sync_widgets.dart';
import 'poster_image.dart';
import 'progress_badge.dart';

export 'series_bulk_flow.dart' show BulkWatchDialog, kAckSettle, kAckVerify, kAckWait;

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

class _FavoritesSectionState extends ConsumerState<FavoritesSection>
    with SeriesBulkFlow<FavoritesSection> {
  _Filter _filter = _Filter.all;
  _Group _group = _Group.inProgress;

  /// Storage keys whose quick-watched action is running (anti double tap). Kept
  /// here, not in the card: the card can leave the tab as soon as the item
  /// changes group.
  final Set<String> _busy = {};

  /// Key whose confirmation dialog is open: it is modal, so no spinner is shown
  /// on the card meanwhile (the guard in [_busy] still holds).
  String? _dialogKey;

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
  void dispose() {
    disposeBulkFlow();
    super.dispose();
  }

  void _setBusy(String key, bool busy) {
    if (!mounted) return;
    setState(() => busy ? _busy.add(key) : _busy.remove(key));
  }

  /// Movie: flips `watchedMovie` straight away (no confirmation). Series: opens
  /// the confirmation, applies the change in one write and offers "Desfazer".
  Future<void> _toggleWatched(FavoriteItem item, FavoriteStatus status) async {
    final key = item.storageKey;
    if (_busy.contains(key) || bulkBusy.contains(key)) return;
    _setBusy(key, true);
    try {
      if (item.mediaType == MediaType.movie) {
        await runDetailWrite(context, (repo) => repo.setMovieWatched(item.id, !item.watchedMovie));
      } else {
        await toggleSeriesBulk(
          series: item.toSearchResult(),
          isFavorite: true,
          markAll: !status.isCompleted,
          onDialog: (open) {
            if (mounted) setState(() => _dialogKey = open ? key : null);
          },
        );
      }
    } finally {
      _setBusy(key, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A different account never sees (or undoes) the previous one's action.
    ref.listen(currentUidProvider, (_, _) => discardBulkUndo());
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
                    onRetry: () => ref.read(catalogSyncProvider.notifier).retry(force: true),
                  ),
                if (shown.isEmpty)
                  _emptyGroup(entries.isEmpty, _group)
                else
                  _FavoritesGrid(
                    entries: shown,
                    busy: {..._busy, ...bulkBusy}..remove(_dialogKey),
                    onToggleWatched: _toggleWatched,
                  ),
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
  final Set<String> busy;
  final void Function(FavoriteItem item, FavoriteStatus status) onToggleWatched;

  const _FavoritesGrid({required this.entries, required this.busy, required this.onToggleWatched});

  @override
  Widget build(BuildContext context) {
    // No fixed card height: each row is as tall as its tallest card (any font
    // scale), and the cards of a row stretch to it so their chips line up.
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        const maxExtent = 460.0;
        final inner = constraints.maxWidth - 24;
        final columns = math.max(1, (inner / (maxExtent + spacing)).ceil());
        final rows = <Widget>[];
        for (var i = 0; i < entries.length; i += columns) {
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var c = 0; c < columns; c++) ...[
                    if (c > 0) const SizedBox(width: spacing),
                    Expanded(
                      child: i + c < entries.length
                          ? _FavoriteCard(
                              key: ValueKey(entries[i + c].item.storageKey),
                              item: entries[i + c].item,
                              status: entries[i + c].status,
                              pending: busy.contains(entries[i + c].item.storageKey),
                              onToggleWatched: () => onToggleWatched(
                                entries[i + c].item,
                                entries[i + c].status,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
          if (i + columns < entries.length) rows.add(const SizedBox(height: spacing));
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Column(children: rows),
        );
      },
    );
  }
}

class _FavoriteCard extends StatelessWidget {
  final FavoriteItem item;
  final FavoriteStatus status;
  final bool pending;
  final VoidCallback onToggleWatched;

  const _FavoriteCard({
    super.key,
    required this.item,
    required this.status,
    required this.pending,
    required this.onToggleWatched,
  });

  @override
  Widget build(BuildContext context) {
    final isMovie = item.mediaType == MediaType.movie;
    final theme = Theme.of(context);

    // Movies: the chip itself says watched / not (no duplicated status text).
    final Widget? statusWidget = isMovie ? null : SeriesStatusBadge(status: status);

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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Exact 2:3 box + contain: the whole poster, no crop.
                Align(
                  alignment: Alignment.topCenter,
                  child: PosterImage(
                    posterPath: item.posterPath,
                    width: _posterWidth,
                    height: _posterHeight,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (statusWidget != null) ...[const SizedBox(height: 2), statusWidget],
                      // Labelled chip anchored at the base of the card (aligned between
                      // neighbours), left aligned. Same height in every state (no
                      // layout shift); the label wraps instead of being cut.
                      const Spacer(),
                      // Two independent chips side by side; on a narrow card (or
                      // large font) the second one drops to the next line.
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          QuickWatchedButton(
                            title: item.title,
                            isMovie: isMovie,
                            watched: isMovie ? item.watchedMovie : status.isCompleted,
                            pending: pending,
                            onPressed: onToggleWatched,
                          ),
                          RecommendToggleChip(
                            recommended: item.recommended,
                            title: item.title,
                            onSet: (target) => setRecommendedFromUi(
                              context,
                              item.toSearchResult(),
                              inFavorites: true,
                              recommended: target,
                            ),
                          ),
                        ],
                      ),
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

/// Quick watched control of a favorites card: the same chip as the details
/// ("Marcar como assistido" / "Assistido", icon + text, 48 px target). Its tap
/// wins over the card's InkWell, so it never opens the details.
class QuickWatchedButton extends StatelessWidget {
  final String title;
  final bool isMovie;
  final bool watched;
  final bool pending;
  final VoidCallback onPressed;

  const QuickWatchedButton({
    super.key,
    required this.title,
    required this.isMovie,
    required this.watched,
    required this.pending,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final label = isMovie
        ? (watched ? 'Assistido: desmarcar $title' : 'Marcar como assistido: $title')
        : (watched
              ? 'Assistido: desmarcar todos os episódios de $title'
              : 'Marcar como assistido: todos os episódios de $title');
    return DetailToggleChip(
      label: watched ? 'Assistido' : 'Marcar como assistido',
      semanticsLabel: pending ? '$title: atualizando' : label,
      tooltip: label,
      icon: Icons.check_circle_outline,
      selectedIcon: Icons.check_circle,
      selected: watched,
      pending: pending,
      accent: true,
      onPressed: onPressed,
    );
  }
}
