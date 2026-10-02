import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_shell.dart';
import '../models/media_type.dart';
import '../models/search_result.dart';
import '../providers/providers.dart';
import '../services/tmdb_exception.dart';
import '../widgets/auth_gate.dart';
import '../widgets/error_state.dart';
import '../widgets/poster_image.dart';

/// A single reusable horizontal carousel for any discovery section ("Em
/// Alta", "Novidades", one per category) — one widget, one `AsyncValue`,
/// so an error in one section can never take down another (structural
/// guarantee, not a convention to remember).
///
/// Handles all 4 states itself: loading (spinner), error (message + retry
/// via `ref.invalidate(provider)`), empty data (the section disappears —
/// e.g. a genre with no recent releases) and data (the carousel).
class DiscoverySection extends ConsumerStatefulWidget {
  final String title;
  final FutureProvider<List<SearchResult>> provider;

  const DiscoverySection({super.key, required this.title, required this.provider});

  @override
  ConsumerState<DiscoverySection> createState() => _DiscoverySectionState();
}

class _DiscoverySectionState extends ConsumerState<DiscoverySection> {
  final Set<String> _pendingKeys = {};

  @override
  Widget build(BuildContext context) {
    final asyncItems = ref.watch(widget.provider);

    return asyncItems.when(
      loading: () => _shell(
        context,
        const SizedBox(
          height: 240,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, _) => _shell(
        context,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ErrorState(
            message: error is TmdbException ? error.message : 'Erro ao carregar "${widget.title}".',
            onRetry: () => ref.invalidate(widget.provider),
          ),
        ),
      ),
      data: (items) {
        // Empty catalog for this section (e.g. genre with no releases) —
        // the section disappears instead of showing an empty carousel.
        if (items.isEmpty) return const SizedBox.shrink();
        return _shell(context, _carousel(items));
      },
    );
  }

  Widget _shell(BuildContext context, Widget content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          ),
          content,
        ],
      ),
    );
  }

  Widget _carousel(List<SearchResult> items) {
    final favoriteKeys =
        ref.watch(favoritesListProvider).value?.map((f) => f.storageKey).toSet() ?? <String>{};

    return SizedBox(
      height: 240,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final result = items[index];
          return _DiscoveryCard(
            result: result,
            isFavorite: favoriteKeys.contains(result.storageKey),
            isPending: _pendingKeys.contains(result.storageKey),
            onToggleFavorite: () => _addFavorite(result),
          );
        },
      ),
    );
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
}

class _DiscoveryCard extends StatelessWidget {
  final SearchResult result;
  final bool isFavorite;
  final bool isPending;
  final VoidCallback onToggleFavorite;

  const _DiscoveryCard({
    required this.result,
    required this.isFavorite,
    required this.isPending,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: result.title,
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SizedBox(
          width: 130,
          child: GestureDetector(
            onTap: () => _openDetails(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    PosterImage(posterPath: result.posterPath, width: 130, height: 195),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: FavoriteButton(
                        isFavorite: isFavorite,
                        isPending: isPending,
                        onPressed: isFavorite ? null : onToggleFavorite,
                      ),
                    ),
                  ],
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
        ),
      ),
    );
  }

  void _openDetails(BuildContext context) {
    if (result.mediaType == MediaType.movie) {
      context.push('/movie/${result.id}');
    } else {
      context.push('/tv/${result.id}');
    }
  }
}

class FavoriteButton extends StatelessWidget {
  final bool isFavorite;
  final bool isPending;
  final VoidCallback? onPressed;

  const FavoriteButton({
    super.key,
    required this.isFavorite,
    required this.isPending,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final decoration = BoxDecoration(
      color: scheme.surface.withValues(alpha: 0.85),
      shape: BoxShape.circle,
    );

    // The heart is a quick-favorite shortcut: whatever its state, a tap on it
    // must never fall through to the card underneath (which opens details).
    // An enabled IconButton wins the gesture arena on its own; this absorbs
    // the taps of the disabled/pending states.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: () {},
      child: _button(context, scheme, decoration),
    );
  }

  Widget _button(BuildContext context, ColorScheme scheme, BoxDecoration decoration) {
    if (isPending) {
      return Container(
        padding: const EdgeInsets.all(6),
        decoration: decoration,
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
        ),
      );
    }

    return Container(
      decoration: decoration,
      child: IconButton(
        icon: Icon(
          isFavorite ? Icons.favorite : Icons.favorite_border,
          color: isFavorite ? scheme.primary : scheme.onSurface,
        ),
        // Desktop keeps the original compact 40px target; mobile uses 48px.
        visualDensity: isMobileWidth(context) ? null : VisualDensity.compact,
        onPressed: onPressed,
        tooltip: isFavorite ? 'Já é favorito' : 'Favoritar',
      ),
    );
  }
}
