import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/services/watch_time.dart';

String f(int minutes) => WatchTimeFormatter.format(minutes);
const h = 60;
const d = 24 * 60;

void main() {
  group('WatchTimeFormatter (1 dia = 24 h, 1 mês = 30 dias, 1 ano = 365 dias)', () {
    test('under one hour: minutes', () {
      expect(f(0), '0 min');
      expect(f(1), '1 min');
      expect(f(59), '59 min');
    });

    test('under 24 h: hours and minutes, zero units omitted', () {
      expect(f(1 * h), '1 hora');
      expect(f(1 * h + 5), '1 hora e 5 min');
      expect(f(2 * h), '2 horas');
      expect(f(23 * h + 59), '23 horas e 59 min');
    });

    test('24 h up to 48 h and beyond: days and hours, minutes dropped', () {
      expect(f(24 * h), '1 dia');
      expect(f(24 * h + 30), '1 dia');
      expect(f(25 * h), '1 dia e 1 hora');
      expect(f(47 * h), '1 dia e 23 horas');
      expect(f(48 * h), '2 dias');
      expect(f(2 * d + 5 * h), '2 dias e 5 horas');
    });

    test('months: x meses, y dias e z horas', () {
      expect(f(29 * d + 23 * h), '29 dias e 23 horas');
      expect(f(30 * d), '1 mês');
      expect(f(30 * d + 1 * h), '1 mês e 1 hora');
      expect(f(65 * d + 3 * h), '2 meses, 5 dias e 3 horas');
      expect(f(364 * d), '12 meses e 4 dias');
    });

    test('years: x anos, y meses, dias, horas', () {
      expect(f(365 * d), '1 ano');
      expect(f(365 * d + 30 * d), '1 ano e 1 mês');
      expect(f(2 * 365 * d + 3 * 30 * d + 4 * d + 5 * h), '2 anos, 3 meses, 4 dias e 5 horas');
      expect(f(100 * 365 * d), '100 anos');
    });

    test('negative is clamped to zero', () => expect(f(-5), '0 min'));

    test('accumulated hours with pt-BR thousands separator', () {
      expect(WatchTimeFormatter.accumulatedHours(0), '0 h no total');
      expect(WatchTimeFormatter.accumulatedHours(59), '0 h no total');
      expect(WatchTimeFormatter.accumulatedHours(999 * h), '999 h no total');
      expect(WatchTimeFormatter.accumulatedHours(1234 * h + 30), '1.234 h no total');
      expect(WatchTimeFormatter.accumulatedHours(1234567 * h), '1.234.567 h no total');
    });
  });

  group('WatchTimeCalculator', () {
    FavoriteDoc movie(int id, {bool watched = true}) => FavoriteDoc(
        id: id,
        mediaType: MediaType.movie,
        title: 'M$id',
        posterPath: null,
        overview: '',
        addedAt: DateTime(2024),
        watchedMovie: watched);
    FavoriteDoc show(Set<String> eps) => FavoriteDoc(
        id: 7,
        mediaType: MediaType.tv,
        title: 'S',
        posterPath: null,
        overview: '',
        addedAt: DateTime(2024),
        watchedEpisodes: eps);
    const season = SeasonCache(seasonNumber: 1, episodes: [
      EpisodeCache(episodeNumber: 1, name: '', airDate: null, watched: false, runtime: 40),
      EpisodeCache(episodeNumber: 2, name: '', airDate: null, watched: false, runtime: 50),
      EpisodeCache(episodeNumber: 3, name: '', airDate: null, watched: false),
    ]);

    WatchTime run(List<FavoriteDoc> docs, {int? fallback, Map<int, int> movies = const {}}) =>
        WatchTimeCalculator.compute(
          docs,
          catalog: (id) => id == 7 ? const [season] : const [],
          movieRuntime: (id) => movies[id],
          tvFallbackRuntime: (_) => fallback,
        );

    test('movies and episodes with their own runtime are exact', () {
      final t = run([
        movie(1),
        movie(2, watched: false),
        show({'1_1', '1_2'})
      ], movies: {
        1: 100
      });
      expect(t.minutes, 190);
      expect(t.isExact, isTrue);
    });

    test('episode without runtime uses the show typical runtime and is flagged estimated', () {
      final t = run([
        show({'1_1', '1_3', '2_1'})
      ], fallback: 45);
      expect(t.minutes, 40 + 45 + 45);
      expect(t.estimated, 2);
      expect(t.isExact, isFalse);
    });

    test('no runtime anywhere: not added (never a made-up total), counted as unknown', () {
      final t = run([
        movie(1),
        show({'1_3'})
      ]);
      expect(t.minutes, 0);
      expect(t.unknown, 2);
    });
  });
}
