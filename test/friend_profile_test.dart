import 'dart:async';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/providers/friend_profile_providers.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/providers/social_lists_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/screens/friend_profile_screen.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_shared_profile_cloud.dart';
import 'support/fake_social_cloud.dart';
import 'support/friends_harness.dart';

/// Fatia 3: the friend's profile (docs/82 §7.2, docs/81 RF-F, docs/83 B6/B7).
/// Full app over the fakes: real router, providers and screens.

/// 15/10/2026 12:00 in America/Sao_Paulo (UTC-3).
final kNow = DateTime.utc(2026, 10, 15, 15);
const kBruno = 'uid-bruno';
const kCarla = AppUser(
  uid: 'uid-carla',
  displayName: 'Carla Teste',
  email: 'carla@example.test',
  photoUrl: 'https://lh3.googleusercontent.com/a/carla',
);

Map<String, dynamic> brunoStats({Map<String, Object?>? month, Map<String, Object?>? total}) => {
  'total':
      total ??
      {
        'favorites': 54,
        'movies': 20,
        'series': 34,
        'watchedMovies': 12,
        'watchedEpisodes': 300,
        'watchedSeries': 10,
        'completedSeries': 3,
        'minutes': 20000,
        'estimated': 5,
        'unknown': 2,
      },
  'year': {
    'key': '2026',
    'watchedMovies': 3,
    'watchedEpisodes': 40,
    'watchedSeries': 4,
    'completedSeries': 1,
    'minutes': 2100,
    'estimated': 0,
    'unknown': 0,
  },
  'month':
      month ??
      {
        'key': '2026-10',
        'watchedMovies': 1,
        'watchedEpisodes': 12,
        'watchedSeries': 2,
        'completedSeries': 0,
        'minutes': 600,
        'estimated': 0,
        'unknown': 0,
      },
  'undatedMovies': 2,
  'undatedEpisodes': 260,
  'datedFrom': DateTime.utc(2026, 10, 11, 22, 10),
  'memberSince': DateTime.utc(2025, 3, 2, 10),
};

Map<String, Object?> movieActivity(int i, {String? title, String? poster}) => {
  'type': 'watched_movie',
  'id': 100 + i,
  'mediaType': 'movie',
  'title': title ?? 'Filme $i',
  'poster': ?poster,
  'at': kNow.subtract(Duration(hours: i + 1)),
};

Map<String, dynamic> brunoDoc({
  bool stats = true,
  bool activity = true,
  int activities = 10,
  Map<String, dynamic>? statsOverride,
  List<Object?>? activityOverride,
  Map<String, Object?> extra = const {},
}) => {
  'v': 1,
  'calc': 1,
  'updatedAt': kNow.subtract(const Duration(hours: 2)),
  'tz': -180,
  'sharing': {if (stats) 'stats': true, if (activity) 'activity': true},
  if (activity) 'actSince': DateTime.utc(2026, 10, 1),
  if (stats) 'stats': statsOverride ?? brunoStats(),
  if (activity)
    'activity': activityOverride ?? [for (var i = 0; i < activities; i++) movieActivity(i)],
  ...extra,
};

class Rig {
  DateTime now = kNow;
  final shared = FakeSharedProfileCloud();
  late FriendsApp app;

  Future<FriendsApp> pump(
    WidgetTester tester, {
    Map<String, dynamic>? doc,
    bool befriend = true,
    String? start,
    Size size = const Size(390, 3000),
    double textScale = 1,
    Brightness brightness = Brightness.light,
    bool active = true,
    void Function(FakeSocialCloud social)? seed,
  }) async {
    if (doc != null) shared.docs[kBruno] = doc;
    app = await pumpFriends(
      tester,
      size: size,
      textScale: textScale,
      brightness: brightness,
      active: active,
      shared: shared,
      start: start,
      seed: (social) {
        if (befriend) social.seedFriendship('uid-ana', kBruno, aName: 'Ana', bName: 'Bruno');
        seed?.call(social);
      },
      extraOverrides: [sharedProfileClockProvider.overrideWithValue(() => now)],
    );
    return app;
  }

