import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/account/session_expiry.dart';
import 'package:cinetrack/auth/auth_repository.dart';
import 'package:cinetrack/data/sync_status.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/search_result.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/in_memory_favorites_data_source.dart';

const _movie = SearchResult(
    id: 11, mediaType: MediaType.movie, title: 'Filme', posterPath: null, overview: '');

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _container(FakeAuthRepository auth, FakeCloud cloud,
    {Duration? grace, Duration? stall}) {
  final container = ProviderContainer(
    overrides: cloudOverrides(
      auth: auth,
      cloud: cloud,
      grace: grace ?? Duration.zero,
      stall: stall ?? Duration.zero,
    ),
  );
  addTearDown(container.dispose);
  // Keep the notifiers alive like the app root does.
  container.listen(authStateProvider, (_, __) {});
  container.listen(syncStatusProvider, (_, __) {});
  container.listen(sessionExpiryProvider, (_, __) {});
  return container;
}

void main() {
  test('signed out: nothing to sync', () async {
    final container = _container(FakeAuthRepository(), FakeCloud());
    await _settle();
    expect(container.read(syncStatusProvider).signedIn, isFalse);
    expect(container.read(syncStatusProvider).phase, SyncPhase.synced);
  });

  test('online and idle: synced', () async {
    final container = _container(FakeAuthRepository(initialUser: kAna), FakeCloud());
    await _settle();
    final s = container.read(syncStatusProvider);
    expect(s.phase, SyncPhase.synced);
    expect(s.serverConfirmed, isTrue);
  });

  test('offline write is pending/offline, then synced after reconnecting', () async {
    final cloud = FakeCloud();
    final container = _container(FakeAuthRepository(initialUser: kAna), cloud);
    await _settle();

    cloud.offline = true;
    await container.read(favoritesRepositoryProvider).addResult(_movie);
    await _settle();
    var s = container.read(syncStatusProvider);
    expect(s.offline, isTrue);
    expect(s.hasPendingWrites, isTrue);
    expect(s.phase, SyncPhase.offline);

    cloud
      ..offline = false
      ..flush('uid-ana');
    await _settle();
    s = container.read(syncStatusProvider);
    expect(s.phase, SyncPhase.synced);
    expect(cloud.server['uid-ana'], contains('11-movie'));
  });

  group('write failures become visible state', () {
    test('rules rejection (session still valid): failed, permissionDenied', () async {
      final auth = FakeAuthRepository(initialUser: kAna);
      final container = _container(auth, FakeCloud());
      await _settle();

      container.read(syncFailureSinkProvider).reportCode('permission-denied');
      await _settle();

      final s = container.read(syncStatusProvider);
      expect(s.phase, SyncPhase.failed);
      expect(s.failure!.kind, SyncFailureKind.permissionDenied);
    });

    test('permission-denied with a dead session becomes sessionExpired', () async {
      final auth = FakeAuthRepository(initialUser: kAna)..sessionCheck = SessionCheck.expired;
      final container = _container(auth, FakeCloud());
      await _settle();

      container.read(syncFailureSinkProvider).reportCode('permission-denied');
      await _settle();

      expect(container.read(syncStatusProvider).failure!.kind, SyncFailureKind.sessionExpired);
    });

    test('permission-denied while the check is inconclusive (offline) stays a rules failure',
        () async {
      final auth = FakeAuthRepository(initialUser: kAna)..sessionCheck = SessionCheck.unknown;
      final container = _container(auth, FakeCloud());
      await _settle();

      container.read(syncFailureSinkProvider).reportCode('permission-denied');
      await _settle();

      expect(container.read(syncStatusProvider).failure!.kind, SyncFailureKind.permissionDenied);
    });

    test('unauthenticated and resource-exhausted are mapped without asking the provider', () async {
      final container = _container(FakeAuthRepository(initialUser: kAna), FakeCloud());
      await _settle();

      container.read(syncFailureSinkProvider).reportCode('resource-exhausted');
      await _settle();
      expect(container.read(syncStatusProvider).failure!.kind, SyncFailureKind.quotaExceeded);

      container.read(syncFailureSinkProvider).reportCode('unauthenticated');
      await _settle();
      expect(container.read(syncStatusProvider).failure!.kind, SyncFailureKind.sessionExpired);
    });

    test('dismissing clears the failure', () async {
      final container = _container(FakeAuthRepository(initialUser: kAna), FakeCloud());
      await _settle();
      container.read(syncFailureSinkProvider).reportCode('resource-exhausted');
      await _settle();

      container.read(syncStatusProvider.notifier).dismissFailure();

      expect(container.read(syncStatusProvider).failure, isNull);
    });

    test('a check still in flight for account A never lands on account B (I1-B)', () async {
      final auth = FakeAuthRepository(initialUser: kAna)..verifyGate = Completer<void>();
      final container = _container(auth, FakeCloud());
      await _settle();
      container.read(syncFailureSinkProvider).reportCode('permission-denied');
      await _settle(); // verifySession() of Ana is now waiting

      auth.nextUser = kBruno;
      await auth.signOut();
      await auth.signInWithGoogle();
      await _settle();
      expect(container.read(currentUidProvider), 'uid-bruno');

      auth.verifyGate!.complete(); // Ana's answer arrives while Bruno is signed in
      await _settle();

      expect(container.read(syncStatusProvider).failure, isNull);
    });

    test('a retry (rebuild) while a check is in flight drops the stale result', () async {
      final auth = FakeAuthRepository(initialUser: kAna)..verifyGate = Completer<void>();
      final container = _container(auth, FakeCloud());
      await _settle();
      container.read(syncFailureSinkProvider).reportCode('permission-denied');
      await _settle();

      container.invalidate(favoritesDataSourceProvider); // what retrySync does
      await _settle();
      auth.verifyGate!.complete();
      await _settle();

      // The failure was kept in the sink, so the rebuilt status shows it ONCE,
      // for the right account, and it is not duplicated or lost.
      expect(container.read(syncStatusProvider).failure!.kind, SyncFailureKind.permissionDenied);
    });

    test('a failure reported before anyone observes the status is not lost (I1-C)', () async {
      final container = ProviderContainer(
        overrides: cloudOverrides(auth: FakeAuthRepository(initialUser: kAna), cloud: FakeCloud()),
      );
      addTearDown(container.dispose);
      container.listen(authStateProvider, (_, __) {});
      await _settle();

      // Nobody has read syncStatusProvider yet (no banner built).
      container.read(syncFailureSinkProvider).reportCode('resource-exhausted');
      await _settle();

      container.listen(syncStatusProvider, (_, __) {});
      await _settle();
      expect(container.read(syncStatusProvider).failure!.kind, SyncFailureKind.quotaExceeded);
    });

    test('a dismissed failure does not come back after a retry', () async {
      final container = _container(FakeAuthRepository(initialUser: kAna), FakeCloud());
      await _settle();
      container.read(syncFailureSinkProvider).reportCode('resource-exhausted');
      await _settle();
      container.read(syncStatusProvider.notifier).dismissFailure();

      container.invalidate(favoritesDataSourceProvider);
      await _settle();

      expect(container.read(syncStatusProvider).failure, isNull);
    });

    test('a failure of one account never shows up for the next one', () async {
      final auth = FakeAuthRepository(initialUser: kAna);
      final container = _container(auth, FakeCloud());
      await _settle();
      container.read(syncFailureSinkProvider).reportCode('permission-denied');
      await _settle();
      expect(container.read(syncStatusProvider).failure, isNotNull);

      await auth.signOut();
      auth.nextUser = kBruno;
      await auth.signInWithGoogle();
      await _settle();

      expect(container.read(syncStatusProvider).failure, isNull);
    });
  });

  group('writes the server never acknowledges (I1-A: the SDK retries quota/auth errors)', () {
    test('connected with pending writes for 30 s: "stalled", cause not claimed', () {
      fakeAsync((async) {
        final cloud = FakeCloud()..stuck = true;
        final container = _container(
          FakeAuthRepository(initialUser: kAna),
          cloud,
          stall: const Duration(seconds: 30),
        );
        async.elapse(const Duration(milliseconds: 10));
        container.read(favoritesRepositoryProvider).addResult(_movie);
        async.elapse(const Duration(seconds: 10));
        expect(container.read(syncStatusProvider).phase, SyncPhase.pending);

        async.elapse(const Duration(seconds: 21));

        final status = container.read(syncStatusProvider);
        expect(status.phase, SyncPhase.stalled);
        expect(status.failure, isNull);
        expect(SyncStatus.stalledMessage.toLowerCase(), isNot(contains('limite')));
      });
    });

    test('the signal disappears when the server finally acknowledges', () {
      fakeAsync((async) {
        final cloud = FakeCloud()..stuck = true;
        final container = _container(
          FakeAuthRepository(initialUser: kAna),
          cloud,
          stall: const Duration(seconds: 30),
        );
        async.elapse(const Duration(milliseconds: 10));
        container.read(favoritesRepositoryProvider).addResult(_movie);
        async.elapse(const Duration(seconds: 31));
        expect(container.read(syncStatusProvider).phase, SyncPhase.stalled);

        cloud.stuck = false;
        cloud.flush('uid-ana');
        async.elapse(const Duration(milliseconds: 10));

        expect(container.read(syncStatusProvider).phase, SyncPhase.synced);
      });
    });

    test('offline is not "stalled": being offline already has its own indicator', () {
      fakeAsync((async) {
        final cloud = FakeCloud();
        final container = _container(
          FakeAuthRepository(initialUser: kAna),
          cloud,
          stall: const Duration(seconds: 30),
        );
        async.elapse(const Duration(milliseconds: 10));
        cloud.offline = true;
        container.read(favoritesRepositoryProvider).addResult(_movie);
        async.elapse(const Duration(seconds: 60));

        expect(container.read(syncStatusProvider).phase, SyncPhase.offline);
        expect(container.read(syncStatusProvider).pendingStalled, isFalse);
      });
    });
  });

  group('first load: error is not empty', () {
    test('offline with a cold cache: loading, then unconfirmed after the grace period', () {
      fakeAsync((async) {
        final cloud = FakeCloud()..offline = true;
        final container = _container(
          FakeAuthRepository(initialUser: kAna),
          cloud,
          grace: const Duration(seconds: 5),
        );
        container.listen(favoritesListProvider, (_, __) {});
        async.elapse(const Duration(milliseconds: 100));

        expect(container.read(favoritesGateProvider), FavoritesGate.loading);
        expect(container.read(syncStatusProvider).phase, SyncPhase.connecting);

        async.elapse(const Duration(seconds: 6));

        expect(container.read(favoritesGateProvider), FavoritesGate.unconfirmed);
        expect(container.read(syncStatusProvider).offline, isTrue);
      });
    });

    test('a server answer with no favorites is a legitimate empty state', () async {
      final container = _container(FakeAuthRepository(initialUser: kAna), FakeCloud());
      container.listen(favoritesListProvider, (_, __) {});
      await _settle();
      expect(container.read(favoritesGateProvider), FavoritesGate.ready);
      expect(container.read(favoritesListProvider).value, isEmpty);
    });

    test('cached favorites are shown even while offline (never an error state)', () async {
      final cloud = FakeCloud();
      final container = _container(FakeAuthRepository(initialUser: kAna), cloud);
      container.listen(favoritesListProvider, (_, __) {});
      await _settle();
      await container.read(favoritesRepositoryProvider).addResult(_movie);
      cloud.offline = true;
      await _settle();
      expect(container.read(favoritesGateProvider), FavoritesGate.ready);
      expect(container.read(favoritesListProvider).value, hasLength(1));
    });

    test('retry recreates the data source and recovers once the server answers', () async {
      final cloud = FakeCloud()..offline = true;
      final created = <String>[];
      final auth = FakeAuthRepository(initialUser: kAna);
      final container = ProviderContainer(
        overrides: cloudOverrides(auth: auth, cloud: cloud, createdFor: created),
      );
      addTearDown(container.dispose);
      container.listen(syncStatusProvider, (_, __) {});
      container.listen(favoritesListProvider, (_, __) {});
      await _settle();
      expect(container.read(favoritesGateProvider), FavoritesGate.unconfirmed);
      final before = created.length;

      cloud.offline = false;
      container.invalidate(favoritesDataSourceProvider); // what retrySync does
      await _settle();

      expect(created.length, greaterThan(before));
      expect(container.read(favoritesGateProvider), FavoritesGate.ready);
    });
  });

  group('session expiry (signed out without asking)', () {
    test('revoked session -> expired flag; signing in again clears it', () async {
      final auth = FakeAuthRepository(initialUser: kAna);
      final container = _container(auth, FakeCloud());
      await _settle();
      expect(container.read(sessionExpiryProvider), isFalse);

      auth.revokeSession();
      await _settle();
      expect(container.read(sessionExpiryProvider), isTrue);

      await auth.signInWithGoogle();
      await _settle();
      expect(container.read(sessionExpiryProvider), isFalse);
    });

    test('the sign-out button is not an expiry', () async {
      final auth = FakeAuthRepository(initialUser: kAna);
      final container = _container(auth, FakeCloud());
      await _settle();

      await container.read(authControllerProvider.notifier).signOut();
      await _settle();

      expect(container.read(sessionExpiryProvider), isFalse);
    });

    test('pending changes made before expiry are sent after signing in as the same account',
        () async {
      final cloud = FakeCloud();
      final auth = FakeAuthRepository(initialUser: kAna);
      final container = _container(auth, cloud);
      await _settle();
      cloud.offline = true;
      await container.read(favoritesRepositoryProvider).addResult(_movie);

      auth.revokeSession();
      await _settle();
      expect(cloud.server['uid-ana'] ?? {}, isEmpty); // nothing lost, nothing sent
      expect(cloud.pending['uid-ana'], hasLength(1));

      cloud.offline = false;
      await auth.signInWithGoogle(); // same account
      cloud.flush('uid-ana');
      await _settle();

      expect(cloud.server['uid-ana'], contains('11-movie'));
    });
  });
}
