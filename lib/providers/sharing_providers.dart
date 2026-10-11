import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/shared_profile_data_source.dart';
import '../data/sync_status.dart';
import '../models/favorite_doc.dart';
import '../repositories/shared_profile_repository.dart';
import '../shared_profile/period_key.dart';
import '../shared_profile/shared_profile_builder.dart';
import '../shared_profile/shared_profile_doc.dart';
import '../shared_profile/shared_profile_models.dart';
import '../shared_profile/shared_sync_policy.dart';
import 'account_providers.dart';
import 'catalog_sync_providers.dart';
import 'providers.dart';
import 'shared_profile_providers.dart';
import 'social_providers.dart';
import 'sync_providers.dart';

/// The owner's side of the shared profile for the signed-in account.
final sharedProfileRepositoryProvider = Provider<SharedProfileRepository>(
  (ref) => SharedProfileRepository(ref.watch(sharedProfileDataSourceProvider)),
);

/// The owner's UTC offset at calculation time (`tz`, B1). Device zone by
/// default; overridden in tests (America/Sao_Paulo = -180).
final sharedTzProvider = Provider<int Function(DateTime now)>((ref) => deviceTzMinutes);

/// The sections this slice lets the owner turn on (Recomendados: Fatia 4).
const kSharingSections = [SharedSection.stats, SharedSection.activity];

enum SharingPhase {
  /// No active friendships (RF-P1): the section does not exist.
  hidden,

  /// The session read is running (toggles from the local hint, disabled).
  loading,

  /// The server state of this session is known.
  ready,

  /// The state could not be confirmed (no connection): toggles disabled.
  offline,

  /// The phase-2 rules are not published (old rules).
  unavailable,
}

/// A one-shot message for the screen (a SnackBar); [id] tells repeats apart.
class SharingNotice {
  final int id;
  final String text;

  const SharingNotice(this.id, this.text);
}

class SharingState {
  final SharingPhase phase;

  /// The document as the server holds it (null = nothing shared). Only
  /// meaningful when [confirmed].
  final SharedProfileDoc? doc;

  /// [doc] was read from the server in this session (or written by it).
  final bool confirmed;

  /// Sections the device remembers (shown while loading); null = no hint.
  final Set<SharedSection>? hint;

  /// The toggle running now (one at a time, RF-P8).
  final SharedSection? busy;

  /// Toggles whose result is unknown (B5): section -> it was turning ON.
  final Map<SharedSection, bool> uncertain;
  final SharingNotice? notice;

  const SharingState({
    this.phase = SharingPhase.hidden,
    this.doc,
    this.confirmed = false,
    this.hint,
    this.busy,
    this.uncertain = const {},
    this.notice,
  });

  /// What the toggles show.
  Set<SharedSection> get sections => confirmed ? (doc?.sharing ?? const {}) : (hint ?? const {});

  SharingState copyWith({
    SharingPhase? phase,
    SharedProfileDoc? doc,
    bool clearDoc = false,
    bool? confirmed,
    SharedSection? busy,
    bool clearBusy = false,
    Map<SharedSection, bool>? uncertain,
    SharingNotice? notice,
  }) => SharingState(
    phase: phase ?? this.phase,
    doc: clearDoc ? null : (doc ?? this.doc),
    confirmed: confirmed ?? this.confirmed,
    hint: hint,
    busy: clearBusy ? null : (busy ?? this.busy),
    uncertain: uncertain ?? this.uncertain,
    notice: notice ?? this.notice,
  );
}

/// pt-BR "turned off" confirmation (RF-P5).
String sharingOffMessage(SharedSection s) => switch (s) {
  SharedSection.stats => 'Seus amigos não veem mais suas estatísticas.',
  SharedSection.activity => 'Seus amigos não veem mais suas atividades recentes.',
  SharedSection.recs => 'Seus amigos não veem mais seus recomendados.',
};

const kSharingOnConfirmed = 'Compartilhamento ligado.';
const kSharingOffFailed = 'Não foi possível desligar. Tente de novo.';

