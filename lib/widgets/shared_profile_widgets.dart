import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/watch_time.dart';
import '../shared_profile/period_key.dart';
import '../shared_profile/shared_profile_models.dart';
import '../shared_profile/shared_profile_texts.dart';
import '../shared_profile/shared_stats_reading.dart';
import 'poster_image.dart';
import 'profile_stats_card.dart';

/// The shared statistics as friends see them (docs/82 §9: the same
/// component in the owner's preview and in the friend's profile).
/// "Este mês"/"este ano" follow the OWNER's zone [tz] (B1); the note on
/// dates (B2) sits under the period where the cut falls. A number the
/// document does not have shows "—" (RF-F9).
class SharedStatsView extends StatelessWidget {
  final SharedStatsReading reading;
  final int tz;
  final DateTime now;
  final DateTime? updatedAt;

  /// "No CineTrack desde" at the end. The friend's profile shows it in the
  /// header instead (D8).
  final bool showMemberSince;

  /// Key of the "No total" grid (tests of the consent preview).
  final Key? totalGridKey;

  /// The owner's own numbers (every value known).
  SharedStatsView({
    super.key,
    required SharedStats stats,
    required this.tz,
    required this.now,
    this.updatedAt,
    this.showMemberSince = true,
    this.totalGridKey,
  }) : reading = SharedStatsReading.of(stats);

  /// A friend's document, read leniently.
  const SharedStatsView.reading({
    super.key,
    required this.reading,
    required this.tz,
    required this.now,
    this.updatedAt,
    this.showMemberSince = true,
    this.totalGridKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = reading;
    final keys = periodKey(now, tz);
    final month = r.month.current(keys.month);
    final year = r.year.current(keys.year);
    final undated = r.undatedMovies + r.undatedEpisodes;
    final note = SharedProfileTexts.datesNoteFor(undated: undated, datedFrom: r.datedFrom, tz: tz);
    final place = SharedProfileTexts.notePlacementFor(
      undated: undated,
      datedFrom: r.datedFrom,
      updatedAt: updatedAt,
      tz: tz,
      now: now,
    );
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Semantics(header: true, child: Text(text, style: theme.textTheme.titleSmall)),
    );
    Widget time(int? minutes) {
      final value = minutes == null
          ? SharedProfileTexts.unknownValue
          : WatchTimeFormatter.format(minutes);
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Semantics(
          label: minutes == null ? 'Tempo assistido: sem informação' : null,
          excludeSemantics: minutes == null,
          child: Text('Tempo assistido: $value', style: theme.textTheme.bodyMedium),
        ),
      );
    }

    Widget period(String title, PeriodReading p, bool withNote) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading(title),
        ProfileStatsGrid(
          items: [
            ('Filmes assistidos', p.watchedMovies),
            ('Episódios assistidos', p.watchedEpisodes),
            ('Séries assistidas', p.watchedSeries),
            ('Séries concluídas', p.completedSeries),
          ],
        ),
        time(p.minutes),
        if (withNote && note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(note, style: theme.textTheme.bodySmall),
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading('No total'),
        ProfileStatsGrid(
          key: totalGridKey,
          items: [
            ('Favoritos', r.favorites),
            ('Filmes favoritos', r.movies),
            ('Séries favoritas', r.series),
            ('Filmes assistidos', r.total.watchedMovies),
            ('Episódios assistidos', r.total.watchedEpisodes),
            ('Séries concluídas', r.total.completedSeries),
          ],
        ),
        time(r.total.minutes),
        period('Este mês', month, place.month),
        period('Este ano', year, place.year),
        if (showMemberSince && r.memberSince != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'No CineTrack desde ${SharedProfileTexts.date(r.memberSince!, tz)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// One activity: the sentence of RF-A8 plus the relative date; opens the
/// title's details (RF-A7). Long titles are cut with an ellipsis, the screen
/// reader gets the whole sentence.
class SharedActivityTile extends StatelessWidget {
  final ActivityItem item;
  final DateTime now;

  const SharedActivityTile({super.key, required this.item, required this.now});

  @override
  Widget build(BuildContext context) {
    final text = SharedProfileTexts.activity(item);
    final ago = SharedProfileTexts.ago(item.at, now);
    return MergeSemantics(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(switch (item.type) {
          ActivityType.favorited => Icons.favorite_border,
          ActivityType.watchedMovie => Icons.movie_outlined,
          ActivityType.watchedEpisodes => Icons.live_tv_outlined,
          ActivityType.completedSeries => Icons.task_alt,
        }),
        title: Semantics(
          label: '$text, $ago',
          excludeSemantics: true,
          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        subtitle: ExcludeSemantics(child: Text(ago)),
        onTap: () =>
            context.push(item.mediaType == 'movie' ? '/movie/${item.id}' : '/tv/${item.id}'),
      ),
    );
  }
}

/// "Recomendados" as friends see them (docs/81 RF-R1, docs/82 §5.4): the
/// number "Recomendações" (`recs.count`, "—" when unknown), the listed
/// titles in the owner's order (at most 50) and "e mais N" when the number
/// is larger than the list. The same component in the owner's preview and
/// in the friend's profile.
class SharedRecsView extends StatelessWidget {
  final SharedRecsReading reading;

  /// Shown instead of the list when nothing is listed.
  final String emptyText;

  const SharedRecsView({super.key, required this.reading, required this.emptyText});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = reading.count;
    final more = reading.more;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: 'Recomendações: ${count ?? 'sem informação'}',
          excludeSemantics: true,
          child: Text(
            'Recomendações: ${count ?? SharedProfileTexts.unknownValue}',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (reading.items.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(emptyText, style: theme.textTheme.bodyMedium),
          )
        else
          for (final item in reading.items) SharedRecTile(item: item),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(SharedProfileTexts.andMore(more), style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

/// One recommended title: poster (or the media type's icon when there is
/// none), title and kind; opens the title's details. Long titles are cut
/// with an ellipsis, the screen reader gets the whole title.
class SharedRecTile extends StatelessWidget {
  final RecItem item;

  const SharedRecTile({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final movie = item.mediaType == 'movie';
    final kind = movie ? 'Filme' : 'Série';
    return MergeSemantics(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: ExcludeSemantics(
          child: PosterImage(
            posterPath: item.poster,
            width: 40,
            height: 60,
            fit: BoxFit.contain,
            placeholderIcon: movie ? Icons.movie_outlined : Icons.live_tv_outlined,
          ),
        ),
        title: Semantics(
          label: '${item.title}, ${kind.toLowerCase()}',
          excludeSemantics: true,
          child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        subtitle: ExcludeSemantics(child: Text(kind)),
        onTap: () => context.push(movie ? '/movie/${item.id}' : '/tv/${item.id}'),
      ),
    );
  }
}
