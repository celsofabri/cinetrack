import 'shared_profile_models.dart';

/// The owner's `shared_profiles/{uid}` as read from the server (raw map with
/// timestamps already converted to `DateTime`), parsed defensively: a
/// malformed section is absent, an unknown field is ignored (RF-F9).
class SharedProfileDoc {
  /// Sections whose consent is in `sharing` (the source of truth of the
  /// toggles).
  final Set<SharedSection> sharing;
  final DateTime? updatedAt;
  final DateTime? actSince;
  final int tz;
  final int calc;
  final SharedStats? stats;

  /// Null when the field is absent or not a list.
  final List<ActivityItem>? activity;
  final SharedRecs? recs;

  const SharedProfileDoc({
    required this.sharing,
    this.updatedAt,
    this.actSince,
    this.tz = 0,
    this.calc = kSharedCalcVersion,
    this.stats,
    this.activity,
    this.recs,
  });

  static SharedProfileDoc? parse(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final rawSharing = raw['sharing'];
    final sharing = <SharedSection>{
      if (rawSharing is Map)
        for (final e in rawSharing.entries)
          if (e.value == true) ?SharedSection.fromField('${e.key}'),
    };
    DateTime? date(Object? v) => v is DateTime ? v.toUtc() : null;
    final tz = raw['tz'];
    final calc = raw['calc'];
    final activity = raw['activity'];
    return SharedProfileDoc(
      sharing: sharing,
      updatedAt: date(raw['updatedAt']),
      actSince: date(raw['actSince']),
      tz: tz is int ? tz : 0,
      calc: calc is int ? calc : kSharedCalcVersion,
      stats: SharedSectionParsers.stats(raw['stats']),
      activity: activity is List ? ActivityItem.parseList(activity) : null,
      recs: SharedSectionParsers.recs(raw['recs']),
    );
  }

  /// What the server holds, in the shape the builder produces (for the
  /// "only write if it changed" comparison).
  SharedProfileContent get content => SharedProfileContent(
    calc: calc,
    tz: tz,
    stats: sharing.contains(SharedSection.stats) ? stats : null,
    activity: sharing.contains(SharedSection.activity) ? activity : null,
    recs: sharing.contains(SharedSection.recs) ? recs : null,
  );

  SharedProfileDoc copyWith({
    Set<SharedSection>? sharing,
    DateTime? updatedAt,
    DateTime? actSince,
    bool clearActSince = false,
    int? tz,
    int? calc,
    SharedStats? stats,
    bool clearStats = false,
    List<ActivityItem>? activity,
    bool clearActivity = false,
    SharedRecs? recs,
    bool clearRecs = false,
  }) => SharedProfileDoc(
    sharing: sharing ?? this.sharing,
    updatedAt: updatedAt ?? this.updatedAt,
    actSince: clearActSince ? null : (actSince ?? this.actSince),
    tz: tz ?? this.tz,
    calc: calc ?? this.calc,
    stats: clearStats ? null : (stats ?? this.stats),
    activity: clearActivity ? null : (activity ?? this.activity),
    recs: clearRecs ? null : (recs ?? this.recs),
  );

  /// The same document after a recalculation of [changed] with [content]
  /// was written at [at] (the owner's local view of their write).
  SharedProfileDoc afterRecalc(SharedProfileContent content, Set<SharedSection> changed, DateTime at) =>
      copyWith(
        updatedAt: at,
        tz: content.tz,
        calc: content.calc,
        stats: changed.contains(SharedSection.stats) ? content.stats : null,
        activity: changed.contains(SharedSection.activity) ? content.activity : null,
        recs: changed.contains(SharedSection.recs) ? content.recs : null,
      );
}