/// State of "O que seus amigos veem" (docs/82 §7.1, B5): ONE server read per
/// session for accounts with active friendships (it also feeds the rules
/// gate, decision Q1 of docs/85), the consent toggles as transactions, the
/// "uncertain" reconciliation and the local hint. Accounts without active
/// friendships: nothing is read.
class SharingController extends Notifier<SharingState> {
  int _generation = 0;
  int _noticeId = 0;

  @override
  SharingState build() {
    final generation = ++_generation;
    final uid = ref.watch(currentUidProvider);
    if (uid == null) return const SharingState();
    if (!ref.watch(socialActiveProvider)) return const SharingState();
    ref.onDispose(() {
      if (generation == _generation) _generation++;
    });
    // Back online: confirm what is not confirmed yet (and reconcile an
    // uncertain toggle), without any queue (RF-P7).
    ref.listen(syncStatusProvider.select((s) => s.fromCache), (prev, next) {
      if (prev == true && next == false && generation == _generation) _onReconnect(generation);
    });
    Future.microtask(() {
      if (generation == _generation) _load(generation);
    });
    return SharingState(phase: SharingPhase.loading, hint: _readHint(uid));
  }

  Set<SharedSection>? _readHint(String uid) {
    try {
      final raw = ref.read(localStoreProvider).sharedHint(uid);
      if (raw == null) return null;
      return {for (final f in raw) ?SharedSection.fromField(f)};
    } catch (_) {
      return null;
    }
  }

  void _saveHint(SharedProfileDoc? doc) {
    final uid = ref.read(currentUidProvider);
    if (uid == null) return;
    try {
      unawaited(
        ref
            .read(localStoreProvider)
            .setSharedHint(uid, {for (final s in doc?.sharing ?? const {}) s.field})
            .catchError((Object _) {}),
      );
    } catch (_) {}
  }

  void _notice(String text) => state = state.copyWith(notice: SharingNotice(++_noticeId, text));

  /// The server state (this session's read; also the rules probe, Q1).
  Future<void> _load(int generation) async {
    final repo = ref.read(sharedProfileRepositoryProvider);
    try {
      final doc = await repo.readOwn();
      if (generation != _generation) return;
      unawaited(ref.read(sharedRulesGateProvider).feed(RulesProbe.ready));
      _setDoc(doc);
      state = state.copyWith(phase: SharingPhase.ready);
      _resolveUncertain(doc);
    } on SharedProfileFailure catch (f) {
      if (generation != _generation) return;
      if (f.kind == SharedProfileFailureKind.denied) {
        unawaited(ref.read(sharedRulesGateProvider).feed(RulesProbe.oldRules));
        state = state.copyWith(phase: SharingPhase.unavailable);
      } else if (!state.confirmed) {
        state = state.copyWith(phase: SharingPhase.offline);
      }
    } catch (_) {
      if (generation == _generation && !state.confirmed) {
        state = state.copyWith(phase: SharingPhase.offline);
      }
    }
  }

  void _setDoc(SharedProfileDoc? doc) {
    state = doc == null
        ? state.copyWith(clearDoc: true, confirmed: true)
        : state.copyWith(doc: doc, confirmed: true);
    _saveHint(doc);
  }

  void _onReconnect(int generation) {
    if (state.phase == SharingPhase.unavailable) return;
    if (!state.confirmed || state.uncertain.isNotEmpty) _load(generation);
  }

  /// Shows the REAL state after an uncertain toggle (RF-P7).
  void _resolveUncertain(SharedProfileDoc? doc) {
    if (state.uncertain.isEmpty) return;
    final pending = state.uncertain;
    state = state.copyWith(uncertain: const {});
    for (final MapEntry(key: section, value: turningOn) in pending.entries) {
      final shared = doc?.sharing.contains(section) ?? false;
      if (turningOn) {
        if (shared) _notice(kSharingOnConfirmed);
      } else {
        _notice(shared ? kSharingOffFailed : sharingOffMessage(section));
      }
    }
  }

