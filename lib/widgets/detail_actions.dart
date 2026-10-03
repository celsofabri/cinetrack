import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/search_result.dart';
import '../providers/providers.dart';
import '../services/progress_calculator.dart';
import '../models/title_details.dart';
import '../repositories/favorites_repository.dart';
import '../services/tmdb_exception.dart';
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

/// Asks before removing a favorite that has progress (the progress lives in the
/// favorite document and is deleted with it). Returns true when confirmed.
Future<bool> confirmRemoveFavorite(BuildContext context) async {
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
  return confirmed == true;
}

/// Whether removing the favorite [id] would delete progress (watched movie, or
/// watched episodes in the document or the local cache). When the raw
/// documents cannot be read (loading too long, or failed) we cannot rule
/// progress out, so it says true and the caller asks for confirmation.
Future<bool> favoriteHasProgress(ProviderContainer container, int id, MediaType type) async {
  final items = container.read(favoritesListProvider).value ?? const <FavoriteItem>[];
  final matches = items.where((f) => f.id == id && f.mediaType == type);
  if (matches.isEmpty) return false;
  final item = matches.first;
  if (type == MediaType.movie) return item.watchedMovie;
  if (ProgressCalculator.compute(item.seasons ?? const []).isStarted) return true;
  try {
    // Not watched by the list screens, so it may still be loading.
    final docs =
        await container.read(favoriteDocsProvider.future).timeout(const Duration(seconds: 3));
    return docs.any((d) => d.id == id && d.mediaType == type && d.watchedEpisodes.isNotEmpty);
  } catch (_) {
    return true;
  }
}

/// Heart on a poster (Explorar, Busca, Descoberta, Início): toggles. Removing
/// asks for confirmation when there is progress. [setPending] is called with
/// true once the write really starts (after any confirmation) and false when
/// it ends. The add path calls straight into the write/login flow with no
/// await before it, so the Google popup is still opened by the user gesture.
Future<void> toggleFavoriteFromList(
  BuildContext context,
  SearchResult result, {
  required bool isFavorite,
  required void Function(bool pending) setPending,
}) async {
  if (!isFavorite) {
    setPending(true);
    try {
      await runWrite(context, (repo) => repo.addResult(result));
    } finally {
      setPending(false);
    }
    return;
  }
  final container = ProviderScope.containerOf(context);
  if (await favoriteHasProgress(container, result.id, result.mediaType)) {
    if (!context.mounted || !await confirmRemoveFavorite(context) || !context.mounted) return;
  } else if (!context.mounted) {
    return;
  }
  setPending(true);
  try {
    await runWrite(context, (repo) => repo.remove(result.id, result.mediaType));
  } finally {
    setPending(false);
  }
}

/// The one chip used by both detail actions (favorite and watched), so they
/// share shape, height, typography, icon size, spacing and states. [accent]
/// only changes the selected color (purple primary for the favorite).
class DetailToggleChip extends StatelessWidget {
  final String label;
  final String semanticsLabel;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final bool pending;
  final bool accent;
  final VoidCallback onPressed;

  const DetailToggleChip({
    super.key,
    required this.label,
    required this.semanticsLabel,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.pending,
    required this.onPressed,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected && accent ? scheme.onPrimaryContainer : null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: !pending,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: pending ? null : onPressed,
      child: FilterChip(
        label: Text(label),
        labelStyle: fg == null ? null : TextStyle(color: fg),
        selected: selected,
        showCheckmark: false,
        selectedColor: selected && accent ? scheme.primaryContainer : null,
        avatar: pending
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            : Icon(selected ? selectedIcon : icon, size: 18, color: fg),
        // Padded tap target: 48 px high on mobile, the M3 default elsewhere.
        materialTapTargetSize: MaterialTapTargetSize.padded,
        // The tap handler calls straight into the write/login flow: no await
        // before it, so the Google popup is still opened by the user gesture.
        onSelected: pending ? null : (_) => onPressed(),
      ),
    );
  }
}

/// Favorite / unfavorite control of a details screen. Same chip as the watched
/// control, purple when favorite, with a spinner while the write is in flight
/// (no double tap). Removing a title that has progress asks for confirmation.
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
      if (!await confirmRemoveFavorite(context) || !mounted) return;
    }
    await _run(widget.onRemove);
  }

  @override
  Widget build(BuildContext context) {
    return DetailToggleChip(
      label: widget.isFavorite ? 'Remover dos favoritos' : 'Favoritar',
      semanticsLabel:
          widget.isFavorite ? 'Remover ${widget.title} dos favoritos' : 'Favoritar ${widget.title}',
      icon: Icons.favorite_border,
      selectedIcon: Icons.favorite,
      selected: widget.isFavorite,
      accent: true,
      pending: _pending,
      onPressed: widget.isFavorite ? _remove : () => _run(widget.onAdd),
    );
  }
}

/// "Marcar como assistido" control (movie details): the same chip as the
/// favorite, with its own pending state.
class WatchedToggleChip extends StatefulWidget {
  final bool watched;
  final String title;
  final Future<void> Function() onToggle;

  const WatchedToggleChip({
    super.key,
    required this.watched,
    required this.title,
    required this.onToggle,
  });

  @override
  State<WatchedToggleChip> createState() => _WatchedToggleChipState();
}

class _WatchedToggleChipState extends State<WatchedToggleChip> {
  bool _pending = false;

  Future<void> _run() async {
    setState(() => _pending = true);
    try {
      await widget.onToggle();
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DetailToggleChip(
      label: widget.watched ? 'Assistido' : 'Marcar como assistido',
      semanticsLabel: widget.watched
          ? 'Desmarcar ${widget.title} como assistido'
          : 'Marcar ${widget.title} como assistido',
      icon: Icons.check_circle_outline,
      selectedIcon: Icons.check_circle,
      selected: widget.watched,
      pending: _pending,
      onPressed: _run,
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
