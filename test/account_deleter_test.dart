import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/account/account_deleter.dart';
import 'package:cinetrack/account/account_deletion_failure.dart';
import 'package:cinetrack/account/session_expiry.dart';
import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/data/profile_data_source.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

FavoriteDoc _doc(int id) => FavoriteDoc(
      id: id,
      mediaType: MediaType.movie,
      title: 'Filme $id',
      posterPath: null,
      overview: '',
      addedAt: DateTime(2026, 1, 1),
    );

/// Deleting the profile is the moment another tab switches the session to
/// Bruno (shared browser session).
class _SwitchingProfile extends InMemoryProfileDataSource {
  _SwitchingProfile(super.cloud, this.auth) : super(uid: 'uid-ana');

  final FakeAuthRepository auth;

  @override
  Future<void> deleteProfile() async {
    await super.deleteProfile();
    auth.switchSessionTo(kBruno);
  }
}

class _Rig {
  final cloud = FakeCloud();
  final auth = FakeAuthRepository(initialUser: kAna);
  late final profile = InMemoryProfileDataSource(cloud, uid: 'uid-ana');
  final expectedSignOut = <String>[];
  late final deleter = AccountDeleter(
    uid: 'uid-ana',
    auth: auth,
    profile: profile,
    onBeforeUserDelete: () => expectedSignOut.add('expect'),
    onDeleteAborted: () => expectedSignOut.add('cancel'),
  );

  _Rig() {
    cloud.server['uid-ana'] = {'1-movie': _doc(1), '2-movie': _doc(2)};
    cloud.profiles['uid-ana'] = const UserProfile(nickname: 'Ana');
  }

  Future<AccountDeletionFailure?> run() async {
    try {
      await deleter.run();
      return null;
    } on AccountDeletionFailure catch (f) {
      return f;
    }
  }
}

