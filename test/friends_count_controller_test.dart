import 'dart:async';

import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/providers/friends_count_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/ranking_providers.dart';
import 'package:cinetrack/providers/social_lists_providers.dart';
import 'package:cinetrack/providers/social_providers.dart';
import 'package:cinetrack/social/social_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/favorites_harness.dart';

/// docs/91 §8 (Fatia 2): the "tenho ≥ 1 amigo" signal (O7) and who may open
/// the ranking (O8). Fakes only: the count is a `Completer` per call (one
/// call = one billed aggregate read), the clock is fixed.

const _ana = AppUser(uid: 'uid-ana', displayName: 'Ana', email: 'ana@example.test');
const _bia = AppUser(uid: 'uid-bia', displayName: 'Bia', email: 'bia@example.test');
const _pwd = AppUser(uid: 'uid-pwd', displayName: 'Pwd', isGoogle: false);
final _now = DateTime.utc(2026, 10, 15, 15);

final _offline = StateProvider<bool>((ref) => false);

class _Social extends SocialController {
  _Social(this.initial);
  final SocialPhase initial;

  @override
  SocialState build() => SocialState(phase: initial);

  void set(SocialPhase phase) => state = SocialState(phase: phase);
}

class Rig {
  final auth = StreamController<AppUser?>();
  final store = FakeLocalStore();
  final calls = <Completer<int>>[];
  DateTime now = _now;
  late final ProviderContainer c;

