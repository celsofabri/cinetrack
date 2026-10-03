import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/media_type.dart';
import '../models/search_result.dart';
import '../providers/providers.dart';
import '../services/tmdb_exception.dart';
import '../widgets/app_shell.dart';
import '../widgets/empty_state.dart';
import '../widgets/detail_actions.dart';
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
    final favoriteKeys =
        favoritesAsync.value?.map((f) => '${f.id}-${f.mediaType.jsonValue}').toSet() ?? <String>{};

    final inShell = MobileShellScope.active(context);
    final field = TextField(
      controller: _controller,
      // On mobile this screen is a tab: don't pop the keyboard on every visit.
      autofocus: !inShell,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Buscar filme ou série...',
        border: inShell ? const OutlineInputBorder() : InputBorder.none,
        prefixIcon: inShell ? const Icon(Icons.search) : null,
      ),
      onChanged: _onChanged,
      onSubmitted: (value) {
        _debounceTimer?.cancel();
        setState(() => _submittedQuery = value.trim());
      },
    );

    final content = _submittedQuery.isEmpty
        ? const EmptyState(
            icon: Icons.search,
            title: 'Busque algo para favoritar',
            message: 'Digite pelo menos 2 letras do título.',
          )
        : _buildResults(favoriteKeys);

    return Scaffold(
      appBar: inShell ? null : AppBar(title: field),
      body: inShell
          ? Column(
              children: [
                Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: field),
                Expanded(child: content),
              ],
            )
          : content,
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
                      icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border,
                          color: isFavorite ? Theme.of(context).colorScheme.primary : null),
                      tooltip: isFavorite
                          ? 'Remover ${result.title} dos favoritos'
                          : 'Favoritar ${result.title}',
                      onPressed: () => _toggleFavorite(result, key, isFavorite),
                    ),
              // Tapping the row opens the details (favorite or not); the
              // heart is the quick-favorite shortcut.
              onTap: () => _openDetails(result),
            );
          },
        );
      },
    );
  }

  Future<void> _toggleFavorite(SearchResult result, String key, bool isFavorite) {
    return toggleFavoriteFromList(
      context,
      result,
      isFavorite: isFavorite,
      setPending: (p) {
        if (!mounted) return;
        setState(() => p ? _pendingKeys.add(key) : _pendingKeys.remove(key));
      },
    );
  }

  void _openDetails(SearchResult result) {
    if (result.mediaType == MediaType.movie) {
      context.push('/movie/${result.id}');
    } else {
      context.push('/tv/${result.id}');
    }
  }
}
