import 'package:fake_async/fake_async.dart';
import 'package:cinetrack/providers/catalog_sync_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/providers/sharing_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/sharing_rig.dart';

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  catalogTests();

  // QA-8 (Q6): the re-read after "Compartilhar" fails: the local view of the committed transaction.
  test(
    'QA-8 turn on, then the re-read fails: ON with the content written, actSince local',
    () async {
      final rig = SharingRig()..seed(sharingMovie(1, watched: true));
      final c = rig.container();
      addTearDown(c.dispose);
      await _settle();
      final ctl = c.read(sharingControllerProvider.notifier);
      rig.shared.failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
      await ctl.turnOn(SharedSection.stats, c.read(sharedPreviewProvider(SharedSection.stats))!);
      await _settle();
      final st = c.read(sharingControllerProvider);
      expect(rig.doc, isNotNull);
      expect(st.sections, {SharedSection.stats});
      expect(st.doc!.stats!.total.watchedMovies, 1);
      expect(st.doc!.updatedAt, kSharingNow);
    },
  );
  // QA-1 (B5, RF-P7): the reconciliation read races the SDK commit.
  test('QA-1 uncertain turn-on that commits AFTER the immediate re-read ends ON', () async {
    final rig = SharingRig()..seed(sharingMovie(1));
    final c = rig.container();
    addTearDown(c.dispose);
    await _settle();
    final ctl = c.read(sharingControllerProvider.notifier);
    // Timeout: nothing applied yet (the SDK keeps the transaction running).
    rig.shared.failNext(
      'toggle',
      const SocialFailure(SocialFailureKind.uncertain, code: 'timeout'),
    );
    await ctl.turnOn(SharedSection.stats, c.read(sharedPreviewProvider(SharedSection.stats))!);
    await _settle();
    // The SDK commits the transaction later (consent given in the dialog).
    rig.seedShared({SharedSection.stats});
    // Connection blips (the reconciliation trigger of RF-P7).
    rig.cloud.offline = true;
    await _settle();
    rig.cloud.offline = false;
    await _settle();
    expect(rig.doc, isNotNull, reason: 'the server HAS the section on');
    expect(c.read(sharingControllerProvider).sections, {
      SharedSection.stats,
    }, reason: 'RF-P7: "ligar confirmado depois = ligado"');
  });

  // QA-2 (RF-P10): "ligar no A aparece no B na próxima confirmação de sessão (ou reconexão)".
  test('QA-2 two devices: a section turned on elsewhere shows after a reconnection', () async {
    final rig = SharingRig()..seed(sharingMovie(1));
    rig.seedShared({SharedSection.stats});
    final c = rig.container();
    addTearDown(c.dispose);
    await _settle();
    expect(c.read(sharingControllerProvider).sections, {SharedSection.stats});
    // Device A turns "Atividades" on.
    rig.seedShared({SharedSection.stats, SharedSection.activity});
    rig.cloud.offline = true;
    await _settle();
    rig.cloud.offline = false;
    await _settle();
    expect(c.read(sharingControllerProvider).sections, {
      SharedSection.stats,
      SharedSection.activity,
    });
  });

  ProviderContainer start(FakeAsync async, SharingRig rig) {
    final c = rig.container();
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1));
    async.flushMicrotasks();
    return c;
  }

  // QA-3 (Q1): after a write, a trigger without change writes nothing.
  test('QA-3 after a write, a new trigger with the same content: 0 extra writes', () {
    fakeAsync((async) {
      final rig = SharingRig();
      for (var i = 1; i <= 3; i++) {
        rig.seed(sharingMovie(i));
      }
      rig.seedShared({SharedSection.stats});
      final c = start(async, rig);
      rig.cloud.write(
        'uid-ana',
        (d) => d['1-movie'] = d['1-movie']!.copyWith(watchedMovie: true, lastWatchedAt: rig.now),
      );
      async.elapse(const Duration(seconds: 6));
      expect(rig.writes, 1);
      // A snapshot of the favorites with the same content (e.g. another field).
      rig.cloud.write('uid-ana', (_) {});
      async.elapse(const Duration(seconds: 6));
      expect(rig.writes, 1, reason: '"só grava se mudou" against what was just written');
      c.dispose();
    });
  });

  // QA-4 (Q2): a failed write is retried at the NEXT trigger even if content equals.
  test('QA-4 a failed write (unavailable) is sent again at the next trigger', () {
    fakeAsync((async) {
      final rig = SharingRig();
      for (var i = 1; i <= 3; i++) {
        rig.seed(sharingMovie(i));
      }
      rig.seedShared({SharedSection.stats});
      rig.shared.failNext(
        'write',
        const SocialFailure(SocialFailureKind.offline, code: 'unavailable'),
      );
      final c = start(async, rig);
      rig.cloud.write(
        'uid-ana',
        (d) => d['1-movie'] = d['1-movie']!.copyWith(watchedMovie: true, lastWatchedAt: rig.now),
      );
      async.elapse(const Duration(seconds: 6));
      expect(rig.shared.writeAttempts, 1);
      expect(rig.writes, 0);
      rig.cloud.write('uid-ana', (_) {});
      async.elapse(const Duration(seconds: 6));
      expect(rig.shared.writeAttempts, 2);
      expect(rig.writes, 1);
      expect(((rig.doc!['stats'] as Map)['total'] as Map)['watchedMovies'], 1);
      c.dispose();
    });
  });

  // QA-5 (Q3): with the app open, the 24 h pulse is sent without any other trigger.
  test('QA-5 app open for 25 h mid-month, nothing changes: 1 pulse (updatedAt only)', () {
    fakeAsync((async) {
      final rig = SharingRig()..seed(sharingMovie(1));
      rig.seedShared({SharedSection.stats});
      final c = start(async, rig);
      async.elapse(const Duration(seconds: 6));
      expect(rig.writes, 0);
      for (var h = 0; h < 25; h++) {
        rig.now = rig.now.add(const Duration(hours: 1));
        async.elapse(const Duration(hours: 1));
      }
      async.elapse(const Duration(seconds: 6));
      expect(rig.writes, 1);
      expect(rig.shared.writes.single.ops.single.data!.keys, ['updatedAt']);
      c.dispose();
    });
  });
}

