import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/profile_stats.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/shared_profile/shared_profile_builder.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_profile_validator.dart';

/// docs/82 §5.2 (B2/B3): definitions of total / month / year.
const _sp = -180; // America/Sao_Paulo
final _now = DateTime.utc(2026, 10, 15, 15); // 15/10/2026 12:00 in São Paulo

FavoriteDoc _series(
  int id, {
  Map<String, DateTime> dated = const {},
  Set<String> undated = const {},
  Map<String, DateTime> orphans = const {},
  int summaryEpisodes = 0,
  bool rec = false,
  DateTime? lastWatchedAt,
}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.tv,
  title: 'S$id',
  posterPath: '/s$id.jpg',
  overview: '',
  addedAt: DateTime.utc(2025),
  lastWatchedAt: lastWatchedAt,
  seasonSummaries: summaryEpisodes == 0
      ? const []
      : [TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: summaryEpisodes)],
  watchedEpisodes: {...dated.keys, ...undated},
  watchedAt: {...dated, ...orphans},
  recommended: rec,
);

FavoriteDoc _movie(
  int id, {
  DateTime? at,
  bool watched = true,
  bool rec = false,
  DateTime? added,
}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.movie,
  title: 'M$id',
  posterPath: null,
  overview: '',
  addedAt: added ?? DateTime.utc(2025),
  watchedMovie: watched,
  lastWatchedAt: at,
  recommended: rec,
);

SharedStats _stats(
  List<FavoriteDoc> docs, {
  Map<int, List<SeasonCache>> catalog = const {},
  DateTime? now,
  int tz = _sp,
}) => SharedProfileBuilder.build(
  docs,
  catalog: (id) => catalog[id] ?? const [],
  movieRuntime: (id) => 100,
  tvFallbackRuntime: (id) => 40,
  sections: {SharedSection.stats},
  now: now ?? _now,
  tzMinutes: tz,
  memberSince: DateTime.utc(2025, 3, 2),
).stats!;

