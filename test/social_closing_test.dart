import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/providers/social_refresh_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:cinetrack/screens/profile_screen.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:cinetrack/widgets/social_section.dart' show kPhotoOffHint, kPhotoOnHint;

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_social_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Closing slice of phase 1 (docs/73): 🟡-1 (a busy section never answers "done") and
/// 🟡-2 (the Google photo of the account follows to the card once per session).

const _old = 'https://lh3.googleusercontent.com/a/velha';
const _new = 'https://lh3.googleusercontent.com/a/nova';

AppUser _ana({String? photo}) =>
    AppUser(uid: 'uid-ana', displayName: 'Ana Teste', email: 'ana@example.test', photoUrl: photo);

class _Rig {
  final social = FakeSocialCloud();
  final cloud = FakeCloud();
  final store = FakeLocalStore();
  late final FakeAuthRepository auth;

  _Rig({String? googlePhoto, String? cardPhoto = _old, bool seed = true}) {
    auth = FakeAuthRepository(initialUser: _ana(photo: googlePhoto));
    if (seed) {
      social
        ..seedActive('uid-ana', 'ana', nickname: 'Ana', photoUrl: cardPhoto, inviteCode: _code)
        ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno')
        ..seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana', bName: 'Bruno');
      // Ana's half carries the photo that is on her card now.
      social.friendships['uid-ana_uid-bruno']!['aPhoto'] = cardPhoto;
      // The invite must still be valid (the card update carries its copy).
      social.invites[_code]!['expiresAt'] = DateTime.now().add(const Duration(days: 10));
      social.invites[_code]!['photoURL'] = cardPhoto;
    }
  }