  Rig({SocialPhase phase = SocialPhase.active, void Function(FakeLocalStore s)? hints}) {
    hints?.call(store);
    c = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith((ref) => auth.stream),
        socialControllerProvider.overrideWith(() => _Social(phase)),
        localStoreProvider.overrideWithValue(store),
        socialClockProvider.overrideWithValue(() => now),
        friendsCountReaderProvider.overrideWithValue(() {
          final k = Completer<int>();
          calls.add(k);
          return k.future;
        }),
        socialConnectivityProvider.overrideWith(
          (ref) => (offline: ref.watch(_offline), fromCache: false),
        ),
      ],
    );
    c.listen(friendsCountControllerProvider, (_, _) {});
    c.listen(rankingAccessProvider, (_, _) {});
  }

  Future<void> signIn([AppUser user = _ana]) async {
    auth.add(user);
    await settle();
  }

  FriendsCountController get n => c.read(friendsCountControllerProvider.notifier);
  FriendsCountState get s => c.read(friendsCountControllerProvider);
  RankingAccess get access => c.read(rankingAccessProvider);
  bool get entry => access == RankingAccess.allowed;
  _Social get social => c.read(socialControllerProvider.notifier) as _Social;

  /// `{count, confirmed, inFlight, dirty}` as in the O7 table.
  (int?, bool, bool, bool) get t => (s.count, s.confirmed, s.inFlight, s.dirty);

  Future<void> answer(int n, {int at = -1}) async {
    final k = at < 0 ? calls.last : calls[at];
    k.complete(n);
    await settle();
  }

  Future<void> fail({int at = -1}) async {
    final k = at < 0 ? calls.last : calls[at];
    k.completeError(const SocialFailure(SocialFailureKind.offline));
    await settle();
  }

  /// Puts the controller in `{count, confirmed}` with a server answer.
  Future<void> confirmed(int n) async {
    this.n.onShellShown();
    await settle();
    await answer(n);
    calls.clear();
  }

  void dispose() => c.dispose();
}

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('O7 — transitions of the signal', () {
    late Rig r;
    tearDown(() => r.dispose());

    test('1: build without hint -> {null,F,F,F}, 0 reads, pending, hidden', () async {
      r = Rig();
      await r.signIn();
      expect(r.t, (null, false, false, false));
      expect(r.calls, isEmpty);
      expect(r.access, RankingAccess.pending);
      expect(r.entry, isFalse);
    });

    test('2: fresh hint (-1 h) has=T -> allowed without a read', () async {
      r = Rig(
        hints: (s) => s.friendsHints['uid-ana'] = (
          has: true,
          at: _now.subtract(const Duration(hours: 1)),
        ),
      );
      await r.signIn();
      expect(r.t, (null, false, false, false));
      expect(r.s.hint, isTrue);
      expect(r.calls, isEmpty);
      expect(r.access, RankingAccess.allowed);
      expect(r.entry, isTrue);
    });

    test('3: hint 24 h + 1 s old is ignored (exactly 24 h still counts)', () async {
      r = Rig(
        hints: (s) => s.friendsHints['uid-ana'] = (
          has: true,
          at: _now.subtract(const Duration(hours: 24, seconds: 1)),
        ),
      );
      await r.signIn();
      expect(r.s.hint, isNull);
      expect(r.access, RankingAccess.pending);
      r.dispose();
      r = Rig(
        hints: (s) => s.friendsHints['uid-ana'] = (
          has: true,
          at: _now.subtract(const Duration(hours: 24)),
        ),
      );
      await r.signIn();
      expect(r.access, RankingAccess.allowed);
    });

    test('4: the hint of uid A is never used for uid B', () async {
      r = Rig(hints: (s) => s.friendsHints['uid-ana'] = (has: true, at: _now));
      await r.signIn(_bia);
      expect(r.s.hint, isNull);
      expect(r.calls, isEmpty);
      expect(r.access, RankingAccess.pending);
    });

    test('5-6: first frame of the shell = 1 aggregate; answer 3 -> allowed + hint', () async {
      r = Rig();
      await r.signIn();
      r.n.onShellShown();
      await settle();
      expect(r.t, (null, false, true, false));
      expect(r.calls, hasLength(1));
      expect(r.access, RankingAccess.pending);
      // every later navigation of the shell: no new count
      r.n.onShellShown();
      r.n.onShellShown();
      expect(r.calls, hasLength(1));
      await r.answer(3);
      expect(r.t, (3, true, false, false));
      expect(r.store.friendsHints['uid-ana']!.has, isTrue);
      expect(r.store.friendsHints['uid-ana']!.at, _now);
      expect(r.access, RankingAccess.allowed);
    });

    test('7: answer 0 -> noFriends, hint has=F', () async {
      r = Rig();
      await r.signIn();
      r.n.onShellShown();
      await settle();
      await r.answer(0);
      expect(r.t, (0, true, false, false));
      expect(r.store.friendsHints['uid-ana']!.has, isFalse);
      expect(r.access, RankingAccess.noFriends);
      expect(r.entry, isFalse);
    });

    test('8-9: offline failure -> {null,F,F,F}; navigation does NOT retry; real reconnection does', () async {
      r = Rig();
      await r.signIn();
      r.n.onShellShown();
      await settle();
      await r.fail();
      expect(r.t, (null, false, false, false));
      expect(r.access, RankingAccess.pending);
      r.n.onShellShown();
      await settle();
      expect(r.calls, hasLength(1), reason: 'no count per navigation');
      r.c.read(_offline.notifier).state = true;
      await settle();
      expect(r.calls, hasLength(1));
      r.c.read(_offline.notifier).state = false;
      await settle();
      expect(r.t, (null, false, true, false));
      expect(r.calls, hasLength(2));
    });

    test('10-11: added(Carla) with the list not loaded while a count travels; the answer is discarded', () async {
      r = Rig();
      await r.signIn();
      r.n.onShellShown();
      await settle();
      r.n.added('uid-carla');
      expect(r.t, (1, false, true, true));
      expect(r.access, RankingAccess.allowed);
      await r.answer(0);
      expect(r.t, (1, false, false, false));
      expect(r.access, RankingAccess.allowed);
      expect(r.calls, hasLength(1));
    });

    test('12-13: added on a confirmed count; the same person twice counts once', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(3);
      r.n.added('uid-carla');
      expect(r.t, (4, true, false, false));
      r.n.added('uid-carla');
      expect(r.t, (4, true, false, false));
      expect(r.calls, isEmpty);
      expect(r.access, RankingAccess.allowed);
    });

    test('13b: a person already in the loaded friends list is not counted again', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(1);
      final friends = r.c.read(friendsControllerProvider.notifier);
      // a loaded list with Carla (a server page)
      friends.state = PagedState<Friend>(
        phase: SentPhase.loaded,
        items: const [Friend(uid: 'uid-carla', name: 'Carla')],
        loadedAt: _now,
      );
      r.n.added('uid-carla');
      expect(r.t, (1, true, false, false));
    });

    test('14-16: removed on confirmed counts; 0 stays 0', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(1);
      r.n.removed('uid-carla');
      expect(r.t, (0, true, false, false));
      expect(r.access, RankingAccess.noFriends);
      expect(r.store.friendsHints['uid-ana']!.has, isFalse);
      r.n.removed('uid-x');
      expect(r.t, (0, true, false, false));
      expect(r.calls, isEmpty);
      r.dispose();
      r = Rig();
      await r.signIn();
      await r.confirmed(3);
      r.n.removed('uid-carla');
      expect(r.t, (2, true, false, false));
      expect(r.access, RankingAccess.allowed);
    });

    test('17: removed with nothing known -> one recount', () async {
      r = Rig();
      await r.signIn();
      r.n.removed('uid-carla');
      await settle();
      expect(r.t, (null, false, true, false));
      expect(r.calls, hasLength(1));
    });

    test('18: removed while the count travels -> dirty, one more count AFTER the answer', () async {
      r = Rig();
      await r.signIn();
      r.n.onShellShown();
      await settle();
      r.n.removed('uid-carla');
      expect(r.t, (null, false, true, true));
      expect(r.calls, hasLength(1));
      await r.answer(5, at: 0);
      expect(r.calls, hasLength(2), reason: 'the old answer is discarded and asked again');
      expect(r.t, (null, false, true, false), reason: 'still in flight: nothing blinks');
      await r.answer(4, at: 1);
      expect(r.t, (4, true, false, false));
    });

    test('19: an unconfirmed 1 removed -> 0 unconfirmed = recount, pending', () async {
      r = Rig();
      await r.signIn();
      r.n.added('uid-carla');
      expect(r.t, (1, false, false, false));
      r.n.removed('uid-carla');
      await settle();
      expect(r.t, (0, false, true, false));
      expect(r.calls, hasLength(1));
      expect(r.access, RankingAccess.pending);
    });

    test('19b: removing a person allows adding them again (dedupe is per friendship)', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(2);
      r.n.added('uid-carla');
      r.n.removed('uid-carla');
      r.n.added('uid-carla');
      expect(r.t, (3, true, false, false));
    });

    test('22-23: invalidate on a confirmed count keeps the value until the answer (no blinking)', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(2);
      r.n.invalidate();
      await settle();
      expect(r.t, (2, true, true, false));
      expect(r.access, RankingAccess.allowed);
      // k invalidations while it travels: still ONE more count at most
      expect(r.calls, hasLength(1));
      await r.answer(0);
      expect(r.t, (0, true, false, false));
      expect(r.access, RankingAccess.noFriends);
    });

    test('24: complete first page while a count travels -> confirmed, answer discarded', () async {
      r = Rig();
      await r.signIn();
      r.n.onShellShown();
      await settle();
      r.n.fromFirstPage(2, complete: true);
      expect(r.t, (2, true, true, true));
      expect(r.access, RankingAccess.allowed);
      await r.answer(7);
      expect(r.t, (2, true, false, false));
    });

    test('25: complete empty page -> noFriends; a count in flight stays in flight and is discarded', () async {
      r = Rig();
      await r.signIn();
      r.n.fromFirstPage(0, complete: true);
      expect(r.t, (0, true, false, false));
      expect(r.access, RankingAccess.noFriends);
      r.dispose();
      r = Rig();
      await r.signIn();
      r.n.onShellShown();
      await settle();
      r.n.fromFirstPage(0, complete: true);
      expect(r.t, (0, true, true, true));
      expect(r.access, RankingAccess.noFriends);
      await r.answer(3);
      expect(r.t, (0, true, false, false));
    });

    test('26: a full page with more -> at least 51, not confirmed', () async {
      r = Rig();
      await r.signIn();
      r.n.fromFirstPage(50, complete: false);
      expect(r.t, (51, false, false, false));
      expect(r.access, RankingAccess.allowed);
    });

    test('28: back to the front with a confirmed count reads nothing', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(3);
      r.n.onResume();
      await settle();
      expect(r.calls, isEmpty);
      expect(r.t, (3, true, false, false));
    });

    test('28b: back to the front with an unknown count asks once', () async {
      r = Rig();
      await r.signIn();
      r.n.onShellShown();
      await settle();
      await r.fail();
      r.n.onResume();
      await settle();
      expect(r.calls, hasLength(2));
    });

    test('29: account switch: B starts clean, A answers are ignored, B gets its own count', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(3);
      r.n.invalidate();
      await settle();
      expect(r.calls, hasLength(1));
      await r.signIn(_bia);
      expect(r.s.count, isNull);
      expect(r.calls, hasLength(2), reason: '+1 for the trigger of B');
      await r.answer(9, at: 0); // A's late answer
      expect(r.t, (null, false, true, false));
      expect(r.store.friendsHints.containsKey('uid-bia'), isFalse);
      await r.answer(1, at: 1);
      expect(r.t, (1, true, false, false));
      expect(r.store.friendsHints['uid-ana']!.has, isTrue);
      expect(r.store.friendsHints['uid-bia']!.has, isTrue);
    });

    test('30-31: friendships off -> state dropped, inactive; on again -> line 1 + trigger', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(3);
      r.social.set(SocialPhase.inactive);
      await settle();
      expect(r.t, (null, false, false, false));
      expect(r.access, RankingAccess.inactive);
      expect(r.calls, isEmpty);
      r.social.set(SocialPhase.active);
      await settle();
      expect(r.calls, hasLength(1));
      expect(r.t, (null, false, true, false));
      expect(r.access, RankingAccess.allowed, reason: 'the hint of 3 friends stands in');
    });

    test('a session running on the "friendships on" hint reads NOTHING until confirmed (docs/59)', () async {
      r = Rig(phase: SocialPhase.loading);
      await r.signIn();
      r.n.onShellShown();
      r.n.invalidate();
      r.n.removed('uid-carla');
      await settle();
      expect(r.calls, isEmpty);
      r.social.set(SocialPhase.active);
      await settle();
      expect(r.calls, hasLength(1));
    });

    test('33: a new container (tab reloaded) = new session: hint + one count', () async {
      r = Rig();
      await r.signIn();
      await r.confirmed(2);
      final store = r.store;
      r.dispose();
      r = Rig(hints: (s) => s.friendsHints.addAll(store.friendsHints));
      await r.signIn();
      expect(r.access, RankingAccess.allowed);
      r.n.onShellShown();
      await settle();
      expect(r.calls, hasLength(1));
    });

    test('signed out: no reads, nothing changes', () async {
      r = Rig();
      await r.signIn();
      r.auth.add(null);
      await settle();
      r.n.onShellShown();
      r.n.invalidate();
      r.n.ensureConfirmed();
      await settle();
      expect(r.calls, isEmpty);
      expect(r.access, RankingAccess.noSession);
    });
  });

  group('O8 — rankingAccess (first true row wins)', () {
    late Rig r;
    tearDown(() => r.dispose());

    test('1: session loading -> pending', () async {
      r = Rig();
      await settle();
      expect(r.access, RankingAccess.pending);
    });

    test('2: no session -> noSession', () async {
      r = Rig();
      r.auth.add(null);
      await settle();
      expect(r.access, RankingAccess.noSession);
    });

    test('3: not Google / inactive / unavailable / notGoogle -> inactive', () async {
      r = Rig();
      await r.signIn(_pwd);
      expect(r.access, RankingAccess.inactive);
      for (final phase in [SocialPhase.inactive, SocialPhase.unavailable, SocialPhase.notGoogle]) {
        r.dispose();
        r = Rig(phase: phase, hints: (s) => s.friendsHints['uid-ana'] = (has: true, at: _now));
        await r.signIn();
        expect(r.access, RankingAccess.inactive, reason: '$phase');
      }
    });

    test('4: loadFailed -> pending even with a hint', () async {
      r = Rig(
        phase: SocialPhase.loadFailed,
        hints: (s) => s.friendsHints['uid-ana'] = (has: true, at: _now),
      );
      await r.signIn();
      expect(r.access, RankingAccess.pending);
    });

    test('5: social loading without a fresh has=T hint -> pending; with it -> allowed', () async {
      r = Rig(phase: SocialPhase.loading);
      await r.signIn();
      expect(r.access, RankingAccess.pending);
      r.dispose();
      r = Rig(
        phase: SocialPhase.loading,
        hints: (s) => s.friendsHints['uid-ana'] = (has: false, at: _now),
      );
      await r.signIn();
      expect(r.access, RankingAccess.pending);
      r.dispose();
      r = Rig(
        phase: SocialPhase.loading,
        hints: (s) => s.friendsHints['uid-ana'] = (has: true, at: _now),
      );
      await r.signIn();
      expect(r.access, RankingAccess.allowed);
    });

    test('6: count > 0 (confirmed or local) -> allowed', () async {
      r = Rig();
      await r.signIn();
      r.n.added('uid-carla');
      expect(r.access, RankingAccess.allowed);
    });

    test('7: confirmed 0 -> noFriends even with a has=T hint', () async {
      r = Rig(
        hints: (s) => s.friendsHints['uid-ana'] = (
          has: true,
          at: _now.subtract(const Duration(minutes: 1)),
        ),
      );
      await r.signIn();
      r.n.fromFirstPage(0, complete: true);
      expect(r.access, RankingAccess.noFriends);
    });

    test('8: count unknown + fresh has=T hint -> allowed', () async {
      r = Rig(hints: (s) => s.friendsHints['uid-ana'] = (has: true, at: _now));
      await r.signIn();
      expect(r.access, RankingAccess.allowed);
    });

    test('9: the rest (no hint, has=F hint, unconfirmed 0) -> pending', () async {
      r = Rig(hints: (s) => s.friendsHints['uid-ana'] = (has: false, at: _now));
      await r.signIn();
      expect(r.access, RankingAccess.pending);
      r.n.added('uid-carla');
      r.n.removed('uid-carla'); // unconfirmed 0
      expect(r.s.count, 0);
      expect(r.s.confirmed, isFalse);
      expect(r.access, RankingAccess.pending);
    });
  });
}
