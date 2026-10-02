import 'dart:async';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/services/favorite_mapper.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';

import 'in_memory_favorites_data_source.dart';

/// In-memory fake of the season catalog cache (the only part of
/// LocalStore the repository uses).
class FakeLocalStore extends LocalStore {
  bool purgePending = false;

  @override
  bool get firestoreCachePurgePending => purgePending;

  @override
  Future<void> markFirestoreCachePurge() async => purgePending = true;

  @override
  Future<void> clearFirestoreCachePurgeFlag() async => purgePending = false;

  final Map<int, List<SeasonCache>> _catalog = {};
  final _controller = StreamController<void>.broadcast();

  @override
  List<SeasonCache> readSeasonCatalog(int tvId) => _catalog[tvId] ?? const [];

  @override
  Future<void> saveCatalogSeason(int tvId, SeasonCache season) async {
    _catalog[tvId] = [
      for (final s in readSeasonCatalog(tvId))
        if (s.seasonNumber != season.seasonNumber) s,
      FavoriteMapper.stripWatched(season),
    ];
    _controller.add(null);
  }

  @override
  Stream<void> watchSeasonCatalog() => _controller.stream;
}

class FakeTmdbApiClient extends TmdbApiClient {
  FakeTmdbApiClient() : super(apiKey: 'test');

  int seasonCalls = 0;
  int tvDetailsCalls = 0;
  SeasonCache? seasonResult;
  Object? seasonError;
  Map<String, dynamic> tvDetails = {'seasons': <dynamic>[]};
  Object? tvDetailsError;

  @override
  Future<SeasonCache> getSeasonEpisodes(int tvId, int seasonNumber) async {
    seasonCalls++;
    final error = seasonError;
    if (error != null) throw error;
    final result = seasonResult;
    if (result == null) throw StateError('no seasonResult configured');
    return result;
  }

  @override
  Future<Map<String, dynamic>> getTvDetails(int id) async {
    tvDetailsCalls++;
    final error = tvDetailsError;
    if (error != null) throw error;
    return tvDetails;
  }
}

/// Builds a [FavoritesRepository] over in-memory fakes. The only place the
/// contract tests know how storage is wired.
class FavoritesHarness {
  final cloud = FakeCloud();
  final store = FakeLocalStore();
  final api = FakeTmdbApiClient();
  late final dataSource = InMemoryFavoritesDataSource(cloud, uid: 'user-a');
  late final FavoritesRepository repo =
      FavoritesRepository(api: api, store: store, dataSource: dataSource);

  Future<List<FavoriteItem>> items() => repo.watchAll().first;

  EpisodeCache episode(int number, {bool watched = false, DateTime? airDate}) => EpisodeCache(
        episodeNumber: number,
        name: 'Episode $number',
        airDate: airDate,
        watched: watched,
      );

  /// Puts a TV favorite (id 42) straight into storage: the document in the
  /// user's cloud space (with the watched flags found in [seasons]) and the
  /// seasons themselves in the local catalog.
  Future<void> seedShow({List<SeasonCache>? seasons}) async {
    final list = seasons ?? const <SeasonCache>[];
    cloud.server.putIfAbsent('user-a', () => {})['42-tv'] = FavoriteDoc(
      id: 42,
      mediaType: MediaType.tv,
      title: 'A Show',
      posterPath: null,
      overview: '',
      addedAt: DateTime.now(),
      watchedEpisodes: {
        for (final season in list)
          for (final ep in season.episodes)
            if (ep.watched) FavoriteMapper.episodeKey(season.seasonNumber, ep.episodeNumber),
      },
    );
    for (final season in list) {
      await store.saveCatalogSeason(42, season);
    }
  }
}
