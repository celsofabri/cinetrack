import 'dart:async';

import 'shared_profile_data_source.dart';

/// Gate of the mark dates (`epsAt`, docs/82 §4.2, D17): the app sends a date
/// only after it has SEEN the rules that accept it. The old rules refuse the
/// whole `update`, so a date sent too early would lose the mark itself.
///
/// - Already confirmed on this device ([isStoredReady]): open, no read.
/// - Otherwise ONE probe per session ([start]): `ready` opens the gate and is
///   remembered for good (rules never go back); `oldRules` / `unreachable`
///   keep it closed (marks go without a date, they count in the total only)
///   until the next session.
class SharedRulesGate {
  final Future<RulesProbe> Function() _probe;
  final bool Function() _isStoredReady;
  final Future<void> Function() _storeReady;
  final Future<void> Function()? _clearStored;

  bool _ready = false;
  Future<RulesProbe>? _running;
  RulesProbe? _last;

  SharedRulesGate({
    required this._probe,
    required this._isStoredReady,
    required this._storeReady,
    this._clearStored,
  });

  bool _refused = false;

  /// The server refused a marking because of its date (docs/85, rodada 2):
  /// the rules do not accept `epsAt` after all. Closes the gate for this
  /// session and forgets the device flag, so the next session probes again.
  void invalidate() {
    _refused = true;
    _ready = false;
    final clear = _clearStored;
    if (clear != null) unawaited(clear().catchError((Object _) {}));
  }

  /// A gate that never opens (signed out, no Firebase).
  factory SharedRulesGate.closed() => SharedRulesGate(
    probe: () async => RulesProbe.unreachable,
    isStoredReady: () => false,
    storeReady: () async {},
  )..start();

  /// Marks may carry dates.
  bool get open => !_refused && (_ready || _safeStored());

  /// Answer of this session's probe (null: not run / still running).
  RulesProbe? get lastProbe => _last;

  bool _safeStored() {
    try {
      return _isStoredReady();
    } catch (_) {
      return false;
    }
  }

  /// The owner's session read of `shared_profiles/{uid}` from the SERVER
  /// (docs/85, decision Q1) is itself a probe: it feeds the SAME gate, so a
  /// user with active friendships pays no dedicated read. `ready` opens and
  /// is remembered like [start]; `oldRules` is recorded (gate stays closed);
  /// `unreachable` changes nothing.
  Future<void> feed(RulesProbe result) async {
    if (result == RulesProbe.unreachable) return;
    _last = result;
    if (result != RulesProbe.ready || _refused) return;
    final already = open;
    _ready = true;
    _running ??= Future.value(RulesProbe.ready);
    if (already) return;
    try {
      await _storeReady();
    } catch (_) {
      // The next session probes again: one more read, nothing lost.
    }
  }

  /// Runs the probe once per gate (= per session and account), unless the
  /// device already knows the rules are published.
  Future<RulesProbe> start() {
    if (open) return Future.value(RulesProbe.ready);
    return _running ??= _run();
  }

  Future<RulesProbe> _run() async {
    RulesProbe result;
    try {
      result = await _probe();
    } catch (_) {
      result = RulesProbe.unreachable;
    }
    _last = result;
    if (result == RulesProbe.ready) {
      _ready = true;
      try {
        await _storeReady();
      } catch (_) {
        // The next session probes again: one more read, nothing lost.
      }
    }
    return result;
  }
}
