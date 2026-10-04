import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/favorites_data_source.dart';
import '../data/sync_status.dart';
import '../models/search_result.dart';
import '../providers/catalog_sync_providers.dart';
import '../providers/providers.dart';
import '../providers/sync_providers.dart';
import '../services/bulk_watch.dart';
import 'auth_gate.dart';
import 'detail_actions.dart';

enum BulkAck { saved, failed, offline, stalled }

/// Pause before reading the sync state after a write, so the "pending" flag of
/// the local database has time to show up. Max wait for the server's answer.
const kAckSettle = Duration(milliseconds: 250);
const kAckWait = Duration(seconds: 8);

/// How long the pending flag must stay down before a write counts as saved.
const kAckVerify = Duration(milliseconds: 1500);

/// The whole-series mark/unmark flow, shared by "Meus favoritos" (card button)
/// and the show details (chip): the same dialog, write, "salvando…" and
/// "Desfazer" for both (docs/30, docs/45). Mixed into the screen's State, which
/// calls [disposeBulkFlow] from `dispose` and [discardBulkUndo] on account
/// change.
mixin SeriesBulkFlow<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// Storage keys whose bulk action (or its undo) is running (anti double tap).
  final Set<String> bulkBusy = {};

  /// The one "Desfazer" snackbar (the last whole-series action) and its owner.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoSnack;

  /// The "salvando…" snackbar while the server's answer is awaited.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _savingSnack;

  /// Leaving the screen discards the pending "Desfazer" and any "salvando…"
  /// (docs/30). Controllers are captured, no context of this State is used.
  void disposeBulkFlow() {
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
  }

  void discardBulkUndo() {
    final snack = _undoSnack;
    _undoSnack = null;
    snack?.close();
    final saving = _savingSnack;
    _savingSnack = null;
    saving?.close();
  }

  /// Whole-series mark/unmark: confirmation dialog (with the real counts), ONE
  /// write, then "salvando…" and "Desfazer". [isFavorite] false = the series is
  /// not in Favoritos yet: the plan comes from TMDB without saving anything,
  /// and the title is favorited together with the write (docs/15, docs/45).
  /// [onDialog] tells the caller when the modal opens/closes.
  Future<void> toggleSeriesBulk({
    required SearchResult series,
    required bool isFavorite,
    required bool markAll,
    void Function(bool open)? onDialog,
  }) async {
    final repo = ref.read(favoritesRepositoryProvider);
    final delay = ref.read(catalogSyncDelayProvider);
    final uid = ref.read(currentUidProvider);
    onDialog?.call(true);
    final plan = await showDialog<SeriesBulkPlan>(
      context: context,
      barrierDismissible: true, // outside tap and Esc = Cancelar
      builder: (_) => BulkWatchDialog(
        title: series.title,
        watched: markAll,
        load: (isCancelled) => isFavorite
            ? repo.planSeriesBulk(
                series.id,
                watched: markAll,
                delay: delay,
                isCancelled: isCancelled,
              )
            : repo.planNewSeriesBulk(series.id, delay: delay, isCancelled: isCancelled),
      ),
    );
    if (mounted) onDialog?.call(false);
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
        await favoriteThen(repo, series, isFavorite, () async {
          undo = await repo.applySeriesBulk(plan, uid: uid);
        });
      } catch (_) {
        failed = true;
        rethrow;
      }
    });
    final applied = undo;
    if (failed || applied == null || !mounted) return;
    // The card is usable again as soon as the local write is accepted (the
    // caller's `finally`); the server's answer is followed in the background.
    unawaited(
      _afterBulkWrite(
        messenger: messenger,
        title: series.title,
        addedToFavorites: !isFavorite,
        markAll: markAll,
        applied: applied,
        count: markAll ? plan.episodeCount : applied.inverse.length,
        baseline: baseline,
      ),
    );
  }

  int _actionSeq = 0;

  Future<void> _afterBulkWrite({
    required ScaffoldMessengerState messenger,
    required String title,
    required bool addedToFavorites,
    required bool markAll,
    required SeriesBulkUndo applied,
    required int count,
    required SyncFailure? baseline,
  }) async {
    final seq = ++_actionSeq;
    // A newer action owns the snackbar from now on.
    bool stale() => !mounted || seq != _actionSeq || ref.read(currentUidProvider) != applied.uid;
    discardBulkUndo();
    final what = '$count ${_eps(count)}';
    // Do not promise what the server may still refuse: wait for its answer.
    messenger.clearSnackBars(); // also drops a queued/closing older "Desfazer"
    _savingSnack = messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 1),
        persist: false,
        content: Row(
          children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text('$title: salvando…')),
          ],
        ),
      ),
    );
    final ack = await _awaitAck(baseline);
    if (!mounted || seq != _actionSeq) return; // left the screen / replaced by a newer action
    _savingSnack = null;
    messenger.clearSnackBars(); // the "salvando…" one
    if (ack == BulkAck.failed) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Não foi possível salvar a alteração em $title. '
            'O progresso volta ao que era.',
          ),
        ),
      );
      return;
    }
    if (stale()) return; // account changed meanwhile: no Desfazer of another account
    final done = markAll
        ? '$what marcados como assistidos${addedToFavorites ? ' e série adicionada aos favoritos' : ''}'
        : 'progresso apagado ($what)';
    final suffix = switch (ack) {
      BulkAck.saved => '.',
      BulkAck.offline => ' neste aparelho. Sincroniza quando houver conexão.',
      _ => ' neste aparelho. Aguardando confirmação do servidor.',
    };
    final snack = messenger.showSnackBar(
      SnackBar(
        duration: kUndoWindow,
        // Since Flutter 3.29 a snackbar with an action stays until dismissed.
        persist: false,
        content: Text('$title: $done$suffix'),
        action: SnackBarAction(
          label: 'Desfazer',
          onPressed: () => undoBulk(applied, messenger, keepsFavorite: addedToFavorites),
        ),
      ),
    );
    _undoSnack = snack;
    snack.closed.then((_) {
      if (identical(_undoSnack, snack)) _undoSnack = null;
    });
  }

  /// Waits (bounded) for the server to acknowledge the write just made:
  /// [BulkAck.saved], [BulkAck.failed] (rules/quota refused it, the local view rolls
  /// back), [BulkAck.offline] (kept on this device) or [BulkAck.stalled] (connected
  /// but no answer in [kAckWait]: kept, flagged).
  ///
  /// [baseline] is the sync failure that existed before the write. "Saved" is
  /// only declared after the pending flag has stayed down for [kAckVerify]:
  /// a refused write rolls back (pending drops) BEFORE its failure is
  /// recorded (a permission-denied is first checked against the session).
  Future<BulkAck> _awaitAck(SyncFailure? baseline) async {
    await Future<void>.delayed(kAckSettle);
    if (!mounted) return BulkAck.saved;
    final done = Completer<BulkAck>();
    Timer? verify;
    void evaluate(SyncStatus s) {
      if (done.isCompleted) return;
      if (s.failure != null && !identical(s.failure, baseline)) {
        done.complete(BulkAck.failed);
      } else if (s.offline) {
        done.complete(BulkAck.offline);
      } else if (s.hasPendingWrites) {
        verify?.cancel();
        verify = null;
        if (s.pendingStalled) done.complete(BulkAck.stalled);
      } else {
        verify ??= Timer(kAckVerify, () {
          if (!done.isCompleted) done.complete(BulkAck.saved);
        });
      }
    }

    final sub = ref.listenManual(syncStatusProvider, (_, next) => evaluate(next));
    evaluate(ref.read(syncStatusProvider));
    final timer = Timer(kAckWait, () {
      if (!done.isCompleted) done.complete(BulkAck.stalled);
    });
    try {
      return await done.future;
    } finally {
      sub.close();
      timer.cancel();
      verify?.cancel();
    }
  }

  Future<void> undoBulk(
    SeriesBulkUndo undo,
    ScaffoldMessengerState messenger, {
    bool keepsFavorite = false,
  }) async {
    if (!mounted) return;
    if (ref.read(currentUidProvider) != undo.uid) {
      messenger.showSnackBar(const SnackBar(content: Text(_kAccountChanged)));
      return;
    }
    if (!bulkBusy.add(undo.docKey)) return;
    setState(() {});
    String message;
    try {
      final baseline = ref.read(syncStatusProvider).failure;
      final outcome = await ref.read(favoritesRepositoryProvider).undoSeriesBulk(undo);
      message = switch (outcome) {
        UndoOutcome.restored =>
          keepsFavorite
              ? 'Progresso desfeito. A série continua nos favoritos.'
              : 'Progresso restaurado.',
        UndoOutcome.changed => 'Algo mudou, não foi possível desfazer.',
        UndoOutcome.gone => kGoneMessage,
      };
      if (outcome == UndoOutcome.restored &&
          mounted &&
          await _awaitAck(baseline) == BulkAck.failed) {
        message = 'Não foi possível salvar o "desfazer". O progresso volta ao que era.';
      }
    } catch (error) {
      message = error is AuthRequiredException || error is FavoritesUnavailableException
          ? kFavoriteUnavailableMessage
          : writeErrorMessage(error);
    } finally {
      bulkBusy.remove(undo.docKey);
      if (mounted) setState(() {});
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  static const _kAccountChanged = 'A conta mudou. Nada foi alterado.';

  static String _eps(int n) => n == 1 ? 'episódio' : 'episódios';
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
