import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/favorite_item.dart';
import '../providers/providers.dart';
import '../providers/catalog_sync_providers.dart';
import '../services/favorite_status.dart';
import '../providers/sync_providers.dart';
import 'poster_image.dart';
import 'sync_widgets.dart';
import 'progress_badge.dart';

/// Highlights TV shows with partial watch progress (some episode watched,
/// not all) — separate from the generic favorites list per product spec.
/// Purely local/derived data (`continueWatchingProvider`), so it never has
/// a loading/error state of its own: it either has entries, or it doesn't.
class ContinueWatchingSection extends ConsumerWidget {
  const ContinueWatchingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(continueWatchingProvider);
    if (items.isEmpty && ref.watch(favoritesGateProvider) == FavoritesGate.unconfirmed) {
      return const FavoritesLoadError(compact: true);
    }
    if (items.isEmpty) {
      // New login/device: the series' seasons are being downloaded.
      if (!ref.watch(catalogSyncProvider).isRunning) return const SizedBox.shrink();
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Flexible(child: Text('Calculando seu progresso…')),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('Continue assistindo', style: Theme.of(context).textTheme.titleLarge),
          ),
          SizedBox(
            height: 288,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              itemBuilder: (context, index) => _ContinueWatchingCard(item: items[index]),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueWatchingCard extends StatelessWidget {
  final FavoriteItem item;

  const _ContinueWatchingCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final status = FavoriteStatus.of(item);

    return Semantics(
      label: item.title,
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SizedBox(
          width: 130,
          child: GestureDetector(
            onTap: () => context.push('/tv/${item.id}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PosterImage(posterPath: item.posterPath, width: 130, height: 195),
                const SizedBox(height: 4),
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                SeriesStatusBadge(status: status),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
