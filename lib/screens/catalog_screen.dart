import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/media_type.dart';
import '../models/search_result.dart';
import '../providers/providers.dart';
import '../services/tmdb_exception.dart';
import '../widgets/app_shell.dart';
import '../widgets/discovery_section.dart' show FavoriteButton;
import '../widgets/empty_state.dart';
import '../widgets/auth_gate.dart';
import '../widgets/error_state.dart';
import '../widgets/poster_image.dart';

/// "Explorar": the whole TMDB catalog, split by Filmes / Séries and
/// filterable by genre, loaded page by page as the user scrolls.
class CatalogScreen extends ConsumerStatefulWidget {
  const CatalogScreen({super.key});

  @override
  ConsumerState<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends ConsumerState<CatalogScreen> {
  final _scroll = ScrollController();
  final _items = <SearchResult>[];
  final _pendingKeys = <String>{};

  MediaType _type = MediaType.movie;
  int? _genreId; // null = all genres
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  Object? _error;

  /// Bumped on every filter change so a slow response for a previous
  /// filter can never overwrite the list of the current one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadNext();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static const _prefetchExtent = 600.0;

  void _onScroll() {
    // After a failure, retrying is an explicit tap, never a side effect of
    // scrolling (avoids hammering an API that is down).
    if (_error == null && _scroll.position.extentAfter < _prefetchExtent) _loadNext();
  }

  void _resetWith({MediaType? type, int? genreId, bool clearGenre = false}) {
    setState(() {
      if (type != null && type != _type) {
        _type = type;
        _genreId = null; // genre ids differ between movies and TV
      }
      if (clearGenre) _genreId = null;
      if (genreId != null) _genreId = genreId;
      _generation++;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _loading = false;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _loadNext();
  }

  Future<void> _loadNext() async {
    if (_loading || !_hasMore) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(tmdbApiClientProvider)
          .discoverPage(_type, genreId: _genreId, page: _page + 1);
      if (!mounted || generation != _generation) return;
      setState(() {
        // Popularity shifts between requests, so a title can reappear on the
        // next page; keep the grid free of duplicates.
        final seen = _items.map((r) => r.storageKey).toSet();
        _items.addAll(page.results.where((r) => seen.add(r.storageKey)));
        _page = page.page;
        _hasMore = page.hasMore;
        _loading = false;
      });
      // A short (or empty) page may not fill the viewport; keep filling it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _error != null) return;
        final needsMore = _items.isEmpty ||
            (_scroll.hasClients && _scroll.position.extentAfter < _prefetchExtent);
        if (needsMore) _loadNext();
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _addFavorite(SearchResult result) async {
    final key = result.storageKey;
    setState(() => _pendingKeys.add(key));
    try {
      await runWrite(context, (repo) => repo.addResult(result));
    } finally {
      if (mounted) setState(() => _pendingKeys.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final genresAsync = ref.watch(genresProvider(_type));
    final favoriteKeys =
        ref.watch(favoritesListProvider).value?.map((f) => f.storageKey).toSet() ?? <String>{};

    return Scaffold(
      appBar: MobileShellScope.active(context)
          ? null
          : AppBar(
              title: const Text('Explorar'),
              actions: [
                IconButton(
                  tooltip: 'Buscar',
                  icon: const Icon(Icons.search),
                  onPressed: () => context.push('/search'),
                ),
              ],
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<MediaType>(
              segments: const [
                ButtonSegment(value: MediaType.movie, label: Text('Filmes')),
                ButtonSegment(value: MediaType.tv, label: Text('Séries')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => _resetWith(type: s.first),
            ),
          ),
          SizedBox(
            height: 48,
            child: genresAsync.when(
              loading: () => const SizedBox.shrink(),
              // The catalog still works without the genre chips.
              error: (_, _) => Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => ref.invalidate(genresProvider(_type)),
                  child: const Text('Gêneros indisponíveis — tentar de novo'),
                ),
              ),
              data: (genres) => ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _chip('Todos', _genreId == null, () => _resetWith(clearGenre: true)),
                  for (final g in genres)
                    _chip(g.name, _genreId == g.id, () => _resetWith(genreId: g.id)),
                ],
              ),
            ),
          ),
          Expanded(child: _buildGrid(favoriteKeys)),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap()),
      ),
    );
  }

  Widget _buildGrid(Set<String> favoriteKeys) {
    if (_items.isEmpty) {
      if (_error != null) {
        return ErrorState(
          message: _error is TmdbException
              ? (_error as TmdbException).message
              : 'Erro ao carregar o catálogo.',
          onRetry: _loadNext,
        );
      }
      if (_loading || _hasMore) {
        return const Center(child: CircularProgressIndicator());
      }
      return const EmptyState(
        icon: Icons.movie_filter_outlined,
        title: 'Nada encontrado',
        message: 'Não há títulos neste gênero.',
      );
    }

    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: isMobileWidth(context) ? 190 : 170,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.52,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) => _CatalogTile(
              result: _items[i],
              isFavorite: favoriteKeys.contains(_items[i].storageKey),
              isPending: _pendingKeys.contains(_items[i].storageKey),
              onFavorite: () => _addFavorite(_items[i]),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : _error != null
                      ? TextButton(
                          onPressed: _loadNext,
                          child: const Text('Erro ao carregar mais — tentar de novo'),
                        )
                      : !_hasMore
                          ? const Text('Fim da lista')
                          : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

class _CatalogTile extends StatelessWidget {
  final SearchResult result;
  final bool isFavorite;
  final bool isPending;
  final VoidCallback onFavorite;

  const _CatalogTile({
    required this.result,
    required this.isFavorite,
    required this.isPending,
    required this.onFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: result.title,
      button: true,
      child: GestureDetector(
        onTap: () => context.push(
          result.mediaType == MediaType.movie ? '/movie/${result.id}' : '/tv/${result.id}',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) => Stack(
                  children: [
                    PosterImage(
                      posterPath: result.posterPath,
                      width: c.maxWidth,
                      height: c.maxHeight,
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: FavoriteButton(
                        isFavorite: isFavorite,
                        isPending: isPending,
                        onPressed: isFavorite ? null : onFavorite,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
