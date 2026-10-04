import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/favorites_data_source.dart';
import '../data/sync_status.dart';
import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../providers/catalog_sync_providers.dart';
import '../providers/providers.dart';
import '../providers/sync_providers.dart';
import '../services/bulk_watch.dart';
import '../services/favorite_status.dart';
import 'auth_gate.dart';
import 'detail_actions.dart';
import 'empty_state.dart';
import 'sync_widgets.dart';
import 'poster_image.dart';
import 'progress_badge.dart';

enum _Filter { all, movies, tv }

enum _Ack { saved, failed, offline, stalled }

/// Pause before reading the sync state after a write, so the "pending" flag of
/// the local database has time to show up. Max wait for the server's answer.
const kAckSettle = Duration(milliseconds: 250);
const kAckWait = Duration(seconds: 8);

/// How long the pending flag must stay down before a write counts as saved.
const kAckVerify = Duration(milliseconds: 1500);

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

  /// Storage keys whose quick-watched action is running (anti double tap). Kept
  /// here, not in the card: the card can leave the tab as soon as the item
  /// changes group.
  final Set<String> _busy = {};

  /// Key whose confirmation dialog is open: it is modal, so no spinner is shown
  /// on the card meanwhile (the guard in [_busy] still holds).
  String? _dialogKey;

  /// The one "Desfazer" snackbar (the last whole-series action) and its owner.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoSnack;

  /// The "salvando…" snackbar while the server's answer is awaited.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _savingSnack;

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
    // Leaving Favoritos discards the pending "Desfazer" and any "salvando…"
    // (docs/30). Controllers are captured, no context of this State is used.
    final snacks = [_undoSnack, _savingSnack];
    _undoSnack = _savingSnack = null;
    if (snacks.any((c) => c != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final snack in snacks) {
          try {
            snack?.close();
          } catch (_) {}
        }
      });
    }
    super.dispose();
  }

  void _discardUndo() {
    final snack = _undoSnack;
    _undoSnack = null;
    snack?.close();
    _discardSaving();
  }

  void _discardSaving() {
    final saving = _savingSnack;
    _savingSnack = null;
    saving?.close();
  }

  void _setBusy(String key, bool busy) {
    if (!mounted) return;
    setState(() => busy ? _busy.add(key) : _busy.remove(key));
  }

  /// Movie: flips `watchedMovie` straight away (no confirmation). Series: opens
  /// the confirmation, applies the change in one write and offers "Desfazer".
  Future<void> _toggleWatched(FavoriteItem item, FavoriteStatus status) async {
    final key = item.storageKey;
    if (_busy.contains(key)) return;
    _setBusy(key, true);
    try {
      if (item.mediaType == MediaType.movie) {
        await runDetailWrite(context, (repo) => repo.setMovieWatched(item.id, !item.watchedMovie));
      } else {
        await _toggleSeries(item, markAll: !status.isCompleted);
      }
    } finally {
      _setBusy(key, false);
    }
  }

  Future<void> _toggleSeries(FavoriteItem item, {required bool markAll}) async {
    final repo = ref.read(favoritesRepositoryProvider);
    final delay = ref.read(catalogSyncDelayProvider);
    final uid = ref.read(currentUidProvider);
    setState(() => _dialogKey = item.storageKey);
    final plan = await showDialog<SeriesBulkPlan>(
      context: context,
      barrierDismissible: true, // outside tap and Esc = Cancelar
      builder: (_) => BulkWatchDialog(
        title: item.title,
        watched: markAll,
        load: (isCancelled) => repo.planSeriesBulk(
          item.id,
          watched: markAll,
          delay: delay,
          isCancelled: isCancelled,
        ),
      ),
    );
    if (mounted) setState(() => _dialogKey = null);
    if (plan == null || !mounted || uid == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (ref.read(currentUidProvider) != uid) {
      // The account changed while the dialog was open: write nothing.
      messenger.showSnackBar(const SnackBar(content: Text(_kAccountChanged)));
      return;
    }
    SeriesBulkUndo? undo;
    var failed = false;
    // Taken BEFORE the write: a refusal that lands within milliseconds (or
    // after the session check of a permission-denied) must still look new.
    final baseline = ref.read(syncStatusProvider).failure;
    await runDetailWrite(context, (repo) async {
      try {
        undo = await repo.applySeriesBulk(plan, uid: uid);
      } catch (_) {
        failed = true;
        rethrow;
      }
    });
    final applied = undo;
    if (failed || applied == null || !mounted) return;
    // The card is usable again as soon as the local write is accepted (the
    // caller's `finally`); the server's answer is followed in the background.
    unawaited(_afterBulkWrite(
      messenger: messenger,
      item: item,
      markAll: markAll,
      applied: applied,
      count: markAll ? plan.episodeCount : applied.inverse.length,
      baseline: baseline,
    ));
  }

  int _actionSeq = 0;

  Future<void> _afterBulkWrite({
    required ScaffoldMessengerState messenger,
    required FavoriteItem item,
    required bool markAll,
    required SeriesBulkUndo applied,
    required int count,
    required SyncFailure? baseline,
  }) async {
    final seq = ++_actionSeq;
    // A newer action owns the snackbar from now on.
    bool stale() => !mounted || seq != _actionSeq || ref.read(currentUidProvider) != applied.uid;
    _discardUndo();
    final what = '$count ${_eps(count)}';
    // Do not promise what the server may still refuse: wait for its answer.
    messenger.clearSnackBars(); // also drops a queued/closing older "Desfazer"
    _savingSnack = messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 1),
        persist: false,
        content: Row(children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text('${item.title}: salvando…')),
        ]),
      ),
    );
    final ack = await _awaitAck(baseline);
    if (!mounted || seq != _actionSeq) return; // left the screen / replaced by a newer action
    _savingSnack = null;
    messenger.clearSnackBars(); // the "salvando…" one
    if (ack == _Ack.failed) {
      messenger.showSnackBar(SnackBar(
        content: Text('Não foi possível salvar a alteração em ${item.title}. '
            'O progresso volta ao que era.'),
      ));
      return;
    }
    if (stale()) return; // account changed meanwhile: no Desfazer of another account
    final done = markAll ? '$what marcados como assistidos' : 'progresso apagado ($what)';
    final suffix = switch (ack) {
      _Ack.saved => '.',
      _Ack.offline => ' neste aparelho. Sincroniza quando houver conexão.',
      _ => ' neste aparelho. Aguardando confirmação do servidor.',
    };
    final snack = messenger.showSnackBar(
      SnackBar(
        duration: kUndoWindow,
        // Since Flutter 3.29 a snackbar with an action stays until dismissed.
        persist: false,
        content: Text('${item.title}: $done$suffix'),
        action: SnackBarAction(label: 'Desfazer', onPressed: () => _undo(applied, messenger)),
      ),
    );
    _undoSnack = snack;
    snack.closed.then((_) {
      if (identical(_undoSnack, snack)) _undoSnack = null;
    });
  }

  /// Waits (bounded) for the server to acknowledge the write just made:
  /// [_Ack.saved], [_Ack.failed] (rules/quota refused it, the local view rolls
  /// back), [_Ack.offline] (kept on this device) or [_Ack.stalled] (connected
  /// but no answer in [kAckWait]: kept, flagged).
  ///
  /// [baseline] is the sync failure that existed before the write. "Saved" is
  /// only declared after the pending flag has stayed down for [kAckVerify]:
  /// a refused write rolls back (pending drops) BEFORE its failure is
  /// recorded (a permission-denied is first checked against the session).
  Future<_Ack> _awaitAck(SyncFailure? baseline) async {
    await Future<void>.delayed(kAckSettle);
    if (!mounted) return _Ack.saved;
    final done = Completer<_Ack>();
    Timer? verify;
    void evaluate(SyncStatus s) {
      if (done.isCompleted) return;
      if (s.failure != null && !identical(s.failure, baseline)) {
        done.complete(_Ack.failed);
      } else if (s.offline) {
        done.complete(_Ack.offline);
      } else if (s.hasPendingWrites) {
        verify?.cancel();
        verify = null;
        if (s.pendingStalled) done.complete(_Ack.stalled);
      } else {
        verify ??= Timer(kAckVerify, () {
          if (!done.isCompleted) done.complete(_Ack.saved);
        });
      }
    }

    final sub = ref.listenManual(syncStatusProvider, (_, next) => evaluate(next));
    evaluate(ref.read(syncStatusProvider));
    final timer = Timer(kAckWait, () {
      if (!done.isCompleted) done.complete(_Ack.stalled);
    });
    try {
      return await done.future;
    } finally {
      sub.close();
      timer.cancel();
      verify?.cancel();
    }
  }

  Future<void> _undo(SeriesBulkUndo undo, ScaffoldMessengerState messenger) async {
    if (!mounted) return;
    if (ref.read(currentUidProvider) != undo.uid) {
      messenger.showSnackBar(const SnackBar(content: Text(_kAccountChanged)));
      return;
    }
    if (!_busy.add(undo.docKey)) return;
    setState(() {});
    String message;
    try {
      final baseline = ref.read(syncStatusProvider).failure;
      final outcome = await ref.read(favoritesRepositoryProvider).undoSeriesBulk(undo);
      message = switch (outcome) {
        UndoOutcome.restored => 'Progresso restaurado.',
        UndoOutcome.changed => 'Algo mudou, não foi possível desfazer.',
        UndoOutcome.gone => kGoneMessage,
      };
      if (outcome == UndoOutcome.restored && mounted && await _awaitAck(baseline) == _Ack.failed) {
        message = 'Não foi possível salvar o "desfazer". O progresso volta ao que era.';
      }
    } catch (error) {
      message = error is AuthRequiredException || error is FavoritesUnavailableException
          ? kFavoriteUnavailableMessage
          : writeErrorMessage(error);
    } finally {
      _busy.remove(undo.docKey);
      if (mounted) setState(() {});
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  static const _kAccountChanged = 'A conta mudou. Nada foi alterado.';

  static String _eps(int n) => n == 1 ? 'episódio' : 'episódios';

  @override
  Widget build(BuildContext context) {
    // A different account never sees (or undoes) the previous one's action.
    ref.listen(currentUidProvider, (_, _) => _discardUndo());
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
                    busy: {..._busy}..remove(_dialogKey),
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
                      QuickWatchedButton(
                        title: item.title,
                        isMovie: isMovie,
                        watched: isMovie ? item.watchedMovie : status.isCompleted,
                        pending: pending,
                        onPressed: onToggleWatched,
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

/// Confirmation of a whole-series mark/unmark. Phases: "Preparando…" while the
/// missing seasons are loaded, an error with "Tentar novamente" (nothing is
/// changed), then the confirmation with the real counts. Pops the plan when
/// confirmed, null when cancelled.
class BulkWatchDialog extends StatefulWidget {
  final String title;
  final bool watched;
  final Future<SeriesBulkPlan> Function(bool Function() isCancelled) load;

  const BulkWatchDialog({
    super.key,
    required this.title,
    required this.watched,
    required this.load,
  });

  @override
  State<BulkWatchDialog> createState() => _BulkWatchDialogState();
}

class _BulkWatchDialogState extends State<BulkWatchDialog> {
  SeriesBulkPlan? _plan;
  Object? _error;
  int _attempt = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // Cancel / Esc: the running download stops at its next step and its
    // result is ignored (nothing is written after cancelling).
    _disposed = true;
    super.dispose();
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    setState(() {
      _plan = null;
      _error = null;
    });
    try {
      final plan = await widget.load(() => _disposed || attempt != _attempt);
      if (mounted && attempt == _attempt) setState(() => _plan = plan);
    } catch (error) {
      if (mounted && attempt == _attempt) setState(() => _error = error);
    }
  }

  static String _n(int n, String one, String many) => '$n ${n == 1 ? one : many}';

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final seconds = kUndoWindow.inSeconds;
    final undoText =
        'Você poderá desfazer por $seconds segundos logo após; depois disso só '
        'marcando manualmente, episódio por episódio.';
    final String heading;
    final String body;
    final List<Widget> actions;
    if (_error != null) {
      heading = 'Não foi possível preparar';
      body = '${writeErrorMessage(_error!)} Nada foi alterado.';
      actions = [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(autofocus: true, onPressed: _start, child: const Text('Tentar novamente')),
      ];
    } else if (plan == null) {
      heading = 'Preparando…';
      body = 'Carregando as temporadas de ${widget.title}.';
      actions = [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
      ];
    } else if (plan.isEmpty) {
      heading = widget.watched ? 'Nada para marcar' : 'Nada para desmarcar';
      body = widget.watched
          ? 'Nenhum episódio já exibido de ${widget.title} falta marcar.'
          : 'Nenhum episódio de ${widget.title} está marcado.';
      actions = [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ];
    } else {
      final eps = _n(plan.episodeCount, 'episódio', 'episódios');
      final seasons = _n(plan.seasonCount, 'temporada', 'temporadas');
      if (widget.watched) {
        heading = 'Marcar a série inteira como assistida?';
        body =
            'Isso vai marcar $eps de $seasons como assistidos de uma só vez. '
            'Episódios que ainda não foram exibidos e especiais não entram. $undoText';
      } else {
        heading = 'Desmarcar a série inteira?';
        body =
            'Isso vai desmarcar $eps de $seasons e apagar o seu progresso nesta série '
            'de uma só vez. $undoText';
      }
      actions = [
        // Enter confirms a mark; for the destructive unmark Enter cancels.
        TextButton(
          autofocus: !widget.watched,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          autofocus: widget.watched,
          onPressed: () => Navigator.of(context).pop(plan),
          child: Text(widget.watched ? 'Marcar tudo' : 'Desmarcar tudo'),
        ),
      ];
    }
    return AlertDialog(
      title: Text(heading),
      content: ConstrainedBox(
        // Minimum height: limits the jump between phases (loading -> text).
        constraints: const BoxConstraints(minHeight: 120),
        child: Semantics(
          liveRegion: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (plan == null && _error == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator()),
                ),
              Text(body),
            ],
          ),
        ),
      ),
      actions: actions,
    );
  }
}
