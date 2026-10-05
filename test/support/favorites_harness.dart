import 'dart:async';

import 'package:cinetrack/models/cast_member.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/person.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/title_video.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/services/favorite_mapper.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';

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

  final Set<String> socialCleanup = {};

  @override
  bool socialCleanupPending(String uid) => socialCleanup.contains(uid);

  @override
  Future<void> setSocialCleanupPending(String uid, bool pending) async =>
      pending ? socialCleanup.add(uid) : socialCleanup.remove(uid);

  final Map<String, ({bool active, DateTime at})> socialHints = {};

  @override
  ({bool active, DateTime at})? socialHint(String uid) => socialHints[uid];

  @override
  Future<void> setSocialHint(String uid, bool? active, {DateTime? at}) async => active == null
      ? socialHints.remove(uid)
      : socialHints[uid] = (active: active, at: at ?? DateTime.now());

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

  final Map<int, DateTime> fetchedAt = {};

  @override
  DateTime? readCatalogFetchedAt(int tvId) => fetchedAt[tvId];

  @override
  Future<void> saveCatalogFetchedAt(int tvId, DateTime at) async => fetchedAt[tvId] = at;

  final Map<int, int> movieRuntimes = {};
  final Map<int, int> tvRuntimes = {};

  @override
  int? readMovieRuntime(int id) => movieRuntimes[id];

  @override
  Future<void> saveMovieRuntime(int id, int minutes) async {
    movieRuntimes[id] = minutes;
    _controller.add(null);
  }

  @override
  int? readTvFallbackRuntime(int id) => tvRuntimes[id];

  @override
  Future<void> saveTvFallbackRuntime(int id, int minutes) async {
    tvRuntimes[id] = minutes;
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

  int movieDetailsCalls = 0;

  /// When true every `/movie/{id}` call waits for its own gate in [movieGates].
  bool holdMovieDetails = false;
  final List<Completer<void>> movieGates = [];
  Map<String, dynamic> movieDetails = {};
  Object? movieDetailsError;

  @override
  Future<Map<String, dynamic>> getMovieDetails(int id) async {
    movieDetailsCalls++;
    if (holdMovieDetails) {
      final gate = Completer<void>();
      movieGates.add(gate);
      await gate.future;
    }
    final error = movieDetailsError;
    if (error != null) throw error;
    return movieDetails;
  }

  /// Per-season answers (take precedence over [seasonResult]).
  final Map<int, SeasonCache> seasonsByNumber = {};

  /// Errors thrown (one per call, in order) before answers start.
  final List<Object> seasonErrorQueue = [];

  /// When set, season calls wait for it (simulates a slow TMDB).
  Completer<void>? seasonGate;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<SeasonCache> getSeasonEpisodes(int tvId, int seasonNumber) async {
    seasonCalls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await seasonGate?.future;
      if (seasonErrorQueue.isNotEmpty) throw seasonErrorQueue.removeAt(0);
      final error = seasonError;
      if (error != null) throw error;
      final result = seasonsByNumber[seasonNumber] ?? seasonResult;
      if (result == null) throw StateError('no seasonResult configured');
      return result;
    } finally {
      inFlight--;
    }
  }

  // --- videos / trailer (docs/45) ---
  List<TitleVideo> videos = const [];
  Object? videosError;
  Completer<void>? videosGate;
  int videosCalls = 0;

  @override
  Future<List<TitleVideo>> getTitleVideos(MediaType type, int id) async {
    videosCalls++;
    await videosGate?.future;
    final error = videosError;
    if (error != null) throw error;
    return videos;
  }

  // --- cast and people (docs/19) ---
  List<CastMember> cast = const [];
  Object? castError;
  Completer<void>? castGate;
  int castCalls = 0;

  @override
  Future<List<CastMember>> getTitleCast(MediaType type, int id) async {
    castCalls++;
    await castGate?.future;
    final error = castError;
    if (error != null) throw error;
    return cast;
  }

  /// `/person/{id}` answers by id and language ('pt-BR' default, 'en-US').
  final Map<int, Map<String, dynamic>> people = {};
  final Map<int, Map<String, dynamic>> peopleEn = {};
  Object? personError;
  Object? personEnError;
  Completer<void>? personGate;
  int personCalls = 0;
  final List<String?> personLanguages = [];

  @override
  Future<Map<String, dynamic>> getPerson(int id, {String? language}) async {
    personCalls++;
    personLanguages.add(language);
    await personGate?.future;
    final error = language == 'en-US' ? personEnError ?? personError : personError;
    if (error != null) throw error;
    final json = (language == 'en-US' ? peopleEn[id] : people[id]);
    if (json == null) throw TmdbException.notFound();
    return json;
  }

  List<PersonCredit> credits = const [];
  Object? creditsError;
  int creditsCalls = 0;

  @override
  Future<List<PersonCredit>> getPersonCredits(int id) async {
    creditsCalls++;
    final error = creditsError;
    if (error != null) throw error;
    return credits;
  }

  /// Runs when a `/tv/{id}` request starts (to flip flags mid-run).
  void Function()? onTvDetails;

  @override
  Future<Map<String, dynamic>> getTvDetails(int id) async {
    tvDetailsCalls++;
    onTvDetails?.call();
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

  /// An episode as the current app caches it (image/description fields
  /// present). Pass `detailed: false` for a catalog cached by an older version.
  EpisodeCache episode(int number,
          {bool watched = false, DateTime? airDate, bool detailed = true}) =>
      EpisodeCache(
        episodeNumber: number,
        name: 'Episode $number',
        airDate: airDate,
        watched: watched,
        detailed: detailed,
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
