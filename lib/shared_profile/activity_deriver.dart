import '../models/favorite_doc.dart';
import '../models/media_type.dart';
import '../services/favorite_mapper.dart';
import 'shared_profile_models.dart';

/// Activities kept in the document (the reader shows 3).
const kMaxActivities = 10;

/// "Favoritar e assistir no mesmo gesto" (docs/82 §5.3).
const kSameGestureWindow = Duration(minutes: 10);

enum _Kind { favorited, movie, episode }

class _Event {
  final _Kind kind;
  final FavoriteDoc doc;
  final DateTime at;
  final int season;
  final int episode;

  const _Event(this.kind, this.doc, this.at, {this.season = 0, this.episode = 0});
}

/// Recent activities DERIVED from the user's documents (D1, docs/82 §5.3):
/// nothing is recorded, so undoing, unmarking or removing a title changes the
/// list by itself, and two devices derive the same list from the same data.
/// Pure: depends only on its arguments.
class ActivityDeriver {
  const ActivityDeriver._();

  /// Newest first, at most [kMaxActivities]. Only events at or after
  /// [actSince] (the consent) count; dates later than [now] are clamped to
  /// [now]. [isCompleted] is the "Concluídos" rule of a series right now.
  static List<ActivityItem> derive(
    List<FavoriteDoc> docs, {
    required DateTime actSince,
    required DateTime now,
    required bool Function(FavoriteDoc doc) isCompleted,
  }) {
    final since = actSince.toUtc();
    final limit = now.toUtc();
    DateTime clamp(DateTime at) => at.toUtc().isAfter(limit) ? limit : at.toUtc();

    final events = <_Event>[];
    final conclusion = <String, DateTime>{};
    for (final doc in docs) {
      events.add(_Event(_Kind.favorited, doc, clamp(doc.addedAt)));
      if (doc.mediaType == MediaType.movie) {
        final at = doc.lastWatchedAt;
        if (doc.watchedMovie && at != null) events.add(_Event(_Kind.movie, doc, clamp(at)));
        continue;
      }
      DateTime? last;
      for (final key in doc.watchedEpisodes) {
        final at = doc.markedAt(key);
        final parsed = FavoriteMapper.parseEpisodeKey(key);
        if (at == null || parsed == null) continue;
        final when = clamp(at);
        events.add(_Event(_Kind.episode, doc, when, season: parsed.$1, episode: parsed.$2));
        if (last == null || when.isAfter(last)) last = when;
      }
      if (last != null && isCompleted(doc)) conclusion[doc.key] = last;
    }
    events.removeWhere((e) => e.at.isBefore(since));
    events.sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      if (byTime != 0) return byTime;
      final byTitle = a.doc.key.compareTo(b.doc.key);
      if (byTitle != 0) return byTitle;
      final byKind = a.kind.index.compareTo(b.kind.index);
      if (byKind != 0) return byKind;
      final bySeason = a.season.compareTo(b.season);
      return bySeason != 0 ? bySeason : a.episode.compareTo(b.episode);
    });

    // Oldest first while reducing; the last element is the most recent.
    final out = <ActivityItem>[];
    for (final e in events) {
      final last = out.isEmpty ? null : out.last;
      final sameTitle =
          last != null && last.id == e.doc.id && last.mediaType == e.doc.mediaType.jsonValue;
      final sameGesture =
          sameTitle &&
          last.type == ActivityType.favorited &&
          !e.at.difference(last.at).isNegative &&
          e.at.difference(last.at) <= kSameGestureWindow;
      switch (e.kind) {
        case _Kind.favorited:
          out.add(_item(ActivityType.favorited, e.doc, e.at));
        case _Kind.movie:
          final item = _item(ActivityType.watchedMovie, e.doc, e.at);
          sameGesture ? out[out.length - 1] = item : out.add(item);
        case _Kind.episode:
          if (sameTitle && last.type == ActivityType.watchedEpisodes) {
            final higher = (e.season, e.episode) > (last.season!, last.episode!);
            out[out.length - 1] = last.copyWith(
              at: e.at,
              count: last.count! + 1,
              season: higher ? e.season : last.season,
              episode: higher ? e.episode : last.episode,
            );
          } else {
            final item = _item(
              ActivityType.watchedEpisodes,
              e.doc,
              e.at,
              count: 1,
              season: e.season,
              episode: e.episode,
            );
            sameGesture ? out[out.length - 1] = item : out.add(item);
          }
      }
    }

    // A series completed NOW: its group that ends at the conclusion becomes
    // "concluiu" (keeps count and season/episode).
    for (var i = out.length - 1; i >= 0; i--) {
      final item = out[i];
      if (item.type != ActivityType.watchedEpisodes) continue;
      final done = conclusion['${item.id}-${item.mediaType}'];
      if (done != null && done == item.at) {
        out[i] = item.copyWith(type: ActivityType.completedSeries);
        conclusion.remove('${item.id}-${item.mediaType}');
      }
    }

    final recent = out.length > kMaxActivities ? out.sublist(out.length - kMaxActivities) : out;
    return recent.reversed.toList();
  }

  static ActivityItem _item(
    ActivityType type,
    FavoriteDoc doc,
    DateTime at, {
    int? count,
    int? season,
    int? episode,
  }) => ActivityItem(
    type: type,
    id: doc.id,
    mediaType: doc.mediaType.jsonValue,
    title: doc.title,
    poster: doc.posterPath,
    at: at,
    count: count,
    season: season,
    episode: episode,
  );
}

extension on (int, int) {
  bool operator >((int, int) other) => $1 != other.$1 ? $1 > other.$1 : $2 > other.$2;
}
