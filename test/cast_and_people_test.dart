import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cinetrack/main.dart' show CineTrackApp;
import 'package:cinetrack/models/cast_member.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/person.dart';
import 'package:cinetrack/router.dart';
import 'package:cinetrack/screens/cast_screen.dart';
import 'package:cinetrack/screens/movie_details_screen.dart';
import 'package:cinetrack/screens/person_screen.dart';
import 'package:cinetrack/screens/tv_details_screen.dart';
import 'package:cinetrack/services/tmdb_api_client.dart';
import 'package:cinetrack/services/tmdb_exception.dart';
import 'package:cinetrack/widgets/app_shell.dart';
import 'package:cinetrack/widgets/cast_widgets.dart';
import 'package:cinetrack/widgets/tmdb_attribution.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

CastMember _m(int id, {String? character, String? photo}) =>
    CastMember(id: id, name: 'Ator $id', character: character, profilePath: photo);

PersonCredit _c(
  int id,
  MediaType type,
  String title, {
  String? date,
  String? character,
  double popularity = 1,
}) =>
    PersonCredit(
      id: id,
      mediaType: type,
      title: title,
      date: parseTmdbDate(date),
      character: character,
      popularity: popularity,
    );

FakeTmdbApiClient _api() => FakeTmdbApiClient()
  ..movieDetails = {
    'id': 11,
    'title': 'Filme X',
    'overview': 'Sinopse do TMDB',
    'release_date': '2019-05-01',
    'genres': <dynamic>[],
  }
  ..tvDetails = {
    'id': 12,
    'name': 'Serie Y',
    'overview': 'Sinopse serie',
    'first_air_date': '2020-01-01',
    'genres': <dynamic>[],
    'seasons': [
      {'season_number': 1, 'name': 'Temporada 1', 'episode_count': 2},
    ],
  };

Map<String, dynamic> _person(int id, {String bio = 'Bio em português', String? birthday}) => {
      'id': id,
      'name': 'Ator $id',
      'biography': bio,
      'birthday': birthday,
      'deathday': null,
      'place_of_birth': 'Lisboa, Portugal',
      'profile_path': null,
      'known_for_department': 'Acting',
    };

