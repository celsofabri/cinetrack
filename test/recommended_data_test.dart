import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/favorites_data_source.dart';
import 'package:cinetrack/data/firestore_favorites_data_source.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/profile_stats.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/services/bulk_watch.dart';
import 'package:cinetrack/services/favorite_mapper.dart';

import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// "Minhas recomendações" (docs/35 R, docs/36 R): the `recommended` field and
/// the proofs that no existing data is ever lost or rewritten.

final _added = DateTime(2026, 1, 1);
final _watchedAt = DateTime(2026, 3, 3, 12);

/// Logs every call so a test can prove WHICH writes happened.
class _Recording extends InMemoryFavoritesDataSource {
  _Recording(super.cloud, {required super.uid});

  final calls = <String>[];

  @override
  Future<void> add(FavoriteDoc doc) {
    calls.add('add:${doc.key}:${doc.recommended}');
    return super.add(doc);
  }

  @override
  Future<void> remove(String key) {
    calls.add('remove:$key');
    return super.remove(key);
  }

  @override
  Future<void> setRecommended(String key, bool recommended) {
    calls.add('setRecommended:$key:$recommended');
    return super.setRecommended(key, recommended);
  }

  @override
  Future<void> setEpisodes(String key, Map<String, bool> changes) {
    calls.add('setEpisodes:$key');
    return super.setEpisodes(key, changes);
  }

  @override
  Future<void> setWatchedMovie(String key, bool watched) {
    calls.add('setWatchedMovie:$key');
    return super.setWatchedMovie(key, watched);
  }
}

FavoriteDoc _series({bool recommended = false}) => FavoriteDoc(
  id: 42,
  mediaType: MediaType.tv,
  title: 'A Show',
  posterPath: '/p.jpg',
  overview: 'o',
  addedAt: _added,
  lastWatchedAt: _watchedAt,
  seasonSummaries: const [TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 3)],
  watchedEpisodes: const {'1_1', '1_2'},
  recommended: recommended,
);

FavoriteDoc _movie({bool recommended = false}) => FavoriteDoc(
  id: 7,
  mediaType: MediaType.movie,
  title: 'A Movie',
  posterPath: null,
  overview: '',
  addedAt: _added,
  lastWatchedAt: _watchedAt,
  watchedMovie: true,
  recommended: recommended,
);

const _newMovie = SearchResult(
  id: 99,
  mediaType: MediaType.movie,
  title: 'Novo',
  posterPath: null,
  overview: '',
);
const _newShow = SearchResult(
  id: 98,
  mediaType: MediaType.tv,
  title: 'Nova serie',
  posterPath: null,
  overview: '',
);

/// Everything a user could lose, as comparable values.
Map<String, Object?> _snapshot(FavoriteDoc d) => {
  'id': d.id,
  'type': d.mediaType,
  'title': d.title,
  'poster': d.posterPath,
  'overview': d.overview,
  'addedAt': d.addedAt,
  'lastWatchedAt': d.lastWatchedAt,
  'watchedMovie': d.watchedMovie,
  'eps': {...d.watchedEpisodes},
  'seasons': d.seasonSummaries.map((s) => s.toJson().toString()).toList(),
};

