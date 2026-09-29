import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/media_type.dart';
import '../models/search_result.dart';
import '../providers/providers.dart';
import '../services/tmdb_exception.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_state.dart';
import '../widgets/poster_image.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  static const _minChars = 2;
  static const _debounce = Duration(milliseconds: 400);

  final _controller = TextEditingController();
  Timer? _debounceTimer;
  String _submittedQuery = '';
  final Set<String> _pendingKeys = {};

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Searches as the user types: waits for a pause in typing ([_debounce])
  /// and only fires from [_minChars] characters on, so we don't spam TMDB.
  void _onChanged(String value) {
    _debounceTimer?.cancel();
    final query = value.trim();
    if (query.length < _minChars) {
      setState(() => _submittedQuery = '');
      return;
    }
    _debounceTimer = Timer(_debounce, () {
      if (mounted) setState(() => _submittedQuery = query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final favoritesAsync = ref.watch(favoritesListProvider);
    final favoriteKeys = favoritesAsync.value
            ?.map((f) => '${f.id}-${f.mediaType.jsonValue}')
            .toSet() ??
        <String>{};

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Buscar filme ou série...',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: (value) {
            _debounceTimer?.cancel();
            setState(() => _submittedQuery = value.trim());
          },
        ),
      ),
      body: _submittedQuery.isEmpty
          ? const EmptyState(
              icon: Icons.search,
              title: 'Busque algo para favoritar',
              message: 'Digite pelo menos 2 letras do título.',
            )
          : _buildResults(favoriteKeys),
    );
  }

  Widget _buildResults(Set<String> favoriteKeys) {
    final resultsAsync = ref.watch(searchResultsProvider(_submittedQuery));

    return resultsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorState(
        message: error is TmdbException ? error.message : 'Erro inesperado ao buscar.',
        onRetry: () => ref.invalidate(searchResultsProvider(_submittedQuery)),
      ),
      data: (results) {
        if (results.isEmpty) {
          return const EmptyState(
            icon: Icons.movie_filter_outlined,
            title: 'Nada encontrado',
            message: 'Tente buscar com outro título.',
          );
        }
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            final key = '${result.id}-${result.mediaType.jsonValue}';
            final isFavorite = favoriteKeys.contains(key);
            final isPending = _pendingKeys.contains(key);

            return ListTile(
              leading: PosterImage(posterPath: result.posterPath, width: 46, height: 69),
              title: Text(result.title),
              subtitle: Text(
                result.overview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: isPending
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
                      onPressed: isFavorite ? null : () => _addFavorite(result, key),
                    ),
              onTap: isFavorite
                  ? () => _openDetails(result)
                  : (isPending ? null : () => _addFavorite(result, key)),
            );
          },
        );
      },
    );
  }

  Future<void> _addFavorite(SearchResult result, String key) async {
    setState(() => _pendingKeys.add(key));
    try {
      final repo = ref.read(favoritesRepositoryProvider);
      if (result.mediaType == MediaType.movie) {
        await repo.addMovie(
          id: result.id,
          title: result.title,
          posterPath: result.posterPath,
          overview: result.overview,
        );
      } else {
        await repo.addTvShow(
          id: result.id,
          title: result.title,
          posterPath: result.posterPath,
          overview: result.overview,
        );
      }
    } finally {
      if (mounted) setState(() => _pendingKeys.remove(key));
    }
  }

  void _openDetails(SearchResult result) {
    if (result.mediaType == MediaType.movie) {
      context.push('/movie/${result.id}');
    } else {
      context.push('/tv/${result.id}');
    }
  }
}
