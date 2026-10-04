import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_item.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/repositories/favorites_repository.dart';
import 'package:cinetrack/screens/tv_details_screen.dart';
import 'package:cinetrack/services/local_store.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';
import 'package:cinetrack/widgets/episode_tile.dart';

/// Fake repository that mimics the real one closely enough to reproduce
/// the bug: `loadSeason` reads from the in-memory item's cached seasons
/// (like the real repo reads from Hive), and `toggleEpisodeWatched`
/// mutates that same cache and pushes a new list through `watchAll` —
/// exactly like a Hive `box.watch()` event would.
class _FakeFavoritesRepository extends FavoritesRepository {
  _FakeFavoritesRepository(this._item)
      : super(api: TmdbApiClient(apiKey: 'test'), store: LocalStore());

  FavoriteItem _item;
  final _controller = StreamController<List<FavoriteItem>>.broadcast();

  @override
  Stream<List<FavoriteItem>> watchAll() async* {
    yield [_item];
    yield* _controller.stream;
  }

  @override
  Future<SeasonCache> loadSeason(int tvId, int seasonNumber) async {
    final cached = _item.seasons?.where((s) => s.seasonNumber == seasonNumber);
    if (cached != null && cached.isNotEmpty) return cached.first;
    throw StateError('Season $seasonNumber not cached in fake repo');
  }

  @override
  Future<void> toggleEpisodeWatched(
    int tvId,
    int seasonNumber,
    int episodeNumber,
  ) async {
    final updatedSeasons = [
      for (final season in _item.seasons ?? const <SeasonCache>[])
        if (season.seasonNumber == seasonNumber)
          season.copyWithEpisode(
            season.episodes
                .firstWhere((e) => e.episodeNumber == episodeNumber)
                .copyWith(
                  watched: !season.episodes
                      .firstWhere((e) => e.episodeNumber == episodeNumber)
                      .watched,
                ),
          )
        else
          season,
    ];
    _item = _item.copyWith(seasons: updatedSeasons);
    _controller.add([_item]);
  }

  @override
  Future<void> setSeasonWatched(int tvId, int seasonNumber, {required bool watched}) async {
    final updatedSeasons = [
      for (final season in _item.seasons ?? const <SeasonCache>[])
        if (season.seasonNumber == seasonNumber)
          SeasonCache(
            seasonNumber: season.seasonNumber,
            episodes: [
              for (final ep in season.episodes)
                ep.hasAired ? ep.copyWith(watched: watched) : ep,
            ],
          )
        else
          season,
    ];
    _item = _item.copyWith(seasons: updatedSeasons);
    _controller.add([_item]);
  }
}

/// Extends the fake above with control over the timing/outcome of
/// `setSeasonWatched`, to exercise the loading-feedback and error-handling
/// paths of `_SeasonWatchedCheckbox` without a real network call.
class _ControllableFavoritesRepository extends _FakeFavoritesRepository {
  _ControllableFavoritesRepository(super.item, {this.gate, this.error});

  /// When set, `setSeasonWatched` waits on this before doing anything else
  /// — lets a test pump a frame mid-flight and assert on the pending UI.
  final Completer<void>? gate;

  /// When set, `setSeasonWatched` throws this instead of applying the
  /// update, simulating a network failure surfacing from `loadSeason`.
  final Object? error;

  @override
  Future<void> setSeasonWatched(int tvId, int seasonNumber, {required bool watched}) async {
    if (gate != null) await gate!.future;
    final configuredError = error;
    if (configuredError != null) throw configuredError;
    await super.setSeasonWatched(tvId, seasonNumber, watched: watched);
  }
}

