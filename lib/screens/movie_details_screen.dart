import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/search_result.dart';
import '../providers/providers.dart';
import '../services/tmdb_exception.dart';
import '../widgets/app_shell.dart';
import '../widgets/cast_widgets.dart';
import '../widgets/detail_actions.dart';
import '../widgets/error_state.dart';
import '../widgets/poster_image.dart';

/// Details of a movie. Works for any TMDB movie: when it is a favorite the
/// saved data (and the watched flag) is shown; otherwise it is fetched from
/// TMDB, so the user can read about a title BEFORE favoriting it, and still
/// favorite / mark it watched from here.
class MovieDetailsScreen extends ConsumerStatefulWidget {
  final int movieId;

  const MovieDetailsScreen({super.key, required this.movieId});

  @override
  ConsumerState<MovieDetailsScreen> createState() => _MovieDetailsScreenState();
}

class _MovieDetailsScreenState extends ConsumerState<MovieDetailsScreen> {
  /// Last favorite seen: lets the screen keep its content if the user removes
  /// it while TMDB is unreachable (otherwise it would turn into an error page).
  FavoriteItem? _last;

  @override
  Widget build(BuildContext context) {
    final movieId = widget.movieId;
    final favorites = ref.watch(favoritesListProvider).value ?? [];
    final matches = favorites.where((f) => f.id == movieId && f.mediaType == MediaType.movie);
    final FavoriteItem? item = matches.isEmpty ? null : matches.first;

    final key = (id: movieId, type: MediaType.movie);
    // Favorites also show year/genres when TMDB answers; their failure is
    // ignored (the saved data is enough, e.g. offline).
    final detailsAsync = ref.watch(titleDetailsProvider(key));
    final details = detailsAsync.valueOrNull;
    _last = item ?? _last;
    final base = item ?? (details == null ? _last : null);

    if (base == null && details == null) {
      return Scaffold(
        appBar: detailAppBar(context, title: 'Detalhes'),
        bottomNavigationBar: const DetailBottomBanner(),
        body: detailsAsync.hasError
            ? ErrorState(
                message: detailsErrorMessage(detailsAsync.error),
                retryLabel: 'Tentar novamente',
                onRetry: () => ref.invalidate(titleDetailsProvider(key)),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }

    final title = base?.title ?? details!.title;
    final result = base == null
        ? details!.toSearchResult()
        : SearchResult(
            id: base.id,
            mediaType: MediaType.movie,
            title: base.title,
            posterPath: base.posterPath,
            overview: base.overview,
          );
    final overview = base?.overview ?? details!.overview;
    final watched = item?.watchedMovie ?? false;

    return Scaffold(
      bottomNavigationBar: const DetailBottomBanner(),
      appBar: detailAppBar(context, title: title),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PosterImage(posterPath: result.posterPath, width: 120, height: 180),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            TitleMeta(details: details),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _Actions(item: item, result: result, watched: watched),
                  const SizedBox(height: 16),
                  Text(
                    overview.isEmpty ? 'Sem sinopse disponível.' : overview,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            // Own loading/error/empty: never replaces the rest of the screen.
            // Full width: the carousel pads itself.
            CastSection(titleKey: key),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  final FavoriteItem? item;
  final SearchResult result;
  final bool watched;

  const _Actions({required this.item, required this.result, required this.watched});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FavoriteToggleButton(
          isFavorite: item != null,
          hasProgress: watched,
          recommended: item?.recommended ?? false,
          title: result.title,
          onAdd: () => runDetailWrite(context, (repo) => repo.addResult(result)),
          onRemove: () =>
              runDetailWrite(context, (repo) => repo.remove(result.id, MediaType.movie)),
        ),
        RecommendToggleChip(
          recommended: item?.recommended ?? false,
          title: result.title,
          onSet: (target) => setRecommendedFromUi(
            context,
            result,
            inFavorites: item != null,
            recommended: target,
          ),
        ),
        WatchedToggleChip(
          watched: watched,
          title: result.title,
          onToggle: () => runDetailWrite(
              context,
              // Not a favorite yet: progress lives in the favorite, so this
              // favorites it first and then marks it (see docs/15).
              (repo) => item == null
                  ? favoriteThen(repo, result, false, () => repo.markMovieWatched(result.id))
                  : repo.toggleMovieWatched(result.id)),
        ),
      ],
    );
  }
}

/// User-facing message for a failed TMDB details request.
String detailsErrorMessage(Object? error) => error is TmdbException
    ? error.message
    : 'Não foi possível carregar os detalhes. Verifique a conexão.';
