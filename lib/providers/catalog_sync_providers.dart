import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/favorite_doc.dart';
import '../models/media_type.dart';
import '../repositories/favorites_repository.dart';
import 'providers.dart';

/// Which series are having their season catalog downloaded in the
/// background, which gave up and which are known to be done in this session.
class CatalogSyncState {
  final Set<int> loading;
  final Set<int> failed;
  final Set<int> settled;

  /// Runtimes (for "Tempo assistido") being fetched.
  final bool runtimesLoading;

  const CatalogSyncState({
    this.loading = const {},
    this.failed = const {},
    this.settled = const {},
    this.runtimesLoading = false,
  });

  bool get isRunning => loading.isNotEmpty || runtimesLoading;

  CatalogSyncState copyWith({
    Set<int>? loading,
    Set<int>? failed,
    Set<int>? settled,
    bool? runtimesLoading,
  }) =>
      CatalogSyncState(
        loading: loading ?? this.loading,
        failed: failed ?? this.failed,
        settled: settled ?? this.settled,
        runtimesLoading: runtimesLoading ?? this.runtimesLoading,
      );
}

/// Pause between retries of a transient TMDB failure (1 s, 2 s, 4 s...).
/// Overridden in tests so no real timer is left pending.
final catalogSyncDelayProvider = Provider<Future<void> Function(Duration)>((ref) => Future.delayed);

/// Keeps the local season catalog of the favorite series complete, so the
/// progress badge and the "Concluídos" group are right right after a login or
/// on a new device, without the user opening each series. Started by the app
/// shell; reacts to the signed-in account's documents (recreated with the
/// uid, in-flight work of a previous account is dropped).
class CatalogSyncNotifier extends Notifier<CatalogSyncState> {
  int _generation = 0;
  final Set<String> _runtimeTried = {};
  bool _runtimeRunning = false;

  @override
  CatalogSyncState build() {
    final generation = ++_generation;
    // Per-account bookkeeping: nothing of the previous account survives.
    _runtimeTried.clear();
    _runtimeRunning = false;
    final uid = ref.watch(currentUidProvider);
    if (uid == null) return const CatalogSyncState();
    ref.watch(favoritesRepositoryProvider);
    ref.onDispose(() {
      if (generation == _generation) _generation++;
    });
    ref.listen(favoriteDocsProvider, (_, next) {
      final docs = next.valueOrNull;
      if (docs != null) _start(docs, generation);
    }, fireImmediately: true);
    return const CatalogSyncState();
  }

  /// Forgets previous failures and tries again for what is still incomplete
  /// (called when the favorites screen opens and by the "Tentar de novo"
  /// action).
  void retry() {
    // `settled` is cleared too so shows whose catalog went stale (TTL) or whose
    // season list changed are looked at again.
    state = state.copyWith(failed: const {}, settled: const {});
    _runtimeTried.clear();
    final docs = ref.read(favoriteDocsProvider).valueOrNull;
    if (docs != null) _start(docs, _generation);
  }

  void _start(List<FavoriteDoc> docs, int generation) {
    // Never mutate state while the provider is still building.
    scheduleMicrotask(() async {
      if (generation != _generation) return;
      final repo = ref.read(favoritesRepositoryProvider);
      final todo = [
        for (final doc in repo.docsNeedingCatalog(docs))
          if (!state.loading.contains(doc.id) &&
              !state.failed.contains(doc.id) &&
              !state.settled.contains(doc.id))
            doc,
      ];
      if (todo.isNotEmpty) await _reconcileCatalogs(repo, todo, generation);
      await _reconcileRuntimes(generation);
    });
  }

  Future<void> _reconcileCatalogs(
    FavoritesRepository repo,
    List<FavoriteDoc> todo,
    int generation,
  ) async {
    {
      state = state.copyWith(loading: {...state.loading, for (final d in todo) d.id});
      await repo.reconcileCatalog(
        todo,
        delay: ref.read(catalogSyncDelayProvider),
        isCancelled: () => generation != _generation,
        // Unfavorited meanwhile: never write to a document that is gone.
        isStale: (id) => !(ref.read(favoriteDocsProvider).valueOrNull ?? const [])
            .any((d) => d.id == id && d.mediaType == MediaType.tv),
        onDone: (id, ok) {
          if (generation != _generation) return;
          state = state.copyWith(
            loading: {...state.loading}..remove(id),
            failed: ok ? null : {...state.failed, id},
            settled: ok ? {...state.settled, id} : null,
          );
        },
      );
      if (generation != _generation) return;
      // Anything cancelled mid-way (shouldn't happen without a new
      // generation) must not stay "loading" forever.
      final stuck = {for (final d in todo) d.id}.intersection(state.loading);
      if (stuck.isNotEmpty) {
        state = state.copyWith(
          loading: {...state.loading}..removeAll(stuck),
          failed: {...state.failed, ...stuck},
        );
      }
    }
  }

  /// Fetches the runtimes still unknown for what the user watched. Each key
  /// is tried once per session (until [retry]); loops because the catalog
  /// pass can add titles that now need a runtime.
  Future<void> _reconcileRuntimes(int generation) async {
    if (_runtimeRunning) return;
    _runtimeRunning = true;
    try {
      while (generation == _generation) {
        final repo = ref.read(favoritesRepositoryProvider);
        final docs = ref.read(favoriteDocsProvider).valueOrNull ?? const [];
        final keys = [
          for (final k in repo.pendingRuntimes(docs))
            if (!_runtimeTried.contains(k)) k,
        ];
        if (keys.isEmpty) break;
        _runtimeTried.addAll(keys);
        state = state.copyWith(runtimesLoading: true);
        await repo.reconcileRuntimes(
          keys,
          docs: docs,
          delay: ref.read(catalogSyncDelayProvider),
          isCancelled: () => generation != _generation,
        );
      }
    } finally {
      _runtimeRunning = false;
      if (generation == _generation) state = state.copyWith(runtimesLoading: false);
    }
  }
}

final catalogSyncProvider =
    NotifierProvider<CatalogSyncNotifier, CatalogSyncState>(CatalogSyncNotifier.new);