Widget _wrap(FavoritesRepository repository, int tvId) {
  return ProviderScope(
    overrides: [
      favoritesRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(home: TvDetailsScreen(tvId: tvId)),
  );
}

void main() {
  testWidgets(
    'toggling an episode updates the checkbox immediately (regression)',
    (tester) async {
      final show = FavoriteItem(
        id: 42,
        mediaType: MediaType.tv,
        title: 'A Show',
        posterPath: null,
        overview: '',
        addedAt: DateTime.now(),
        seasonSummaries: const [
          TvSeasonSummary(seasonNumber: 1, name: 'Temporada 1', episodeCount: 1),
        ],
        seasons: const [
          SeasonCache(seasonNumber: 1, episodes: [
            EpisodeCache(
              episodeNumber: 1,
              name: 'Pilot',
              airDate: null,
              watched: false,
            ),
          ]),
        ],
      );

      final repository = _FakeFavoritesRepository(show);

      await tester.pumpWidget(_wrap(repository, 42));
      await tester.pumpAndSettle();

      // Expand the season to render its episode list.
      await tester.tap(find.text('Temporada 1'));
      await tester.pumpAndSettle();

      final checkboxFinder = find.byType(EpisodeTile);
      expect(checkboxFinder, findsOneWidget);
      expect(tester.widget<EpisodeTile>(checkboxFinder).episode.watched, isFalse);

      // Mark the episode as watched.
      final episodeCheck = find.descendant(of: checkboxFinder, matching: find.byType(Checkbox));
      await tester.ensureVisible(episodeCheck); // the richer tile is taller than before
      await tester.pumpAndSettle();
      await tester.tap(episodeCheck);
      await tester.pumpAndSettle();

      // Before the fix, seasonProvider kept serving the stale cached
      // SeasonCache from the first load, so this checkbox stayed
      // unchecked even though the repository/Hive already persisted the
      // toggle.
      expect(tester.widget<EpisodeTile>(checkboxFinder).episode.watched, isTrue);
    },
  );

  group('season-level watched checkbox and progress header', () {
    // The season checkbox is the only tristate Checkbox on the screen —
    // CheckboxListTile's own internal Checkbox is never tristate — so this
    // predicate finds it reliably whether the tile is expanded or not.
    final seasonCheckboxFinder =
        find.byWidgetPredicate((widget) => widget is Checkbox && widget.tristate == true);

    FavoriteItem showWithPartiallyWatchedSeason() => FavoriteItem(
          id: 42,
          mediaType: MediaType.tv,
          title: 'A Show',
          posterPath: null,
          overview: '',
          addedAt: DateTime.now(),
          seasonSummaries: const [
            TvSeasonSummary(seasonNumber: 1, name: 'Temporada 1', episodeCount: 2),
          ],
          seasons: const [
            SeasonCache(seasonNumber: 1, episodes: [
              EpisodeCache(episodeNumber: 1, name: 'Ep 1', airDate: null, watched: true),
              EpisodeCache(episodeNumber: 2, name: 'Ep 2', airDate: null, watched: false),
            ]),
          ],
        );

    testWidgets('shows progress in the header even before the tile is expanded', (tester) async {
      final repository = _FakeFavoritesRepository(showWithPartiallyWatchedSeason());

      await tester.pumpWidget(_wrap(repository, 42));
      await tester.pumpAndSettle();

      expect(find.text('1/2 episódios · 50%'), findsOneWidget);
      expect(tester.widget<Checkbox>(seasonCheckboxFinder).value, isNull); // indeterminate
    });

    testWidgets('falls back to the plain episode count when the season was never opened',
        (tester) async {
      final show = FavoriteItem(
        id: 42,
        mediaType: MediaType.tv,
        title: 'A Show',
        posterPath: null,
        overview: '',
        addedAt: DateTime.now(),
        seasonSummaries: const [
          TvSeasonSummary(seasonNumber: 1, name: 'Temporada 1', episodeCount: 10),
        ],
        seasons: const [],
      );
      final repository = _FakeFavoritesRepository(show);

      await tester.pumpWidget(_wrap(repository, 42));
      await tester.pumpAndSettle();

      expect(find.text('10 episódios'), findsOneWidget);
      expect(tester.widget<Checkbox>(seasonCheckboxFinder).value, isFalse);
    });

    testWidgets(
        'tapping the season checkbox marks/unmarks every episode immediately, '
        'without collapsing or reopening the tile (regression)', (tester) async {
      final repository = _FakeFavoritesRepository(showWithPartiallyWatchedSeason());

      await tester.pumpWidget(_wrap(repository, 42));
      await tester.pumpAndSettle();

      // Expand once and leave it expanded for the whole test — the bug
      // this guards against was exactly the UI not refreshing in place.
      await tester.tap(find.text('Temporada 1'));
      await tester.pumpAndSettle();

      expect(tester.widget<Checkbox>(seasonCheckboxFinder).value, isNull);

      // Partial -> tap marks everything (already-aired) as watched.
      await tester.tap(seasonCheckboxFinder);
      await tester.pumpAndSettle();

      expect(tester.widget<Checkbox>(seasonCheckboxFinder).value, isTrue);
      expect(find.text('2/2 episódios · 100%'), findsOneWidget);
      final checkboxTiles = tester.widgetList<EpisodeTile>(find.byType(EpisodeTile));
      expect(checkboxTiles.every((tile) => tile.episode.watched), isTrue);

      // Fully watched -> tap again clears everything.
      await tester.tap(seasonCheckboxFinder);
      await tester.pumpAndSettle();

      expect(tester.widget<Checkbox>(seasonCheckboxFinder).value, isFalse);
      expect(find.text('0/2 episódios · 0%'), findsOneWidget);
      final clearedTiles = tester.widgetList<EpisodeTile>(find.byType(EpisodeTile));
      expect(clearedTiles.every((tile) => !tile.episode.watched), isTrue);
    });

    testWidgets('unaired episodes are never marked as watched by the season checkbox',
        (tester) async {
      final future = DateTime.now().add(const Duration(days: 30));
      final show = FavoriteItem(
        id: 42,
        mediaType: MediaType.tv,
        title: 'A Show',
        posterPath: null,
        overview: '',
        addedAt: DateTime.now(),
        seasonSummaries: const [
          TvSeasonSummary(seasonNumber: 1, name: 'Temporada 1', episodeCount: 2),
        ],
        seasons: [
          SeasonCache(seasonNumber: 1, episodes: [
            const EpisodeCache(episodeNumber: 1, name: 'Ep 1', airDate: null, watched: false),
            EpisodeCache(episodeNumber: 2, name: 'Ep 2', airDate: future, watched: false),
          ]),
        ],
      );
      final repository = _FakeFavoritesRepository(show);

      await tester.pumpWidget(_wrap(repository, 42));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Temporada 1'));
      await tester.pumpAndSettle();

      await tester.tap(seasonCheckboxFinder);
      await tester.pumpAndSettle();

      // Fully watched from the user's perspective (everything aired is
      // watched), even though the unaired episode keeps the percentage
      // below 100 and its own checkbox unchecked/disabled.
      expect(tester.widget<Checkbox>(seasonCheckboxFinder).value, isTrue);
      expect(find.text('1/2 episódios · 50%'), findsOneWidget);
      final tiles = tester.widgetList<EpisodeTile>(find.byType(EpisodeTile)).toList();
      expect(tiles.firstWhere((t) => t.episode.episodeNumber == 1).episode.watched, isTrue);
      final unairedTile = tiles.firstWhere((t) => t.episode.episodeNumber == 2);
      expect(unairedTile.episode.watched, isFalse);
      // Disabled, same as before this feature.
      final unairedCheck = find.descendant(
        of: find.byWidget(unairedTile),
        matching: find.byType(Checkbox),
      );
      expect(tester.widget<Checkbox>(unairedCheck).onChanged, isNull);
    });

    testWidgets(
        'shows a loading spinner in place of the checkbox while marking a season that '
        'was never opened before, then settles once the call resolves', (tester) async {
      final show = FavoriteItem(
        id: 42,
        mediaType: MediaType.tv,
        title: 'A Show',
        posterPath: null,
        overview: '',
        addedAt: DateTime.now(),
        seasonSummaries: const [
          TvSeasonSummary(seasonNumber: 1, name: 'Temporada 1', episodeCount: 2),
        ],
        seasons: const [], // never opened/cached -> setSeasonWatched would hit the network
      );
      final gate = Completer<void>();
      final repository = _ControllableFavoritesRepository(show, gate: gate);

      await tester.pumpWidget(_wrap(repository, 42));
      await tester.pumpAndSettle();

      expect(seasonCheckboxFinder, findsOneWidget);

      await tester.tap(seasonCheckboxFinder);
      await tester.pump(); // one frame: the await hasn't resolved yet, call is "in flight"

      // The checkbox is swapped out for a spinner instead of sitting there
      // looking unresponsive.
      expect(seasonCheckboxFinder, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      // Spinner is gone, checkbox is back and reflects the applied update.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(seasonCheckboxFinder, findsOneWidget);
    });

    testWidgets(
        'shows a SnackBar with the TmdbException message on failure and clears the '
        'pending state so the checkbox is tappable again', (tester) async {
      final repository = _ControllableFavoritesRepository(
        showWithPartiallyWatchedSeason(),
        error: TmdbException.network(),
      );

      await tester.pumpWidget(_wrap(repository, 42));
      await tester.pumpAndSettle();

      await tester.tap(seasonCheckboxFinder);
      await tester.pumpAndSettle();

      expect(find.text('Sem conexão com a internet.'), findsOneWidget);
      // Pending state was cleared in `finally` — checkbox is back, not
      // stuck showing a spinner forever.
      expect(seasonCheckboxFinder, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'shows a generic message on a non-TmdbException failure and still clears '
        'the pending state', (tester) async {
      final repository = _ControllableFavoritesRepository(
        showWithPartiallyWatchedSeason(),
        error: StateError('boom'),
      );

      await tester.pumpWidget(_wrap(repository, 42));
      await tester.pumpAndSettle();

      await tester.tap(seasonCheckboxFinder);
      await tester.pumpAndSettle();

      expect(
        find.text('Não foi possível atualizar esta temporada. Tente novamente.'),
        findsOneWidget,
      );
      expect(seasonCheckboxFinder, findsOneWidget);
    });
  });
}
