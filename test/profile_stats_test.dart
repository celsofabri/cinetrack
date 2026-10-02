import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/nickname.dart';
import 'package:cinetrack/models/profile_stats.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';

FavoriteDoc _movie(int id, {bool watched = false}) => FavoriteDoc(
      id: id,
      mediaType: MediaType.movie,
      title: 'Filme $id',
      posterPath: null,
      overview: '',
      addedAt: DateTime(2026),
      watchedMovie: watched,
    );

FavoriteDoc _show(int id, {Set<String> watched = const {}, List<int> seasons = const []}) =>
    FavoriteDoc(
      id: id,
      mediaType: MediaType.tv,
      title: 'Serie $id',
      posterPath: null,
      overview: '',
      addedAt: DateTime(2026),
      watchedEpisodes: watched,
      seasonSummaries: [
        for (var i = 0; i < seasons.length; i++)
          TvSeasonSummary(seasonNumber: i + 1, name: 'T${i + 1}', episodeCount: seasons[i]),
      ],
    );

List<SeasonCache> _noCatalog(int _) => const [];

void main() {
  group('ProfileStats (spec scenario)', () {
    test('3 favorite movies (1 watched) + 2 shows with 5 watched episodes', () {
      final stats = ProfileStats.fromDocs([
        _movie(1, watched: true),
        _movie(2),
        _movie(3),
        _show(10, watched: {'1_1', '1_2', '1_3'}, seasons: [10]),
        _show(11, watched: {'1_1', '1_2'}, seasons: [10]),
      ], catalog: _noCatalog);

      expect(stats.favorites, 5);
      expect(stats.movies, 3);
      expect(stats.series, 2);
      expect(stats.watchedMovies, 1);
      expect(stats.watchedEpisodes, 5);
      expect(stats.completedSeries, 0);
    });

    test('empty account is all zeros', () {
      final stats = ProfileStats.fromDocs(const [], catalog: _noCatalog);
      expect(stats.favorites + stats.watchedEpisodes + stats.completedSeries, 0);
    });

    test('completed series on a new device uses the stored season summaries', () {
      final done = _show(1, watched: {'1_1', '1_2', '2_1'}, seasons: [2, 1]);
      final notDone = _show(2, watched: {'1_1', '1_2'}, seasons: [2, 1]);
      final noSummaries = _show(3, watched: {'1_1'});

      final stats = ProfileStats.fromDocs([done, notDone, noSummaries], catalog: _noCatalog);

      expect(stats.completedSeries, 1);
    });

    test('with a catalog covering every season it matches the progress calculator', () {
      EpisodeCache ep(int n) =>
          EpisodeCache(episodeNumber: n, name: 'e$n', airDate: null, watched: false);
      // Summary says 2 episodes, but TMDB's cached catalog already has 3.
      final doc = _show(1, watched: {'1_1', '1_2'}, seasons: [2]);
      final catalog = {
        1: [
          SeasonCache(seasonNumber: 1, episodes: [ep(1), ep(2), ep(3)])
        ],
      };

      final stats = ProfileStats.fromDocs([doc], catalog: (id) => catalog[id] ?? const []);

      expect(stats.completedSeries, 0); // 2 of 3 watched: not completed
    });

    test('a partial catalog (some seasons missing) falls back to the summaries', () {
      EpisodeCache ep(int n) =>
          EpisodeCache(episodeNumber: n, name: 'e$n', airDate: null, watched: false);
      final doc = _show(1, watched: {'1_1', '2_1'}, seasons: [1, 1]);
      final partial = {
        1: [
          SeasonCache(seasonNumber: 1, episodes: [ep(1)])
        ],
      };

      final stats = ProfileStats.fromDocs([doc], catalog: (id) => partial[id] ?? const []);

      expect(stats.completedSeries, 1); // 2 of 2 by summaries, not 1 of 1 by catalog
    });
  });

  group('Nickname', () {
    test('trims and accepts 1 to 40 characters', () {
      expect(Nickname.normalize('  Ana  '), 'Ana');
      expect(Nickname.normalize('a'), 'a');
      expect(Nickname.normalize('x' * 40), 'x' * 40);
    });

    test('rejects empty, whitespace-only and over 40 characters', () {
      expect(Nickname.normalize(''), isNull);
      expect(Nickname.normalize('   \n\t'), isNull);
      expect(Nickname.normalize('x' * 41), isNull);
      expect(Nickname.errorFor('   '), contains('não pode ficar vazio'));
      expect(Nickname.errorFor('x' * 41), contains('40'));
      expect(Nickname.errorFor('Ana'), isNull);
    });

    test('length is measured after trimming (matches the rules: trim().size() >= 1)', () {
      expect(Nickname.normalize('${' ' * 10}${'x' * 40}'), 'x' * 40);
    });
  });
}