void main() {
  group('AccountDeleter', () {
    test('happy path: reauth, online check, marker, favorites, profile, then the user', () async {
      final rig = _Rig();
      final steps = <AccountDeletionStep>[];

      await rig.deleter.run(onStep: steps.add);

      expect(rig.auth.reauthCalls, 1);
      expect(rig.cloud.deletionLog,
          ['ensureOnline', 'markDeleting', 'deleteAllFavorites', 'deleteProfile']);
      expect(rig.cloud.server['uid-ana'], isEmpty);
      expect(rig.cloud.profiles['uid-ana'], isNull);
      expect(rig.auth.deleteUserCalls, 1);
      expect(steps, [
        AccountDeletionStep.reauthenticating,
        AccountDeletionStep.deletingData,
        AccountDeletionStep.deletingAccount,
      ]);
      expect(rig.expectedSignOut, ['expect']);
    });

    test('reauthentication starts synchronously (web popup must open inside the tap)', () {
      final rig = _Rig();
      rig.deleter.run(); // no await on purpose
      expect(rig.auth.reauthCalls, 1);
    });

    test('offline: nothing is deleted and the user is told', () async {
      final rig = _Rig();
      rig.cloud.offline = true;

      final failure = await rig.run();

      expect(failure!.kind, AccountDeletionFailureKind.offline);
      expect(rig.cloud.server['uid-ana'], hasLength(2));
      expect(rig.cloud.profiles['uid-ana']!.nickname, 'Ana');
      expect(rig.cloud.deletionLog, isEmpty);
      expect(rig.auth.deleteUserCalls, 0);
    });

    test('closing the Google window cancels without touching any data', () async {
      final rig = _Rig();
      rig.auth.reauthFailure = const AuthFailure(AuthFailureKind.cancelled);

      final failure = await rig.run();

      expect(failure!.kind, AccountDeletionFailureKind.cancelled);
      expect(rig.cloud.server['uid-ana'], hasLength(2));
      expect(rig.cloud.deletionLog, isEmpty);
    });

    test('a different Google account is refused before anything is deleted', () async {
      final rig = _Rig();
      rig.auth.reauthFailure = const AuthFailure(AuthFailureKind.wrongAccount);

      final failure = await rig.run();

      expect(failure!.kind, AccountDeletionFailureKind.wrongAccount);
      expect(rig.cloud.deletionLog, isEmpty);
      expect(rig.auth.deleteUserCalls, 0);
    });

    test('popup blocked and network on reauth are mapped', () async {
      final rig = _Rig();
      rig.auth.reauthFailure = const AuthFailure(AuthFailureKind.popupBlocked);
      expect((await rig.run())!.kind, AccountDeletionFailureKind.popupBlocked);
      rig.auth.reauthFailure = const AuthFailure(AuthFailureKind.network);
      expect((await rig.run())!.kind, AccountDeletionFailureKind.offline);
    });

    test('failure halfway through the data: marker stays, retry finishes (resumable)', () async {
      final rig = _Rig();
      rig.cloud.deletionFailures['deleteAllFavorites'] =
          const AccountDeletionFailure(AccountDeletionFailureKind.offline);

      final failure = await rig.run();

      expect(failure!.kind, AccountDeletionFailureKind.offline);
      expect(rig.cloud.profiles['uid-ana']!.deleting, isTrue); // resume is offered
      expect(rig.auth.deleteUserCalls, 0); // account untouched until data is gone

      expect(await rig.run(), isNull); // second attempt completes

      expect(rig.cloud.server['uid-ana'], isEmpty);
      expect(rig.cloud.profiles['uid-ana'], isNull);
      expect(rig.auth.deleteUserCalls, 1);
    });

    test('failure deleting the Firebase user: marker is written again so it can be resumed',
        () async {
      final rig = _Rig();
      rig.auth.deleteUserFailure = const AuthFailure(AuthFailureKind.sessionExpired);

      final failure = await rig.run();

      expect(failure!.kind, AccountDeletionFailureKind.sessionExpired);
      expect(rig.cloud.server['uid-ana'], isEmpty);
      expect(rig.cloud.profiles['uid-ana']!.deleting, isTrue);
      expect(rig.expectedSignOut, ['expect', 'cancel']);

      rig.auth.deleteUserFailure = null;
      expect(await rig.run(), isNull);
      expect(rig.auth.deleteUserCalls, 2);
    });

    test('another tab switched the session: reauth refuses before any popup (I4)', () async {
      final rig = _Rig();
      rig.auth.switchSessionTo(kBruno);

      final failure = await rig.run();

      expect(failure!.kind, AccountDeletionFailureKind.wrongAccount);
      expect(rig.cloud.deletionLog, isEmpty);
      expect(rig.auth.deleteUserCalls, 0);
    });

    test('session switched to another account mid-way: never deletes the other user (I4)',
        () async {
      final cloud = FakeCloud();
      final auth = FakeAuthRepository(initialUser: kAna);
      cloud.server['uid-ana'] = {'1-movie': _doc(1)};
      final profile = _SwitchingProfile(cloud, auth);
      final deleter = AccountDeleter(uid: 'uid-ana', auth: auth, profile: profile);

      await expectLater(
        deleter.run(),
        throwsA(isA<AccountDeletionFailure>()
            .having((f) => f.kind, 'kind', AccountDeletionFailureKind.wrongAccount)),
      );

      expect(auth.currentForTest, kBruno); // Bruno's account is intact
      // The marker is not rewritten from a session that is not Ana's.
      expect(cloud.deletionLog.where((e) => e == 'markDeleting'), hasLength(1));
    });

    group('Firebase user delete lost to a network error (I3)', () {
      test('the user is really gone: success, sign out, marker NOT rewritten', () async {
        final rig = _Rig();
        rig.auth
          ..deleteUserFailure = const AuthFailure(AuthFailureKind.network)
          ..useExistsAnswer = true
          ..userExistsAnswer = false;

        expect(await rig.run(), isNull);

        expect(rig.cloud.profiles['uid-ana'], isNull); // no orphan users/{uid}
        expect(rig.cloud.deletionLog.where((e) => e == 'markDeleting'), hasLength(1));
        expect(rig.auth.signOutCalls, 1);
        expect(rig.expectedSignOut, ['expect', 'cancel', 'expect']);
      });

      test('the user still exists: marker is rewritten so the deletion can resume', () async {
        final rig = _Rig();
        rig.auth.deleteUserFailure = const AuthFailure(AuthFailureKind.network);

        final failure = await rig.run();

        expect(failure!.kind, AccountDeletionFailureKind.offline);
        expect(rig.cloud.profiles['uid-ana']!.deleting, isTrue);
      });

      test('cannot tell: no write under a uid that may not exist, says "uncertain"', () async {
        final rig = _Rig();
        rig.auth
          ..deleteUserFailure = const AuthFailure(AuthFailureKind.network)
          ..useExistsAnswer = true
          ..userExistsAnswer = null;

        final failure = await rig.run();

        expect(failure!.kind, AccountDeletionFailureKind.uncertain);
        expect(rig.cloud.profiles['uid-ana'], isNull);
        expect(rig.cloud.deletionLog.where((e) => e == 'markDeleting'), hasLength(1));
      });
    });

    test('running it again after success is harmless: no session, nothing to redo', () async {
      final rig = _Rig();
      await rig.deleter.run();
      final again = await rig.run();
      expect(again!.kind, AccountDeletionFailureKind.sessionExpired);
      expect(rig.cloud.server['uid-ana'], isEmpty);
    });
  });

  group('AccountController', () {
    ProviderContainer container(FakeAuthRepository auth, FakeCloud cloud) {
      final c = ProviderContainer(overrides: cloudOverrides(auth: auth, cloud: cloud));
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      c.listen(sessionExpiryProvider, (_, _) {});
      c.listen(syncStatusProvider, (_, _) {});
      return c;
    }

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('success: true, user signed out and NOT reported as an expired session', () async {
      final cloud = FakeCloud();
      cloud.server['uid-ana'] = {'1-movie': _doc(1)};
      final auth = FakeAuthRepository(initialUser: kAna);
      final c = container(auth, cloud);
      await settle();

      final deleted = await c.read(accountControllerProvider.notifier).deleteAccount();
      await settle();

      expect(deleted, isTrue);
      expect(c.read(currentUserProvider), isNull);
      expect(c.read(sessionExpiryProvider), isFalse);
      expect(cloud.server['uid-ana'], isEmpty);
    });

    test('success schedules the wipe of the local Firestore cache (logout never does)', () async {
      final store = FakeLocalStore();
      final auth = FakeAuthRepository(initialUser: kAna);
      final c = ProviderContainer(
        overrides: cloudOverrides(auth: auth, cloud: FakeCloud(), store: store),
      );
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      c.listen(syncStatusProvider, (_, _) {});
      await settle();

      await c.read(authControllerProvider.notifier).signOut();
      await settle();
      expect(store.purgePending, isFalse); // plain logout: nothing is cleared

      auth.nextUser = kAna;
      await auth.signInWithGoogle();
      await settle();
      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
      expect(store.purgePending, isTrue);
    });

    test('a failed deletion does not schedule any wipe', () async {
      final store = FakeLocalStore();
      final auth = FakeAuthRepository(initialUser: kAna)
        ..reauthFailure = const AuthFailure(AuthFailureKind.cancelled);
      final c = ProviderContainer(
        overrides: cloudOverrides(auth: auth, cloud: FakeCloud(), store: store),
      );
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      c.listen(syncStatusProvider, (_, _) {});
      await settle();

      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isFalse);
      expect(store.purgePending, isFalse);
    });

    test('offline up front: failure without opening the Google popup', () async {
      final cloud = FakeCloud();
      final auth = FakeAuthRepository(initialUser: kAna);
      final c = container(auth, cloud);
      await settle();
      cloud.offline = true;
      await settle();

      final deleted = await c.read(accountControllerProvider.notifier).deleteAccount();

      expect(deleted, isFalse);
      expect(auth.reauthCalls, 0);
      expect(c.read(accountControllerProvider).failure!.kind, AccountDeletionFailureKind.offline);
    });

    test('a second tap while running is ignored', () async {
      final cloud = FakeCloud();
      final auth = FakeAuthRepository(initialUser: kAna);
      final c = container(auth, cloud);
      await settle();
      auth.reauthGate = Completer<void>();

      final first = c.read(accountControllerProvider.notifier).deleteAccount();
      final second = await c.read(accountControllerProvider.notifier).deleteAccount();
      expect(second, isFalse);
      expect(auth.reauthCalls, 1);

      auth.reauthGate!.complete();
      expect(await first, isTrue);
    });

    test('failure is exposed and a retry can succeed', () async {
      final cloud = FakeCloud();
      final auth = FakeAuthRepository(initialUser: kAna)
        ..reauthFailure = const AuthFailure(AuthFailureKind.cancelled);
      final c = container(auth, cloud);
      await settle();

      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isFalse);
      expect(c.read(accountControllerProvider).failure!.kind, AccountDeletionFailureKind.cancelled);
      expect(c.read(accountControllerProvider).running, isFalse);

      auth.reauthFailure = null;
      expect(await c.read(accountControllerProvider.notifier).deleteAccount(), isTrue);
    });
  });
}
