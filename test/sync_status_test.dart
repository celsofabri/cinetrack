import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/sync_status.dart';

void main() {
  group('SyncFailure.fromCode', () {
    test('maps the codes the spec calls out', () {
      expect(SyncFailure.fromCode('permission-denied').kind, SyncFailureKind.permissionDenied);
      expect(SyncFailure.fromCode('resource-exhausted').kind, SyncFailureKind.quotaExceeded);
      expect(SyncFailure.fromCode('unauthenticated').kind, SyncFailureKind.sessionExpired);
      expect(SyncFailure.fromCode('internal').kind, SyncFailureKind.unknown);
      expect(SyncFailure.fromCode('internal').code, 'internal');
    });

    test('messages are honest pt-BR texts', () {
      expect(SyncFailure.fromCode('unauthenticated').message, contains('Sessão expirada'));
      expect(SyncFailure.fromCode('resource-exhausted').message, contains('limite diário'));
      expect(SyncFailure.fromCode('permission-denied').message, contains('não foi salva'));
    });
  });

  group('SyncStatus', () {
    test('signed out is always synced and never unconfirmed', () {
      expect(SyncStatus.signedOut.phase, SyncPhase.synced);
      expect(SyncStatus.signedOut.unconfirmed, isFalse);
      expect(SyncStatus.signedOut.offline, isFalse);
    });

    test('before the first server answer it is connecting, not offline', () {
      const s = SyncStatus(fromCache: true);
      expect(s.connecting, isTrue);
      expect(s.offline, isFalse);
      expect(s.phase, SyncPhase.connecting);
    });

    test('silent server after the grace period: offline and unconfirmed', () {
      const s = SyncStatus(graceOver: true, fromCache: true);
      expect(s.offline, isTrue);
      expect(s.unconfirmed, isTrue);
      expect(s.phase, SyncPhase.offline);
    });

    test('after a server answer, cache means offline right away', () {
      const s = SyncStatus(serverConfirmed: true, fromCache: true);
      expect(s.offline, isTrue);
      expect(s.unconfirmed, isFalse);
    });

    test('pending writes while online; failure outranks everything', () {
      const online = SyncStatus(serverConfirmed: true, fromCache: false, hasPendingWrites: true);
      expect(online.phase, SyncPhase.pending);
      final failed = online.copyWith(failure: SyncFailure.fromCode('permission-denied'));
      expect(failed.phase, SyncPhase.failed);
      expect(failed.copyWith(clearFailure: true).phase, SyncPhase.pending);
    });
  });

  group('SyncFailureSink.fire', () {
    String? codeOf(Object e) => e is _FakeProviderError ? e.code : null;

    test('returns immediately even if the write never completes (offline)', () async {
      final sink = SyncFailureSink();
      addTearDown(sink.dispose);
      final never = Completer<void>();
      var returned = false;
      await sink.fire(() => never.future, codeOf: codeOf).then((_) => returned = true);
      expect(returned, isTrue);
    });

    test('a rejected write is reported with its code, not swallowed (finding I1)', () async {
      final sink = SyncFailureSink();
      addTearDown(sink.dispose);
      final seen = <SyncFailure>[];
      sink.stream.listen(seen.add);

      await sink.fire(() => Future.error(_FakeProviderError('permission-denied')), codeOf: codeOf);
      await sink.fire(() => Future.error(_FakeProviderError('resource-exhausted')), codeOf: codeOf);
      await sink.fire(() => throw StateError('sync throw'), codeOf: codeOf);
      await Future<void>.delayed(Duration.zero);

      expect(seen.map((f) => f.kind), [
        SyncFailureKind.permissionDenied,
        SyncFailureKind.quotaExceeded,
        SyncFailureKind.unknown,
      ]);
      expect(seen.last.code, 'StateError'); // type only: never the message
    });

    test('a successful write reports nothing', () async {
      final sink = SyncFailureSink();
      addTearDown(sink.dispose);
      final seen = <SyncFailure>[];
      sink.stream.listen(seen.add);
      await sink.fire(() async {}, codeOf: codeOf);
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);
    });

    test('remembers a failure reported with no listener until it is acknowledged', () async {
      final sink = SyncFailureSink();
      addTearDown(sink.dispose);
      expect(sink.unacknowledged, isNull);

      sink.reportCode('permission-denied'); // nobody is listening
      expect(sink.unacknowledged!.kind, SyncFailureKind.permissionDenied);

      sink.acknowledge();
      expect(sink.unacknowledged, isNull);
    });
  });
}

class _FakeProviderError implements Exception {
  final String code;
  _FakeProviderError(this.code);
}
