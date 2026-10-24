import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_social_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// docs/91 O7 rows 30 and 32 (Fatia 2): the "has friends" hint of the ranking
/// entry never outlives friendships turned off or the deleted account.
Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('O7-32: deleting the account forgets friendsHint of that uid (and only it)', () async {
    final store = FakeLocalStore()
      ..friendsHints['uid-ana'] = (has: true, at: DateTime.now())
      ..friendsHints['uid-other'] = (has: true, at: DateTime.now());
    final auth = FakeAuthRepository(initialUser: kAna);
    final c = ProviderContainer(
      overrides: cloudOverrides(auth: auth, cloud: FakeCloud(), store: store),
    );
    addTearDown(c.dispose);
    c.listen(authStateProvider, (_, _) {});
    c.listen(syncStatusProvider, (_, _) {});
    await settle();
    expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
    expect(store.friendsHints.containsKey('uid-ana'), isFalse);
    expect(store.friendsHints.containsKey('uid-other'), isTrue);
  });

  test('O7-30: turning friendships off forgets friendsHint of that uid', () async {
    final store = FakeLocalStore()..friendsHints['uid-ana'] = (has: true, at: DateTime.now());
    final social = FakeSocialCloud()..seedActive('uid-ana', 'ana', nickname: 'Ana');
    final auth = FakeAuthRepository(initialUser: kAna);
    final c = ProviderContainer(
      overrides: cloudOverrides(auth: auth, cloud: FakeCloud(), store: store, socialCloud: social),
    );
    addTearDown(c.dispose);
    c.listen(authStateProvider, (_, _) {});
    c.listen(syncStatusProvider, (_, _) {});
    c.listen(socialControllerProvider, (_, _) {});
    await settle();
    expect(c.read(socialControllerProvider).phase, SocialPhase.active);
    expect(store.friendsHints.containsKey('uid-ana'), isTrue);
    expect(await c.read(socialControllerProvider.notifier).deactivate(), isNull);
    await settle();
    expect(c.read(socialControllerProvider).phase, SocialPhase.inactive);
    expect(store.friendsHints.containsKey('uid-ana'), isFalse);
  });
}
