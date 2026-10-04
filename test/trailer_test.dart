import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/title_video.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/catalog_sync_providers.dart';
import 'package:cinetrack/screens/movie_details_screen.dart';
import 'package:cinetrack/screens/tv_details_screen.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';
import 'package:cinetrack/widgets/trailer_dialog.dart';
import 'package:cinetrack/widgets/trailer_player.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

// docs/45 item 3: trailer in a modal on the movie and show details.

Map<String, dynamic> _json({
  String key = 'dQw4w9WgXcQ',
  String site = 'YouTube',
  String type = 'Trailer',
  bool official = true,
  String? lang = 'pt',
  int size = 1080,
  String published = '2024-01-01T00:00:00.000Z',
}) => {
  'id': 'x$key',
  'iso_3166_1': 'BR',
  'iso_639_1': lang,
  'key': key,
  'name': 'Vídeo $key',
  'official': official,
  'published_at': published,
  'site': site,
  'size': size,
  'type': type,
};

TitleVideo _v({
  String key = 'dQw4w9WgXcQ',
  String type = 'Trailer',
  bool official = true,
  String? lang = 'pt',
  int size = 1080,
  String published = '2024-01-01T00:00:00.000Z',
}) => TitleVideo.fromTmdb(
  _json(key: key, type: type, official: official, lang: lang, size: size, published: published),
)!;