void main() {
  test('only the requested sections are calculated', () {
    final c = SharedProfileBuilder.build(
      [_movie(1, at: _now, rec: true)],
      catalog: (_) => const [],
      sections: {SharedSection.stats},
      now: _now,
      tzMinutes: _sp,
    );
    expect(c.stats, isNotNull);
    expect(c.activity, isNull, reason: 'activity never calculated without its consent');
    expect(c.recs, isNull, reason: '"Recomendações" never without its opt-in');
    expect(c.tz, _sp);
  });

  test('total equals the live Profile numbers (same documents, same catalog)', () {
    final catalog = {
      7: [
        SeasonCache(
          seasonNumber: 1,
          episodes: [
            for (var e = 1; e <= 3; e++)
              EpisodeCache(
                episodeNumber: e,
                name: 'E$e',
                airDate: DateTime.utc(2024),
                watched: false,
                runtime: 30,
              ),
          ],
        ),
      ],
    };
    final docs = [
      for (var i = 0; i < 20; i++)
        _movie(100 + i, at: i < 12 ? DateTime.utc(2026, 9, 1) : null, watched: i < 14),
      _series(7, dated: {'1_1': _now, '1_2': _now, '1_3': _now}),
      for (var i = 0; i < 33; i++) _series(200 + i, undated: {'1_1', '1_2'}, summaryEpisodes: 10),
    ];
    expect(docs, hasLength(54));
    final live = ProfileStats.fromDocs(
      docs,
      catalog: (id) => catalog[id] ?? const [],
      movieRuntime: (_) => 100,
      tvFallbackRuntime: (_) => 40,
    );
    final t = _stats(docs, catalog: catalog).total;
    expect(t.favorites, live.favorites);
    expect(t.movies, live.movies);
    expect(t.series, live.series);
    expect(t.watchedMovies, live.watchedMovies);
    expect(t.watchedEpisodes, live.watchedEpisodes);
    expect(t.completedSeries, live.completedSeries);
    expect(t.minutes, live.watchTime.minutes);
    expect(t.estimated, live.watchTime.estimated);
    expect(t.unknown, live.watchTime.unknown);
    expect(t.watchedSeries, 34);
  });

  group('periods (owner zone)', () {
    test('month / year by mark date; undated only in the total', () {
      final s = _stats([
        _series(
          1,
          dated: {
            '1_1': DateTime.utc(2026, 10, 2), // October
            '1_2': DateTime.utc(2026, 9, 30), // September (same year)
            '1_3': DateTime.utc(2025, 12, 31), // last year
          },
          undated: {'1_4'},
        ),
        _movie(2, at: DateTime.utc(2026, 10, 2)),
        _movie(3, at: DateTime.utc(2026, 3, 1)),
        _movie(4), // watched, no date
      ]);
      expect(s.month.key, '2026-10');
      expect(s.year.key, '2026');
      expect(s.total.watchedEpisodes, 4);
      expect(s.year.watchedEpisodes, 2);
      expect(s.month.watchedEpisodes, 1);
      expect(s.month.watchedMovies, 1);
      expect(s.year.watchedMovies, 2);
      expect(s.total.watchedMovies, 3);
      expect(s.month.watchedSeries, 1);
      expect(s.undatedEpisodes, 1);
      expect(s.undatedMovies, 1);
      expect(s.datedFrom, DateTime.utc(2025, 12, 31));
      expect(s.memberSince, DateTime.utc(2025, 3, 2));
    });

    test('the month boundary is the OWNER\'s: 31/10 23:59 local counts in October', () {
      final mark = DateTime.utc(2026, 11, 1, 2, 59); // 31/10 23:59 in São Paulo
      final nowOct = DateTime.utc(2026, 11, 1, 2, 59, 30);
      final s = _stats([
        _series(1, dated: {'1_1': mark}),
      ], now: nowOct);
      expect(s.month.key, '2026-10');
      expect(s.month.watchedEpisodes, 1);
      final utc = _stats(
        [
          _series(1, dated: {'1_1': mark}),
        ],
        now: nowOct,
        tz: 0,
      );
      expect(utc.month.key, '2026-11', reason: 'a UTC owner is already in November');
    });

    test('orphan dates never count; re-marking replaces the date', () {
      final s = _stats([
        _series(
          1,
          dated: {'1_1': DateTime.utc(2026, 10, 3)},
          orphans: {'1_9': DateTime.utc(2026, 10, 4)},
        ),
      ]);
      expect(s.month.watchedEpisodes, 1);
      expect(s.total.watchedEpisodes, 1);
      expect(s.datedFrom, DateTime.utc(2026, 10, 3));
    });

    test('completed in the period = conclusion (latest date) in it; no date = total only', () {
      final s = _stats([
        _series(
          1,
          dated: {'1_1': DateTime.utc(2026, 8, 1), '1_2': DateTime.utc(2026, 10, 5)},
          summaryEpisodes: 2,
        ),
        _series(
          2,
          dated: {'1_1': DateTime.utc(2026, 10, 5), '1_2': DateTime.utc(2026, 9, 5)},
          summaryEpisodes: 2,
        ),
        _series(3, undated: {'1_1', '1_2'}, summaryEpisodes: 2),
      ]);
      expect(s.total.completedSeries, 3);
      expect(s.year.completedSeries, 2);
      expect(s.month.completedSeries, 2);
    });

    test('completion uses the injected clock (episode airing tomorrow)', () {
      final catalog = {
        1: [
          SeasonCache(
            seasonNumber: 1,
            episodes: [
              EpisodeCache(
                episodeNumber: 1,
                name: 'E1',
                airDate: DateTime.utc(2026, 1, 1),
                watched: false,
              ),
              EpisodeCache(
                episodeNumber: 2,
                name: 'E2',
                airDate: DateTime.utc(2026, 10, 16),
                watched: false,
              ),
            ],
          ),
        ],
      };
      final docs = [
        _series(1, dated: {'1_1': DateTime.utc(2026, 10, 2)}),
      ];
      expect(_stats(docs, catalog: catalog).total.completedSeries, 1);
      expect(
        _stats(docs, catalog: catalog, now: DateTime.utc(2026, 10, 17)).total.completedSeries,
        0,
      );
    });

    test('minutes / estimated / unknown restricted to the period', () {
      final catalog = {
        1: [
          SeasonCache(
            seasonNumber: 1,
            episodes: [
              EpisodeCache(
                episodeNumber: 1,
                name: 'E1',
                airDate: DateTime.utc(2024),
                watched: false,
                runtime: 45,
              ),
            ],
          ),
        ],
      };
      final s = _stats([
        _series(1, dated: {'1_1': DateTime.utc(2026, 10, 2), '1_2': DateTime.utc(2026, 10, 2)}),
        _movie(2, at: DateTime.utc(2026, 10, 2)),
        _movie(3, at: DateTime.utc(2026, 1, 2)),
      ], catalog: catalog);
      expect(s.month.minutes, 45 + 40 + 100);
      expect(s.month.estimated, 1);
      expect(s.year.minutes, 45 + 40 + 200);
      expect(s.total.minutes, 45 + 40 + 200);
    });
  });

  group('recs', () {
    test('order of the tab, 50 items, total count', () {
      final docs = [
        for (var i = 0; i < 51; i++)
          _movie(1000 + i, rec: true, at: DateTime.utc(2026, 1, 1).add(Duration(hours: i))),
        _movie(5, rec: false),
      ];
      final r = SharedProfileBuilder.recs(docs);
      expect(r.count, 51);
      expect(r.items, hasLength(kMaxSharedRecs));
      expect(r.items.first.id, 1050, reason: 'most recent activity first');
      expect(r.items.map((i) => i.id), isNot(contains(5)));
    });
  });

  test('the builder output always passes the validator', () {
    final c = SharedProfileBuilder.build(
      [
        _series(1, dated: {'1_1': _now.add(const Duration(days: 9))}),
        FavoriteDoc(
          id: 2,
          mediaType: MediaType.movie,
          title: 'x' * 400,
          posterPath: 'http://evil/p.jpg',
          overview: '',
          addedAt: _now,
          watchedMovie: true,
          lastWatchedAt: _now,
          recommended: true,
        ),
      ],
      catalog: (_) => const [],
      sections: SharedSection.values.toSet(),
      now: _now,
      tzMinutes: _sp,
      actSince: DateTime.utc(2026, 10, 1),
    );
    expect(
      SharedProfileValidator.violations(c, now: _now, actSince: DateTime.utc(2026, 10, 1)),
      isEmpty,
    );
    expect(c.recs!.items.single.title.length, kMaxSharedTitle);
    expect(c.recs!.items.single.poster, isNull);
  });
}
