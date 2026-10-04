import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../providers/providers.dart';
import '../providers/sync_providers.dart';
import 'auth_gate.dart';
import 'detail_actions.dart';
import 'empty_state.dart';
import 'favorites_section.dart' show kPosterAspectRatio;
import 'poster_image.dart';
import 'sync_widgets.dart';

enum _Filter { all, movies, tv }

const String kRecommendationsPrivacyNote = 'Só você vê esta lista, por enquanto.';

const double _posterWidth = 88;
const double _posterHeight = _posterWidth / kPosterAspectRatio;

/// Body of RecommendationsScreen ("Minhas recomendações"): the titles the user
/// marked "Recomendo", in Favoritos order (recent activity), with the
/// Todos/Filmes/Séries filter. Private for now. Never shows the empty state
/// while Favoritos is still loading or unconfirmed (error is not empty).
class RecommendationsSection extends ConsumerStatefulWidget {
  const RecommendationsSection({super.key});

  @override
  ConsumerState<RecommendationsSection> createState() => _RecommendationsSectionState();
}

class _RecommendationsSectionState extends ConsumerState<RecommendationsSection> {
  _Filter _filter = _Filter.all;

  /// The "Desfazer" snackbar of the last unmark; dropped when the screen is left
  /// or the account changes (a snackbar of another account must not linger).
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoSnack;

  void _offered(ScaffoldFeatureController<SnackBar, SnackBarClosedReason> snack) {
    _undoSnack = snack;
  }

  void _discardUndo() {
    final snack = _undoSnack;
    _undoSnack = null;
    if (snack == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        snack.close();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _discardUndo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentUidProvider, (_, _) => _discardUndo());
    final auth = ref.watch(authStateProvider);
    if (auth.isLoading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (auth.valueOrNull == null) return const _SignedOutInvite();

    final favoritesAsync = ref.watch(favoritesListProvider);
    final gate = ref.watch(favoritesGateProvider);
    final theme = Theme.of(context);

    return favoritesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => const FavoritesLoadError(),
      data: (favorites) {
        if (favorites.isEmpty && gate == FavoritesGate.loading) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (favorites.isEmpty && gate == FavoritesGate.unconfirmed) {
          return const FavoritesLoadError();
        }
        final all = ref.watch(recommendedListProvider);
        final shown = [
          for (final item in all)
            if (switch (_filter) {
              _Filter.all => true,
              _Filter.movies => item.mediaType == MediaType.movie,
              _Filter.tv => item.mediaType == MediaType.tv,
            })
              item,
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Semantics(
                header: true,
                child: Text(
                  all.isEmpty ? 'Minhas recomendações' : 'Minhas recomendações (${shown.length})',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              child: Text(
                kRecommendationsPrivacyNote,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            if (all.isEmpty)
              _EmptyRecommendations(hasFavorites: favorites.isNotEmpty)
            else if (shown.isEmpty)
              const EmptyState(
                icon: Icons.thumb_up_outlined,
                title: 'Nada neste filtro',
                message: 'Troque o filtro acima para ver as outras recomendações.',
              )
            else
              _RecommendationsGrid(items: shown, onUndoOffered: _offered),
          ],
        );
      },
    );
  }
}

/// Teaches how to recommend; the button leads to where a title can be found.
class _EmptyRecommendations extends StatelessWidget {
  final bool hasFavorites;

  const _EmptyRecommendations({required this.hasFavorites});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const EmptyState(
          icon: Icons.thumb_up_outlined,
          title: 'Você ainda não recomendou nada',
          message:
              'Abra um filme ou série que você curtiu e toque em Recomendo. '
              '$kRecommendationsPrivacyNote',
        ),
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => context.go(hasFavorites ? '/favorites' : '/search'),
          icon: Icon(hasFavorites ? Icons.favorite_border : Icons.search),
          label: Text(hasFavorites ? 'Ver meus favoritos' : 'Buscar um título'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Signed-out visitor: the tab exists and invites to log in (the sign-in starts
/// straight from the tap, as popup blockers require).
class _SignedOutInvite extends ConsumerWidget {
  const _SignedOutInvite();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signingIn = ref.watch(authControllerProvider).signingIn;
    return Column(
      children: [
        const EmptyState(
          icon: Icons.thumb_up_outlined,
          title: 'Entre para guardar suas recomendações',
          message:
              'Marque com Recomendo os filmes e séries que você realmente curtiu. '
              '$kRecommendationsPrivacyNote',
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: signingIn
              ? null
              : () => signInWithFeedback(
                  ProviderScope.containerOf(context),
                  ScaffoldMessenger.maybeOf(context),
                ),
          icon: const Icon(Icons.login),
          label: Text(signingIn ? 'Entrando...' : 'Entrar com Google'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Responsive grid: one column on phones, more as the width grows. Cards
/// size to their content (any font scale), so nothing overflows.
class _RecommendationsGrid extends StatelessWidget {
  final List<FavoriteItem> items;
  final void Function(ScaffoldFeatureController<SnackBar, SnackBarClosedReason>) onUndoOffered;

  const _RecommendationsGrid({required this.items, required this.onUndoOffered});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        const maxExtent = 460.0;
        final inner = constraints.maxWidth - 24;
        final columns = math.max(1, (inner / (maxExtent + spacing)).ceil());
        final width = (inner - spacing * (columns - 1)) / columns;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final item in items)
                SizedBox(
                  width: width,
                  child: _RecommendationCard(
                    key: ValueKey(item.storageKey),
                    item: item,
                    onUndoOffered: onUndoOffered,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  final FavoriteItem item;
  final void Function(ScaffoldFeatureController<SnackBar, SnackBarClosedReason>) onUndoOffered;

  const _RecommendationCard({super.key, required this.item, required this.onUndoOffered});

  @override
  Widget build(BuildContext context) {
    final isMovie = item.mediaType == MediaType.movie;
    final theme = Theme.of(context);
    final kind = isMovie ? 'Filme' : 'Série';
    return Semantics(
      button: true,
      container: true,
      label: '${item.title}, ${kind.toLowerCase()}',
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
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      Text(kind, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      RecommendToggleChip(
                        recommended: item.recommended,
                        title: item.title,
                        onSet: (target) => setRecommendedFromUi(
                          context,
                          item.toSearchResult(),
                          inFavorites: true,
                          recommended: target,
                          onUndoOffered: onUndoOffered,
                        ),
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