  /// Opens `/friends` and taps Bruno's card (the list hands the card over).
  Future<void> openFromList(WidgetTester tester) async {
    if (here(app) != '/friends') {
      app.router.go('/friends');
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Bruno'));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.text('Voltar'));
    await tester.pumpAndSettle();
  }
}

/// The top route (a push does not change the address bar in go_router 14).
String here(FriendsApp app) => app.router.state.uri.path;

Finder dialogButton(String label) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(label));

void main() {
  group('entry and header', () {
    testWidgets('tapping the card opens /friends/u/<uid>; header before the read ends; 1 read', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      app.router.go('/friends');
      await tester.pumpAndSettle();
      rig.shared.friendGate = Completer<void>();
      await tester.tap(find.text('Bruno'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // transition over, read still held
      expect(here(app), '/friends/u/uid-bruno');
      // RF-F3: the pair's card is there while the read is still pending.
      Finder onProfile(Finder f) =>
          find.descendant(of: find.byType(FriendProfileScreen), matching: f);
      expect(onProfile(find.text('Bruno')), findsOneWidget);
      expect(onProfile(find.textContaining('Amigos desde ')), findsOneWidget);
      expect(find.bySemanticsLabel('Carregando o perfil'), findsWidgets);
      expect(app.friendReads, ['readFriend:uid-bruno']);
      rig.shared.friendGate!.complete();
      await tester.pumpAndSettle();
      // Cold from the list: ONE get (the rule's isFriend is the second billed read).
      expect(app.friendReads, ['readFriend:uid-bruno']);
      expect(app.pairReads, isEmpty);
      expect(find.bySemanticsLabel('Filmes assistidos: 12'), findsOneWidget);
      expect(find.text('Atualizado há 2 h'), findsOneWidget);
      // D8: "No CineTrack desde" in the header, only because stats are shared.
      expect(find.text('No CineTrack desde 02/03/2025'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the card is a button for the keyboard too (Enter opens the profile)', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc(), start: '/friends');
      final card = find.ancestor(of: find.text('Bruno'), matching: find.byType(InkWell));
      Focus.of(tester.element(find.text('Bruno'))).requestFocus();
      await tester.pump();
      expect(card, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(here(app), '/friends/u/uid-bruno');
    });

    testWidgets('by address with no list in memory: the pair, then the profile (2 reads)', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc(), start: '/friends/u/uid-bruno');
      expect(app.pairReads, ['friendship:uid-bruno']);
      expect(app.friendReads, ['readFriend:uid-bruno']);
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.textContaining('Amigos desde '), findsOneWidget);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
    });

    testWidgets('by address, not a friend (no pair): "indisponível", the profile is NOT read', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc(), befriend: false);
      app.router.go('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(find.text('Este perfil não está disponível.'), findsOneWidget);
      expect(find.text('Voltar para Amigos'), findsOneWidget);
      expect(app.pairReads, ['friendship:uid-bruno']);
      expect(app.friendReads, isEmpty);
      await tester.tap(find.text('Voltar para Amigos'));
      await tester.pumpAndSettle();
      expect(here(app), '/friends');
    });

    for (final uid in ['a_b', 'x' * 129, '%2F..%2F', 'a%2Fb']) {
      testWidgets(
        'malformed uid "${uid.length > 20 ? '129 chars' : uid}": "indisponível", 0 reads',
        (tester) async {
          final rig = Rig();
          final app = await rig.pump(tester, doc: brunoDoc());
          app.router.go('/friends/u/$uid');
          await tester.pumpAndSettle();
          expect(find.text('Este perfil não está disponível.'), findsOneWidget);
          expect(app.pairReads, isEmpty);
          expect(app.friendReads, isEmpty);
        },
      );
    }

    testWidgets('own uid goes to /profile without a read', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      app.router.go('/friends/u/uid-ana');
      await tester.pumpAndSettle();
      expect(here(app), '/profile');
      expect(app.pairReads, isEmpty);
      expect(app.friendReads, isEmpty);
    });

    testWidgets('friendships off: the gate of /friends, nothing is read', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc(), active: false, befriend: false);
      app.router.go('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(find.textContaining('ative as amizades no seu Perfil'), findsOneWidget);
      expect(app.pairReads, isEmpty);
      expect(app.friendReads, isEmpty);
    });

    testWidgets('signed out: back to the start', (tester) async {
      final app = await pumpFriends(tester, user: null);
      app.router.go('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(here(app), '/');
    });
  });

  group('memory cache with TTL (D15, B6)', () {
    testWidgets('reopen at 4:59 = 0 reads; at 5:00 = 1 read', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      expect(app.friendReads.length, 1);
      await rig.back(tester);
      rig.now = kNow.add(const Duration(minutes: 4, seconds: 59));
      await rig.openFromList(tester);
      expect(app.friendReads.length, 1);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
      await rig.back(tester);
      rig.now = kNow.add(const Duration(minutes: 5));
      await rig.openFromList(tester);
      expect(app.friendReads.length, 2);
    });

    testWidgets('"Atualizar" ignores the TTL: 1 read per tap', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(app.friendReads.length, 2);
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(app.friendReads.length, 3);
    });

    testWidgets('reopening by address within the TTL: 0 reads (pair and profile in memory)', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc(), start: '/friends/u/uid-bruno');
      app.router.go('/');
      await tester.pumpAndSettle();
      app.router.go('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(app.pairReads.length, 1);
      expect(app.friendReads.length, 1);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
    });

    testWidgets('permission-denied: neutral text, cache and list entry gone AT ONCE', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
      // Bruno removes the friendship on another device; Ana taps "Atualizar".
      app.social.friendships.remove(FakeSocialCloud.pairId('uid-ana', kBruno));
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(find.text('Este perfil não está disponível.'), findsOneWidget);
      expect(find.text('Assistiu Filme 0'), findsNothing);
      expect(find.text('Remover amizade'), findsNothing);
      final list = app.container.read(friendsControllerProvider).items;
      expect(list.any((f) => f.uid == kBruno), isFalse);
      expect(app.container.read(friendProfileCacheProvider).contains(kBruno), isFalse);
      // Reopened within the TTL: never the old content (a new read decides).
      app.router.go('/');
      await tester.pumpAndSettle();
      final before = app.pairReads.length + app.friendReads.length;
      app.router.go('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(app.pairReads.length + app.friendReads.length, before + 1);
      expect(find.text('Assistiu Filme 0'), findsNothing);
      expect(find.text('Este perfil não está disponível.'), findsOneWidget);
    });

    testWidgets('ex-friend reopening within the TTL without "Atualizar" (accepted risk D15)', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      await rig.back(tester);
      app.social.friendships.remove(FakeSocialCloud.pairId('uid-ana', kBruno));
      rig.now = kNow.add(const Duration(minutes: 2));
      await rig.openFromList(tester);
      // The same content seen 2 min ago, nothing newer.
      expect(app.friendReads.length, 1);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(find.text('Este perfil não está disponível.'), findsOneWidget);
    });

    testWidgets('offline: header + "Sem conexão", NOTHING from memory (D10), 0 reads', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      await rig.back(tester);
      app.cloud.offline = true;
      await tester.pumpAndSettle();
      rig.now = kNow.add(const Duration(minutes: 1));
      await rig.openFromList(tester);
      expect(find.text('Sem conexão. Conecte-se para ver o perfil de Bruno.'), findsOneWidget);
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.text('Assistiu Filme 0'), findsNothing);
      expect(find.text('No total'), findsNothing);
      expect(find.textContaining('Atualizado'), findsNothing);
      expect(app.friendReads.length, 1);
      // Back online: shown again (from memory while fresh).
      app.cloud.offline = false;
      await tester.pumpAndSettle();
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
    });

    testWidgets('going offline with the profile on screen hides it after "Atualizar"', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      app.cloud.offline = true;
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Atualizar')).onPressed,
        isNull,
      );
    });

    testWidgets('account switch: nothing of the previous account is shown (cache emptied)', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(
        tester,
        doc: brunoDoc(),
        seed: (social) => social.seedActive('uid-carla', 'carla', nickname: 'Carla'),
      );
      await rig.openFromList(tester);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
      app.auth.switchSessionTo(kCarla);
      await tester.pumpAndSettle();
      app.router.go('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(find.text('Assistiu Filme 0'), findsNothing);
      expect(find.text('Este perfil não está disponível.'), findsOneWidget);
    });

    testWidgets('turning friendships off and on (new period) empties the cache', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      final first = app.container.read(friendProfileCacheProvider);
      expect(first.contains(kBruno), isTrue);
      app.container.read(socialEpochProvider.notifier).state++;
      expect(identical(app.container.read(friendProfileCacheProvider), first), isFalse);
      expect(app.container.read(friendProfileCacheProvider).contains(kBruno), isFalse);
    });
  });

  group('server answer -> screen state (B7)', () {
    testWidgets('stats + activities, 3 of 10 shown, tap opens the title', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      for (var i = 0; i < 3; i++) {
        expect(find.text('Assistiu Filme $i'), findsOneWidget);
      }
      expect(find.text('Assistiu Filme 3'), findsNothing);
      // The cut is in the owner's current month AND year: under both.
      expect(
        find.text('Marcações feitas antes de 11/10/2026 contam só no total.'),
        findsNWidgets(2),
      );
      await tester.tap(find.text('Assistiu Filme 0'));
      await tester.pumpAndSettle();
      expect(here(app), '/movie/100');
    });

    testWidgets('not-found: "ainda não compartilha nada além do cartão", cached', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester);
      await rig.openFromList(tester);
      expect(find.text('Bruno ainda não compartilha nada além do cartão.'), findsOneWidget);
      expect(find.text('No CineTrack desde 02/03/2025'), findsNothing);
      await rig.back(tester);
      await rig.openFromList(tester);
      expect(app.friendReads.length, 1);
      expect(find.text('Bruno ainda não compartilha nada além do cartão.'), findsOneWidget);
    });

    testWidgets('only activities: "não compartilha estatísticas", no "No CineTrack desde"', (
      tester,
    ) async {
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc(stats: false));
      await rig.openFromList(tester);
      expect(find.text('Bruno não compartilha estatísticas com amigos.'), findsOneWidget);
      expect(find.textContaining('No CineTrack desde'), findsNothing);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
    });

    testWidgets('only statistics: "não compartilha atividades"', (tester) async {
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc(activity: false));
      await rig.openFromList(tester);
      expect(find.text('Bruno não compartilha atividades com amigos.'), findsOneWidget);
      expect(find.text('No total'), findsOneWidget);
    });

    testWidgets('activities on but empty: "ainda não tem atividades recentes"', (tester) async {
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc(activities: 0));
      await rig.openFromList(tester);
      expect(find.text('Bruno ainda não tem atividades recentes.'), findsOneWidget);
    });

    testWidgets('unavailable while online: "Não foi possível carregar o perfil." + retry', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      rig.shared.failNext(
        'readFriend',
        const SocialFailure(SocialFailureKind.offline, code: 'unavailable'),
      );
      await rig.openFromList(tester);
      expect(find.text('Não foi possível carregar o perfil.'), findsOneWidget);
      expect(find.text('Assistiu Filme 0'), findsNothing);
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(app.friendReads.length, 2);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
    });

    testWidgets('timeout of 8 s (online): "Não foi possível carregar o perfil."', (tester) async {
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc());
      rig.shared.failNext(
        'readFriend',
        const SocialFailure(SocialFailureKind.offline, code: 'timeout'),
      );
      await rig.openFromList(tester);
      expect(find.text('Não foi possível carregar o perfil.'), findsOneWidget);
    });

    testWidgets('an error never shows what is in memory', (tester) async {
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      rig.shared.failNext(
        'readFriend',
        const SocialFailure(SocialFailureKind.offline, code: 'unavailable'),
      );
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(find.text('Não foi possível carregar o perfil.'), findsOneWidget);
      expect(find.text('Assistiu Filme 0'), findsNothing);
    });

    testWidgets('quota: the existing message + "Tentar novamente"', (tester) async {
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc());
      rig.shared.failNext(
        'readFriend',
        const SocialFailure(SocialFailureKind.quotaExceeded, code: 'resource-exhausted'),
      );
      await rig.openFromList(tester);
      expect(find.text('Muitas operações hoje. Tente de novo amanhã.'), findsOneWidget);
      expect(find.text('Tentar novamente'), findsOneWidget);
    });

    testWidgets('unauthenticated: the expired-session message with "Entrar"', (tester) async {
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc());
      rig.shared.failNext(
        'readFriend',
        const SocialFailure(SocialFailureKind.sessionExpired, code: 'unauthenticated'),
      );
      await rig.openFromList(tester);
      expect(find.textContaining('Sessão expirada'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Entrar'), findsOneWidget);
    });

    testWidgets('interrupted deletion (pair still there, no document): "não compartilha nada"', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester);
      await rig.openFromList(tester);
      expect(find.text('Bruno ainda não compartilha nada além do cartão.'), findsOneWidget);
      // The deletion ends: the pair goes, the next read is denied.
      app.social.friendships.remove(FakeSocialCloud.pairId('uid-ana', kBruno));
      await tester.tap(find.text('Atualizar'));
      await tester.pumpAndSettle();
      expect(find.text('Este perfil não está disponível.'), findsOneWidget);
    });

    testWidgets('a pair read that fails offline-like while online: error, retry reads both', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      app.social.failures['friendship'] = const SocialFailure(SocialFailureKind.unknown);
      app.router.go('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(find.text('Não foi possível carregar o perfil.'), findsOneWidget);
      expect(app.friendReads, isEmpty);
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(app.pairReads.length, 2);
      expect(app.friendReads.length, 1);
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
    });
  });

  group('defensive reading (RF-F9)', () {
    testWidgets('newer schema: unknown fields ignored, missing numbers show "—" (never 0)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final stats = brunoStats(
        month: {
          'key': '2026-10',
          'watchedMovies': 1,
          'watchedEpisodes': 12,
          // no watchedSeries (older writer) and a field from the future
          'completedSeries': 0,
          'minutes': 600,
          'rankPoints': 99,
        },
        total: {
          'favorites': 54,
          'movies': 20,
          'series': 34,
          'watchedMovies': 12,
          'watchedEpisodes': '300', // wrong type (newer writer): unknown
          'watchedSeries': 10,
          'completedSeries': 3,
          // no minutes
        },
      );
      final rig = Rig();
      await rig.pump(
        tester,
        doc: brunoDoc(
          statsOverride: stats,
          activityOverride: [
            {'type': 'rated', 'id': 1, 'mediaType': 'movie', 'title': 'X', 'at': kNow},
            movieActivity(0),
            {'type': 'watched_movie', 'id': 'bad'},
          ],
          extra: {
            'v': 2,
            'rankPoints': 7,
            'badges': ['a'],
          },
        ),
      );
      await rig.openFromList(tester);
      expect(find.bySemanticsLabel('Séries assistidas: sem informação'), findsOneWidget);
      expect(find.bySemanticsLabel('Episódios assistidos: sem informação'), findsOneWidget);
      expect(find.bySemanticsLabel('Episódios assistidos: 0'), findsNothing);
      expect(find.text('—'), findsNWidgets(2));
      expect(find.text('Tempo assistido: —'), findsOneWidget);
      expect(find.bySemanticsLabel('Filmes assistidos: 12'), findsOneWidget);
      // Only the well-formed activity is listed.
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
      expect(find.byType(ListTile), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('older document (no dates fields): tolerated, no note', (tester) async {
      final stats = brunoStats()
        ..remove('undatedMovies')
        ..remove('undatedEpisodes')
        ..remove('datedFrom')
        ..remove('memberSince');
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc(statsOverride: stats));
      await rig.openFromList(tester);
      expect(find.text('No total'), findsOneWidget);
      expect(find.textContaining('contam só no total'), findsNothing);
      expect(find.textContaining('No CineTrack desde'), findsNothing);
    });

    testWidgets('a month of the past shows 0 for "Este mês" (owner zone), "Atualizado há N dias"', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final rig = Rig();
      final doc = brunoDoc(
        statsOverride: brunoStats(
          month: {
            'key': '2026-09',
            'watchedMovies': 7,
            'watchedEpisodes': 70,
            'watchedSeries': 7,
            'completedSeries': 7,
            'minutes': 700,
            'estimated': 0,
            'unknown': 0,
          },
        ),
      )..['updatedAt'] = kNow.subtract(const Duration(days: 20));
      await rig.pump(tester, doc: doc);
      await rig.openFromList(tester);
      expect(find.bySemanticsLabel('Filmes assistidos: 7'), findsNothing);
      expect(find.text('Atualizado há 20 dias'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('title without poster and a 300-char title: icon, ellipsis, full sentence read', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final long = 'L' * 300;
      final rig = Rig();
      await rig.pump(
        tester,
        doc: brunoDoc(
          activityOverride: [
            movieActivity(0, title: long),
            movieActivity(1),
          ],
        ),
      );
      await rig.openFromList(tester);
      expect(find.byIcon(Icons.movie_outlined), findsNWidgets(2));
      final text = tester.widget<Text>(find.text('Assistiu $long'));
      expect(text.overflow, TextOverflow.ellipsis);
      expect(find.bySemanticsLabel(RegExp('^Assistiu $long, há 1 h')), findsOneWidget);
      semantics.dispose();
    });
  });

  group('Remover / Bloquear from the profile (Phase 1 flows)', () {
    testWidgets('Remover: confirmation, back to /friends with the message, cache cleared', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      await tester.tap(find.text('Remover amizade'));
      await tester.pumpAndSettle();
      expect(find.text('Remover Bruno?'), findsOneWidget);
      expect(find.textContaining('A pessoa não será avisada.'), findsOneWidget);
      await tester.tap(dialogButton('Remover amizade'));
      await tester.pumpAndSettle();
      expect(here(app), '/friends');
      expect(find.text('Amizade removida.'), findsOneWidget);
      expect(find.bySemanticsLabel('Abrir o perfil de Bruno'), findsNothing);
      expect(app.social.friendships, isEmpty);
      expect(app.container.read(friendProfileCacheProvider).contains(kBruno), isFalse);
      // Reopened at once (within the TTL): a read decides, never the old copy.
      app.router.push('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(find.text('Assistiu Filme 0'), findsNothing);
      expect(find.text('Este perfil não está disponível.'), findsOneWidget);
    });

    testWidgets('Remover cancelled: nothing happens', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      await tester.tap(find.text('Remover amizade'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(here(app), '/friends/u/uid-bruno');
      expect(app.social.friendships, isNotEmpty);
    });

    testWidgets('Bloquear: Phase 1 batch, back to /friends, in Bloqueados, cache cleared', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      expect(find.text('Bloquear Bruno?'), findsOneWidget);
      await tester.tap(dialogButton('Bloquear'));
      await tester.pumpAndSettle();
      expect(here(app), '/friends');
      expect(find.text('Pessoa bloqueada. Ela não foi avisada.'), findsOneWidget);
      expect(app.social.blocks['uid-ana']?.containsKey(kBruno), isTrue);
      expect(app.social.friendships, isEmpty);
      expect(app.container.read(friendProfileCacheProvider).contains(kBruno), isFalse);
      app.router.push('/friends/u/uid-bruno');
      await tester.pumpAndSettle();
      expect(find.text('Assistiu Filme 0'), findsNothing);
      expect(find.text('Este perfil não está disponível.'), findsOneWidget);
    });

    testWidgets('in progress: "Removendo..." and both buttons locked', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      app.social.writeGate = Completer<void>();
      await tester.tap(find.text('Remover amizade'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Remover amizade'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Removendo...'), findsOneWidget);
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Bloquear')).onPressed,
        isNull,
      );
      app.social.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(here(app), '/friends');
    });

    testWidgets('offline: both disabled with the Phase 1 reason', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      app.cloud.offline = true;
      await tester.pumpAndSettle();
      expect(find.text('Sem conexão. Remover amigos exige internet.'), findsOneWidget);
      for (final label in ['Remover amizade', 'Bloquear']) {
        expect(tester.widget<TextButton>(find.widgetWithText(TextButton, label)).onPressed, isNull);
      }
    });

    testWidgets('server error: the Phase 1 message, stays on the profile, cache cleared', (
      tester,
    ) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      app.social.failures['removeFriend'] = const SocialFailure(SocialFailureKind.unknown);
      await tester.tap(find.text('Remover amizade'));
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Remover amizade'));
      await tester.pumpAndSettle();
      expect(find.text('Não foi possível concluir. Tente novamente.'), findsOneWidget);
      expect(here(app), '/friends/u/uid-bruno');
      expect(find.text('Assistiu Filme 0'), findsOneWidget);
      expect(app.container.read(friendProfileCacheProvider).contains(kBruno), isFalse);
    });
  });

  group('keyboard, screen reader, layout', () {
    testWidgets('focus starts on "Voltar"; Tab: Atualizar, each activity, Remover, Bloquear', (
      tester,
    ) async {
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      String focused() {
        final focus = FocusManager.instance.primaryFocus?.context;
        if (focus == null) return '?';
        final texts = find.descendant(
          of: find.byElementPredicate((e) => e == focus),
          matching: find.byType(Text),
        );
        final words = [for (final t in tester.widgetList<Text>(texts)) t.data ?? ''];
        return words.isEmpty ? '?' : words.first;
      }

      final order = [focused()];
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        order.add(focused());
      }
      expect(order, [
        'Voltar',
        'Atualizar',
        'Assistiu Filme 0',
        'Assistiu Filme 1',
        'Assistiu Filme 2',
        'Remover amizade',
        'Bloquear',
      ]);
    });

    testWidgets('Esc goes back to the friends list', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(here(app), '/friends');
    });

    testWidgets('a deep link has no history: "Voltar" goes to /friends', (tester) async {
      final rig = Rig();
      final app = await rig.pump(tester, doc: brunoDoc(), start: '/friends/u/uid-bruno');
      await rig.back(tester);
      expect(here(app), '/friends');
    });

    testWidgets('screen reader labels: stats "<rótulo>: <valor>", buttons with the name', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final rig = Rig();
      await rig.pump(tester, doc: brunoDoc());
      await rig.openFromList(tester);
      expect(find.bySemanticsLabel('Favoritos: 54'), findsOneWidget);
      expect(find.bySemanticsLabel('Séries concluídas: 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Atualizar o perfil de Bruno'), findsOneWidget);
      expect(find.bySemanticsLabel('Remover amizade com Bruno'), findsOneWidget);
      expect(find.bySemanticsLabel('Bloquear Bruno'), findsOneWidget);
      expect(find.bySemanticsLabel('Voltar para Amigos'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Assistiu Filme 0, há 1 h')), findsOneWidget);
      semantics.dispose();
    });

    for (final width in [320.0, 375.0, 768.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 2.0, 3.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('layout $width px, ${scale}x, ${brightness.name}: no overflow', (
            tester,
          ) async {
            final rig = Rig();
            await rig.pump(
              tester,
              doc: brunoDoc(
                activityOverride: [
                  movieActivity(0, title: 'T' * 300),
                  movieActivity(1),
                ],
              ),
              size: Size(width, 900),
              textScale: scale,
              brightness: brightness,
              start: '/friends/u/uid-bruno',
            );
            expect(tester.takeException(), isNull);
            expect(find.text('Bruno'), findsOneWidget);
            await tester.drag(find.byType(Scrollable).last, const Offset(0, -3000));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    for (final scale in [1.0, 3.0]) {
      testWidgets('320 px ${scale}x: unavailable and offline states fit', (tester) async {
        final rig = Rig();
        final app = await rig.pump(tester, size: const Size(320, 700), textScale: scale);
        app.router.go('/friends/u/a_b');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Este perfil não está disponível.'), findsOneWidget);
        app.cloud.offline = true;
        app.router.go('/friends/u/uid-bruno');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Sem conexão. Conecte-se para ver'), findsOneWidget);
      });
    }
  });
}