void main() {
  group('pure logic', () {
    test('parseTmdbDate: only a real yyyy-MM-dd', () {
      expect(parseTmdbDate('1980-02-29'), DateTime(1980, 2, 29));
      for (final bad in ['1980', '1980-02', '1981-02-29', '', '80-01-01', null, 5]) {
        expect(parseTmdbDate(bad), isNull, reason: '$bad');
      }
      expect(formatDateBr(DateTime(1980, 2, 9)), '09/02/1980');
    });

    test('age: birthday today counts, death freezes it, bad data omits it', () {
      PersonProfile p(String? b, [String? d]) => PersonProfile.fromTmdb(
          {'id': 1, 'name': 'x', 'birthday': b, 'deathday': d, 'biography': ''});
      final today = DateTime(2026, 10, 3);
      expect(p('1990-10-03').ageOn(today), 36);
      expect(p('1990-10-04').ageOn(today), 35);
      expect(p(null).ageOn(today), isNull);
      expect(p('not-a-date').ageOn(today), isNull);
      expect(p('1950-01-01', '2000-01-01').ageAtDeath, 50);
      expect(p('1950-01-01', '1940-01-01').ageAtDeath, isNull);
      expect(p('2030-01-01').ageOn(today), isNull);
    });

    test('biography: pt-BR wins, empty falls back to English and says so', () {
      final own = PersonProfile.fromTmdb({'id': 1, 'name': 'x', 'biography': 'Olá'},
          fallbackBiography: 'Hello');
      expect(own.biography, 'Olá');
      expect(own.biographyIsFallback, isFalse);
      final fb = PersonProfile.fromTmdb({'id': 1, 'name': 'x', 'biography': '  '},
          fallbackBiography: 'Hello');
      expect(fb.biography, 'Hello');
      expect(fb.biographyIsFallback, isTrue);
      expect(PersonProfile.fromTmdb({'id': 1, 'name': 'x', 'biography': ''}).biography, isNull);
    });

    test('filmography: newest first, undated last, split, no duplicates, adult hidden', () {
      final film = Filmography.fromCredits([
        _c(1, MediaType.movie, 'Antigo', date: '1999-01-01'),
        _c(2, MediaType.movie, 'Novo', date: '2024-06-01'),
        _c(3, MediaType.movie, 'Sem data'),
        _c(4, MediaType.movie, 'Meio', date: '2010-03-03'),
        _c(5, MediaType.tv, 'Série A', date: '2015-01-01', character: 'Ana'),
        _c(5, MediaType.tv, 'Série A', date: '2015-01-01', character: 'Bia'),
        _c(5, MediaType.tv, 'Série A', date: '2015-01-01', character: 'Ana'),
        _c(5, MediaType.movie, 'Filme com mesmo id', date: '2000-01-01'),
        _c(6, MediaType.tv, 'Série B', date: '2022-01-01'),
      ]);
      expect(film.movies.map((c) => c.title),
          ['Novo', 'Meio', 'Filme com mesmo id', 'Antigo', 'Sem data']);
      expect(film.shows.map((c) => c.title), ['Série B', 'Série A']);
      expect(film.shows.last.character, 'Ana / Bia');

      final parsed = [
        {'id': 1, 'media_type': 'movie', 'title': 'Ok', 'release_date': '2020-01-01'},
        {'id': 2, 'media_type': 'movie', 'title': 'Adulto', 'adult': true},
        {'id': 3, 'media_type': 'person', 'name': 'Alguém'},
        {'id': 'x', 'media_type': 'movie'},
      ].map(PersonCredit.fromTmdb).whereType<PersonCredit>();
      expect(parsed.map((c) => c.title), ['Ok']);
    });

    test('undated credits keep a stable order (popularity, then id)', () {
      final film = Filmography.fromCredits([
        _c(3, MediaType.movie, 'c', popularity: 1),
        _c(1, MediaType.movie, 'a', popularity: 1),
        _c(2, MediaType.movie, 'b', popularity: 5),
      ]);
      expect(film.movies.map((c) => c.title), ['b', 'a', 'c']);
    });

    test('known for: 3 most popular', () {
      final film = Filmography.fromCredits([
        _c(1, MediaType.movie, 'a', popularity: 5),
        _c(2, MediaType.movie, 'b', popularity: 50),
        _c(3, MediaType.tv, 'c', popularity: 20),
        _c(4, MediaType.tv, 'd', popularity: 30),
      ]);
      expect(film.knownFor().map((c) => c.title), ['b', 'd', 'c']);
    });
  });

  group('TmdbApiClient', () {
    TmdbApiClient client(Map<String, Map<String, dynamic>> byPath, List<Uri> seen) => TmdbApiClient(
          apiKey: 'k',
          httpClient: MockClient((request) async {
            seen.add(request.url);
            final body = byPath[request.url.path];
            return body == null ? http.Response('{}', 404) : http.Response(jsonEncode(body), 200);
          }),
        );

    test('movie cast uses /credits, keeps order, one entry per person', () async {
      final seen = <Uri>[];
      final c = client({
        '/3/movie/1/credits': {
          'cast': [
            {'id': 1, 'name': 'A', 'character': 'X', 'profile_path': '/a.jpg'},
            {'id': 2, 'name': 'B', 'character': '', 'profile_path': null},
            {'id': 1, 'name': 'A', 'character': 'Y'},
            {'name': 'sem id'},
          ]
        }
      }, seen);
      final cast = await c.getTitleCast(MediaType.movie, 1);
      expect(cast.map((m) => m.id), [1, 2]);
      expect(cast.first.character, 'X / Y');
      expect(cast.last.character, isNull);
      expect(seen.single.queryParameters['language'], 'pt-BR');
    });

    test('show cast uses aggregate_credits, first two roles', () async {
      final seen = <Uri>[];
      final c = client({
        '/3/tv/9/aggregate_credits': {
          'cast': [
            {
              'id': 1,
              'name': 'A',
              'roles': [
                {'character': 'R1'},
                {'character': 'R2'},
                {'character': 'R3'},
              ],
            },
            {'id': 2, 'name': 'B', 'roles': <dynamic>[]},
          ]
        }
      }, seen);
      final cast = await c.getTitleCast(MediaType.tv, 9);
      expect(cast.first.character, 'R1 / R2');
      expect(cast.last.character, isNull);
    });

    test('a browser/offline ClientException becomes the standard offline error', () async {
      final offline = TmdbApiClient(
          apiKey: 'k',
          httpClient: MockClient((_) async => throw http.ClientException('Failed to fetch')));
      await expectLater(
          offline.getPerson(1),
          throwsA(isA<TmdbException>()
              .having((e) => e.message, 'message', 'Sem conexão com a internet.')));
    });

    test('person: language override, 404 and 429 map to TmdbException', () async {
      final seen = <Uri>[];
      final c = client({
        '/3/person/5': {'id': 5, 'name': 'P'}
      }, seen);
      await c.getPerson(5, language: 'en-US');
      expect(seen.single.queryParameters['language'], 'en-US');
      await expectLater(c.getPerson(6),
          throwsA(isA<TmdbException>().having((e) => e.type, 'type', TmdbErrorType.notFound)));
      final limited =
          TmdbApiClient(apiKey: 'k', httpClient: MockClient((_) async => http.Response('', 429)));
      await expectLater(limited.getPersonCredits(1),
          throwsA(isA<TmdbException>().having((e) => e.type, 'type', TmdbErrorType.rateLimited)));
    });
  });

  group('screens', () {
    late FakeTmdbApiClient api;

    Future<ProviderContainer> pumpApp(
      WidgetTester tester, {
      Size size = const Size(390, 900),
      double textScale = 1,
      FakeAuthRepository? auth,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final container = ProviderContainer(
        overrides: cloudOverrides(auth: auth ?? FakeAuthRepository(), cloud: FakeCloud(), api: api),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const CineTrackApp()),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      return container;
    }

    Future<void> go(WidgetTester tester, ProviderContainer c, String location) async {
      c.read(routerProvider).go(location);
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    // After an imperative push `uri` still reports the underlying route; the
    // last match is the visible one.
    String path(ProviderContainer c) =>
        c.read(routerProvider).routerDelegate.currentConfiguration.last.matchedLocation;

    setUp(() => api = _api());

    group('cast section', () {
      testWidgets('movie: carousel of 15 with photo placeholder, name and character; "Ver todos"',
          (tester) async {
        api.cast = [for (var i = 1; i <= 20; i++) _m(i, character: i == 2 ? null : 'Papel $i')];
        final c = await pumpApp(tester);
        await go(tester, c, '/movie/11');

        expect(find.text('Elenco'), findsOneWidget);
        expect(find.text('Ator 1'), findsOneWidget);
        expect(find.text('Papel 1'), findsOneWidget);
        expect(find.byIcon(Icons.person_outline), findsWidgets); // no photo: placeholder
        // Order is TMDB's; only 15 are built into the carousel (lazy), none beyond.
        expect(find.text('Ator 20'), findsNothing);
        expect(find.text('Ver todos'), findsOneWidget);
        expect(api.castCalls, 1);
        // Semantics: one button per card, "<name>, <character>"; no character: just the name.
        expect(find.bySemanticsLabel('Ator 1, Papel 1'), findsOneWidget);
        expect(find.bySemanticsLabel('Ator 2'), findsOneWidget);
        // Touch target >= 48.
        final card = tester.getSize(find.byType(CastCard).first);
        expect(card.width, greaterThanOrEqualTo(48));
        expect(card.height, greaterThanOrEqualTo(48));
      });

      testWidgets('movie with up to 15 people has no "Ver todos"', (tester) async {
        api.cast = [for (var i = 1; i <= 15; i++) _m(i)];
        final c = await pumpApp(tester);
        await go(tester, c, '/movie/11');
        expect(find.text('Elenco'), findsOneWidget);
        expect(find.text('Ver todos'), findsNothing);
      });

      testWidgets('show: cast section appears next to the seasons', (tester) async {
        api.cast = [_m(1, character: 'Heroína / Vilã')];
        final c = await pumpApp(tester);
        await go(tester, c, '/tv/12');
        expect(find.byType(TvDetailsScreen), findsOneWidget);
        expect(find.text('Elenco'), findsOneWidget);
        expect(find.text('Heroína / Vilã'), findsOneWidget);
        expect(find.text('Temporada 1'), findsOneWidget);
      });

      testWidgets('empty cast: section is hidden entirely', (tester) async {
        api.cast = const [];
        final c = await pumpApp(tester);
        await go(tester, c, '/movie/11');
        expect(find.text('Sinopse do TMDB'), findsOneWidget);
        expect(find.text('Elenco'), findsNothing);
      });

      testWidgets('loading shows a skeleton and the rest of the screen stays usable',
          (tester) async {
        api.castGate = Completer<void>();
        api.cast = [_m(1)];
        final c = await pumpApp(tester);
        c.read(routerProvider).go('/movie/11');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.bySemanticsLabel('Carregando elenco'), findsOneWidget);
        expect(find.text('Sinopse do TMDB'), findsOneWidget);
        expect(find.text('Marcar como assistido'), findsOneWidget);
        api.castGate!.complete();
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.text('Ator 1'), findsOneWidget);
      });

      testWidgets('error (offline): message + retry that refetches only the cast', (tester) async {
        api.castError = TmdbException.network();
        final c = await pumpApp(tester);
        await go(tester, c, '/movie/11');
        expect(find.text('Sem conexão com a internet.'), findsOneWidget);
        expect(find.text('Sinopse do TMDB'), findsOneWidget, reason: 'rest of the screen intact');
        final details = api.movieDetailsCalls;
        expect(api.castCalls, 1);

        api.castError = null;
        api.cast = [_m(1)];
        await tester.tap(find.text('Tentar novamente'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(api.castCalls, 2);
        expect(api.movieDetailsCalls, details, reason: 'details are not refetched');
        expect(find.text('Ator 1'), findsOneWidget);
      });

      testWidgets('rate limit (429) shows the standard message, no automatic loop', (tester) async {
        api.castError = TmdbException.rateLimited();
        final c = await pumpApp(tester);
        await go(tester, c, '/movie/11');
        expect(find.textContaining('Muitas requisições'), findsOneWidget);
        await tester.pump(const Duration(seconds: 30));
        expect(api.castCalls, 1);
      });

      testWidgets('320 px and 200% text: no overflow in the carousel', (tester) async {
        api.cast = [
          for (var i = 1; i <= 5; i++)
            CastMember(
                id: i,
                name: 'Um nome muito comprido de atriz número $i',
                character: 'Uma personagem com nome bem longo também $i'),
        ];
        final c = await pumpApp(tester, size: const Size(320, 700), textScale: 2);
        await go(tester, c, '/movie/11');
        expect(find.text('Elenco'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    group('full cast', () {
      testWidgets('"Ver todos" lists everyone in TMDB order; back returns to the details',
          (tester) async {
        api.cast = [for (var i = 1; i <= 40; i++) _m(i, character: 'P$i')];
        final c = await pumpApp(tester);
        await go(tester, c, '/movie/11');
        await tester.tap(find.text('Ver todos'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.byType(CastScreen), findsOneWidget);
        expect(path(c), '/movie/11/cast');
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.byType(BrandMark), findsOneWidget, reason: 'logo visible on mobile');
        expect(find.text('Ator 1'), findsOneWidget);
        // Reaches the last person by scrolling the list.
        await tester.dragUntilVisible(
            find.text('Ator 40'), find.byType(ListView), const Offset(0, -300));
        expect(find.text('Ator 40'), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.byType(MovieDetailsScreen), findsOneWidget);
        expect(api.castCalls, 1, reason: 'cached');
      });

      testWidgets('deep link to the full cast of a show; back goes to the show', (tester) async {
        api.cast = [for (var i = 1; i <= 20; i++) _m(i)];
        final c = await pumpApp(tester);
        await go(tester, c, '/tv/12/cast');
        expect(find.byType(CastScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.byType(TvDetailsScreen), findsOneWidget);
      });

      testWidgets('invalid ids on the cast route show not found', (tester) async {
        final c = await pumpApp(tester);
        await go(tester, c, '/movie/abc/cast');
        expect(find.text('Filme não encontrado'), findsOneWidget);
      });
    });

    group('invalid ids', () {
      for (final (location, message) in [
        ('/person/abc', 'Pessoa não encontrada'),
        ('/person/0', 'Pessoa não encontrada'),
        ('/person/-3', 'Pessoa não encontrada'),
        ('/movie/abc', 'Filme não encontrado'),
        ('/tv/abc', 'Série não encontrada'),
      ]) {
        testWidgets('$location shows "$message" without throwing', (tester) async {
          final c = await pumpApp(tester);
          await go(tester, c, location);
          expect(find.text(message), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(api.personCalls, 0);
          await tester.tap(find.text('Ir para o início'));
          await tester.pumpAndSettle(const Duration(seconds: 1));
          expect(path(c), '/');
        });
      }

      testWidgets('unknown person (TMDB 404) shows "Pessoa não encontrada"', (tester) async {
        final c = await pumpApp(tester);
        await go(tester, c, '/person/999999999');
        expect(find.text('Pessoa não encontrada'), findsOneWidget);
        expect(find.text('Tentar novamente'), findsNothing);
      });
    });

    group('person screen', () {
      setUp(() {
        api.people[7] = _person(7, birthday: '1980-06-15');
        api.credits = [
          _c(1, MediaType.movie, 'Filme Antigo', date: '2001-01-01', character: 'Ana'),
          _c(2, MediaType.movie, 'Filme Novo', date: '2023-01-01', character: 'Bia'),
          _c(3, MediaType.tv, 'Série Única', date: '2018-01-01', character: 'Clara'),
        ];
      });

      testWidgets('full profile, no tab bar, logo + back, attribution', (tester) async {
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        expect(find.byType(PersonScreen), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byType(BrandMark), findsOneWidget);
        expect(find.text('Ator 7'), findsWidgets);
        expect(find.text('Atuação'), findsOneWidget);
        expect(find.textContaining('Nascimento: 15/06/1980 ('), findsOneWidget);
        expect(find.text('Local de nascimento: Lisboa, Portugal'), findsOneWidget);
        expect(find.text('Bio em português'), findsOneWidget);
        expect(find.text('Biografia em inglês'), findsNothing);
        expect(find.text('Ler mais'), findsNothing, reason: 'short bio');
        expect(find.text('Conhecido por'), findsOneWidget);
        expect(find.text('Filmes (2)'), findsOneWidget);
        expect(find.text('Séries (1)'), findsOneWidget);
        // Newest first inside Filmes.
        final newer = tester.getTopLeft(find.text('Filme Novo').last).dy;
        final older = tester.getTopLeft(find.text('Filme Antigo').last).dy;
        expect(newer, lessThan(older));

        await tester.scrollUntilVisible(find.text(kTmdbNotice), 300,
            scrollable: find.byType(Scrollable).first);
        expect(find.text('Dados fornecidos pelo TMDB.'), findsOneWidget);
      });

      testWidgets('age uses the injected clock; deceased shows age at death, not current',
          (tester) async {
        api.people[8] = {
          ..._person(8, birthday: '1950-01-10'),
          'deathday': '2010-01-09',
        };
        final c = await pumpApp(tester);
        await go(tester, c, '/person/8');
        expect(find.text('Nascimento: 10/01/1950'), findsOneWidget);
        expect(find.text('Falecimento: 09/01/2010 (59 anos)'), findsOneWidget);
      });

      testWidgets('missing and malformed data are omitted, never "null"', (tester) async {
        api.people[9] = {
          ..._person(9, bio: ''),
          'birthday': '1980-13',
          'place_of_birth': null,
          'known_for_department': null,
        };
        api.peopleEn[9] = {'id': 9, 'biography': ''};
        api.credits = const [];
        final c = await pumpApp(tester);
        await go(tester, c, '/person/9');
        expect(find.textContaining('Nascimento'), findsNothing);
        expect(find.textContaining('Local de nascimento'), findsNothing);
        expect(find.textContaining('null'), findsNothing);
        expect(find.text('Biografia não disponível'), findsOneWidget);
        expect(find.text('Nenhum filme ou série encontrado'), findsOneWidget);
        expect(find.byIcon(Icons.person_outline), findsWidgets);
      });

      testWidgets('English fallback failing is an error, not a cached "no biography"',
          (tester) async {
        api.people[7] = _person(7, bio: '');
        api.peopleEn[7] = _person(7, bio: 'English biography');
        api.personEnError = TmdbException.rateLimited();
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        expect(find.textContaining('Muitas requisições'), findsOneWidget);
        expect(find.text('Biografia não disponível'), findsNothing);
        api.personEnError = null;
        await tester.tap(find.text('Tentar novamente'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.text('English biography'), findsOneWidget);
      });

      testWidgets('profile and filmography are requested in parallel', (tester) async {
        api.personGate = Completer<void>();
        final c = await pumpApp(tester);
        c.read(routerProvider).go('/person/7');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(api.personCalls, 1);
        expect(api.creditsCalls, 1, reason: 'not waiting for the profile');
        api.personGate!.complete();
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.text('Filmes (2)'), findsOneWidget);
      });

      testWidgets('adult profile is shown as not found', (tester) async {
        api.people[7] = {..._person(7), 'adult': true};
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        expect(find.text('Pessoa não encontrada'), findsOneWidget);
      });

      testWidgets('TMDB logo and required notice on the person screen', (tester) async {
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        await tester.scrollUntilVisible(find.text(kTmdbNotice), 300,
            scrollable: find.byType(Scrollable).first);
        expect(find.bySemanticsLabel('Logo do TMDB'), findsOneWidget);
        expect(find.text(kTmdbNotice), findsOneWidget);
        expect(find.text('Dados fornecidos pelo TMDB.'), findsOneWidget);
      });

      testWidgets('TMDB logo and notice on the profile screen', (tester) async {
        final c = await pumpApp(tester, auth: FakeAuthRepository(initialUser: kAna));
        await go(tester, c, '/profile');
        await tester.scrollUntilVisible(find.text(kTmdbNotice), 300,
            scrollable: find.byType(Scrollable).first);
        expect(find.bySemanticsLabel('Logo do TMDB'), findsOneWidget);
      });

      testWidgets('empty pt-BR biography falls back to English with a notice', (tester) async {
        api.people[7] = _person(7, bio: '');
        api.peopleEn[7] = _person(7, bio: 'English biography');
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        expect(find.text('English biography'), findsOneWidget);
        expect(find.text('Biografia em inglês'), findsOneWidget);
        expect(api.personLanguages, [null, 'en-US']);
      });

      testWidgets('long biography: 5 lines, "Ler mais" expands, "Mostrar menos" collapses',
          (tester) async {
        api.people[7] = _person(7, bio: List.filled(80, 'palavra').join(' '));
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        Text bio() => tester.widget<Text>(find
            .byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('palavra palavra')));
        expect(bio().maxLines, 5);
        expect(find.text('Ler mais'), findsOneWidget);
        await tester.tap(find.text('Ler mais'));
        await tester.pumpAndSettle();
        expect(bio().maxLines, isNull);
        expect(find.text('Mostrar menos'), findsOneWidget);
        expect(find.bySemanticsLabel('Mostrar menos'), findsOneWidget);
        expect(
            tester
                .getSemantics(find.bySemanticsLabel('Mostrar menos'))
                .flagsCollection
                .isExpanded
                .name,
            'isTrue');
        await tester.tap(find.text('Mostrar menos'));
        await tester.pumpAndSettle();
        expect(bio().maxLines, 5);
      });

      testWidgets('first 20 of each list, "Mostrar mais" reveals the rest', (tester) async {
        api.credits = [
          for (var i = 1; i <= 45; i++)
            _c(i, MediaType.movie, 'Filme $i', date: '${1950 + i}-01-01'),
        ];
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        final list = find.byType(Scrollable).first;
        expect(find.text('Filmes (45)'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Mostrar mais (25)'), 400, scrollable: list);
        expect(find.text('Filme 26'), findsOneWidget); // 45..26 are the first 20
        expect(find.text('Filme 25'), findsNothing);
        await tester.tap(find.text('Mostrar mais (25)'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Mostrar mais'), findsNothing);
        await tester.scrollUntilVisible(find.text('Filme 1'), 400, scrollable: list);
        expect(find.text('Filme 1'), findsOneWidget);
      });

      testWidgets('credits failing: profile stays, only filmography shows retry', (tester) async {
        api.creditsError = TmdbException.rateLimited();
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        expect(find.text('Bio em português'), findsOneWidget);
        expect(find.textContaining('Muitas requisições'), findsOneWidget);
        final people = api.personCalls;
        api.creditsError = null;
        await tester.tap(find.text('Tentar novamente'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.text('Filmes (2)'), findsOneWidget);
        expect(api.personCalls, people, reason: 'profile not refetched');
      });

      testWidgets('profile failing: full-screen error keeps logo/back and retries', (tester) async {
        api.personError = TmdbException.network();
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        expect(find.text('Sem conexão com a internet.'), findsOneWidget);
        expect(find.byType(BrandMark), findsOneWidget);
        api.personError = null;
        await tester.tap(find.text('Tentar novamente'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.text('Bio em português'), findsOneWidget);
      });

      testWidgets('320 px: no overflow with long names, 200% text', (tester) async {
        api.people[7] = {
          ..._person(7, bio: List.filled(60, 'longa').join(' ')),
          'name': 'Nome Extremamente Comprido De Uma Pessoa Muito Famosa Mesmo',
        };
        api.credits = [
          for (var i = 1; i <= 3; i++)
            _c(i, MediaType.movie, 'Um título de filme realmente muito longo número $i',
                date: '2020-01-01', character: 'Personagem com nome gigantesco e complicado'),
        ];
        final c = await pumpApp(tester, size: const Size(320, 640), textScale: 2);
        await go(tester, c, '/person/7');
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.textContaining('Dados fornecidos'), 300,
            scrollable: find.byType(Scrollable).first);
        expect(tester.takeException(), isNull);
      });

      testWidgets('desktop: no tab bar, content capped to a readable width', (tester) async {
        final c = await pumpApp(tester, size: const Size(1440, 900));
        await go(tester, c, '/person/7');
        expect(find.byType(NavigationBar), findsNothing);
        expect(tester.getSize(find.byType(CustomScrollView)).width, lessThanOrEqualTo(800));
      });

      testWidgets('title tap opens its details (no favorite, signed out); back returns',
          (tester) async {
        api.credits = [_c(11, MediaType.movie, 'Filme X', date: '2019-05-01', character: 'Ana')];
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        await tester.tap(find.bySemanticsLabel('Filme X, 2019, Ana'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(path(c), '/movie/11');
        expect(find.byType(MovieDetailsScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(find.byType(PersonScreen), findsOneWidget);
        expect(api.personCalls, 1, reason: 'cached on the way back');
        expect(api.creditsCalls, 1);
      });

      testWidgets('"Conhecido por" tile opens the title', (tester) async {
        api.credits = [_c(12, MediaType.tv, 'Serie Y', date: '2020-01-01', popularity: 99)];
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        await tester.tap(find.bySemanticsLabel('Serie Y').first);
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(path(c), '/tv/12');
      });

      testWidgets('deep link without history: back button goes to "/"', (tester) async {
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        expect(find.byType(BackButton), findsNothing);
        await tester.tap(find.byTooltip('Ir para o início'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(path(c), '/');
      });

      testWidgets('navigation chain: home > movie > actor > movie > actor, and back step by step',
          (tester) async {
        api.cast = [_m(7, character: 'Ana')];
        api.people[7] = _person(7);
        api.credits = [_c(11, MediaType.movie, 'Filme X', date: '2019-05-01')];
        final c = await pumpApp(tester);
        final router = c.read(routerProvider);
        router.push('/movie/11');
        await tester.pumpAndSettle(const Duration(seconds: 1));
        await tester.tap(find.bySemanticsLabel('Ator 7, Ana'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(path(c), '/person/7');
        await tester.tap(find.bySemanticsLabel('Filme X, 2019'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(path(c), '/movie/11');
        await tester.tap(find.bySemanticsLabel('Ator 7, Ana'));
        await tester.pumpAndSettle(const Duration(seconds: 1));
        expect(path(c), '/person/7');
        for (final expected in ['/movie/11', '/person/7', '/movie/11', '/']) {
          await tester.pageBack();
          await tester.pumpAndSettle(const Duration(seconds: 1));
          expect(path(c), expected);
        }
        expect(api.castCalls, 1);
        expect(api.personCalls, 1);
      });

      testWidgets('signed out: /person is not redirected', (tester) async {
        final c = await pumpApp(tester);
        await go(tester, c, '/person/7');
        expect(path(c), '/person/7');
      });
    });
  });
}
