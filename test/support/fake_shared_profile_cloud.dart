import 'dart:async';

import 'package:cinetrack/data/shared_profile_data_source.dart';
import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/social/social_models.dart';

/// In-memory `shared_profiles` (docs/83 §4 "fakes novos"): one document per
/// uid, an operation log (shared with other fakes to check ORDER), a read
/// counter, injectable failures and an "old rules" mode.
class FakeSharedProfileCloud {
  FakeSharedProfileCloud({List<String>? log}) : log = log ?? [];

  final Map<String, Map<String, dynamic>> docs = {};

  /// Operations in order: `readOwn`, `probe`, `deleteSharedProfile`,
  /// `readFriend:<uid>`, `toggle` (a transaction that reached the server),
  /// `writeShared` (a recalculation / pulse that reached the server).
  final List<String> log;

  /// Documents read (every `get`, as Firestore bills them).
  int reads = 0;

  /// The phase-2 rules are NOT published: every operation is denied.
  bool oldRules = false;

  /// Pairs of mutual friends (`a|b`, any order): who may read whom.
  final Set<String> friends = {};

  /// Next failures per operation (`readOwn`, `probe`, `deleteOwn`,
  /// `readFriend`), consumed in order.
  final Map<String, List<SocialFailure>> failures = {};

  /// A `deleteOwn` failing with [SocialFailureKind.uncertain] (timeout) still
  /// reaches the server (delivered later by the SDK queue).
  bool deliverUncertainDeletes = false;

  /// Holds `deleteOwn` until completed (operations in flight).
  Completer<void>? deleteGate;

  /// Server clock (`serverTimestamp`).
  DateTime Function() clock = () => DateTime.now().toUtc();

  /// Uids whose `social/{uid}` does not exist: consent changes are denied
  /// (the rules need it to create or change `sharing`).
  final Set<String> socialClosed = {};

  /// A toggle failing with [SocialFailureKind.uncertain] still committed.
  bool deliverUncertainToggles = false;

  /// "Late commit" mode (docs/86 rodada 2, A): an uncertain toggle has NOT
  /// ended when the caller gives up (timeout); the SDK keeps it running.
  /// [commitLate] applies its write later; [abortLate] ends it unapplied.
  bool lateUncertainToggles = false;
  void Function()? _late;
  Completer<void>? _lateDone;
  bool get hasLateToggle => _late != null;

  void commitLate() {
    final apply = _late!;
    _late = null;
    apply();
    _lateDone!.complete();
  }

  void abortLate() {
    _late = null;
    _lateDone!.complete();
  }

  /// A recalculation failing with [SocialFailureKind.uncertain] still landed.
  bool deliverUncertainWrites = false;

  /// Holds toggles / recalculation writes until completed (in flight).
  Completer<void>? toggleGate;
  Completer<void>? readGate;
  Completer<void>? writeGate;

  /// Every write the fake ACCEPTED, in order (the payloads as sent).
  final List<SocialWrite> toggles = [];
  final List<SocialWrite> writes = [];

  /// Recalculation attempts (accepted or not).
  int writeAttempts = 0;

  static const _denied = SocialFailure(SocialFailureKind.denied, code: 'permission-denied');
  static const _notFound = SocialFailure(SocialFailureKind.unknown, code: 'not-found');

  Object? _value(Object? v) => switch (v) {
    ServerTimestamp() => clock(),
    Map() => {for (final e in v.entries) '${e.key}': _value(e.value)},
    List() => [for (final i in v) _value(i)],
    _ => v,
  };

  /// Applies [write] to [uid]'s document like the server and the rules of
  /// docs/84 would (subset: update of a missing document = not-found; a
  /// section without its consent = denied; consent change without `social`
  /// = denied). Throws without changing anything when refused.
  void apply(String uid, SocialWrite write, {required bool consent}) {
    if (oldRules) throw _denied;
    for (final op in write.ops) {
      final id = op.path.split('/').last;
      switch (op.op) {
        case 'delete':
          docs.remove(id);
        case 'set':
          if (consent && socialClosed.contains(uid)) throw _denied;
          final next = Map<String, dynamic>.from(_value(op.data) as Map);
          _check(next);
          docs[id] = next;
        case 'update':
          final current = docs[id];
          if (current == null) throw _notFound;
          final touchesConsent = op.data!.keys.any(
            (k) => k.startsWith('sharing') || k == 'actSince',
          );
          if (touchesConsent && socialClosed.contains(uid)) throw _denied;
          final next = _deepCopy(current);
          for (final e in op.data!.entries) {
            final parts = e.key.split('.');
            Map<String, dynamic> target = next;
            for (final p in parts.take(parts.length - 1)) {
              target = (target[p] ??= <String, dynamic>{}) as Map<String, dynamic>;
            }
            if (e.value is DeleteField) {
              target.remove(parts.last);
            } else {
              target[parts.last] = _value(e.value);
            }
          }
          _check(next);
          docs[id] = next;
      }
    }
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> m) => {
    for (final e in m.entries)
      e.key: e.value is Map<String, dynamic> ? _deepCopy(e.value as Map<String, dynamic>) : e.value,
  };

