import '../services/episode_dates.dart';
import 'social_payloads.dart' show DeleteField, ServerTimestamp, deleteField, serverTimestamp;

/// The exact field-level `update` payloads of the favorites writes that carry
/// mark dates, as pure maps with sentinels ([serverTimestamp], [deleteField];
/// dates are `DateTime`). `FirestoreFavoritesDataSource` resolves them; the
/// shared-profile golden (test/shared_profile_payloads_golden_test.dart)
/// replays them against the rules.
class FavoritePayloads {
  const FavoritePayloads._();

  /// `setEpisodes`: per-episode `eps` paths, the `epsAt` part of [dates]
  /// (empty when the new rules are not confirmed), `lastWatchedAt` and
  /// `updatedAt` from the server clock.
  static Map<String, Object?> setEpisodes(
    Map<String, bool> changes, {
    EpisodeDatesPlan dates = EpisodeDatesPlan.none,
  }) => {
    for (final e in changes.entries) 'eps.${e.key}': e.value ? true : deleteField,
    for (final k in (dates.delete.toList()..sort())) 'epsAt.$k': deleteField,
    for (final k in (dates.set.keys.toList()..sort())) 'epsAt.$k': dates.set[k]!.toUtc(),
    'lastWatchedAt': serverTimestamp,
    'updatedAt': serverTimestamp,
  };

  static bool isSentinel(Object? v) => v is ServerTimestamp || v is DeleteField;
}
