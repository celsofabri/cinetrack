import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/watch_time.dart';
import '../shared_profile/shared_profile_models.dart';
import '../shared_profile/shared_profile_texts.dart';
import 'profile_stats_card.dart';

/// The shared statistics as friends see them (docs/82 §9: the same
/// component in the owner's preview and, in Fatia 3, the friend's profile).
/// "Este mês"/"este ano" follow the OWNER's zone [tz] (B1); the note on
/// dates (B2) sits under the period where the cut falls.
class SharedStatsView extends StatelessWidget {
  final SharedStats stats;
  final int tz;
  final DateTime now;
  final DateTime? updatedAt;

  const SharedStatsView({
    super.key,
    required this.stats,
    required this.tz,
    required this.now,
    this.updatedAt,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = stats.total;
    final month = SharedProfileTexts.current(stats.month, month: true, tz: tz, now: now);
    final year = SharedProfileTexts.current(stats.year, month: false, tz: tz, now: now);
    final note = SharedProfileTexts.datesNote(stats, tz);
    final place = SharedProfileTexts.notePlacement(stats, updatedAt: updatedAt, tz: tz, now: now);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Semantics(header: true, child: Text(text, style: theme.textTheme.titleSmall)),
    );
    Widget time(int minutes) {
      final text = 'Tempo assistido: ${WatchTimeFormatter.format(minutes)}';
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(text, style: theme.textTheme.bodyMedium),
      );
    }

    Widget period(String title, PeriodStats p, bool withNote) => Column(
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
          items: [
            ('Favoritos', t.favorites),
            ('Filmes favoritos', t.movies),
            ('Séries favoritas', t.series),
            ('Filmes assistidos', t.watchedMovies),
            ('Episódios assistidos', t.watchedEpisodes),
            ('Séries concluídas', t.completedSeries),
          ],
        ),
        time(t.minutes),
        period('Este mês', month, place.month),
        period('Este ano', year, place.year),
        if (stats.memberSince != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'No CineTrack desde ${SharedProfileTexts.date(stats.memberSince!, tz)}',
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
