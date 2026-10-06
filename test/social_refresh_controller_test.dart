import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/providers/social_refresh_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_social_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Slice 5 (docs/68): the refresh of nickname / photo in the friendships as the app runs
/// it: background, resumable (flag per uid), coalesced, stopped by deactivation and by
/// an account change, visible only as a discreet state.

void main() {
  late FakeSocialCloud social;
  late FakeAuthRepository auth;
  late FakeLocalStore store;

  ProviderContainer make({void Function(FakeSocialCloud s)? seed, FakeLocalStore? withStore}) {
    social = FakeSocialCloud();
    social
      ..seedActive('uid-ana', 'ana', nickname: 'Ana')
      ..seedActive('uid-bruno', 'bruno', nickname: 'Bruno')
      ..seedActive('uid-caio', 'caio', nickname: 'Caio');
    seed?.call(social);
    auth = FakeAuthRepository(initialUser: kAna);
    store = withStore ?? FakeLocalStore();
    final c = ProviderContainer(
      overrides: cloudOverrides(auth: auth, cloud: FakeCloud(), socialCloud: social, store: store),
    );
    addTearDown(c.dispose);
    c.listen(authStateProvider, (_, _) {});
    c.listen(syncStatusProvider, (_, _) {});
    c.listen(socialControllerProvider, (_, _) {});
    c.listen(socialRefreshProvider, (_, _) {});
    return c;
  }

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void stalePairs(FakeSocialCloud s) => s
    ..seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana Velha', bName: 'Bruno')
    ..seedFriendship('uid-ana', 'uid-caio', aName: 'Ana Velha', bName: 'Caio');

  String anaHalf(String key) => social.friendships[key]!['aName'] as String;

  int batches() => social.log.where((e) => e.startsWith('refreshHalves')).length;

  test(
    'a new nickname reaches every friend in the background; the flag is cleared after',
    () async {
      final c = make(seed: stalePairs);
      await settle();
      expect(await c.read(socialControllerProvider.notifier).updateNickname('Ana Nova'), isNull);
      await settle();
      expect(anaHalf('uid-ana_uid-bruno'), 'Ana Nova');
      expect(anaHalf('uid-ana_uid-caio'), 'Ana Nova');
      expect(
        social.friendships['uid-ana_uid-bruno']!['bName'],
        'Bruno',
        reason: 'their half stays',
      );
      expect(store.socialRefresh, isEmpty);
      expect(c.read(socialRefreshProvider).phase, SocialRefreshPhase.idle);
      expect(batches(), 1);
    },
  );

  test('a photo on/off change is refreshed the same way', () async {
    final c = make(seed: stalePairs);
    await settle();
    // the fake user has no Google photo: turning it on fails visibly and refreshes nothing
    final failure = await c.read(socialControllerProvider.notifier).setPhotoVisible(true);
    expect(failure?.kind, SocialFailureKind.invalid);
    await settle();
    expect(batches(), 0);
    // turning it off works (no photo on the card is already "off": the half still follows)
    expect(await c.read(socialControllerProvider.notifier).setPhotoVisible(false), isNull);
    await settle();
    expect(social.friendships['uid-ana_uid-bruno']!['aPhoto'], isNull);
    expect(anaHalf('uid-ana_uid-bruno'), 'Ana', reason: 'the half also takes the card as it is');
  });

  test('"Aparecer na busca" and the handle never start a refresh', () async {
    final c = make(seed: stalePairs);
    await settle();
    await c.read(socialControllerProvider.notifier).setDiscoverable(false);
    await settle();
    expect(batches(), 0);
    expect(store.socialRefresh, isEmpty);
  });

  test('five quick changes: one pass in flight, ONE more at the end (never five)', () async {
    final c = make(seed: stalePairs);
    await settle();
    social.writeGate = Completer<void>();
    final controller = c.read(socialControllerProvider.notifier);
    await controller.updateNickname('Ana 1');
    await settle();
    expect(c.read(socialRefreshProvider).running, isTrue, reason: 'the first pass is running');
    for (final n in ['Ana 2', 'Ana 3', 'Ana 4', 'Ana 5']) {
      await controller.updateNickname(n);
    }
    await settle();
    expect(store.socialRefresh, {'uid-ana'}, reason: 'the flag is kept while it is not finished');
    social.writeGate!.complete();
    await settle();
    expect(anaHalf('uid-ana_uid-bruno'), 'Ana 5');
    expect(anaHalf('uid-ana_uid-caio'), 'Ana 5');
    expect(batches(), 2, reason: 'one pass with what it saw, one more for the rest: not 5');
    expect(store.socialRefresh, isEmpty);
    expect(c.read(socialRefreshProvider).phase, SocialRefreshPhase.idle);
  });

  test('a failure keeps the flag and shows "failed"; retry finishes and clears it', () async {
    final c = make(seed: stalePairs);
    await settle();
    social.failures['updateHalves'] = const SocialFailure(SocialFailureKind.offline);
    await c.read(socialControllerProvider.notifier).updateNickname('Ana Nova');
    await settle();
    final state = c.read(socialRefreshProvider);
    expect(state.phase, SocialRefreshPhase.failed);
    expect(state.failure?.kind, SocialFailureKind.offline);
    expect(store.socialRefresh, {'uid-ana'});
    expect(anaHalf('uid-ana_uid-bruno'), 'Ana Velha');
    // the card itself did change: nothing was lost
    expect(social.handles['ana']!['nickname'], 'Ana Nova');
    c.read(socialRefreshProvider.notifier).retry();
    await settle();
    expect(anaHalf('uid-ana_uid-bruno'), 'Ana Nova');
    expect(store.socialRefresh, isEmpty);
    expect(c.read(socialRefreshProvider).phase, SocialRefreshPhase.idle);
  });

  test(
    'resumes after a restart: the flag on the device + a fresh load of the social state',
    () async {
      final saved = FakeLocalStore()..socialRefresh.add('uid-ana');
      final c = make(
        withStore: saved,
        seed: (s) {
          stalePairs(s);
          s.handles['ana']!['nickname'] = 'Ana Nova'; // the card changed before the app closed
        },
      );
      await settle();
      expect(anaHalf('uid-ana_uid-bruno'), 'Ana Nova');
      expect(anaHalf('uid-ana_uid-caio'), 'Ana Nova');
      expect(saved.socialRefresh, isEmpty);
      expect(c.read(socialRefreshProvider).phase, SocialRefreshPhase.idle);
    },
  );

  test(
    'nothing pending, nothing happens: no reads of the friendships for a quiet session',
    () async {
      make(seed: stalePairs);
      await settle();
      expect(social.readLog.where((e) => e == 'friends:page'), isEmpty);
      expect(batches(), 0);
    },
  );

  test('the flag of an account with friendships OFF does nothing (no reads, no writes)', () async {
    final saved = FakeLocalStore()..socialRefresh.add('uid-ana');
    make(
      withStore: saved,
      seed: (s) {
        s.social.remove('uid-ana');
        s.handles.remove('ana');
        s.seedFriendship('uid-ana', 'uid-bruno', aName: 'Ana Velha');
      },
    );
    await settle();
    expect(social.readLog.where((e) => e == 'friends:page'), isEmpty);
    expect(batches(), 0);
  });

  test('deactivating while it runs stops it, forgets the flag and leaves nothing behind', () async {
    final c = make(seed: stalePairs);
    await settle();
    social.writeGate = Completer<void>();
    await c.read(socialControllerProvider.notifier).updateNickname('Ana Nova');
    await settle();
    expect(c.read(socialRefreshProvider).running, isTrue);
    final done = c.read(socialControllerProvider.notifier).deactivate();
    await settle();
    social.writeGate!.complete();
    expect(await done, isNull);
    await settle();
    expect(social.leftoversOf('uid-ana'), isEmpty);
    expect(store.socialRefresh, isEmpty);
    expect(c.read(socialRefreshProvider).phase, SocialRefreshPhase.idle);
    expect(social.friendships, isEmpty);
    expect(batches(), 0, reason: 'the in-flight batch found the pairs gone and wrote nothing');
  });

  test('a deactivation that FAILS keeps the refresh pending and goes on with it', () async {
    final c = make(seed: stalePairs);
    await settle();
    social.failures['readSweep:friendships'] = const SocialFailure(SocialFailureKind.offline);
    store.socialRefresh.add('uid-ana');
    final failure = await c.read(socialControllerProvider.notifier).deactivate();
    expect(failure, isNotNull);
    await settle();
    expect(social.social.containsKey('uid-ana'), isTrue, reason: 'still on');
    expect(anaHalf('uid-ana_uid-bruno'), 'Ana', reason: 'the pending refresh continued');
    expect(store.socialRefresh, isEmpty, reason: 'and finished');
  });

  test(
    'a deactivation that works forgets the flag; one that fails before closing keeps it',
    () async {
      final c = make(seed: stalePairs);
      await settle();
      social.writeGate = Completer<void>();
      await c.read(socialControllerProvider.notifier).updateNickname('Ana Nova');
      await settle();
      expect(store.socialRefresh, {'uid-ana'});
      social.failures['readSweep:friendships'] = const SocialFailure(SocialFailureKind.offline);
      final failed = c.read(socialControllerProvider.notifier).deactivate();
      await settle();
      social.writeGate!.complete();
      expect(await failed, isNotNull);
      await settle();
      expect(store.socialRefresh, isEmpty, reason: 'it resumed and finished after the failure');
      expect(anaHalf('uid-ana_uid-bruno'), 'Ana Nova');
    },
  );

  test('changing account mid-run: the other account is untouched and keeps no state', () async {
    final c = make(
      seed: (s) {
        stalePairs(s);
        s.seedFriendship('uid-bruno', 'uid-caio', aName: 'Bruno Velho', bName: 'Caio');
      },
    );
    await settle();
    social.writeGate = Completer<void>();
    await c.read(socialControllerProvider.notifier).updateNickname('Ana Nova');
    await settle();
    expect(c.read(socialRefreshProvider).running, isTrue);
    await c.read(authControllerProvider.notifier).signOut();
    await settle();
    auth.nextUser = kBruno;
    await auth.signInWithGoogle();
    await settle();
    social.writeGate!.complete();
    await settle();
    expect(c.read(socialRefreshProvider).phase, SocialRefreshPhase.idle);
    expect(store.socialRefresh, {'uid-ana'}, reason: 'Ana\'s flag stays for her next session');
    expect(anaHalf('uid-bruno_uid-caio'), 'Bruno Velho', reason: 'Bruno\'s pairs are not touched');
  });

  test('Ana\'s unfinished refresh continues when she comes back; Bruno never sees it', () async {
    final saved = FakeLocalStore()..socialRefresh.add('uid-ana');
    final c = make(withStore: saved, seed: stalePairs);
    await settle();
    // it already ran for Ana on this start; stale it again and flag it
    social.friendships['uid-ana_uid-bruno']!['aName'] = 'Ana Velha';
    saved.socialRefresh.add('uid-ana');
    await c.read(authControllerProvider.notifier).signOut();
    await settle();
    auth.nextUser = kBruno;
    await auth.signInWithGoogle();
    await settle();
    expect(anaHalf('uid-ana_uid-bruno'), 'Ana Velha', reason: 'not Bruno\'s business');
    await c.read(authControllerProvider.notifier).signOut();
    await settle();
    auth.nextUser = kAna;
    await auth.signInWithGoogle();
    await settle();
    expect(anaHalf('uid-ana_uid-bruno'), 'Ana');
    expect(saved.socialRefresh, isEmpty);
  });

  test('account deletion forgets the flag of the deleted uid', () async {
    final saved = FakeLocalStore()..socialRefresh.add('uid-ana');
    final c = make(withStore: saved);
    await settle();
    expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
    expect(saved.socialRefresh, isEmpty);
  });
}