  /// Why a toggle cannot start now (null = it can). Shown as a notice.
  String? blockReason() {
    // One toggle at a time; an uncertain one is still "in progress" (RF-P8).
    if (state.busy != null || state.uncertain.isNotEmpty) {
      return const SharedProfileFailure(SharedProfileFailureKind.busy).message;
    }
    if (state.phase == SharingPhase.unavailable) return SharedProfileFailure.unavailableMessage;
    if (!state.confirmed || ref.read(syncStatusProvider).offline) {
      return SharedProfileFailure.offlineMessage;
    }
    return null;
  }

  /// Tells the screen about [reason] (see [blockReason]).
  void tell(String reason) => _notice(reason);

  /// Turns [section] on with the consent given in the dialog; [content] is
  /// the preview the dialog showed (RF-P4).
  Future<void> turnOn(SharedSection section, SharedProfileContent content) async {
    final generation = _generation;
    final reason = blockReason();
    if (reason != null) return _notice(reason);
    state = state.copyWith(busy: section);
    final now = ref.read(serverClockProvider).now();
    try {
      await ref.read(sharedProfileRepositoryProvider).turnOn(section, content, now);
      if (generation != _generation) return;
      state = state.copyWith(clearBusy: true);
      // The server's own times (`actSince`, `updatedAt`) come with a read.
      final before = state.doc;
      await _load(generation);
      if (generation != _generation) return;
      if (identical(state.doc, before) || !(state.doc?.sharing.contains(section) ?? false)) {
        // The read failed: the local view of the committed transaction.
        final base = state.doc ?? const SharedProfileDoc(sharing: {});
        _setDoc(
          base.copyWith(
            sharing: {...base.sharing, section},
            updatedAt: now,
            tz: content.tz,
            calc: content.calc,
            actSince: section == SharedSection.activity ? now : null,
            stats: section == SharedSection.stats ? content.stats : null,
            activity: section == SharedSection.activity ? const [] : null,
          ),
        );
      }
    } on SharedProfileFailure catch (f) {
      await _onFailure(generation, section, true, f);
    }
  }

  /// Turns [section] off, without confirmation (RF-P5).
  Future<void> turnOff(SharedSection section) async {
    final generation = _generation;
    final reason = blockReason();
    if (reason != null) return _notice(reason);
    state = state.copyWith(busy: section);
    try {
      await ref.read(sharedProfileRepositoryProvider).turnOff(section);
      if (generation != _generation) return;
      state = state.copyWith(clearBusy: true);
      final doc = state.doc;
      final left = {...?doc?.sharing}..remove(section);
      _setDoc(
        doc == null || left.isEmpty
            ? null
            : doc.copyWith(
                sharing: left,
                updatedAt: ref.read(serverClockProvider).now(),
                clearStats: section == SharedSection.stats,
                clearActivity: section == SharedSection.activity,
                clearActSince: section == SharedSection.activity,
                clearRecs: section == SharedSection.recs,
              ),
      );
      _notice(sharingOffMessage(section));
    } on SharedProfileFailure catch (f) {
      await _onFailure(generation, section, false, f);
    }
  }

  Future<void> _onFailure(
    int generation,
    SharedSection section,
    bool turningOn,
    SharedProfileFailure f,
  ) async {
    if (generation != _generation) return;
    state = state.copyWith(clearBusy: true);
    switch (f.kind) {
      case SharedProfileFailureKind.uncertain:
        // It may have happened: never "failed" (B5). Read the server now and
        // at every reconnection until it answers.
        state = state.copyWith(uncertain: {...state.uncertain, section: turningOn});
        await _load(generation);
      case SharedProfileFailureKind.denied:
        // Friendships turned off elsewhere (this section disappears when the
        // friendships state says so) or the rules are old.
        await ref.read(socialControllerProvider.notifier).refresh();
        if (generation != _generation) return;
        _notice(SharedProfileFailure.unavailableMessage);
      default:
        _notice(f.message);
    }
  }

