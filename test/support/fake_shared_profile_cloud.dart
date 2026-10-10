import 'dart:async';

import 'package:cinetrack/data/shared_profile_data_source.dart';
import 'package:cinetrack/social/social_models.dart';

/// In-memory `shared_profiles` (docs/83 §4 "fakes novos"): one document per
/// uid, an operation log (shared with other fakes to check ORDER), a read
/// counter, injectable failures and an "old rules" mode.
class FakeSharedProfileCloud {
  FakeSharedProfileCloud({List<String>? log}) : log = log ?? [];

  final Map<String, Map<String, dynamic>> docs = {};

  /// Operations in order: `readOwn`, `probe`, `deleteSharedProfile`,
  /// `readFriend:<uid>`.
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
