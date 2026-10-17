import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/firestore_shared_profile_data_source.dart';
import 'package:cinetrack/data/shared_profile_data_source.dart';
import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';

import 'support/sharing_rig.dart';

void main() {
  // QA-R2-1: the REAL source carries the end of the ORIGINAL transaction on timeout.
  test(
    'QA-R2-1 Firestore toggle timeout: settled completes only when the transaction ends',
    () async {
      final tx = Completer<void>();
      final s = FirestoreSharedProfileDataSource(
        uid: 'uid-ana',
        toggleTimeout: const Duration(milliseconds: 20),
        txRunner: (path, body) async {
          await body(null, (_) {});
          await tx.future;
        },
      );
      SharedToggleUncertain? f;
      try {
        await s.toggle((_) => const SocialWrite(SocialWriteMode.transaction, []));
      } on SharedToggleUncertain catch (e) {
        f = e;
      }
      expect(f, isNotNull);
      var done = false;
      unawaited(f!.settled.then((_) => done = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done, isFalse, reason: 'the transaction is still running');
      tx.completeError(Exception('x'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(done, isTrue, reason: 'settled never errors and ends with the transaction');
    },
  );

  // QA-R2-2: a deletion that SUCCEEDS with a pending change: 0 write attempts.
  test('QA-R2-2 account deletion completes with a pending change: 0 write attempts', () {
    fakeAsync((async) {
      final rig = SharingRig();
      for (var i = 1; i <= 3; i++) {
        rig.seed(sharingMovie(i));
      }
      rig.seedShared({SharedSection.stats});
      final c = rig.container();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      c.listen(accountControllerProvider, (_, _) {});
      rig.cloud.write(
        'uid-ana',
        (d) => d['1-movie'] = d['1-movie']!.copyWith(watchedMovie: true, lastWatchedAt: rig.now),
      );
      async.elapse(const Duration(seconds: 2));
      bool? ok;
      c.read(accountControllerProvider.notifier).deleteAccount().then((v) => ok = v);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(ok, isTrue);
      expect(rig.doc, isNull);
      expect(rig.shared.writeAttempts, 0);
      c.dispose();
    });
  });
}