  /// The confirmed server document, for the engine (null = nothing to do).
  SharedProfileDoc? get confirmedDoc => state.confirmed ? state.doc : null;

  /// The engine sent a recalculation: the owner's view follows at once.
  void noteWritten(SharedProfileDoc doc) {
    if (state.confirmed && state.doc != null) _setDoc(doc);
  }

  /// A recalculation failed: back to what the server holds, unless
  /// something newer replaced the optimistic view meanwhile.
  void revertWrite(SharedProfileDoc optimistic, SharedProfileDoc previous) {
    if (identical(state.doc, optimistic)) _setDoc(previous);
  }

  /// The server refused a recalculation (`permission-denied` / `not-found`):
  /// consent changed elsewhere or the rules; read again (docs/82 §6).
  Future<void> reloadAfterRefusal() => _load(_generation);
}

final sharingControllerProvider = NotifierProvider<SharingController, SharingState>(
  SharingController.new,
);

/// Timings of the engine (overridden in tests).
class SharedSyncTiming {
  final Duration window;
  final Duration maxWait;
  final Duration catalogWait;

  const SharedSyncTiming({
    this.window = kSharedSyncWindow,
    this.maxWait = kSharedSyncMaxWait,
    this.catalogWait = kSharedCatalogWait,
  });
}

final sharedSyncTimingProvider = Provider<SharedSyncTiming>((ref) => const SharedSyncTiming());

/// Calls [onHidden] when the page is hidden or paused; returns the disposer.
typedef SharedLifecycleHook = void Function() Function(void Function() onHidden);

final sharedLifecycleHookProvider = Provider<SharedLifecycleHook>(
  (ref) => (onHidden) {
    try {
      final binding = WidgetsBinding.instance;
      final observer = _HiddenObserver(onHidden);
      binding.addObserver(observer);
      return () => binding.removeObserver(observer);
    } catch (_) {
      return () {};
    }
  },
);

/// A plain observer (not `AppLifecycleListener`, which asserts on the order
/// of the transitions): hidden or paused = write what is ready.
class _HiddenObserver with WidgetsBindingObserver {
  final void Function() onHidden;

  _HiddenObserver(this.onHidden);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) onHidden();
  }
}

class SharedSyncState {
  /// A catalog download is running and has not waited [SharedSyncTiming.catalogWait] yet.
  final bool catalogHeld;

  const SharedSyncState({this.catalogHeld = false});
}

/// The favorites the shared content may be calculated from: confirmed by
/// the server in this session, served by the server now, nothing pending,
/// the catalog idle (or waited for long enough). RF-S6.
bool sharedDataReady(SyncStatus status, {required bool catalogHeld}) =>
    status.signedIn &&
    status.serverConfirmed &&
    !status.fromCache &&
    !status.hasPendingWrites &&
    !catalogHeld;

/// The recalculation engine `SharedProfileSync` (docs/82 §6, D4, D7): watches
/// the favorites LISTENER (never the repository: no write of a favorite
/// changes because of it), coalesces (W = 5 s, at most 30 s), writes ONLY
/// when the data is trustworthy and something changed, with its own
/// `update` (never the favorite's batch), and pulses after 24 h. Recreated
/// with the account: timers of a previous session never write.
class SharedProfileSync extends Notifier<SharedSyncState> {
  int _generation = 0;
  Timer? _debounce;
  Timer? _maxWait;
  Timer? _catalogTimer;
  Timer? _wake;
  bool _dirty = false;
  bool _catalogHeld = false;

  void _cancelTimers() {
    _debounce?.cancel();
    _maxWait?.cancel();
    _catalogTimer?.cancel();
    _wake?.cancel();
    _debounce = _maxWait = _catalogTimer = _wake = null;
  }

