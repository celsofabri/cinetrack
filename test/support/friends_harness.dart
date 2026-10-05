import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/main.dart' show CineTrackApp;
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/router.dart';

import 'cloud_overrides.dart';
import 'fake_auth_repository.dart';
import 'fake_social_cloud.dart';
import 'favorites_harness.dart';
import 'in_memory_favorites_data_source.dart';

/// Full-app harness of the friends screens: real router and providers over
/// the in-memory fakes (no Firebase, no network).
const kAnaGoogle = AppUser(
  uid: 'uid-ana',
  displayName: 'Ana Teste',
  email: 'ana@example.test',
  photoUrl: 'https://lh3.googleusercontent.com/a/ana',
);

class FriendsApp {
  final ProviderContainer container;
  final FakeSocialCloud social;
  final FakeCloud cloud;
  final FakeAuthRepository auth;

  FriendsApp(this.container, this.social, this.cloud, this.auth);

  GoRouter get router => container.read(routerProvider);
  String get location => router.routeInformationProvider.value.uri.path;

  /// Reads of the social state, lists and searches. The badge's aggregate
  /// `count()` (slice 3, one per TTL while the icon shows) is separate:
  /// [countReads].
  List<String> get reads => [
    for (final r in social.readLog)
      if (r != 'countReceived') r,
  ];

  List<String> get countReads => [
    for (final r in social.readLog)
      if (r == 'countReceived') r,
  ];
}

Future<FriendsApp> pumpFriends(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  Brightness brightness = Brightness.light,
  AppUser? user = kAnaGoogle,
  bool active = true,
  bool rulesLive = true,
  Duration ttl = const Duration(minutes: 5),
  String? start,
  FakeAuthRepository? authOverride,
  FakeLocalStore? store,
  void Function(FakeSocialCloud social)? seed,
  List<Override> extraOverrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);

  final social = FakeSocialCloud();
  if (active) {
    social
      ..seedActive('uid-ana', 'ana', nickname: 'Ana', photoUrl: kAnaGoogle.photoUrl)
      ..seedActive(
        'uid-bruno',
        'bruno',
        nickname: 'Bruno',
        photoUrl: 'https://lh4.googleusercontent.com/b',
      );
  } else {
    social.seedActive('uid-bruno', 'bruno', nickname: 'Bruno');
  }
  seed?.call(social);
  social.rulesLive = rulesLive;

  final cloud = FakeCloud();
  final auth = authOverride ?? FakeAuthRepository(initialUser: user);
  final container = ProviderContainer(
    overrides: [
      ...cloudOverrides(auth: auth, cloud: cloud, socialCloud: social, store: store),
      sentRequestsTtlProvider.overrideWithValue(ttl),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const CineTrackApp()),
  );
  await tester.pumpAndSettle(const Duration(seconds: 1));
  final app = FriendsApp(container, social, cloud, auth);
  if (start != null) {
    app.router.go(start);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }
  return app;
}

Finder btn(String label) =>
    find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>());

Future<void> searchHandle(WidgetTester tester, String handle) async {
  await tester.enterText(find.byType(TextField), handle);
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void addSentRequests(FakeSocialCloud social, int n, {String Function(int i)? name}) {
  final base = DateTime.now().subtract(const Duration(days: 40));
  for (var i = 0; i < n; i++) {
    social.requests['uid-ana_uid-t$i'] = {
      'from': 'uid-ana',
      'to': 'uid-t$i',
      'fromName': 'Ana',
      'toName': name?.call(i) ?? 'Pessoa $i',
      'createdAt': base.add(Duration(hours: i)),
    };
  }
}

/// [n] pending requests addressed to Ana from people who have friendships on.
void addReceivedRequests(FakeSocialCloud social, int n, {String Function(int i)? name}) {
  final base = DateTime.now().subtract(const Duration(days: 40));
  for (var i = 0; i < n; i++) {
    social.seedActive('uid-r$i', 'recebe$i', nickname: name?.call(i) ?? 'Remetente $i');
    social.requests['uid-r${i}_uid-ana'] = {
      'from': 'uid-r$i',
      'to': 'uid-ana',
      'fromName': name?.call(i) ?? 'Remetente $i',
      'toName': 'Ana',
      'createdAt': base.add(Duration(hours: i)),
    };
  }
}

/// [n] friends of Ana (names "Amigo 0".. unless [name]).
void addFriends(FakeSocialCloud social, int n, {String Function(int i)? name}) {
  for (var i = 0; i < n; i++) {
    social.seedActive('uid-f$i', 'amigo$i', nickname: name?.call(i) ?? 'Amigo $i');
    social.seedFriendship('uid-ana', 'uid-f$i', aName: 'Ana', bName: name?.call(i) ?? 'Amigo $i');
  }
}
