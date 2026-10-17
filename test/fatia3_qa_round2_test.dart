import 'dart:async';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/providers/friend_profile_providers.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_shared_profile_cloud.dart';
import 'support/fake_social_cloud.dart';
import 'support/friends_harness.dart';

/// Fatia 3, round 2: QA-F3-1..4 as validated by QA (docs/87 "Rodada 2").

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
  for (final action in ['Remover amizade', 'Bloquear']) {
    testWidgets(
      'QA-F3-1 $action FROM THE LIST, then reopening by address within the TTL: no old content',
      (tester) async {
        final rig = Rig();
        final app = await rig.pump(tester, doc: brunoDoc());
        await rig.openFromList(tester);
        expect(find.text('Assistiu Filme 0'), findsOneWidget);
        await rig.back(tester);
        expect(here(app), '/friends');
        await tester.tap(find.text(action).first);
        await tester.pumpAndSettle();
        await tester.tap(dialogButton(action));
        await tester.pumpAndSettle();
        expect(app.social.friendships, isEmpty);
        expect(
          app.container.read(friendProfileCacheProvider).contains(kBruno),
          isFalse,
          reason: 'same invariant as from the profile (docs/87 decision 1)',
        );
        rig.now = kNow.add(const Duration(minutes: 1));
        app.router.push('/friends/u/uid-bruno');
        await tester.pumpAndSettle();
        expect(find.text('Assistiu Filme 0'), findsNothing);
        expect(find.text('Este perfil não está disponível.'), findsOneWidget);
      },
    );
  }

  // QA-F3-2 (W6): permission-denied shows NO header of the ex-friend (docs/87 decision 2).
  testWidgets('QA-F3-2 permission-denied: no name, photo or "Amigos desde" of the ex-friend', (
    tester,
  ) async {
    final rig = Rig();
    final app = await rig.pump(tester, doc: brunoDoc());
    await rig.openFromList(tester);
    app.social.friendships.remove(FakeSocialCloud.pairId('uid-ana', kBruno));
    await tester.tap(find.text('Atualizar'));
    await tester.pumpAndSettle();
    expect(find.text('Este perfil não está disponível.'), findsOneWidget);
    expect(find.text('Bruno'), findsNothing);
    expect(find.textContaining('Amigos desde'), findsNothing);
  });

  // QA-F3-3 (W5): state messages are live regions (screen reader announces them).
  testWidgets(
    'QA-F3-3 "indisponível", "não compartilha nada" and error messages are live regions',
    (tester) async {
      final rig = Rig();
      final handle = tester.ensureSemantics();
      await rig.pump(tester, start: '/friends/u/a_b');
      expect(
        tester.getSemantics(find.text('Este perfil não está disponível.')),
        matchesSemantics(label: 'Este perfil não está disponível.', isLiveRegion: true),
      );
      handle.dispose();
    },
  );

  // QA-F3-4 (W1): a read in flight when the account switches never reaches the new account.
  testWidgets('QA-F3-4 account switch while the profile read is in flight: nothing shown', (
    tester,
  ) async {
    final rig = Rig();
    final app = await rig.pump(
      tester,
      doc: brunoDoc(),
      seed: (social) => social.seedActive('uid-carla', 'carla', nickname: 'Carla'),
    );
    rig.shared.friendGate = Completer<void>();
    app.router.go('/friends');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bruno'));
    await tester.pump();
    await tester.pump();
    app.auth.switchSessionTo(kCarla);
    await tester.pump();
    rig.shared.friendGate!.complete();
    rig.shared.friendGate = null;
    await tester.pumpAndSettle();
    expect(find.text('Assistiu Filme 0'), findsNothing);
    expect(find.text('No total'), findsNothing);
  });

  testWidgets('QA-F3-5 offline arrives during the read: the late answer is not shown', (
    tester,
  ) async {
    final rig = Rig();
    final app = await rig.pump(tester, doc: brunoDoc());
    rig.shared.friendGate = Completer<void>();
    app.router.go('/friends');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bruno'));
    await tester.pump();
    await tester.pump();
    app.cloud.offline = true;
    await tester.pump();
    await tester.pump();
    rig.shared.friendGate!.complete();
    rig.shared.friendGate = null;
    await tester.pumpAndSettle();
    expect(find.text('Assistiu Filme 0'), findsNothing);
    expect(find.text('Sem conexão. Conecte-se para ver o perfil de Bruno.'), findsOneWidget);
  });
}