  @override
  SharedSyncState build() {
    final generation = ++_generation;
    _cancelTimers();
    _dirty = false;
    _catalogHeld = false;
    final uid = ref.watch(currentUidProvider);
    ref.onDispose(() {
      if (generation == _generation) _generation++;
      _cancelTimers();
    });
    if (uid == null) return const SharedSyncState();
    final timing = ref.read(sharedSyncTimingProvider);

    ref.listen(sharingControllerProvider, (prev, next) {
      final before = prev?.confirmed == true ? prev?.doc?.sharing : null;
      final after = next.confirmed ? next.doc?.sharing : null;
      // Session start (state confirmed) and a section turned on elsewhere.
      if (after != null && (before == null || !_sameSet(before, after))) _trigger(generation);
      if (after == null) _discard();
    }, fireImmediately: true);
    ref.listen<AsyncValue<List<FavoriteDoc>>>(favoriteDocsProvider, (_, next) {
      if (next.hasValue) _trigger(generation);
    }, fireImmediately: true);
    ref.listen(catalogSyncProvider.select((s) => s.isRunning), (_, running) {
      _catalogTimer?.cancel();
      _catalogTimer = null;
      if (running) {
        _setHeld(generation, true);
        _catalogTimer = Timer(timing.catalogWait, () {
          _setHeld(generation, false);
          _resume(generation);
        });
      } else {
        _setHeld(generation, false);
        _trigger(generation); // durations / catalog may change the numbers
      }
    }, fireImmediately: true);
    ref.listen(syncStatusProvider, (_, _) => _resume(generation));
    ref.listen(profileProvider.select((p) => p.valueOrNull?.deleting ?? false), (_, deleting) {
      if (deleting) _discard();
    });
    ref.listen(accountControllerProvider.select((s) => s.running), (_, running) {
      if (running) _discard();
    });
    final dispose = ref.read(sharedLifecycleHookProvider)(() => _flush(generation));
    ref.onDispose(dispose);
    return const SharedSyncState();
  }

  static bool _sameSet(Set<SharedSection> a, Set<SharedSection> b) =>
      a.length == b.length && a.containsAll(b);

  void _setHeld(int generation, bool held) {
    _catalogHeld = held;
    scheduleMicrotask(() {
      if (generation == _generation && state.catalogHeld != held) {
        state = SharedSyncState(catalogHeld: held);
      }
    });
  }

  /// A change pending while the conditions did not hold: once they do, the
  /// usual window applies (1 write).
  void _resume(int generation) {
    if (_dirty && _debounce == null && _ready()) _trigger(generation);
  }

  /// Exclusion / deactivation / nothing shared: pending work is dropped.
  void _discard() {
    _dirty = false;
    _debounce?.cancel();
    _maxWait?.cancel();
    _wake?.cancel();
    _debounce = _maxWait = _wake = null;
  }

  bool _sharing() {
    final doc = ref.read(sharingControllerProvider.notifier).confirmedDoc;
    return doc != null && doc.sharing.isNotEmpty;
  }

  void _trigger(int generation) {
    if (generation != _generation || !_sharing()) return;
    final timing = ref.read(sharedSyncTimingProvider);
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(timing.window, () => _flush(generation));
    _maxWait ??= Timer(timing.maxWait, () => _flush(generation));
  }

  bool _ready() {
    if (!_sharing()) return false;
    if (!sharedDataReady(ref.read(syncStatusProvider), catalogHeld: _catalogHeld)) return false;
    if (ref.read(profileProvider).valueOrNull?.deleting ?? false) return false;
    if (ref.read(accountControllerProvider).running) return false;
    // A friendships operation (deactivation deletes this document) runs.
    if (ref.read(socialControllerProvider).busy) return false;
    return true;
  }

  void _flush(int generation) {
    _debounce?.cancel();
    _maxWait?.cancel();
    _debounce = _maxWait = null;
    if (generation != _generation || !_dirty) return;
    if (!_ready()) return; // stays dirty: [_resume] picks it up
    _dirty = false;
    _write(generation);
  }

