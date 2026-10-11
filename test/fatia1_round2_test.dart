import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/activity_overlay.dart';
import 'package:cinetrack/data/export_data_source.dart';
import 'package:cinetrack/data/favorite_payloads.dart';
import 'package:cinetrack/data/firestore_export_data_source.dart';
import 'package:cinetrack/data/firestore_favorites_data_source.dart';
import 'package:cinetrack/data/server_clock.dart';
import 'package:cinetrack/data/shared_profile_data_source.dart';
import 'package:cinetrack/data/shared_rules_gate.dart';
import 'package:cinetrack/data/sync_status.dart';
import 'package:cinetrack/export/data_exporter.dart';
import 'package:cinetrack/export/export_serializer.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/services/episode_dates.dart';
import 'package:cinetrack/shared_profile/activity_deriver.dart';
import 'package:cinetrack/shared_profile/period_key.dart';
import 'package:cinetrack/shared_profile/shared_profile_builder.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_profile_payloads.dart';
import 'package:cinetrack/shared_profile/shared_profile_validator.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_export_data_source.dart';
import 'support/fake_shared_profile_cloud.dart';
import 'support/favorites_harness.dart';
import 'support/in_memory_favorites_data_source.dart';

/// Fatia 1, rodada 2 (docs/85): gaps found by QA (F1–F5, G1–G6) and the
/// Code Review 🟢 (gate self-heal, tz).
final _now = DateTime.utc(2026, 10, 10, 21);
final _since = DateTime.utc(2026, 10, 1);
DateTime _t(int m) => _since.add(Duration(hours: 1, minutes: m));

FavoriteDoc _movie(int id, {required DateTime added, DateTime? watched}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.movie,
  title: 'M$id',
  posterPath: null,
  overview: '',
  addedAt: added,
  watchedMovie: watched != null,
  lastWatchedAt: watched,
);

FavoriteDoc _show({required DateTime added, Map<String, DateTime> at = const {}}) => FavoriteDoc(
  id: 10,
  mediaType: MediaType.tv,
  title: 'X',
  posterPath: null,
  overview: '',
  addedAt: added,
  watchedEpisodes: at.keys.toSet(),
  watchedAt: at,
);

List<ActivityType> _types(List<FavoriteDoc> d) => [
  for (final a in ActivityDeriver.derive(d, actSince: _since, now: _now, isCompleted: (_) => false))
    a.type,
];

/// The REAL favorites factory (Firestore source is lazy: no Firebase call
/// until it reads or writes) with fake auth / store / shared profile.
ProviderContainer _realFactory(FakeSharedProfileCloud shared, FakeLocalStore store) {
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(FakeAuthRepository(initialUser: kAna)),
      localStoreProvider.overrideWithValue(store),
      sharedProfileDataSourceFactoryProvider.overrideWithValue(
        (uid) => InMemorySharedProfileDataSource(shared, uid: uid),
      ),
    ],
  );
  addTearDown(c.dispose);
  c.listen(authStateProvider, (_, _) {});
  return c;
}

