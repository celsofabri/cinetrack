import '../shared_profile/shared_profile_models.dart';
import '../shared_profile/shared_stats_reading.dart';
import '../social/collation_key.dart';
import 'ranking_models.dart';
import 'ranking_reading.dart';

/// Most friends the ranking considers (D5): the first 50 of the list.
const kRankingMaxFriends = 50;

/// One person in the ranking: "Você" (only when sharing "Estatísticas") or a
/// friend whose snapshot has `stats` (docs/91 §6). Holds the RAW reading:
/// periods and the marker depend on the ranking's "agora" (O5), which
/// depends on every participant, so they are read in [RankingTable.rank].
class RankingParticipant {
  final String uid;

  /// The label shown on the line (and used to order ties): the friend's
  /// nickname from the pair, or my `displayLabelProvider`.
  final String name;
  final String? photoUrl;
  final bool isMe;
  final SharedStatsReading stats;
  final DateTime? updatedAt;

  /// The owner's zone in minutes (out of −840..840 reads as 0).
  final int tz;

  /// The snapshot's calculation version; null = unreadable.
  final int? calc;

  const RankingParticipant({
    required this.uid,
    required this.name,
    this.photoUrl,
    this.isMe = false,
    required this.stats,
    this.updatedAt,
    this.tz = 0,
    this.calc,
  });

  /// A friend's line from their snapshot; null when they do not share
  /// "Estatísticas" (`stats` absent: "não participa", D10).
  static RankingParticipant? friend({
    required String uid,
    required String name,
    String? photoUrl,
    required FriendSharedView view,
  }) {
    final stats = view.stats;
    if (stats == null) return null;
    return RankingParticipant(
      uid: uid,
      name: name,
      photoUrl: photoUrl,
      stats: stats,
      updatedAt: view.updatedAt,
      tz: view.tz,
      calc: view.calc,
    );
  }

  /// "Você" from my own confirmed snapshot, with the friends' ceilings
  /// applied ([RankingReading.fromOwn]) so I see what they see.
  factory RankingParticipant.me({
    required String uid,
    required String name,
    String? photoUrl,
    required SharedStats stats,
    DateTime? updatedAt,
    int tz = 0,
    int? calc,
  }) => RankingParticipant(
    uid: uid,
    name: name,
    photoUrl: photoUrl,
    isMe: true,
    stats: RankingReading.fromOwn(SharedStatsReading.of(stats)),
    updatedAt: updatedAt,
    tz: tz,
    calc: calc,
  );
}

class RankingRow {
  final RankingParticipant who;

  /// Null = unknown ("—"). Hours: MINUTES (D14; only the text shows hours).
  final int? value;

  /// Competition ranking: 1, 1, 3. Null for an unknown value.
  final int? position;

  /// Another KNOWN line has the same value (true on every line of the group).
  final bool tied;

  /// Out-of-date marker (O6); always false for "Você".
  final bool stale;

  /// Whole days since the snapshot's `updatedAt`; null = unknown.
  final int? staleDays;

  const RankingRow({
    required this.who,
    required this.value,
    required this.position,
    required this.tied,
    required this.stale,
    required this.staleDays,
  });
}

class RankingResult {
  final List<RankingRow> rows;

  /// Lines with a position (the N of "de N"), me included.
  final int ranked;

  /// Null: I am not in the ranking or my value is unknown.
  final int? myPosition;

  /// Someone has a position and every known value is 0 (RF-E13).
  final bool nobodyScored;

  /// Period other than Total and some participant's dates note falls in it
  /// (RF-R9).
  final bool undatedNote;

  /// The "agora" used (O5).
  final DateTime now;

  const RankingResult({
    required this.rows,
    required this.ranked,
    required this.myPosition,
    required this.nobodyScored,
    required this.undatedNote,
    required this.now,
  });
}

/// The pure ranking function (docs/91 §6). Deterministic, O(n log n):
/// the output does not depend on the order of the input.
class RankingTable {
  const RankingTable._();

  /// The ranking's "agora" (O5, N4): the latest of [serverNow] and every
  /// participant's `updatedAt` (a server time, never ahead of the real now),
  /// which corrects a device clock that is behind.
  static DateTime agora(List<RankingParticipant> ps, DateTime serverNow) {
    var now = serverNow.toUtc();
    for (final p in ps) {
      final u = p.updatedAt?.toUtc();
      if (u != null && u.isAfter(now)) now = u;
    }
    return now;
  }

  static RankingResult rank(List<RankingParticipant> ps, RankingMetric m, RankingPeriod p, DateTime serverNow) {
    final now = agora(ps, serverNow);
    final read = [
      for (final who in ps)
        (
          who: who,
          stats: RankingReading.read(who.stats, tz: who.tz, updatedAt: who.updatedAt, calc: who.calc, now: now),
        ),
    ];
    int byName(RankingParticipant a, RankingParticipant b) {
      final c = collationKey(a.name).compareTo(collationKey(b.name));
      return c != 0 ? c : a.uid.compareTo(b.uid);
    }

    final known =
        [
          for (final r in read)
            if (r.stats.value(m, p) != null) r,
        ]..sort((a, b) {
          final c = b.stats.value(m, p)!.compareTo(a.stats.value(m, p)!);
          return c != 0 ? c : byName(a.who, b.who);
        });
    final unknown = [
      for (final r in read)
        if (r.stats.value(m, p) == null) r,
    ]..sort((a, b) => byName(a.who, b.who));

    final values = [for (final r in known) r.stats.value(m, p)!];
    final counts = <int, int>{};
    for (final v in values) {
      counts[v] = (counts[v] ?? 0) + 1;
    }
    final rows = <RankingRow>[];
    int? myPosition;
    var position = 0;
    for (var i = 0; i < known.length; i++) {
      final v = values[i];
      // Competition ranking: 1 + how many known values are larger.
      if (i == 0 || v != values[i - 1]) position = i + 1;
      if (known[i].who.isMe) myPosition = position;
      rows.add(_row(known[i].who, known[i].stats, value: v, position: position, tied: counts[v]! > 1));
    }
    for (final r in unknown) {
      rows.add(_row(r.who, r.stats, value: null, position: null, tied: false));
    }
    final undatedNote = switch (p) {
      RankingPeriod.total => false,
      RankingPeriod.year => read.any((r) => r.stats.undatedPlacement.year),
      RankingPeriod.month => read.any((r) => r.stats.undatedPlacement.month),
    };
    return RankingResult(
      rows: rows,
      ranked: known.length,
      myPosition: myPosition,
      nobodyScored: values.isNotEmpty && values.every((v) => v == 0),
      undatedNote: undatedNote,
      now: now,
    );
  }

  static RankingRow _row(
    RankingParticipant who,
    RankingStats s, {
    required int? value,
    required int? position,
    required bool tied,
  }) => RankingRow(
    who: who,
    value: value,
    position: position,
    tied: tied,
    stale: !who.isMe && s.stale,
    staleDays: s.staleDays,
  );
}