void main() {
  group('Firestore payload of setRecommended', () {
    test('mark: exactly recommended:true and updatedAt (field-level update)', () {
      final u = FirestoreFavoritesDataSource.recommendedUpdate(true);
      expect(u.keys.toSet(), {'recommended', 'updatedAt'});
      expect(u['recommended'], isTrue);
      expect(u['updatedAt'], isA<FieldValue>());
    });

    test('unmark: the field is DELETED (never written as false)', () {
      final u = FirestoreFavoritesDataSource.recommendedUpdate(false);
      expect(u.keys.toSet(), {'recommended', 'updatedAt'});
      expect(u['recommended'], isA<FieldValue>());
      expect(u['recommended'], isNot(false));
      expect(u['recommended'], isNot(FieldValue.serverTimestamp()));
    });
  });

  group('model and mapper', () {
    test('toMap writes recommended ONLY when true (a plain add is unchanged)', () {
      final plain = FavoriteMapper.toMap(_series());
      expect(plain.containsKey('recommended'), isFalse);
      expect(FavoriteMapper.toMap(_series(recommended: true))['recommended'], isTrue);
      // The plain shape has exactly the keys the previous app wrote.
      expect(plain.keys.toSet(), {
        'id',
        'mediaType',
        'title',
        'posterPath',
        'overview',
        'addedAt',
        'lastWatchedAt',
        'watchedMovie',
        'seasonSummaries',
        'eps',
      });
    });

    test('fromMap: absent, false and non-bool values all read as not recommended', () {
      Map<String, dynamic> base() => FavoriteMapper.toMap(_movie());
      expect(FavoriteMapper.fromMap('7-movie', base())!.recommended, isFalse);
      expect(
        FavoriteMapper.fromMap('7-movie', {...base(), 'recommended': false})!.recommended,
        isFalse,
      );
      for (final junk in ['sim', 1, null, <String, dynamic>{}]) {
        expect(
          FavoriteMapper.fromMap('7-movie', {...base(), 'recommended': junk})!.recommended,
          isFalse,
          reason: '$junk',
        );
      }
      expect(
        FavoriteMapper.fromMap('7-movie', {...base(), 'recommended': true})!.recommended,
        isTrue,
      );
    });

    test('a document that carries recommended parses the same as before for every other field', () {
      // What an app WITHOUT the field sees: it ignores the unknown key, and
      // everything else is identical.
      final withField = FavoriteMapper.fromMap(
        '42-tv',
        FavoriteMapper.toMap(_series(recommended: true)),
      )!;
      final without = FavoriteMapper.fromMap('42-tv', FavoriteMapper.toMap(_series()))!;
      expect(_snapshot(withField), _snapshot(without));
      expect(withField.recommended, isTrue);
      expect(without.recommended, isFalse);
    });

    test('hydrate carries recommended; FavoriteItem JSON is tolerant to absence', () {
      expect(FavoriteMapper.hydrate(_movie(recommended: true), const []).recommended, isTrue);
      expect(FavoriteMapper.hydrate(_movie(), const []).recommended, isFalse);
      final item = FavoriteMapper.hydrate(_movie(recommended: true), const []);
      expect(FavoriteItem.fromJson(item.toJson()).recommended, isTrue);
      expect(item.copyWith(recommended: false).recommended, isFalse);
      final legacy = {...FavoriteMapper.hydrate(_movie(), const []).toJson()}
        ..remove('recommended');
      expect(FavoriteItem.fromJson(legacy).recommended, isFalse);
    });

    test('recommending never changes the ordering (lastActivityAt ignores it)', () {
      final a = FavoriteMapper.hydrate(_movie(), const []);
      final b = a.copyWith(recommended: true);
      expect(b.lastActivityAt, a.lastActivityAt);
      expect(FavoriteItem.byRecentActivity(a, b), 0);
    });

    test('ProfileStats counts recommended titles from the documents', () {
      final stats = ProfileStats.fromDocs([
        _movie(recommended: true),
        _series(recommended: true),
        _series().copyWith(),
      ], catalog: (_) => const []);
      expect(stats.recommendedCount, 2);
      expect(stats.favorites, 3);
      expect(ProfileStats.fromDocs([_movie()], catalog: (_) => const []).recommendedCount, 0);
    });
  });

  group('repository writes', () {
    late FavoritesHarness h;
    late _Recording data;
    late FavoritesRepository repo;

    FavoriteDoc? stored(String key) => h.cloud.view('user-a')[key];

    setUp(() {
      h = FavoritesHarness();
      data = _Recording(h.cloud, uid: 'user-a');
      repo = FavoritesRepository(api: h.api, store: h.store, dataSource: data);
      h.cloud.server['user-a'] = {'42-tv': _series(), '7-movie': _movie()};
    });

    test('mark then unmark: every other field stays identical, only field-level writes', () async {
      final before = {for (final e in h.cloud.view('user-a').entries) e.key: _snapshot(e.value)};

      await repo.setRecommended(42, MediaType.tv, true);
      await repo.setRecommended(7, MediaType.movie, true);
      expect(stored('42-tv')!.recommended, isTrue);
      expect(stored('7-movie')!.recommended, isTrue);
      await repo.setRecommended(42, MediaType.tv, false);
      await repo.setRecommended(7, MediaType.movie, false);

      expect(stored('42-tv')!.recommended, isFalse);
      expect({for (final e in h.cloud.view('user-a').entries) e.key: _snapshot(e.value)}, before);
      expect(data.calls.every((c) => c.startsWith('setRecommended:')), isTrue);
      expect(data.calls, hasLength(4));
    });

    test('marking is idempotent', () async {
      await repo.setRecommended(42, MediaType.tv, true);
      await repo.setRecommended(42, MediaType.tv, true);
      expect(stored('42-tv')!.recommended, isTrue);
      expect(stored('42-tv')!.watchedEpisodes, {'1_1', '1_2'});
    });

    test('title gone: FavoriteGoneException and NOTHING is recreated', () async {
      h.cloud.server['user-a']!.remove('7-movie');
      await expectLater(
        repo.setRecommended(7, MediaType.movie, true),
        throwsA(isA<FavoriteGoneException>()),
      );
      expect(stored('7-movie'), isNull);
      expect(data.calls, isEmpty);
    });

    test('unreadable state propagates (never a silent no-op)', () async {
      h.cloud.readsUnavailable = true;
      await expectLater(
        repo.setRecommended(7, MediaType.movie, true),
        throwsA(isA<FavoritesUnavailableException>()),
      );
    });

    test('outside Favoritos: ONE add carrying recommended:true (movie)', () async {
      await repo.addAndRecommend(_newMovie);
      expect(data.calls, ['add:99-movie:true']);
      expect(stored('99-movie')!.recommended, isTrue);
    });

    test(
      'outside Favoritos: series adds once with recommended, then summaries best-effort',
      () async {
        h.api.tvDetails = {
          'seasons': [
            {'season_number': 1, 'name': 'T1', 'episode_count': 2},
          ],
        };
        await repo.addAndRecommend(_newShow);
        expect(data.calls.where((c) => c.startsWith('add:')), ['add:98-tv:true']);
        expect(data.calls.where((c) => c.startsWith('setRecommended')), isEmpty);
        expect(stored('98-tv')!.recommended, isTrue);
      },
    );

    test('failure of the add leaves it in NEITHER list', () async {
      final failing = _FailingAdd(h.cloud, uid: 'user-a');
      final r = FavoritesRepository(api: h.api, store: h.store, dataSource: failing);
      await expectLater(r.addAndRecommend(_newMovie), throwsA(isA<StateError>()));
      expect(stored('99-movie'), isNull);
    });

    test('already in Favoritos (stale screen): only the field is written, doc untouched', () async {
      final before = _snapshot(stored('42-tv')!);
      await repo.addAndRecommend(
        const SearchResult(
          id: 42,
          mediaType: MediaType.tv,
          title: 'A Show',
          posterPath: null,
          overview: '',
        ),
      );
      expect(data.calls, ['setRecommended:42-tv:true']);
      expect(_snapshot(stored('42-tv')!), before);
      expect(stored('42-tv')!.recommended, isTrue);
    });

    test(
      'cold cache (state unreadable): the add goes through as a create, never an update',
      () async {
        h.cloud.readsUnavailable = true;
        await repo.addAndRecommend(_newMovie);
        h.cloud.readsUnavailable = false;
        expect(data.calls, ['add:99-movie:true']);
      },
    );

    test('progress writes never touch recommended (episodes, movie, season, bulk, undo)', () async {
      await repo.setRecommended(42, MediaType.tv, true);
      await repo.setRecommended(7, MediaType.movie, true);

      await repo.toggleEpisodeWatched(42, 1, 3);
      await repo.setEpisodeWatched(42, 1, 3, watched: false);
      await repo.toggleMovieWatched(7);
      await repo.setMovieWatched(7, true);
      expect(stored('42-tv')!.recommended, isTrue);
      expect(stored('7-movie')!.recommended, isTrue);

      // Whole-series mark and "Desfazer" (docs/30).
      final plan = SeriesBulkPlan(
        docKey: '42-tv',
        watched: false,
        keys: const {'1_1', '1_2'},
        seasonCount: 1,
      );
      final undo = await repo.applySeriesBulk(plan, uid: 'uid-x');
      expect(stored('42-tv')!.watchedEpisodes, isEmpty);
      expect(stored('42-tv')!.recommended, isTrue);
      await repo.undoSeriesBulk(undo!);
      expect(stored('42-tv')!.watchedEpisodes, {'1_1', '1_2'});
      expect(stored('42-tv')!.recommended, isTrue);
      expect(stored('42-tv')!.addedAt, _added);
    });

    test('recommending does not change addedAt/lastWatchedAt and does not mark watched', () async {
      h.cloud.server['user-a']!['7-movie'] = _movie().copyWith(watchedMovie: false);
      await repo.setRecommended(7, MediaType.movie, true);
      final doc = stored('7-movie')!;
      expect(doc.watchedMovie, isFalse);
      expect(doc.addedAt, _added);
      expect(doc.lastWatchedAt, _watchedAt);
    });

    test(
      'remove deletes the mark with the doc; re-adding starts clean (not recommended)',
      () async {
        await repo.setRecommended(7, MediaType.movie, true);
        await repo.remove(7, MediaType.movie);
        expect(stored('7-movie'), isNull);
        await repo.addMovie(id: 7, title: 'A Movie', posterPath: null, overview: '');
        expect(stored('7-movie')!.recommended, isFalse);
        expect(stored('7-movie')!.watchedMovie, isFalse);
      },
    );

    test('offline: the mark shows at once and reaches the server after reconnecting', () async {
      h.cloud.offline = true;
      await repo.setRecommended(42, MediaType.tv, true);
      expect(stored('42-tv')!.recommended, isTrue); // optimistic view
      expect(h.cloud.server['user-a']!['42-tv']!.recommended, isFalse);
      h.cloud.offline = false;
      h.cloud.flush('user-a');
      expect(h.cloud.server['user-a']!['42-tv']!.recommended, isTrue);
      expect(h.cloud.server['user-a']!['42-tv']!.watchedEpisodes, {'1_1', '1_2'});
    });

    test('another account never sees (or gets) the mark', () async {
      await repo.setRecommended(42, MediaType.tv, true);
      expect(h.cloud.view('uid-bruno'), isEmpty);
      final other = InMemoryFavoritesDataSource(h.cloud, uid: 'uid-bruno');
      expect(await other.get('42-tv'), isNull);
    });

    test('signed-out source asks for login on setRecommended', () async {
      final r = FavoritesRepository(api: h.api, store: h.store);
      await expectLater(r.addAndRecommend(_newMovie), throwsA(isA<AuthRequiredException>()));
    });

    test('account deletion removes documents that carry the mark', () async {
      await repo.setRecommended(42, MediaType.tv, true);
      final profile = InMemoryProfileDataSource(h.cloud, uid: 'user-a');
      await profile.markDeleting();
      await profile.deleteAllFavorites();
      expect(h.cloud.view('user-a'), isEmpty);
    });
  });
}

class _FailingAdd extends InMemoryFavoritesDataSource {
  _FailingAdd(super.cloud, {required super.uid});

  @override
  Future<void> add(FavoriteDoc doc) => Future.error(StateError('boom'));
}
