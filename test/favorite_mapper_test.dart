import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/services/favorite_mapper.dart';

import 'support/in_memory_favorites_data_source.dart';

FavoriteDoc _show({Set<String> eps = const {}}) => FavoriteDoc(
      id: 42,
      mediaType: MediaType.tv,
      title: 'A Show',
      posterPath: '/p.jpg',
      overview: 'o',
      addedAt: DateTime.utc(2026, 1, 2),
      lastWatchedAt: DateTime.utc(2026, 2, 3),
      seasonSummaries: const [TvSeasonSummary(seasonNumber: 1, name: 'S1', episodeCount: 3)],
      watchedEpisodes: eps,
    );

void main() {
  group('FavoriteMapper map conversion', () {
    test('round-trips a document, including the eps map', () {
      final doc = _show(eps: {'1_1', '2_5'});

      final map = FavoriteMapper.toMap(doc);
      expect(map['eps'], {'1_1': true, '2_5': true});

      final back = FavoriteMapper.fromMap('42-tv', map)!;
      expect(back.id, 42);
      expect(back.mediaType, MediaType.tv);
      expect(back.title, 'A Show');
      expect(back.addedAt, doc.addedAt);
      expect(back.lastWatchedAt, doc.lastWatchedAt);
      expect(back.watchedEpisodes, {'1_1', '2_5'});
      expect(back.seasonSummaries.single.episodeCount, 3);
    });

    test('applies the same defaults as FavoriteItem.fromJson for missing fields', () {
      final doc = FavoriteMapper.fromMap('7-movie', {'id': 7, 'mediaType': 'movie'})!;

      expect(doc.title, '');
      expect(doc.overview, '');
      expect(doc.posterPath, isNull);
      expect(doc.watchedMovie, isFalse);
      expect(doc.lastWatchedAt, isNull);
      expect(doc.watchedEpisodes, isEmpty);
    });

    test('ignores unusable documents instead of throwing', () {
      expect(FavoriteMapper.fromMap('1-movie', {'mediaType': 'movie'}), isNull);
      expect(FavoriteMapper.fromMap('1-movie', {'id': 1, 'mediaType': 'person'}), isNull);
      // Key that does not match id + media type.
      expect(FavoriteMapper.fromMap('2-movie', {'id': 1, 'mediaType': 'movie'}), isNull);
    });

    test('drops malformed or false entries from eps', () {
      final doc = FavoriteMapper.fromMap('1-tv', {
        'id': 1,
        'mediaType': 'tv',
        'eps': {'1_2': true, 'x': true, '1_3': false, '1_2_3': true},
      })!;

      expect(doc.watchedEpisodes, {'1_2'});
    });

    test('episode keys round-trip', () {
      expect(FavoriteMapper.episodeKey(3, 12), '3_12');
      expect(FavoriteMapper.parseEpisodeKey('3_12'), (3, 12));
      expect(FavoriteMapper.parseEpisodeKey('3-12'), isNull);
    });
  });

  group('FavoriteMapper.hydrate', () {
    const catalog = [
      SeasonCache(seasonNumber: 1, episodes: [
        EpisodeCache(episodeNumber: 1, name: 'a', airDate: null, watched: false),
        EpisodeCache(episodeNumber: 2, name: 'b', airDate: null, watched: false),
      ]),
    ];

    test('overlays watched flags from the document onto the catalog', () {
      final item = FavoriteMapper.hydrate(_show(eps: {'1_2'}), catalog);

      final episodes = item.seasons!.single.episodes;
      expect(episodes.firstWhere((e) => e.episodeNumber == 1).watched, isFalse);
      expect(episodes.firstWhere((e) => e.episodeNumber == 2).watched, isTrue);
      expect(item.storageKey, '42-tv');
    });

    test('a show without cached catalog has empty seasons; a movie has null', () {
      expect(FavoriteMapper.hydrate(_show(), const []).seasons, isEmpty);

      final movie = FavoriteDoc(
        id: 1,
        mediaType: MediaType.movie,
        title: 'M',
        posterPath: null,
        overview: '',
        addedAt: DateTime.utc(2026),
      );
      expect(FavoriteMapper.hydrate(movie, const []).seasons, isNull);
    });

    test('stripWatched keeps the catalog free of progress', () {
      const watched = SeasonCache(seasonNumber: 1, episodes: [
        EpisodeCache(episodeNumber: 1, name: 'a', airDate: null, watched: true),
      ]);

      expect(FavoriteMapper.stripWatched(watched).episodes.single.watched, isFalse);
    });
  });

  group('per-field merge of episode progress', () {
    test('changes to different episodes both survive', () {
      final onA = FavoriteMapper.applyEpisodeChanges({'1_1'}, {'1_2': true});
      final onB = FavoriteMapper.applyEpisodeChanges(onA, {'1_3': true});

      expect(onB, {'1_1', '1_2', '1_3'});
    });

    test('unmarking one episode does not touch the others', () {
      expect(FavoriteMapper.applyEpisodeChanges({'1_1', '1_2'}, {'1_1': false}), {'1_2'});
    });

    test('same episode: the last write to reach the server wins', () {
      var eps = <String>{};
      eps = FavoriteMapper.applyEpisodeChanges(eps, {'1_1': true}); // device A
      eps = FavoriteMapper.applyEpisodeChanges(eps, {'1_1': false}); // device B, later

      expect(eps, isEmpty);
    });

    test('two devices marking different episodes of one show', () async {
      // Spec scenario: device A marks S1E2, B marks S1E3 -> both remain.
      final cloud = FakeCloud();
      final deviceA = InMemoryFavoritesDataSource(cloud, uid: 'u');
      final deviceB = InMemoryFavoritesDataSource(cloud, uid: 'u');
      await deviceA.add(_show());

      await deviceA.setEpisodes('42-tv', {'1_2': true});
      await deviceB.setEpisodes('42-tv', {'1_3': true});

      expect((await deviceA.get('42-tv'))!.watchedEpisodes, {'1_2', '1_3'});
    });
  });
}