  static const _code = 'AbCdEfGhIjKlMnOpQrStUv12';

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: cloudOverrides(auth: auth, cloud: cloud, socialCloud: social, store: store),
    );
    addTearDown(c.dispose);
    c.listen(authStateProvider, (_, _) {});
    c.listen(syncStatusProvider, (_, _) {});
    c.listen(socialControllerProvider, (_, _) {});
    c.listen(socialRefreshProvider, (_, _) {});
    return c;
  }

  /// A later session of the same account (a new sign-in): new container, a fresh device
  /// store (no hint, so the state is read from the server), the Google photo of that sign-in.
  ProviderContainer session({String? googlePhoto}) {
    final c = ProviderContainer(
      overrides: cloudOverrides(
        auth: FakeAuthRepository(initialUser: _ana(photo: googlePhoto)),
        cloud: cloud,
        socialCloud: social,
        store: FakeLocalStore(),
      ),
    );
    addTearDown(c.dispose);
    c.listen(authStateProvider, (_, _) {});
    c.listen(syncStatusProvider, (_, _) {});
    c.listen(socialControllerProvider, (_, _) {});
    c.listen(socialRefreshProvider, (_, _) {});
    return c;
  }

  int cardUpdates() => social.log.where((e) => e == 'updateCard').length;
  Object? cardPhoto() => social.handles['ana']!['photoURL'];
  Object? invitePhoto() => social.invites[_code]!['photoURL'];
  Object? halfPhoto() => social.friendships['uid-ana_uid-bruno']!['aPhoto'];
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('🟡-1: an operation while another runs is refused, never "done"', () {
    test('updateNickname while the section is busy: busy failure; card and app nickname '
        'unchanged; no refresh', () async {
      final rig = _Rig(googlePhoto: _old);
      final c = rig.container();
      await _settle();
      final controller = c.read(socialControllerProvider.notifier);
      rig.social.writeGate = Completer<void>();
      final slow = controller.createInvite(); // holds "busy" (waits for the server)
      await _settle();
      expect(c.read(socialControllerProvider).busy, isTrue);

      final failure = await controller.updateNickname('Ana Nova');
      expect(failure?.kind, SocialFailureKind.busy);
      expect(failure?.message, 'Aguarde a operação anterior terminar.');
      expect(rig.social.handles['ana']!['nickname'], 'Ana', reason: 'nothing reached the card');
      expect(rig.cloud.profiles['uid-ana']?.nickname, isNull, reason: 'nor users/{uid}');
      expect(rig.social.log.where((e) => e.startsWith('refreshHalves')), isEmpty);

      rig.social.writeGate!.complete();
      expect(await slow, isNull);
      await _settle();
      // Once free, the same call works.
      expect(await controller.updateNickname('Ana Nova'), isNull);
      expect(rig.social.handles['ana']!['nickname'], 'Ana Nova');
    });

    test('deactivate while busy: busy, friendships stay on, no "off" hint, no cleanup flag', () async {
      final rig = _Rig(googlePhoto: _old);
      final c = rig.container();
      await _settle();
      final controller = c.read(socialControllerProvider.notifier);
      rig.social.writeGate = Completer<void>();
      final slow = controller.revokeInvite();
      await _settle();
      final failure = await controller.deactivate();
      expect(failure?.kind, SocialFailureKind.busy);
      expect(rig.social.social.containsKey('uid-ana'), isTrue);
      expect(rig.store.socialHint('uid-ana')?.active, isNot(false));
      expect(rig.store.socialCleanupPending('uid-ana'), isFalse);
      rig.social.writeGate!.complete();
      await slow;
    });
  });

  group('🟡-2: the Google photo follows to the card once per session', () {
    test('changed: ONE card update (invite copy too) and the friendship half follows', () async {
      final rig = _Rig(googlePhoto: _new);
      rig.container();
      await _settle();
      expect(rig.cardUpdates(), 1);
      expect(rig.cardPhoto(), _new);
      expect(rig.invitePhoto(), _new);
      expect(rig.halfPhoto(), _new, reason: 'the existing refresh carries it to the pairs');
    });

    test('removed from Google: the card loses the photo (null), invite and half too', () async {
      final rig = _Rig(googlePhoto: null);
      rig.container();
      await _settle();
      expect(rig.cardUpdates(), 1);
      expect(rig.cardPhoto(), isNull);
      expect(rig.invitePhoto(), isNull);
      expect(rig.halfPhoto(), isNull);
    });

    test('photo removed at Google (provider photo null): the card goes without a photo, never '
        'back to the account-creation photo (docs/76 🟡-R2, docs/77 P1)', () async {
      // Composition: the REAL photo choice (pickPhotoUrl) feeds the AppUser the sync reads.
      const creation = 'https://lh3.googleusercontent.com/a/foto-da-criacao-da-conta';
      final photo = pickPhotoUrl(
        topLevel: creation, // filled when the account was created, never refreshed
        providers: const [(providerId: 'google.com', photoUrl: null)], // removed at Google
      );
      final rig = _Rig(googlePhoto: photo);
      final c = rig.container();
      await _settle();
      expect(rig.cardUpdates(), 1);
      expect(rig.cardPhoto(), isNull);
      expect(rig.invitePhoto(), isNull);
      expect(rig.halfPhoto(), isNull);
      for (final url in [rig.cardPhoto(), rig.invitePhoto(), rig.halfPhoto()]) {
        expect(url, isNot(creation));
      }
      expect(c.read(socialControllerProvider).profile!.photoVisible, isFalse, reason: 'switch off');
    });

    test('same photo: zero writes', () async {
      final rig = _Rig(googlePhoto: _old);
      rig.container();
      await _settle();
      expect(rig.cardUpdates(), 0);
      expect(rig.social.log.where((e) => e.startsWith('refreshHalves')), isEmpty);
    });

    test('photo turned off by the user: stays off even with a Google photo', () async {
      final rig = _Rig(googlePhoto: _new, cardPhoto: null);
      rig.container();
      await _settle();
      expect(rig.cardUpdates(), 0);
      expect(rig.cardPhoto(), isNull);
    });

    test('offline (state from the device): nothing is written', () async {
      final rig = _Rig(googlePhoto: _new)..social.offline = true;
      rig.container();
      await _settle();
      expect(rig.cardUpdates(), 0);
      expect(rig.cardPhoto(), _old);
    });

    test('offline: the photo sync is not even attempted; back online in the same session the '
        'first server read syncs it (docs/75 N3)', () async {
      final rig = _Rig(googlePhoto: _new)..social.offline = true;
      final c = rig.container();
      await _settle();
      expect(c.read(socialControllerProvider).fromCache, isTrue, reason: 'state from the device');
      expect(rig.social.attempts, isEmpty, reason: 'no write is even tried from the cache');
      rig.social.offline = false;
      await c.read(socialControllerProvider.notifier).refresh();
      await _settle();
      expect(rig.social.attempts, ['updateCard']);
      expect(rig.cardUpdates(), 1);
      expect(rig.cardPhoto(), _new);
    });

    test('Google photo removed, then a new one in a later session: the card stays without a '
        'photo until the user turns it back on; turning it on uses the new photo', () async {
      // Session 1: the Google account has no photo anymore -> card without photo, switch off.
      final rig = _Rig(googlePhoto: null);
      final first = rig.container();
      await _settle();
      expect(rig.cardPhoto(), isNull);
      expect(first.read(socialControllerProvider).profile!.photoVisible, isFalse);
      first.dispose();

      // Session 2 (a later sign-in): Google has a NEW photo. Re-enabling is manual.
      final second = rig.session(googlePhoto: _new);
      await _settle();
      expect(second.read(socialControllerProvider).phase, SocialPhase.active);
      expect(rig.cardPhoto(), isNull, reason: 'never comes back by itself');
      expect(second.read(socialControllerProvider).profile!.photoVisible, isFalse);
      expect(rig.cardUpdates(), 1, reason: 'only the removal of session 1 was written');

      // The user turns "Mostrar minha foto" on: the NEW Google photo is used.
      expect(await second.read(socialControllerProvider.notifier).setPhotoVisible(true), isNull);
      await _settle();
      expect(rig.cardPhoto(), _new);
      expect(rig.invitePhoto(), _new);
      expect(rig.halfPhoto(), _new);
    });

    test('no loop: later reads in the same session do not write again', () async {
      final rig = _Rig(googlePhoto: _new);
      final c = rig.container();
      await _settle();
      expect(rig.cardUpdates(), 1);
      // Somebody (another device) puts the old photo back: this session already checked.
      rig.social.handles['ana']!['photoURL'] = _old;
      await c.read(socialControllerProvider.notifier).refresh();
      await _settle();
      expect(rig.cardUpdates(), 1);
    });

    test('a Google URL that fails the rules\' test is not copied: the card loses the photo', () async {
      final rig = _Rig(googlePhoto: 'https://evil.example/a.png');
      rig.container();
      await _settle();
      expect(rig.cardUpdates(), 1);
      expect(rig.cardPhoto(), isNull);
    });

    test('friendships off: nothing is read or written for the photo', () async {
      final rig = _Rig(googlePhoto: _new, seed: false);
      rig.container();
      await _settle();
      expect(rig.social.log, isEmpty);
    });
  });

  testWidgets('🟡-1: the header "Editar apelido" is disabled while a friendships operation runs', (
    tester,
  ) async {
    final rig = _Rig(googlePhoto: _old);
    await tester.pumpWidget(
      ProviderScope(
        overrides: cloudOverrides(
          auth: rig.auth,
          cloud: rig.cloud,
          socialCloud: rig.social,
          store: rig.store,
        ),
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pumpAndSettle();
    Finder header() => find.ancestor(
      of: find.text('Definir apelido'),
      matching: find.bySubtype<ButtonStyleButton>(),
    );
    ButtonStyleButton button() => tester.widget<ButtonStyleButton>(header());
    expect(button().onPressed, isNotNull);

    final container = ProviderScope.containerOf(tester.element(find.byType(ProfileScreen)));
    rig.social.writeGate = Completer<void>();
    unawaited(container.read(socialControllerProvider.notifier).createInvite());
    await tester.pump();
    expect(button().onPressed, isNull, reason: 'locked while busy');

    rig.social.writeGate!.complete();
    await tester.pumpAndSettle();
    expect(button().onPressed, isNotNull, reason: 'free again');
  });

  for (final (label, googlePhoto, hint) in [
    ('removed from Google: switch off with the "turn it back on" explanation', null, kPhotoOffHint),
    ('photo shown: the hint says when a Google change arrives', _old, kPhotoOnHint),
  ]) {
    testWidgets('"Mostrar minha foto": $label', (tester) async {
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rig = _Rig(googlePhoto: googlePhoto);
      await tester.pumpWidget(
        ProviderScope(
          overrides: cloudOverrides(
            auth: rig.auth,
            cloud: rig.cloud,
            socialCloud: rig.social,
            store: rig.store,
          ),
          child: const MaterialApp(home: ProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Mostrar minha foto'),
      );
      expect(tile.value, googlePhoto != null);
      expect(find.text(hint), findsOneWidget);
      expect(hint == kPhotoOffHint ? hint.contains('ligue "Mostrar minha foto"') : true, isTrue);
    });
  }
}

