import '../models/episode_cache.dart';
import '../models/favorite_doc.dart';
import '../models/favorite_item.dart';
import '../models/media_type.dart';
import '../models/season_cache.dart';
import '../models/tv_season_summary.dart';

/// Pure conversions between the cloud document shape ([FavoriteDoc] /
/// Firestore map) and the in-app [FavoriteItem]. No Firebase types here, so
/// everything is unit-testable; the Firestore data source converts
/// `Timestamp` <-> `DateTime` at its own edge.
class FavoriteMapper {
  const FavoriteMapper._();

  /// Key of a watched episode inside the `eps` map.
  static String episodeKey(int season, int episode) => '${season}_$episode';

  /// Returns `(season, episode)` or null when [key] is malformed.
  static (int, int)? parseEpisodeKey(String key) {
    final parts = key.split('_');
    if (parts.length != 2) return null;
    final season = int.tryParse(parts[0]);
    final episode = int.tryParse(parts[1]);
    if (season == null || episode == null) return null;
    return (season, episode);
  }

  /// Field-by-field merge of episode changes into [current]: `true` marks,
  /// `false` unmarks, episodes not mentioned are untouched. This is the
  /// same semantics Firestore gives us with `update({'eps.1_2': true})` /
  /// `FieldValue.delete()` — kept here so fakes mirror the server.
  static Set<String> applyEpisodeChanges(Set<String> current, Map<String, bool> changes) {
    final result = {...current};
    changes.forEach((key, watched) {
      if (watched) {
        result.add(key);
      } else {
        result.remove(key);
      }
    });
    return result;
  }

  /// Document body to create a favorite. Date values stay `DateTime`.
  ///
  /// `recommended` is written ONLY when true: a plain add stays bit-for-bit
  /// what it always was (accepted even by the previous security rules), and
  /// "not recommended" is the absence of the field, never `false`.
  static Map<String, dynamic> toMap(FavoriteDoc doc) => {
        'id': doc.id,
        'mediaType': doc.mediaType.jsonValue,
        'title': doc.title,
        'posterPath': doc.posterPath,
        'overview': doc.overview,
        'addedAt': doc.addedAt,
        'lastWatchedAt': doc.lastWatchedAt,
        'watchedMovie': doc.watchedMovie,
        'seasonSummaries': doc.seasonSummaries.map((s) => s.toJson()).toList(),
        'eps': {for (final key in doc.watchedEpisodes) key: true},
        if (doc.recommended) 'recommended': true,
      };

  /// Parses a stored document. Returns null (document ignored) when the
  /// essential fields are unusable, mirroring `FavoriteItem.fromJson`'s
  /// defaults for everything optional.
  static FavoriteDoc? fromMap(String key, Map<dynamic, dynamic> map) {
    try {
      final id = map['id'];
      final mediaTypeRaw = map['mediaType'];
      if (id is! int || mediaTypeRaw is! String) return null;
      final mediaType = MediaType.fromJson(mediaTypeRaw);
      if ('$id-${mediaType.jsonValue}' != key) return null;

      final eps = map['eps'];
      return FavoriteDoc(
        id: id,
        mediaType: mediaType,
        title: map['title'] as String? ?? '',
        posterPath: map['posterPath'] as String?,
        overview: map['overview'] as String? ?? '',
        addedAt: _date(map['addedAt']) ?? DateTime.now(),
        lastWatchedAt: _date(map['lastWatchedAt']),
        watchedMovie: map['watchedMovie'] as bool? ?? false,
        recommended: map['recommended'] == true,
        seasonSummaries: [
          for (final s in (map['seasonSummaries'] as List? ?? const []))
            TvSeasonSummary.fromJson(Map<dynamic, dynamic>.from(s as Map)),
        ],
        watchedEpisodes: {
          if (eps is Map)
            for (final entry in eps.entries)
              if (entry.value == true && parseEpisodeKey('${entry.key}') != null) '${entry.key}',
        },
      );
    } catch (_) {
      return null;
    }
  }

  static DateTime? _date(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  /// Rebuilds the public [FavoriteItem] shape (so screens and
  /// `ProgressCalculator` stay untouched): cloud document + locally cached
  /// catalog seasons, with `watched` overlaid from the document.
  static FavoriteItem hydrate(FavoriteDoc doc, List<SeasonCache> catalog) {
    final isTv = doc.mediaType == MediaType.tv;
    return FavoriteItem(
      id: doc.id,
      mediaType: doc.mediaType,
      title: doc.title,
      posterPath: doc.posterPath,
      overview: doc.overview,
      addedAt: doc.addedAt,
      watchedMovie: doc.watchedMovie,
      lastWatchedAt: doc.lastWatchedAt,
      recommended: doc.recommended,
      seasonSummaries: isTv ? doc.seasonSummaries : null,
      seasons:
          isTv ? [for (final season in catalog) overlayWatched(season, doc.watchedEpisodes)] : null,
    );
  }

  /// [season] with each episode's `watched` taken from [watchedEpisodes].
  static SeasonCache overlayWatched(SeasonCache season, Set<String> watchedEpisodes) => SeasonCache(
        seasonNumber: season.seasonNumber,
        episodes: [
          for (final ep in season.episodes)
            ep.copyWith(
              watched: watchedEpisodes.contains(episodeKey(season.seasonNumber, ep.episodeNumber)),
            ),
        ],
      );

  /// Catalog copy of [season]: episodes and dates only, never `watched`
  /// (progress must come from the signed-in user's document, otherwise it
  /// could leak between accounts through the shared local cache).
  static SeasonCache stripWatched(SeasonCache season) => SeasonCache(
        seasonNumber: season.seasonNumber,
        episodes: [
          for (final ep in season.episodes)
            EpisodeCache(
              episodeNumber: ep.episodeNumber,
              name: ep.name,
              airDate: ep.airDate,
              watched: false,
              runtime: ep.runtime,
              stillPath: ep.stillPath,
              overview: ep.overview,
              detailed: ep.detailed,
            ),
        ],
      );
}
