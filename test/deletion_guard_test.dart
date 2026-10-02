import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/account/account_deletion_failure.dart';
import 'package:cinetrack/data/deletion_guard.dart';
import 'package:cinetrack/data/firestore_profile_data_source.dart';

/// Server-side collection that serves pages of at most [limit] ids, like
/// `collection.limit(400).get(Source.server)`, and records every batch.
class _FakeCollection {
  _FakeCollection(int count) : ids = List.generate(count, (i) => 'doc-$i');

  final List<String> ids;
  final batches = <int>[];

  Future<List<String>> readPage() async => ids.take(FirestoreProfileDataSource.batchSize).toList();

  Future<void> deletePage(List<String> page) async {
    expect(page.length, lessThanOrEqualTo(500)); // Firestore's batch limit
    batches.add(page.length);
    ids.removeWhere(page.contains);
  }
}

void main() {
  group('wipeInPages (401+ favorites)', () {
    for (final count in [0, 1, 400, 401, 800, 950]) {
      test('$count documents: all deleted, batches within the limit', () async {
        final col = _FakeCollection(count);

        await wipeInPages<String>(readPage: col.readPage, deletePage: col.deletePage);

        expect(col.ids, isEmpty);
        expect(col.batches.fold<int>(0, (a, b) => a + b), count);
        expect(col.batches.every((n) => n <= FirestoreProfileDataSource.batchSize), isTrue);
        expect(col.batches.length, (count / FirestoreProfileDataSource.batchSize).ceil());
      });
    }

    test('a failure in the 2nd batch leaves the rest, and a rerun finishes (idempotent)', () async {
      final col = _FakeCollection(950);
      var calls = 0;
      Future<void> flaky(List<String> page) async {
        if (++calls == 2) {
          throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
        }
        await col.deletePage(page);
      }

      await expectLater(
        wipeInPages<String>(readPage: col.readPage, deletePage: flaky),
        throwsA(isA<AccountDeletionFailure>()
            .having((f) => f.kind, 'kind', AccountDeletionFailureKind.offline)),
      );
      expect(col.ids, hasLength(550));

      await wipeInPages<String>(readPage: col.readPage, deletePage: col.deletePage);
      expect(col.ids, isEmpty);
    });

    test('never loops forever if the server keeps returning documents', () async {
      await expectLater(
        wipeInPages<String>(
          readPage: () async => ['x'],
          deletePage: (_) async {},
          maxPages: 3,
        ),
        throwsA(isA<AccountDeletionFailure>().having((f) => f.code, 'code', 'too-many-pages')),
      );
    });
  });

  group('guardDeletionStep timeout (I2)', () {
    test('a READ that never answers = offline: nothing was changed', () {
      fakeAsync((async) {
        Object? error;
        guardDeletionStep(() => Completer<void>().future, write: false)
            .catchError((Object e) => error = e);
        async.elapse(const Duration(seconds: 31));
        expect(error, isA<AccountDeletionFailure>());
        expect((error as AccountDeletionFailure).kind, AccountDeletionFailureKind.offline);
      });
    });

    test('a WRITE that never answers = uncertain: it stays queued in the SDK', () {
      fakeAsync((async) {
        Object? error;
        guardDeletionStep(() => Completer<void>().future, write: true)
            .catchError((Object e) => error = e);
        async.elapse(const Duration(seconds: 31));
        final failure = error as AccountDeletionFailure;
        expect(failure.kind, AccountDeletionFailureKind.uncertain);
        expect(failure.code, 'timeout');
        // The message must not promise that nothing was deleted.
        expect(failure.message.toLowerCase(), isNot(contains('nada foi apagado')));
      });
    });

    test('the batch commit timing out in the middle of a wipe is uncertain', () {
      fakeAsync((async) {
        Object? error;
        wipeInPages<String>(
          readPage: () async => ['a'],
          deletePage: (_) => Completer<void>().future,
        ).catchError((Object e) => error = e);
        async.elapse(const Duration(seconds: 31));
        expect((error as AccountDeletionFailure).kind, AccountDeletionFailureKind.uncertain);
      });
    });

    test('quota and session errors from Firestore are mapped, not leaked', () async {
      Future<AccountDeletionFailure> failWith(String code) async {
        try {
          await guardDeletionStep<void>(
            () => Future.error(FirebaseException(plugin: 'cloud_firestore', code: code)),
            write: true,
          );
        } on AccountDeletionFailure catch (f) {
          return f;
        }
        throw StateError('did not fail');
      }

      expect((await failWith('resource-exhausted')).kind, AccountDeletionFailureKind.quotaExceeded);
      expect((await failWith('unauthenticated')).kind, AccountDeletionFailureKind.sessionExpired);
      expect((await failWith('permission-denied')).kind, AccountDeletionFailureKind.unknown);
    });
  });
}