class _HeldCatalog extends CatalogSyncNotifier {
  @override
  CatalogSyncState build() => const CatalogSyncState(runtimesLoading: true);
  void finish() => state = const CatalogSyncState();
}

void catalogTests() {
  ProviderContainer start(FakeAsync async, SharingRig rig, {List<Override> extra = const []}) {
    final c = rig.container(extra: extra);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1));
    async.flushMicrotasks();
    return c;
  }

  SharingRig rig3() {
    final rig = SharingRig();
    for (var i = 1; i <= 3; i++) {
      rig.seed(sharingMovie(i));
    }
    rig.seedShared({SharedSection.stats});
    return rig;
  }

  void mark(SharingRig rig) => rig.cloud.write(
    'uid-ana',
    (d) => d['1-movie'] = d['1-movie']!.copyWith(watchedMovie: true, lastWatchedAt: rig.now),
  );

  // QA-6 (Q4): a running catalog download holds the write; it goes when it ends.
  test('QA-6 catalog running: 0 writes; catalog ends: 1 write', () {
    fakeAsync((async) {
      final rig = rig3();
      final c = start(async, rig, extra: [catalogSyncProvider.overrideWith(_HeldCatalog.new)]);
      c.listen(catalogSyncProvider, (_, _) {});
      mark(rig);
      async.elapse(const Duration(seconds: 20));
      expect(rig.shared.writeAttempts, 0);
      (c.read(catalogSyncProvider.notifier) as _HeldCatalog).finish();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 6));
      expect(rig.writes, 1);
      c.dispose();
    });
  });

  // QA-7 (Q5): a catalog that never ends is waited for 60 s at most.
  test('QA-7 catalog stuck: the write goes after the 60 s wait', () {
    fakeAsync((async) {
      final rig = rig3();
      final c = start(async, rig, extra: [catalogSyncProvider.overrideWith(_HeldCatalog.new)]);
      c.listen(catalogSyncProvider, (_, _) {});
      mark(rig);
      async.elapse(const Duration(seconds: 59));
      expect(rig.shared.writeAttempts, 0);
      async.elapse(const Duration(seconds: 10));
      expect(rig.writes, 1);
      c.dispose();
    });
  });
}
