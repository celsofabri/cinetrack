import 'package:cinetrack/providers/ranking_providers.dart';
import 'package:cinetrack/providers/sharing_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_doc.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_stats_reading.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// docs/91 §10.6: "my row" of the ranking comes from the owner's confirmed
/// document (0 reads); not confirmed = null (D9 waits). The rule lives in
/// ONE injectable provider (docs/95 may change how sharing is decided).
class FakeSharing extends SharingController {
  FakeSharing(this.initial);
  final SharingState initial;

  @override
  SharingState build() => initial;
}

const _stats = SharedStats(
  total: TotalStats(watchedEpisodes: 3),
  year: PeriodStats(key: '2026', watchedEpisodes: 3),
  month: PeriodStats(key: '2026-10', watchedEpisodes: 1),
);

RankingMe meFor(SharingState s) {
  final c = ProviderContainer(
    overrides: [sharingControllerProvider.overrideWith(() => FakeSharing(s))],
  );
  addTearDown(c.dispose);
  return c.read(rankingMeProvider);
}

void main() {
  test('not confirmed -> sharing null, no doc (even if the doc has stats)', () {
    final me = meFor(
      const SharingState(
        doc: SharedProfileDoc(sharing: {SharedSection.stats}, stats: _stats),
      ),
    );
    expect(me.sharing, isNull);
    expect(me.doc, isNull);
  });

  test('confirmed with the stats consent and section -> my doc, 0 reads', () {
    const doc = SharedProfileDoc(sharing: {SharedSection.stats}, stats: _stats);
    final me = meFor(const SharingState(confirmed: true, doc: doc));
    expect(me.sharing, isTrue);
    expect(identical(me.doc, doc), isTrue);
  });

  test('confirmed without stats (no doc, other section, consent without section) -> false', () {
    for (final doc in const [
      null,
      SharedProfileDoc(sharing: {SharedSection.recs}),
      SharedProfileDoc(sharing: {SharedSection.stats}),
    ]) {
      final me = meFor(SharingState(confirmed: true, doc: doc));
      expect(me.sharing, isFalse);
      expect(me.doc, isNull);
    }
  });

  test('the friend predicate: stats map = takes part; absent / not a map = not', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final shares = c.read(rankingFriendSharesProvider);
    expect(shares(FriendSharedView.parse({'stats': <String, dynamic>{}})), isTrue);
    expect(shares(FriendSharedView.parse({'stats': 3})), isFalse);
    expect(shares(FriendSharedView.parse({})), isFalse);
    expect(shares(null), isFalse);
  });
}
