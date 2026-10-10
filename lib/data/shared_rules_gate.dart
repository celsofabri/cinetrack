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

  bool _ready = false;
  Future<RulesProbe>? _running;
  RulesProbe? _last;

  SharedRulesGate({required this._probe, required this._isStoredReady, required this._storeReady});

  /// A gate that never opens (signed out, no Firebase).
  factory SharedRulesGate.closed() => SharedRulesGate(
    probe: () async => RulesProbe.unreachable,
    isStoredReady: () => false,
    storeReady: () async {},
  )..start();

  /// Marks may carry dates.
  bool get open => _ready || _safeStored();

  /// Answer of this session's probe (null: not run / still running).
  RulesProbe? get lastProbe => _last;

  bool _safeStored() {
    try {
      return _isStoredReady();
    } catch (_) {
      return false;
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
