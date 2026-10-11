import '../data/social_payloads.dart';
import 'period_key.dart';
import 'shared_profile_models.dart';
import 'shared_profile_validator.dart';

/// How a fixed `DateTime` appears in fixtures/shared_profile_payloads.json
/// (`"$ts:<ISO-8601>"`; the replay turns it into a `Timestamp`).
const kTimestampJsonPrefix = r'$ts:';

/// The exact writes of `shared_profiles/{uid}` (docs/82 §4.3, §6, §7.1), as
/// pure values with sentinels ([serverTimestamp], [deleteField]; dates are
/// `DateTime`). `FirestoreSharedProfileDataSource` executes them; the golden
/// (test/shared_profile_payloads_golden_test.dart) pins them and the rules
/// suite replays them (firestore_rules_test/shared_profile_payloads.test.mjs).
///
/// Invariants (the rules check them; these builders never break them):
/// - `updatedAt` (and `actSince` when it changes) = server time;
/// - a section is present exactly while its consent is in `sharing`;
/// - only the toggles write `sharing`/`actSince`; a recalculation never does
///   (a late device cannot republish a section turned off elsewhere);
/// - content passes [SharedProfileValidator.violations] (else [ArgumentError]).
class SharedProfilePayloads {
  const SharedProfilePayloads._();

  static String path(String uid) => 'shared_profiles/$uid';

  /// Turns [section] on (consent given in the dialog). [current] = sections
  /// of the document as read IN the transaction (null = no document: `set`).
  /// "Atividades" starts empty: nothing before the consent is published.
  static SocialWrite turnOn(
    String uid, {
    required SharedSection section,
    required SharedProfileContent content,
    required Set<SharedSection>? current,
    required DateTime now,
  }) {
    final value = section == SharedSection.activity
        ? const <Object?>[]
        : _section(content, section);
    _check(content, now);
    final isActivity = section == SharedSection.activity;
    final op = current == null
        ? SocialOp.set(path(uid), {
            'v': kSharedSchemaVersion,
            'calc': content.calc,
            'updatedAt': serverTimestamp,
            'tz': normalizeTz(content.tz),
            'sharing': {section.field: true},
            if (isActivity) 'actSince': serverTimestamp,
            section.field: value,
          })
        : SocialOp.update(path(uid), {
            'sharing.${section.field}': true,
            section.field: value,
            if (isActivity) 'actSince': serverTimestamp,
            'calc': content.calc,
            'tz': normalizeTz(content.tz),
            'updatedAt': serverTimestamp,
          });
    return SocialWrite(SocialWriteMode.transaction, [op], reads: [path(uid)]);
  }

  /// Turns [section] off: consent and section go together; the last section
  /// deletes the document. [current] = sections as read in the transaction.
  static SocialWrite turnOff(
    String uid, {
    required SharedSection section,
    required Set<SharedSection> current,
  }) {
    final remaining = {...current}..remove(section);
    final op = remaining.isEmpty
        ? SocialOp.delete(path(uid))
        : SocialOp.update(path(uid), {
            'sharing.${section.field}': deleteField,
            section.field: deleteField,
            if (section == SharedSection.activity) 'actSince': deleteField,
            'updatedAt': serverTimestamp,
          });
    return SocialWrite(SocialWriteMode.transaction, [op], reads: [path(uid)]);
  }

  /// Recalculation: the [changed] sections (all of them shared), `tz`, `calc`
  /// and `updatedAt`. Never `sharing`/`actSince`, never `set`.
  static SocialWrite recalc(
    String uid, {
    required SharedProfileContent content,
    required Set<SharedSection> changed,
    required DateTime now,
    DateTime? actSince,
  }) {
    _check(content, now, actSince: actSince);
    final ordered = SharedSection.values.where(changed.contains);
    return SocialWrite(SocialWriteMode.batch, [
      SocialOp.update(path(uid), {
        for (final s in ordered) s.field: _section(content, s),
        'calc': content.calc,
        'tz': normalizeTz(content.tz),
        'updatedAt': serverTimestamp,
      }),
    ]);
  }

  /// "Atualizado há" pulse: same content, only `updatedAt` (≤ 1 per day).
  static SocialWrite pulse(String uid) => SocialWrite(SocialWriteMode.batch, [
    SocialOp.update(path(uid), {'updatedAt': serverTimestamp}),
  ]);

  /// Deactivation / account deletion / last section off elsewhere.
  static SocialWrite deleteOwn(String uid) =>
      SocialWrite(SocialWriteMode.batch, [SocialOp.delete(path(uid))]);

  static Object? _section(SharedProfileContent content, SharedSection s) {
    final value = content.section(s);
    if (value == null) throw ArgumentError('section ${s.field} was not calculated');
    return value;
  }

  static void _check(SharedProfileContent content, DateTime now, {DateTime? actSince}) {
    final bad = SharedProfileValidator.violations(content, now: now, actSince: actSince);
    if (bad.isNotEmpty) throw ArgumentError('shared profile content out of range: $bad');
  }

  /// JSON of a write for the golden fixture: sentinels as their markers,
  /// dates as [kTimestampJsonPrefix] + ISO-8601 UTC, at any depth.
  static Map<String, Object?> toJson(SocialWrite write) => {
    'mode': write.mode.name,
    if (write.reads.isNotEmpty) 'reads': write.reads,
    'ops': [
      for (final o in write.ops)
        {'op': o.op, 'path': o.path, if (o.data != null) 'data': jsonValue(o.data)},
    ],
  };

  static Object? jsonValue(Object? v) => switch (v) {
    ServerTimestamp() || DeleteField() || ClientTimePlus() => v.toString(),
    DateTime() => '$kTimestampJsonPrefix${v.toUtc().toIso8601String()}',
    Map() => {for (final e in v.entries) '${e.key}': jsonValue(e.value)},
    List() => [for (final i in v) jsonValue(i)],
    _ => v,
  };
}