  void _write(int generation) {
    final controller = ref.read(sharingControllerProvider.notifier);
    final doc = controller.confirmedDoc;
    final docs = ref.read(favoriteDocsProvider).valueOrNull;
    if (doc == null || doc.sharing.isEmpty || docs == null) return;
    final now = ref.read(serverClockProvider).now();
    final tz = ref.read(sharedTzProvider)(now);
    final store = ref.read(localStoreProvider);
    final SharedProfileContent content;
    try {
      content = SharedProfileBuilder.build(
        docs,
        catalog: store.readSeasonCatalog,
        movieRuntime: store.readMovieRuntime,
        tvFallbackRuntime: store.readTvFallbackRuntime,
        sections: doc.sharing,
        now: now,
        tzMinutes: tz,
        actSince: doc.actSince,
        memberSince: ref.read(currentUserProvider)?.createdAt,
      );
    } catch (_) {
      return;
    }
    final decision = SharedSyncPolicy.decide(doc, content, now);
    if (!decision.writes) return _scheduleWake(generation, doc, tz, now);
    final repo = ref.read(sharedProfileRepositoryProvider);
    final optimistic = decision.changed.isEmpty
        ? doc.copyWith(updatedAt: now)
        : doc.afterRecalc(content, decision.changed, now);
    controller.noteWritten(optimistic);
    final write = decision.changed.isEmpty
        ? repo.pulse()
        : repo.recalc(content, decision.changed, now: now, actSince: doc.actSince);
    // Not awaited by anyone: a failure is silent (no banner) and never
    // retried here (at most 1 attempt per trigger, RF-S8).
    unawaited(
      write.then(
        (_) {},
        onError: (Object e) {
          if (generation != _generation) return;
          final kind = e is SharedProfileFailure ? e.kind : null;
          if (kind == SharedProfileFailureKind.denied ||
              kind == SharedProfileFailureKind.notFound) {
            controller.reloadAfterRefusal();
          } else {
            controller.revertWrite(optimistic, doc);
          }
        },
      ),
    );
    _scheduleWake(generation, optimistic, tz, now);
  }

  /// Wakes up at the owner's next month turn or when the pulse is due,
  /// whatever comes first (only while the app is open).
  void _scheduleWake(int generation, SharedProfileDoc doc, int tz, DateTime now) {
    _wake?.cancel();
    final turn = SharedSyncPolicy.nextMonthTurn(now, tz);
    final pulse = (doc.updatedAt ?? now).add(kSharedPulseAge + const Duration(seconds: 1));
    final at = turn.isBefore(pulse) ? turn : pulse;
    var wait = at.difference(now);
    if (wait < const Duration(seconds: 1)) wait = const Duration(seconds: 1);
    _wake = Timer(wait, () => _trigger(generation));
  }
}

final sharedProfileSyncProvider = NotifierProvider<SharedProfileSync, SharedSyncState>(
  SharedProfileSync.new,
);

/// The content the consent dialog previews for [section] (null = the data
/// is not trustworthy yet: "Calculando…", RF-P4). Same builder and inputs as
/// the engine, so the preview equals what will be written.
final sharedPreviewProvider = Provider.family<SharedProfileContent?, SharedSection>((ref, section) {
  final status = ref.watch(syncStatusProvider);
  final held = ref.watch(sharedProfileSyncProvider.select((s) => s.catalogHeld));
  if (!sharedDataReady(status, catalogHeld: held)) return null;
  ref.watch(favoritesListProvider); // catalog changes
  final docs = ref.watch(favoriteDocsProvider).valueOrNull;
  if (docs == null) return null;
  final now = ref.read(serverClockProvider).now();
  final store = ref.watch(localStoreProvider);
  return SharedProfileBuilder.build(
    docs,
    catalog: store.readSeasonCatalog,
    movieRuntime: store.readMovieRuntime,
    tvFallbackRuntime: store.readTvFallbackRuntime,
    sections: {section},
    now: now,
    tzMinutes: ref.read(sharedTzProvider)(now),
    actSince: now,
    memberSince: ref.watch(currentUserProvider)?.createdAt,
  );
});
