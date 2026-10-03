import 'package:flutter/material.dart';

import '../models/search_result.dart';
import '../models/title_details.dart';
import '../repositories/favorites_repository.dart';
import '../services/tmdb_exception.dart';
import 'app_shell.dart';
import 'auth_gate.dart';

/// The title got favorited but the second step (the watched mark) failed.
class PartialWriteException implements Exception {
  const PartialWriteException();
}

const kPartialWriteMessage =
    'O título foi favoritado, mas não foi possível salvar o "assistido". Tente marcar de novo.';
const kGenericWriteMessage = 'Não foi possível concluir a ação. Tente novamente.';

/// Favorites [result] when it is not a favorite yet, then runs [step]. A
/// failure of [step] after the favorite was saved surfaces as
/// [PartialWriteException] (never a silent half-done state).
Future<void> favoriteThen(
  FavoritesRepository repo,
  SearchResult result,
  bool alreadyFavorite,
  Future<void> Function() step,
) async {
  if (!alreadyFavorite) await repo.addResult(result);
  try {
    await step();
  } catch (_) {
    if (alreadyFavorite) rethrow;
    throw const PartialWriteException();
  }
}

String writeErrorMessage(Object error) => error is PartialWriteException
    ? kPartialWriteMessage
    : error is TmdbException
        ? error.message
        : kGenericWriteMessage;

/// [runWrite] plus a visible message for any failure it does not already
/// handle (login and unavailability are handled by [runWrite] itself).
Future<void> runDetailWrite(
  BuildContext context,
  Future<void> Function(FavoritesRepository repo) action,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await runWrite(context, action);
  } catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text(writeErrorMessage(error))));
  }
}

/// Favorite / unfavorite control of a details screen. Shows the real state
/// (filled heart = favorite) and a spinner while the write is in flight, so a
/// double tap cannot fire twice. Removing a title that has progress asks for
/// confirmation first, because the progress lives in the favorite document and
/// is deleted with it.
class FavoriteToggleButton extends StatefulWidget {
  final bool isFavorite;
  final bool hasProgress;
  final String title;
  final Future<void> Function() onAdd;
  final Future<void> Function() onRemove;

  const FavoriteToggleButton({
    super.key,
    required this.isFavorite,
    required this.hasProgress,
    required this.title,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<FavoriteToggleButton> createState() => _FavoriteToggleButtonState();
}

class _FavoriteToggleButtonState extends State<FavoriteToggleButton> {
  bool _pending = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _pending = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _remove() async {
    if (widget.hasProgress) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remover dos favoritos?'),
          content: const Text(
            'Seu progresso (itens assistidos) deste título também será apagado.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remover'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _run(widget.onRemove);
  }

  @override
  Widget build(BuildContext context) {
    // Same Material 3 button family as the rest of the app (stadium shape,
    // 18 px icon, labelLarge): filled primary (the purple accent) to
    // favorite, tonal (same family, calmer) to remove. 48 px high on mobile
    // for the touch target, the M3 default 40 px on desktop.
    final minimumSize = Size(0, isMobileWidth(context) ? 48 : 40);
    final icon = _pending
        ? Builder(
            builder: (context) => SizedBox(
              width: 18,
              height: 18,
              // Same color as the button's foreground, never a stray accent.
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: IconTheme.of(context).color,
              ),
            ),
          )
        : Icon(widget.isFavorite ? Icons.favorite : Icons.favorite_border);

    if (widget.isFavorite) {
      return Semantics(
        button: true,
        label: 'Remover ${widget.title} dos favoritos',
        excludeSemantics: true,
        child: FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: minimumSize),
          onPressed: _pending ? null : _remove,
          icon: icon,
          label: const Text('Remover dos favoritos'),
        ),
      );
    }
    return Semantics(
      button: true,
      label: 'Favoritar ${widget.title}',
      excludeSemantics: true,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: minimumSize),
        // The tap handler calls straight into the write/login flow: no await
        // before it, so the Google popup is still opened by the user gesture.
        onPressed: _pending ? null : () => _run(widget.onAdd),
        icon: icon,
        label: const Text('Favoritar'),
      ),
    );
  }
}

/// "2019 · ★ 8.1" line plus genre chips, from TMDB data.
class TitleMeta extends StatelessWidget {
  final TitleDetails? details;

  const TitleMeta({super.key, required this.details});

  @override
  Widget build(BuildContext context) {
    final d = details;
    if (d == null) return const SizedBox.shrink();
    final parts = [
      if (d.year != null) '${d.year}',
      if (d.voteAverage != null) '★ ${d.voteAverage!.toStringAsFixed(1)}',
    ];
    if (parts.isEmpty && d.genres.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parts.isNotEmpty)
          Text(parts.join(' · '), style: Theme.of(context).textTheme.bodyMedium),
        if (d.genres.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final g in d.genres) Chip(label: Text(g))],
          ),
        ],
      ],
    );
  }
}