  /// "section present <=> consent present" (validShared).
  void _check(Map<String, dynamic> d) {
    final sharing = d['sharing'];
    if (sharing is! Map || sharing.isEmpty) throw _denied;
    for (final f in ['stats', 'activity', 'recs']) {
      if (d.containsKey(f) != (sharing[f] == true)) throw _denied;
    }
    if (d.containsKey('actSince') != (sharing['activity'] == true)) throw _denied;
  }

  void failNext(String op, SocialFailure failure) => (failures[op] ??= []).add(failure);

  SocialFailure? _take(String op) {
    final list = failures[op];
    if (list == null || list.isEmpty) return null;
    return list.removeAt(0);
  }

  void befriend(String a, String b) => friends.add(a.compareTo(b) < 0 ? '$a|$b' : '$b|$a');

  bool areFriends(String a, String b) => friends.contains(a.compareTo(b) < 0 ? '$a|$b' : '$b|$a');
}

class InMemorySharedProfileDataSource implements SharedProfileDataSource {
  final FakeSharedProfileCloud cloud;
  @override
  final String uid;

  InMemorySharedProfileDataSource(this.cloud, {required this.uid});

  static const _denied = SocialFailure(SocialFailureKind.denied, code: 'permission-denied');

  @override
  Future<Map<String, dynamic>?> readOwn({required bool fromServer}) async {
    cloud.log.add('readOwn');
    final gate = cloud.readGate;
    if (gate != null) await gate.future;
    final failure = cloud._take('readOwn');
    if (failure != null) throw failure;
    if (cloud.oldRules) throw _denied;
    cloud.reads++;
    final doc = cloud.docs[uid];
    return doc == null ? null : Map<String, dynamic>.of(doc);
  }

  @override
  Future<RulesProbe> probeRules() async {
    cloud.log.add('probe');
    final failure = cloud._take('probe');
    if (failure != null) {
      return failure.kind == SocialFailureKind.denied
          ? RulesProbe.oldRules
          : RulesProbe.unreachable;
    }
    if (cloud.oldRules) return RulesProbe.oldRules;
    cloud.reads++;
    return RulesProbe.ready;
  }

  @override
  Future<void> deleteOwn() async {
    final gate = cloud.deleteGate;
    if (gate != null) await gate.future;
    final failure = cloud._take('deleteOwn');
    if (failure != null) {
      if (failure.kind == SocialFailureKind.uncertain && cloud.deliverUncertainDeletes) {
        cloud.docs.remove(uid);
      }
      throw failure;
    }
    cloud.log.add('deleteSharedProfile');
    if (cloud.oldRules) return; // denied = nothing can exist (see the interface)
    cloud.docs.remove(uid);
  }

  @override
  Future<void> toggle(SocialWrite Function(Map<String, dynamic>? current) plan) async {
    final gate = cloud.toggleGate;
    if (gate != null) await gate.future;
    final failure = cloud._take('toggle');
    if (failure != null && failure.kind != SocialFailureKind.uncertain) throw failure;
    if (cloud.oldRules) throw _denied;
    cloud.reads++;
    final current = cloud.docs[uid];
    final write = plan(current == null ? null : FakeSharedProfileCloud._deepCopy(current));
    void commit() {
      cloud.apply(uid, write, consent: true);
      cloud.toggles.add(write);
      cloud.log.add('toggle');
    }

    if (failure != null) {
      // Like FirestoreSharedProfileDataSource: an uncertain toggle carries
      // the end of its ORIGINAL transaction.
      if (cloud.lateUncertainToggles) {
        final done = Completer<void>();
        cloud._late = commit;
        cloud._lateDone = done;
        throw SharedToggleUncertain(done.future, code: failure.code ?? 'timeout');
      }
      if (cloud.deliverUncertainToggles) commit();
      throw SharedToggleUncertain(Future<void>.value(), code: failure.code);
    }
    commit();
  }

  @override
  Future<void> writeSections(SocialWrite write) async {
    cloud.writeAttempts++;
    final gate = cloud.writeGate;
    if (gate != null) await gate.future;
    final failure = cloud._take('write');
    if (failure != null) {
      if (failure.kind == SocialFailureKind.uncertain && cloud.deliverUncertainWrites) {
        cloud.apply(uid, write, consent: false);
        cloud.writes.add(write);
        cloud.log.add('writeShared');
      }
      throw failure;
    }
    cloud.apply(uid, write, consent: false);
    cloud.writes.add(write);
    cloud.log.add('writeShared');
  }

  @override
  Future<Map<String, dynamic>?> readFriend(String friendUid) async {
    cloud.log.add('readFriend:$friendUid');
    final failure = cloud._take('readFriend');
    if (failure != null) throw failure;
    if (cloud.oldRules || !cloud.areFriends(uid, friendUid)) throw _denied;
    cloud.reads++;
    final doc = cloud.docs[friendUid];
    return doc == null ? null : Map<String, dynamic>.of(doc);
  }
}