void main() {
  group('TitleVideo', () {
    test('keeps only well-formed YouTube videos', () {
      expect(TitleVideo.fromTmdb(_json())!.key, 'dQw4w9WgXcQ');
      expect(TitleVideo.fromTmdb(_json(site: 'Vimeo')), isNull);
      // The key goes into a URL: anything that is not an 11 char id is dropped.
      expect(TitleVideo.fromTmdb(_json(key: 'abc"><script>alert(1)')), isNull);
      expect(TitleVideo.fromTmdb(_json(key: 'short')), isNull);
      expect(TitleVideo.fromTmdb({'site': 'YouTube'}), isNull);
    });

    test('embed URL: privacy-enhanced domain, https, no user data', () {
      final uri = _v().embedUri;
      expect(uri.scheme, 'https');
      expect(uri.host, 'www.youtube-nocookie.com');
      expect(uri.path, '/embed/dQw4w9WgXcQ');
      expect(uri.queryParameters.keys.toSet(), {'autoplay', 'rel', 'playsinline', 'hl'});
      expect(_v().watchUri.toString(), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    });
  });

  group('malicious or malformed key', () {
    const evil = TitleVideo(
      key: 'a"><script>x</script>',
      name: 'x',
      type: 'Trailer',
      official: true,
    );

    test('embedUri / watchUri refuse to build a URL from it', () {
      expect(() => evil.embedUri, throwsArgumentError);
      expect(() => evil.watchUri, throwsArgumentError);
      expect(TitleVideo.isValidKey('dQw4w9WgXcQ'), isTrue);
      expect(TitleVideo.isValidKey('dQw4w9WgXc'), isFalse);
      expect(TitleVideo.isValidKey('dQw4w9WgXcQ/../x'), isFalse);
    });

    test('the picker never selects it', () {
      expect(TrailerPicker.best([evil]), isNull);
      expect(TrailerPicker.best([evil, _v()])!.key, 'dQw4w9WgXcQ');
    });
  });

  group('TrailerPicker', () {
    test('nothing usable -> null', () {
      expect(TrailerPicker.best(const []), isNull);
      expect(
        TrailerPicker.best([_v(type: 'Featurette'), _v(type: 'Clip'), _v(lang: 'ja')]),
        isNull,
      );
    });

    test('Trailer beats Teaser; official beats unofficial; Portuguese beats English', () {
      final teaser = _v(key: 'AAAAAAAAAAA', type: 'Teaser');
      final trailer = _v(key: 'BBBBBBBBBBB', type: 'Trailer', official: false, lang: 'en');
      expect(TrailerPicker.best([teaser, trailer])!.key, 'BBBBBBBBBBB');

      final unofficialPt = _v(key: 'CCCCCCCCCCC', official: false);
      final officialEn = _v(key: 'DDDDDDDDDDD', lang: 'en');
      expect(TrailerPicker.best([unofficialPt, officialEn])!.key, 'DDDDDDDDDDD');

      final officialPt = _v(key: 'EEEEEEEEEEE');
      expect(TrailerPicker.best([officialEn, officialPt])!.key, 'EEEEEEEEEEE');
      expect(TrailerPicker.best([officialPt, officialEn])!.key, 'EEEEEEEEEEE'); // order-free
    });

    test('a Teaser is used when there is no Trailer; language-less is accepted', () {
      expect(TrailerPicker.best([_v(type: 'Teaser', lang: null)])!.type, 'Teaser');
    });

    test('same score: the larger, then the newer', () {
      final small = _v(key: 'AAAAAAAAAAA', size: 480);
      final big = _v(key: 'BBBBBBBBBBB', size: 1080);
      expect(TrailerPicker.best([small, big])!.key, 'BBBBBBBBBBB');
      final old = _v(key: 'CCCCCCCCCCC', published: '2020-01-01T00:00:00.000Z');
      final recent = _v(key: 'DDDDDDDDDDD', published: '2024-06-01T00:00:00.000Z');
      expect(TrailerPicker.best([old, recent])!.key, 'DDDDDDDDDDD');
      expect(TrailerPicker.best([recent, old])!.key, 'DDDDDDDDDDD');
    });
  });

  group('TmdbApiClient.getTitleVideos', () {
    test('asks pt, en and language-less in ONE request and discards non-YouTube', () async {
      late Uri seen;
      final client = TmdbApiClient(
        apiKey: 'k',
        httpClient: MockClient((request) async {
          seen = request.url;
          return http.Response(
            jsonEncode({
              'id': 603,
              'results': [_json(), _json(site: 'Vimeo', key: 'ZZZZZZZZZZZ')],
            }),
            200,
          );
        }),
      );
      final videos = await client.getTitleVideos(MediaType.tv, 603);
      expect(seen.path, '/3/tv/603/videos');
      expect(seen.queryParameters['include_video_language'], 'pt,en,null');
      expect(videos.map((v) => v.key), ['dQw4w9WgXcQ']);
    });

    test('HTTP error becomes a TmdbException', () async {
      final client = TmdbApiClient(
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(client.getTitleVideos(MediaType.movie, 1), throwsA(isA<TmdbException>()));
    });
  });

  group('UI', () {
    int builds = 0;
    final opened = <Uri>[];

    Future<FakeTmdbApiClient> pump(
      WidgetTester tester, {
      required String location,
      List<TitleVideo> videos = const [],
      Object? error,
      bool hasPlayer = true,
      bool urlOk = true,
      Size size = const Size(390, 1200),
      double scale = 1,
      Brightness brightness = Brightness.light,
      FakeTmdbApiClient? api,
    }) async {
      builds = 0;
      opened.clear();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = api ?? FakeTmdbApiClient();
      fake
        ..videos = videos
        ..videosError = error
        ..movieDetails = {'id': 11, 'title': 'Filme X', 'overview': 'Sinopse'}
        ..tvDetails = {'id': 12, 'name': 'Serie Y', 'overview': 'Sinopse', 'seasons': <dynamic>[]};
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...cloudOverrides(
              auth: FakeAuthRepository(initialUser: kAna),
              cloud: FakeCloud(),
              api: fake,
            ),
            catalogSyncDelayProvider.overrideWithValue((_) async {}),
            trailerPlayerBuilderProvider.overrideWithValue(
              hasPlayer
                  ? (context, video, title) {
                      builds++;
                      return Container(key: ValueKey('player-${video.key}'), color: Colors.black);
                    }
                  : null,
            ),
            urlOpenerProvider.overrideWithValue((uri) async {
              opened.add(uri);
              return urlOk;
            }),
          ],
          child: MaterialApp.router(
            theme: ThemeData(brightness: brightness, useMaterial3: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            routerConfig: GoRouter(
              initialLocation: location,
              routes: [
                GoRoute(
                  path: '/movie/:id',
                  builder: (_, s) =>
                      MovieDetailsScreen(movieId: int.parse(s.pathParameters['id']!)),
                ),
                GoRoute(
                  path: '/tv/:id',
                  builder: (_, s) => TvDetailsScreen(tvId: int.parse(s.pathParameters['id']!)),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return fake;
    }

    final trailer = _v();
    final button = find.text('Assistir trailer');

    for (final location in ['/movie/11', '/tv/12']) {
      testWidgets('$location (not a favorite): button is there; NOTHING is loaded before the tap', (
        tester,
      ) async {
        final api = await pump(tester, location: location, videos: [trailer]);
        expect(button, findsOneWidget);
        expect(builds, 0); // no player (no iframe) before the tap
        expect(opened, isEmpty);
        expect(find.byKey(const ValueKey('player-dQw4w9WgXcQ')), findsNothing);
        expect(api.videosCalls, 1); // only the TMDB list, to know whether to show the button

        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(TrailerDialog), findsOneWidget);
        expect(find.byKey(const ValueKey('player-dQw4w9WgXcQ')), findsOneWidget);
        expect(builds, 1);
        expect(
          find.text('Trailer: ${location == '/movie/11' ? 'Filme X' : 'Serie Y'}'),
          findsOneWidget,
        );
        expect(find.textContaining('modo de privacidade'), findsOneWidget);
      });
    }

    testWidgets('no trailer on TMDB: the button is hidden', (tester) async {
      await pump(
        tester,
        location: '/movie/11',
        videos: [_v(type: 'Featurette')],
      );
      expect(button, findsNothing);
      // The rest of the actions are untouched.
      expect(find.text('Favoritar'), findsOneWidget);
      expect(find.text('Marcar como assistido'), findsOneWidget);
    });

    testWidgets('closes with the X, with Esc and with a tap outside; focus goes to the dialog', (
      tester,
    ) async {
      await pump(tester, location: '/movie/11', videos: [trailer]);

      await tester.tap(button);
      await tester.pumpAndSettle();
      // Keyboard focus starts on the close button.
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        find.descendant(of: find.byType(TrailerDialog), matching: find.byType(IconButton)),
        findsOneWidget,
      );
      expect(focused.findAncestorWidgetOfExactType<TrailerDialog>(), isNotNull);
      await tester.tap(find.byTooltip('Fechar trailer'));
      await tester.pumpAndSettle();
      expect(find.byType(TrailerDialog), findsNothing);
      expect(find.text('Filme X'), findsWidgets); // back on the details, same screen

      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TrailerDialog), findsNothing);

      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byType(TrailerDialog), findsNothing);
    });

    testWidgets('closing and reopening builds a fresh player (the old one is gone)', (
      tester,
    ) async {
      await pump(tester, location: '/movie/11', videos: [trailer]);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Fechar trailer'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('player-dQw4w9WgXcQ')), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(builds, 2);
    });

    testWidgets('loading state while TMDB answers, then the player', (tester) async {
      final api = FakeTmdbApiClient()..videosGate = Completer<void>();
      await pump(tester, location: '/movie/11', videos: [trailer], api: api);
      expect(button, findsOneWidget); // still loading: the button is shown
      await tester.tap(button);
      await tester.pump();
      await tester.pump();
      expect(find.text('Carregando trailer…'), findsOneWidget);
      expect(builds, 0);
      api.videosGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Carregando trailer…'), findsNothing);
      expect(builds, 1);
    });

    testWidgets('error / offline: message and "Tentar novamente" recovers', (tester) async {
      final api = await pump(
        tester,
        location: '/movie/11',
        videos: [trailer],
        error: TmdbException.network(),
      );
      expect(button, findsOneWidget); // failed list: the dialog explains and retries
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Sem conexão com a internet.'), findsOneWidget);
      expect(builds, 0);

      api.videosError = null;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(find.text('Sem conexão com a internet.'), findsNothing);
      expect(builds, 1);
    });

    testWidgets('unexpected error gets the generic message', (tester) async {
      await pump(tester, location: '/movie/11', error: StateError('x'));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(kTrailerErrorMessage), findsOneWidget);
    });

    testWidgets('trailer disappears while the dialog is open: friendly message', (tester) async {
      final api = FakeTmdbApiClient()..videosGate = Completer<void>();
      await pump(tester, location: '/movie/11', videos: const [], api: api);
      await tester.tap(button);
      await tester.pump();
      api.videosGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text(kTrailerUnavailableMessage), findsOneWidget);
    });

    testWidgets('platform without an in-page player: opens YouTube, only after the tap', (
      tester,
    ) async {
      await pump(tester, location: '/tv/12', videos: [trailer], hasPlayer: false);
      expect(opened, isEmpty);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(opened, isEmpty); // opening the dialog opens nothing
      expect(builds, 0);
      expect(find.textContaining('abre no YouTube'), findsOneWidget);
      await tester.tap(find.text('Assistir no YouTube'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    });

    testWidgets('web player: "Abrir no YouTube" is a fallback; a failed open says so', (
      tester,
    ) async {
      await pump(tester, location: '/movie/11', videos: [trailer], urlOk: false);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abrir no YouTube'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(find.text('Não foi possível abrir o YouTube.'), findsOneWidget);
    });

    testWidgets('semantics: named button, labelled dialog, labelled player, 48 px', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, location: '/movie/11', videos: [trailer]);
      final node = tester.getSemantics(button).getSemanticsData();
      expect(node.label, 'Assistir trailer de Filme X'); // starts with the visible text
      final chip = find.ancestor(of: button, matching: find.byType(ActionChip));
      expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Trailer de Filme X'), findsWidgets);
      expect(find.bySemanticsLabel('Player do trailer de Filme X'), findsOneWidget);
      expect(tester.getSize(find.byTooltip('Fechar trailer')).height, greaterThanOrEqualTo(48));
      handle.dispose();
    });

    group('no overflow', () {
      for (final width in [320.0, 360.0, 768.0, 1024.0, 1440.0]) {
        for (final scale in [1.0, 3.0]) {
          for (final brightness in Brightness.values) {
            testWidgets('$width px, font ${scale}x, ${brightness.name}', (tester) async {
              final api = await pump(
                tester,
                location: '/tv/12',
                videos: [trailer],
                size: Size(width, 900),
                scale: scale,
                brightness: brightness,
              );
              expect(tester.takeException(), isNull);
              for (final state in ['ready', 'error', 'none', 'external']) {
                api
                  ..videosError = state == 'error' ? TmdbException.network() : null
                  ..videos = state == 'none' ? const [] : [trailer];
                await tester.tap(button, warnIfMissed: false);
                await tester.pumpAndSettle();
                if (find.byType(TrailerDialog).evaluate().isEmpty) continue; // hidden button
                expect(tester.takeException(), isNull, reason: state);
                await tester.tap(find.byTooltip('Fechar trailer'));
                await tester.pumpAndSettle();
              }
            });
          }
        }
      }
    });
  });
}
