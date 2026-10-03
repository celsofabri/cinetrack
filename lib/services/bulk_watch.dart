import '../models/season_cache.dart';
import 'favorite_mapper.dart';

/// How long the "Desfazer" of a whole-series mark/unmark stays available
/// (docs/30). One constant for the snackbar, the dialog text and the tests.
const kUndoWindow = Duration(seconds: 30);

/// Largest single write we send for one series. A Firestore document keeps
/// two index entries per `eps.<s>_<e>` field (40,000 entries per document) and
/// the rules cap `eps` at 5,000 entries, so one atomic update above this is
/// refused up front instead of failing halfway.
const kMaxBulkEpisodes = 5000;

/// The favorite is gone (removed on another device, or never saved).
class FavoriteGoneException implements Exception {
  const FavoriteGoneException();
}

/// The series has more episodes than one atomic write may carry.
class BulkTooLargeException implements Exception {
  const BulkTooLargeException();
}

/// What a whole-series mark/unmark is going to change. [keys] are the
/// `"{season}_{episode}"` keys to set ([watched] true) or clear ([watched]
/// false); [seasonCount] how many seasons they belong to.
class SeriesBulkPlan {
  final String docKey;
  final bool watched;
  final Set<String> keys;
  final int seasonCount;

  const SeriesBulkPlan({
    required this.docKey,
    required this.watched,
    required this.keys,
    required this.seasonCount,
  });

  int get episodeCount => keys.length;
  bool get isEmpty => keys.isEmpty;
}

/// Exact inverse of an applied bulk change. [expected] is the set of watched
/// episodes the document had right after the change: the undo only runs when
/// the document still has exactly that.
class SeriesBulkUndo {
  final String docKey;
  final String uid;
  final Map<String, bool> inverse;
  final Set<String> expected;

  const SeriesBulkUndo({
    required this.docKey,
    required this.uid,
    required this.inverse,
    required this.expected,
  });
}

enum UndoOutcome { restored, changed, gone }

/// Pure rules of the whole-series mark (docs/18 "concluído"): every episode
/// that has already aired in the regular seasons; future episodes and the
/// specials (season 0) never enter, except for a show that only has specials.
class BulkWatchRules {
  const BulkWatchRules._();

  static SeriesBulkPlan markAll(
    String docKey,
    List<SeasonCache> catalog,
    Set<String> alreadyWatched,
  ) {
    final regular = catalog.where((s) => s.seasonNumber != 0 && s.episodes.isNotEmpty);
    final counted = regular.isNotEmpty ? regular : catalog.where((s) => s.episodes.isNotEmpty);
    final keys = <String>{};
    final seasons = <int>{};
    for (final season in counted) {
      for (final ep in season.episodes) {
        if (!ep.hasAired) continue;
        final key = FavoriteMapper.episodeKey(season.seasonNumber, ep.episodeNumber);
        if (alreadyWatched.contains(key)) continue;
        keys.add(key);
        seasons.add(season.seasonNumber);
      }
    }
    return SeriesBulkPlan(docKey: docKey, watched: true, keys: keys, seasonCount: seasons.length);
  }

  /// Clears every watched episode of the document (the "apaga o progresso" of
  /// the confirmation), whatever the catalog says.
  static SeriesBulkPlan unmarkAll(String docKey, Set<String> watched) {
    final seasons = <int>{
      for (final k in watched)
        if (FavoriteMapper.parseEpisodeKey(k) case final parsed?) parsed.$1,
    };
    return SeriesBulkPlan(
      docKey: docKey,
      watched: false,
      keys: {...watched},
      seasonCount: seasons.length,
    );
  }
}