FirebaseException _fx(String code) => FirebaseException(plugin: 'cloud_firestore', code: code);

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('F1 rules-gate wiring', () {
    test('the gate provider probes by itself at session start (nobody calls start)', () async {
      final shared = FakeSharedProfileCloud();
      final c = ProviderContainer(
        overrides: cloudOverrides(
          auth: FakeAuthRepository(initialUser: kAna),
          cloud: FakeCloud(),
          sharedCloud: shared,
        ),
      );
      addTearDown(c.dispose);
      c.listen(authStateProvider, (_, _) {});
      await _settle();
      final gate = c.read(sharedRulesGateProvider);
      await _settle();
      expect(shared.log.where((o) => o == 'probe'), hasLength(1));
      expect(gate.open, isTrue);
    });

    test(
      'the real favorites factory asks the gate: old rules = no dates, new rules = dates',
      () async {
        final old = FakeSharedProfileCloud()..oldRules = true;
        final c1 = _realFactory(old, FakeLocalStore());
        await _settle();
        final s1 =
            c1.read(favoritesDataSourceFactoryProvider)('uid-ana') as FirestoreFavoritesDataSource;
        await _settle();
        expect(s1.datesEnabled(), isFalse);
        expect(c1.read(favoritesDatesEnabledProvider)(), isFalse);

        final ready = FakeSharedProfileCloud();
        final c2 = _realFactory(ready, FakeLocalStore());
        await _settle();
        final s2 =
            c2.read(favoritesDataSourceFactoryProvider)('uid-ana') as FirestoreFavoritesDataSource;
        await _settle();
        expect(s2.datesEnabled(), isTrue);
        expect(c2.read(favoritesDatesEnabledProvider)(), isTrue);
      },
    );

    test('G6 the factory uses the SHARED ServerClock of the session', () async {
      final c = _realFactory(FakeSharedProfileCloud(), FakeLocalStore());
      await _settle();
      final s =
          c.read(favoritesDataSourceFactoryProvider)('uid-ana') as FirestoreFavoritesDataSource;
      expect(identical(s.clock, c.read(serverClockProvider)), isTrue);
    });

    test('self-heal wiring: a refused date closes the gate and forgets the device flag', () async {
      final store = FakeLocalStore();
      final c = _realFactory(FakeSharedProfileCloud(), store);
      await _settle();
      final s =
          c.read(favoritesDataSourceFactoryProvider)('uid-ana') as FirestoreFavoritesDataSource;
      await _settle();
      expect(s.datesEnabled(), isTrue);
      expect(store.sharedRules, isNotEmpty);
      s.onDatesRefused();
      await _settle();
      expect(s.datesEnabled(), isFalse);
      expect(store.sharedRules, isEmpty, reason: 'next session probes again');
    });
  });

  test('invalidate closes the gate at once, even if forgetting the device flag fails', () async {
    final gate = SharedRulesGate(
      probe: () async => RulesProbe.ready,
      isStoredReady: () => true, // the device flag stays (clear failed / not done yet)
      storeReady: () async {},
      clearStored: () async => throw StateError('disk'),
    );
    expect(gate.open, isTrue);
    gate.invalidate();
    await _settle();
    expect(gate.open, isFalse);
  });

  group('gate self-heal (Code Review 🟢1): a marking is never lost because of its date', () {
    test('helper: denied WITH dates = refused + same marking resent without dates', () async {
      final sent = <Map<String, Object?>>[];
      var refused = 0;
      final withDates = FavoritePayloads.setEpisodes({
        '1_1': true,
      }, dates: EpisodeDatesPlan(set: {'1_1': _now}));
      final plain = FavoritePayloads.setEpisodes({'1_1': true});
      await FavoritePayloads.sendWithDatesFallback(
        withDates: withDates,
        withoutDates: plain,
        send: (d) async {
          sent.add(d);
          if (FavoritePayloads.carriesDates(d)) throw const FakeDenied();
        },
        isDenied: (e) => e is FakeDenied,
        onDatesRefused: () => refused++,
      );
      expect(refused, 1);
      expect(sent, hasLength(2));
      expect(sent.last.keys, unorderedEquals(['eps.1_1', 'lastWatchedAt', 'updatedAt']));
    });

    test('helper: other errors, or a denial without dates, propagate (no retry)', () async {
      var calls = 0;
      Future<void> run(Map<String, Object?> data, Object error, bool Function(Object) denied) =>
          FavoritePayloads.sendWithDatesFallback(
            withDates: data,
            withoutDates: FavoritePayloads.setEpisodes({'1_1': true}),
            send: (d) async {
              calls++;
              throw error;
            },
            isDenied: denied,
            onDatesRefused: () => fail('not a date refusal'),
          );
      await expectLater(
        run(FavoritePayloads.setEpisodes({'1_1': true}), const FakeDenied(), (e) => true),
        throwsA(isA<FakeDenied>()),
      );
      await expectLater(
        run(
          FavoritePayloads.setEpisodes({'1_1': true}, dates: EpisodeDatesPlan(set: {'1_1': _now})),
          StateError('quota'),
          (e) => e is FakeDenied,
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, 2);
    });

    test(
      'fake in old-rules mode: the episode is marked (without date), gate invalidated',
      () async {
        final h = FavoritesHarness();
        var invalidated = 0;
        h.cloud
          ..datesEnabled = true
          ..rejectDates = true
          ..clock = (() => _now)
          ..onDatesRefused = () => invalidated++;
        await h.seedShow(
          seasons: [
            SeasonCache(seasonNumber: 1, episodes: [h.episode(1, airDate: DateTime.utc(2026))]),
          ],
        );
        await h.repo.toggleEpisodeWatched(42, 1, 1);
        final doc = h.cloud.view('user-a')['42-tv']!;
        expect(doc.watchedEpisodes, {'1_1'});
        expect(doc.watchedAt, isEmpty);
        expect(invalidated, 1);
        expect(h.cloud.datesRefused, 1);
      },
    );
  });

  group('F6 self-heal in the REAL FirestoreFavoritesDataSource (updater seam)', () {
    FavoriteDoc doc() => _show(added: _since);
    ({FirestoreFavoritesDataSource source, List<Map<String, Object?>> calls, SyncFailureSink sink, int Function() refused})
    rig(Object? Function(Map<String, Object?> data) failure, {bool dates = true}) {
      final calls = <Map<String, Object?>>[];
      var refused = 0;
      final sink = SyncFailureSink();
      addTearDown(sink.dispose);
      final source = FirestoreFavoritesDataSource(
        uid: 'uid-ana',
        sink: sink,
        clock: ServerClock(deviceNow: () => _now),
        datesEnabled: () => dates,
        onDatesRefused: () => refused++,
        updater: (path, data) async {
          expect(path, 'users/uid-ana/favorites/10-tv');
          calls.add(data);
          final error = failure(data);
          if (error != null) throw error;
        },
      );
      return (source: source, calls: calls, sink: sink, refused: () => refused);
    }

    bool dated(Map<String, Object?> d) => d.keys.any((k) => k.startsWith('epsAt.'));

    test('dates refused: exactly 2 writes, the 2nd without dates, gate told once', () async {
      final r = rig((d) => dated(d) ? _fx('permission-denied') : null);
      await r.source.setEpisodes('10-tv', {'1_1': true}, current: doc());
      await _settle();
      expect(r.calls, hasLength(2));
      expect(dated(r.calls.first), isTrue);
      expect(dated(r.calls.last), isFalse);
      expect(r.calls.last['eps.1_1'], true);
      expect(r.refused(), 1);
      expect(r.sink.unacknowledged, isNull, reason: 'the marking was saved');
    });

    test('another error (unavailable): 1 write, no refusal, the error reaches the sink', () async {
      final r = rig((d) => _fx('unavailable'));
      await r.source.setEpisodes('10-tv', {'1_1': true}, current: doc());
      await _settle();
      expect(r.calls, hasLength(1));
      expect(r.refused(), 0);
      expect(r.sink.unacknowledged?.code, 'unavailable');
    });

    test('a write WITHOUT dates refused: 1 write, no resend, reported', () async {
      final r = rig((d) => _fx('permission-denied'), dates: false);
      await r.source.setEpisodes('10-tv', {'1_1': true}, current: doc());
      await _settle();
      expect(r.calls, hasLength(1));
      expect(dated(r.calls.single), isFalse);
      expect(r.refused(), 0);
      expect(r.sink.unacknowledged?.code, 'permission-denied');
    });
  });

  test('F2 favorite-then-mark path (setEpisodeWatched) carries the date', () async {
    final h = FavoritesHarness();
    h.cloud
      ..datesEnabled = true
      ..clock = () => _now;
    await h.seedShow(
      seasons: [
        SeasonCache(
          seasonNumber: 1,
          episodes: [for (var e = 1; e <= 3; e++) h.episode(e, airDate: DateTime.utc(2026, 1, e))],
        ),
      ],
    );
    await h.repo.setEpisodeWatched(42, 1, 3, watched: true);
    expect(h.cloud.view('user-a')['42-tv']!.markedAt('1_3'), _now);
  });

  group('F3/G3 ServerClock samples', () {
    test('a settled snapshot never seen pending is NOT a sample (even within 2 days)', () {
      final clock = ServerClock(deviceNow: () => DateTime.utc(2026, 10, 10, 12));
      final overlay = ActivityOverlay(clock: clock);
      overlay.stamp('1-tv', DateTime.utc(2026, 10, 10, 12));
      overlay.resolve('1-tv', DateTime.utc(2026, 10, 10, 11), pending: false);
      expect(clock.sampled, isFalse);
      expect(clock.offset, Duration.zero);
    });

    test('a later confirmed sample replaces the offset', () {
      final clock = ServerClock(deviceNow: () => DateTime.utc(2026, 10, 10, 12));
      final l = DateTime.utc(2026, 10, 10, 12);
      clock.sample(local: l, server: l.add(const Duration(minutes: 5)), elapsed: Duration.zero);
      clock.sample(local: l, server: l.add(const Duration(minutes: 1)), elapsed: Duration.zero);
      expect(clock.offset, const Duration(minutes: 1));
    });
  });

  group('F4 periodKey reads the INSTANT, whatever DateTime it gets', () {
    test('UTC and local DateTimes agree around a month boundary', () {
      for (var h = 0; h < 48; h++) {
        final i = DateTime.utc(2026, 10, 31).add(Duration(hours: h));
        expect(periodKey(i.toLocal(), -180), periodKey(i, -180), reason: '$i');
      }
    });

    test('a non-UTC DateTime is read as its instant (machine zone)', () {
      // `fromMicrosecondsSinceEpoch` gives a DateTime in the MACHINE's zone. On a
      // UTC machine its wall clock equals UTC and this test cannot tell a bug
      // that reads wall-clock fields (mutation E10); that is why CI runs the
      // tests with TZ=America/Sao_Paulo (.github/workflows/deploy-pages.yml),
      // like this development machine. The assertions hold in ANY zone.
      final instant = DateTime.utc(2026, 11, 1, 2, 30);
      final local = DateTime.fromMicrosecondsSinceEpoch(instant.microsecondsSinceEpoch);
      expect(local.isUtc, isFalse);
      expect(periodKey(local, -180), (month: '2026-10', year: '2026'));
      expect(periodKey(local, 0), (month: '2026-11', year: '2026'));
      // And through the builder (the owner's month).
      final stats = SharedProfileBuilder.stats(
        [
          _show(added: _since, at: {'1_1': local}),
        ],
        catalog: (_) => const [],
        movieRuntime: (_) => null,
        tvFallbackRuntime: (_) => null,
        isCompleted: (_) => false,
        now: DateTime.fromMicrosecondsSinceEpoch(
          instant.add(const Duration(minutes: 1)).microsecondsSinceEpoch,
        ),
        tzMinutes: -180,
      );
      expect(stats.month.key, '2026-10');
      expect(stats.month.watchedEpisodes, 1);
    });
  });

  group('F5/G1 same gesture (§5.3)', () {
    test('favorite a series and mark an episode within 10 min = only the episode', () {
      expect(
        _types([
          _show(added: _t(0), at: {'1_1': _t(5)}),
        ]),
        [ActivityType.watchedEpisodes],
      );
    });

    test('watching 11 min after favoriting is a separate gesture', () {
      expect(_types([_movie(30, added: _t(0), watched: _t(11))]), [
        ActivityType.watchedMovie,
        ActivityType.favorited,
      ]);
      expect(_types([_movie(30, added: _t(0), watched: _t(10))]), [ActivityType.watchedMovie]);
    });
  });

  test('G2 exactly 5000 dates after the write: the new mark still gets its date', () {
    final dated = {for (var e = 1; e < kMaxEpisodeDates; e++) '1_$e': _since};
    final doc = _show(added: _since, at: dated);
    final plan = EpisodeDates.plan(changes: {'2_1': true}, current: doc, instant: _now);
    expect(plan.set, {'2_1': _now});
  });

  group('G4 export of the shared profile', () {
    FirestoreExportDataSource source(FakeSharedProfileCloud shared) => FirestoreExportDataSource(
      uid: 'uid-ana',
      sharedSource: () => InMemorySharedProfileDataSource(shared, uid: 'uid-ana'),
    );

    test('old rules (denied) = null; offline = unreachable; document = raw', () async {
      expect(
        await source(FakeSharedProfileCloud()..oldRules = true).readSharedProfile(fromServer: true),
        isNull,
      );
      final offline = FakeSharedProfileCloud()
        ..failNext('readOwn', const SocialFailure(SocialFailureKind.offline));
      await expectLater(
        source(offline).readSharedProfile(fromServer: true),
        throwsA(
          isA<ExportReadException>().having(
            (e) => e.kind,
            'kind',
            ExportReadFailureKind.unreachable,
          ),
        ),
      );
      final present = FakeSharedProfileCloud()..docs['uid-ana'] = {'v': 1};
      final raw = await source(present).readSharedProfile(fromServer: true);
      expect(raw!.id, 'uid-ana');
      expect(raw.data, {'v': 1});
      expect(await source(FakeSharedProfileCloud()).readSharedProfile(fromServer: true), isNull);
    });

    test('an export abandoned during the shared-profile read delivers nothing', () async {
      var current = true;
      final s = _SwitchOnShared(() => current = false);
      await expectLater(
        runExport(
          source: s,
          from: ExportSource.server,
          now: () => _now,
          isCurrent: () => current,
          uid: 'uid-ana',
        ),
        throwsA(isA<ExportCancelled>()),
      );
    });
  });

  group('tz -0 (Code Review 🟢3)', () {
    test('the validator refuses a tz outside the rules, the payload always normalizes', () {
      const bad = SharedProfileContent(tz: 900);
      expect(SharedProfileValidator.violations(bad, now: _now), contains('tz'));
      const utc = SharedProfileContent(tz: 0);
      expect(SharedProfileValidator.violations(utc, now: _now), isEmpty);
      final write = SharedProfilePayloads.pulse('uid-ana');
      expect(write.ops.single.data!.keys, ['updatedAt']);
      final c = SharedProfileBuilder.build(
        const [],
        catalog: (_) => const [],
        sections: {SharedSection.stats},
        now: _now,
        tzMinutes: 0,
      );
      final recalc = SharedProfilePayloads.recalc(
        'uid-ana',
        content: c,
        changed: {SharedSection.stats},
        now: _now,
      );
      final tz = recalc.ops.single.data!['tz']! as int;
      expect(tz, 0);
      expect(tz.isNegative, isFalse);
      expect(normalizeTz(-0.0).isNegative, isFalse);
    });
  });
}

/// The account changes while the shared profile is being read.
class _SwitchOnShared extends FakeExportDataSource {
  final void Function() onShared;

  _SwitchOnShared(this.onShared) : super({});

  @override
  Future<RawDoc?> readSharedProfile({required bool fromServer}) async {
    onShared();
    return null;
  }
}
