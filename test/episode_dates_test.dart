import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/favorite_payloads.dart';
import 'package:cinetrack/data/firestore_favorites_data_source.dart';
import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/services/bulk_watch.dart';
import 'package:cinetrack/services/episode_dates.dart';
import 'package:cinetrack/services/favorite_mapper.dart';

import 'support/favorites_harness.dart';

/// docs/82 §4.2: mark dates (`epsAt`), orphans, Desfazer with dates.
FavoriteDoc _doc({Set<String> eps = const {}, Map<String, DateTime> at = const {}}) => FavoriteDoc(
  id: 42,
  mediaType: MediaType.tv,
  title: 'A Show',
  posterPath: null,
  overview: '',
  addedAt: DateTime.utc(2026),
  watchedEpisodes: eps,
  watchedAt: at,
);

final _t0 = DateTime.utc(2026, 10, 1, 20);
final _now = DateTime.utc(2026, 10, 10, 21);

void main() {
  group('FavoriteDoc / mapper', () {
    test('epsAt is parsed tolerantly; orphans are kept but never "marked"', () {
      final doc = FavoriteMapper.fromMap('42-tv', {
        'id': 42,
        'mediaType': 'tv',
        'title': 'A Show',
        'addedAt': DateTime.utc(2026),
        'eps': {'1_1': true, '1_2': true},
        'epsAt': {'1_1': _t0, '1_2': 'not a date', '1_9': _t0, 'bad': _t0},
      })!;
      expect(doc.watchedAt.keys, unorderedEquals(['1_1', '1_9']));
      expect(doc.markedAt('1_1'), _t0);
      expect(doc.markedAt('1_2'), isNull, reason: 'value is not a date');
      expect(doc.markedAt('1_9'), isNull, reason: 'orphan: 1_9 is not marked');
      expect(doc.orphanDates, {'1_9'});
    });

    test('old documents (no epsAt) parse as before; add never emits epsAt', () {
      final doc = FavoriteMapper.fromMap('42-tv', {
        'id': 42,
        'mediaType': 'tv',
        'title': 'A Show',
        'addedAt': DateTime.utc(2026),
        'eps': {'1_1': true},
      })!;
      expect(doc.watchedAt, isEmpty);
      expect(
        FavoriteMapper.toMap(_doc(eps: {'1_1'}, at: {'1_1': _t0})).containsKey('epsAt'),
        isFalse,
      );
    });

    test('nested Timestamps are converted at the Firestore edge', () {
      final converted = FirestoreFavoritesDataSource.convertValue({
        'epsAt': {'1_1': Timestamp.fromDate(_t0)},
      });
      expect((converted! as Map)['epsAt'], {'1_1': _t0.toLocal()});
    });
  });

  group('EpisodeDates.plan', () {
    test('ONE instant for every mark of the write', () {
      final plan = EpisodeDates.plan(
        changes: {for (var e = 1; e <= 24; e++) '1_$e': true},
        current: _doc(),
        instant: _now,
      );
      expect(plan.set.length, 24);
      expect(plan.set.values.toSet(), {_now});
      expect(plan.delete, isEmpty);
    });

    test('unmarking deletes the date (only when there is one)', () {
      final plan = EpisodeDates.plan(
        changes: {'1_1': false, '1_2': false},
        current: _doc(eps: {'1_1', '1_2'}, at: {'1_1': _t0}),
        instant: _now,
      );
      expect(plan.delete, {'1_1'});
      expect(plan.set, isEmpty);
    });

    test('orphan dates are cleaned by any write of the new version (max 500)', () {
      final orphans = {for (var e = 1; e <= 600; e++) '9_$e': _t0};
      final plan = EpisodeDates.plan(
        changes: {'1_1': true},
        current: _doc(at: orphans),
        instant: _now,
      );
      expect(plan.delete.length, kMaxOrphanDeletesPerWrite);
      expect(plan.set, {'1_1': _now});
    });

    test('re-marking an orphan key gives it the NEW date (not deleted)', () {
      final plan = EpisodeDates.plan(
        changes: {'1_1': true},
        current: _doc(at: {'1_1': _t0}),
        instant: _now,
      );
      expect(plan.set, {'1_1': _now});
      expect(plan.delete, isEmpty);
    });

    test('unknown state (current null): no new dates, deletions only', () {
      final plan = EpisodeDates.plan(
        changes: {'1_1': true, '1_2': false},
        current: null,
        instant: _now,
      );
      expect(plan.set, isEmpty);
      expect(plan.delete, {'1_2'});
    });

    test('never more than 5000 dates: the mark goes WITHOUT a date', () {
      final full = {for (var e = 1; e <= kMaxEpisodeDates; e++) '1_$e': _t0};
      final plan = EpisodeDates.plan(
        changes: {'2_1': true},
        current: _doc(eps: full.keys.toSet(), at: full),
        instant: _now,
      );
      expect(plan.set, isEmpty);
      expect(plan.applyTo(full).length, lessThanOrEqualTo(kMaxEpisodeDates));
    });

    test('restore (Desfazer): previous dates, none for those that had none', () {
      final plan = EpisodeDates.plan(
        changes: {'1_1': true, '1_2': true},
        current: _doc(),
        instant: _now,
        restore: {'1_1': _t0},
      );
      expect(plan.set, {'1_1': _t0});
    });
  });

  group('Firestore payload of setEpisodes', () {
    test('rules not confirmed: exactly the phase-1 payload (no epsAt at all)', () {
      final data = FirestoreFavoritesDataSource.episodesUpdate(
        {'1_1': true, '1_2': false},
        current: _doc(eps: {'1_2'}, at: {'1_2': _t0, '1_9': _t0}),
        restoreDates: null,
        datesEnabled: false,
        instant: _now,
      );
      expect(data.keys, unorderedEquals(['eps.1_1', 'eps.1_2', 'lastWatchedAt', 'updatedAt']));
    });

    test('rules confirmed: dates in the SAME update as the marks', () {
      final data = FirestoreFavoritesDataSource.episodesUpdate(
        {'1_1': true, '1_2': false},
        current: _doc(eps: {'1_2'}, at: {'1_2': _t0, '1_9': _t0}),
        restoreDates: null,
        datesEnabled: true,
        instant: _now,
      );
      expect(data['eps.1_1'], true);
      expect(data['eps.1_2'], isA<DeleteField>());
      expect(data['epsAt.1_1'], _now);
      expect(data['epsAt.1_2'], isA<DeleteField>());
      expect(data['epsAt.1_9'], isA<DeleteField>(), reason: 'orphan cleaned');
      expect(data['lastWatchedAt'], isA<ServerTimestamp>());
      final resolved = FirestoreFavoritesDataSource.resolve(data);
      expect(resolved['epsAt.1_1'], Timestamp.fromDate(_now));
      expect(resolved['epsAt.1_2'], isA<FieldValue>());
      expect(resolved['lastWatchedAt'], isA<FieldValue>());
    });

    test('FavoritePayloads never uses a server timestamp per episode', () {
      final data = FavoritePayloads.setEpisodes({
        for (var e = 1; e <= 600; e++) '1_$e': true,
      }, dates: EpisodeDatesPlan(set: {for (var e = 1; e <= 600; e++) '1_$e': _now}));
      expect(
        data.values.whereType<ServerTimestamp>().length,
        2,
        reason: 'lastWatchedAt + updatedAt',
      );
    });
  });

  group('repository + fake with dates (rules confirmed)', () {
    late FavoritesHarness h;
    var clock = _now;

    setUp(() async {
      h = FavoritesHarness();
      h.cloud
        ..datesEnabled = true
        ..clock = () => clock;
      clock = _now;
      await h.seedShow(
        seasons: [
          SeasonCache(
            seasonNumber: 1,
            episodes: [
              for (var e = 1; e <= 4; e++) h.episode(e, airDate: DateTime.utc(2026, 1, e)),
            ],
          ),
        ],
      );
    });

    FavoriteDoc doc() => h.cloud.view('user-a')['42-tv']!;

    test('toggle marks with the clock, unmark removes the date', () async {
      await h.repo.toggleEpisodeWatched(42, 1, 1);
      expect(doc().markedAt('1_1'), _now);
      clock = _now.add(const Duration(hours: 1));
      await h.repo.toggleEpisodeWatched(42, 1, 1);
      expect(doc().watchedAt, isEmpty);
    });

    test('re-marking replaces the date', () async {
      await h.repo.toggleEpisodeWatched(42, 1, 1);
      await h.repo.toggleEpisodeWatched(42, 1, 1);
      clock = _now.add(const Duration(days: 2));
      await h.repo.toggleEpisodeWatched(42, 1, 1);
      expect(doc().markedAt('1_1'), _now.add(const Duration(days: 2)));
    });

    test('a whole season is ONE instant', () async {
      await h.repo.setSeasonWatched(42, 1, watched: true);
      expect(doc().watchedAt.values.toSet(), {_now});
      expect(doc().watchedAt.length, 4);
    });

    test('unmark the whole series + Desfazer restores the OLD dates (not "now")', () async {
      await h.repo.toggleEpisodeWatched(42, 1, 1); // dated _now
      h.cloud.server['user-a']!['42-tv'] = doc().copyWith(
        watchedEpisodes: {'1_1', '1_2'},
      ); // 1_2 marked by the old app: no date
      final plan = await h.repo.planSeriesBulk(42, watched: false);
      clock = _now.add(const Duration(days: 30));
      final undo = await h.repo.applySeriesBulk(plan, uid: 'user-a');
      expect(doc().watchedEpisodes, isEmpty);
      expect(doc().watchedAt, isEmpty);
      expect(undo!.restoreDates, {'1_1': _now});
      expect(await h.repo.undoSeriesBulk(undo), UndoOutcome.restored);
      expect(doc().watchedEpisodes, {'1_1', '1_2'});
      expect(doc().watchedAt, {'1_1': _now}, reason: '1_2 goes back without a date');
    });

    test('mark the whole series + Desfazer removes the dates', () async {
      final plan = await h.repo.planSeriesBulk(42, watched: true);
      final undo = await h.repo.applySeriesBulk(plan, uid: 'user-a');
      expect(doc().watchedAt.length, 4);
      await h.repo.undoSeriesBulk(undo!);
      expect(doc().watchedEpisodes, isEmpty);
      expect(doc().watchedAt, isEmpty);
    });

    test('state unknown (cold cache offline): the mark goes without a date', () async {
      h.cloud.readsUnavailable = true;
      await h.repo.setEpisodeWatched(42, 1, 3, watched: true);
      h.cloud.readsUnavailable = false;
      expect(doc().watchedEpisodes, contains('1_3'));
      expect(doc().watchedAt, isEmpty);
    });

    test('rules not confirmed: marks work exactly as before, no date anywhere', () async {
      h.cloud.datesEnabled = false;
      await h.repo.toggleEpisodeWatched(42, 1, 1);
      await h.repo.setSeasonWatched(42, 1, watched: true);
      expect(doc().watchedEpisodes.length, 4);
      expect(doc().watchedAt, isEmpty);
      expect(h.cloud.episodeWrites.every((w) => w.dates.isEmpty), isTrue);
    });

    test('the date travels in the same write as the mark (one write per action)', () async {
      await h.repo.toggleEpisodeWatched(42, 1, 2);
      expect(h.cloud.episodeWrites, hasLength(1));
      expect(h.cloud.episodeWrites.single.changes, {'1_2': true});
      expect(h.cloud.episodeWrites.single.dates.set, {'1_2': _now});
    });
  });

  test('BulkWatchRules still ignores the clock injection (device clock)', () {
    final plan = BulkWatchRules.markAll('42-tv', [
      SeasonCache(
        seasonNumber: 1,
        episodes: [
          EpisodeCache(episodeNumber: 1, name: 'E1', airDate: DateTime.utc(2001), watched: false),
        ],
      ),
    ], const {});
    expect(plan.keys, {'1_1'});
  });
}
