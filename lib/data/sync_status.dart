import 'dart:async';

/// Why a write that the app had already accepted locally was refused later
/// by the server (or why the session can no longer sync).
enum SyncFailureKind {
  /// Security rules refused the write (invalid data, wrong owner...).
  permissionDenied,

  /// Free-tier daily quota exhausted.
  quotaExceeded,

  /// The session is no longer valid; pending changes wait for a new login.
  sessionExpired,
  unknown,
}

/// Typed sync failure. [code] is the provider's error code (safe to log:
/// never contains e-mail, name, token or document data).
class SyncFailure {
  final SyncFailureKind kind;
  final String? code;

  const SyncFailure(this.kind, {this.code});

  factory SyncFailure.fromCode(String code) => switch (code) {
        'permission-denied' => SyncFailure(SyncFailureKind.permissionDenied, code: code),
        'resource-exhausted' => SyncFailure(SyncFailureKind.quotaExceeded, code: code),
        'unauthenticated' => SyncFailure(SyncFailureKind.sessionExpired, code: code),
        _ => SyncFailure(SyncFailureKind.unknown, code: code),
      };

  /// pt-BR text for the banner.
  String get message => switch (kind) {
        SyncFailureKind.permissionDenied =>
          'O servidor recusou uma alteração e ela não foi salva. Se continuar, avise quem mantém o app.',
        SyncFailureKind.quotaExceeded =>
          'O limite diário gratuito do serviço foi atingido. Novas alterações podem não ser '
              'salvas até o limite renovar.',
        SyncFailureKind.sessionExpired =>
          'Sessão expirada. Entre novamente para sincronizar; suas alterações pendentes ficam '
              'guardadas neste aparelho.',
        SyncFailureKind.unknown => 'Não foi possível sincronizar uma alteração. Tente novamente.',
      };

  @override
  String toString() => 'SyncFailure($kind, code: $code)';
}

/// What the local database reports about its relation to the server.
class SyncMeta {
  /// There are local writes the server has not acknowledged yet.
  final bool hasPendingWrites;

  /// The data being shown came from the local cache, not from the server
  /// (offline, or the server has not answered yet).
  final bool fromCache;

  const SyncMeta({this.hasPendingWrites = false, this.fromCache = false});

  /// Nothing pending, nothing stale: used by sources with no backend.
  static const settled = SyncMeta();
}

/// Where data sources report writes the server rejected after the UI had
/// already moved on (writes are not awaited, so nothing can throw to the
/// caller). One sink per signed-in account; the sync status listens to it.
///
/// The stream is broadcast (no buffer), so on its own a failure reported while
/// nobody listens would vanish. That is why the sink ALSO remembers the latest
/// failure until somebody [acknowledge]s it: a late listener reads
/// [unacknowledged] and nothing depends on who happens to be observing when
/// the rejection arrives.
class SyncFailureSink {
  final _controller = StreamController<SyncFailure>.broadcast();
  SyncFailure? _unacknowledged;

  Stream<SyncFailure> get stream => _controller.stream;

  /// Latest failure nobody dismissed yet (null = none).
  SyncFailure? get unacknowledged => _unacknowledged;

  /// The user saw and dismissed the failure.
  void acknowledge() => _unacknowledged = null;

  void reportCode(String code) => _add(SyncFailure.fromCode(code));

  void reportUnknown(Object error) =>
      _add(SyncFailure(SyncFailureKind.unknown, code: error.runtimeType.toString()));

  void report(SyncFailure failure) => _add(failure);

  void _add(SyncFailure failure) {
    if (_controller.isClosed) return;
    _unacknowledged = failure;
    _controller.add(failure);
  }

  /// Starts [write] and returns right away, WITHOUT waiting for the server:
  /// a Firestore write Future completes only after the server acknowledges
  /// it, so awaiting it would freeze the UI while offline. The returned
  /// Future means "accepted locally". Transient failures (network) are
  /// retried by the backend and never reach here; an error that does is a
  /// permanent rejection (rules, quota, auth) and is reported to this sink.
  /// [codeOf] extracts the provider error code (null = not a provider error).
  Future<void> fire(Future<void> Function() write, {required String? Function(Object) codeOf}) {
    Future<void> started;
    try {
      started = write();
    } catch (error) {
      started = Future<void>.error(error);
    }
    unawaited(started.catchError((Object error) {
      final code = codeOf(error);
      if (code != null) {
        reportCode(code);
      } else {
        reportUnknown(error);
      }
    }));
    return Future<void>.value();
  }

  void dispose() => _controller.close();
}

enum SyncPhase { connecting, synced, pending, stalled, offline, failed }

/// What the UI shows about synchronization. Pure value, built by the
/// notifier in `sync_providers.dart`.
class SyncStatus {
  final bool signedIn;
  final bool fromCache;
  final bool hasPendingWrites;

  /// At least one snapshot confirmed by the server was seen.
  final bool serverConfirmed;

  /// The grace period for the first server answer has passed.
  final bool graceOver;

  /// Connected, yet local writes stay unacknowledged for too long. The SDK
  /// keeps RETRYING `resource-exhausted` and `unauthenticated` instead of
  /// failing the write, so those causes never arrive as a [SyncFailure]; this
  /// time-based signal is the only trace of them. The cause is unknown here.
  final bool pendingStalled;
  final SyncFailure? failure;

  static const stalledMessage =
      'Não conseguimos confirmar suas últimas alterações. Elas continuam guardadas neste '
      'aparelho e serão reenviadas. Se isso persistir, tente mais tarde.';

  const SyncStatus({
    this.signedIn = true,
    this.fromCache = false,
    this.hasPendingWrites = false,
    this.serverConfirmed = false,
    this.graceOver = false,
    this.pendingStalled = false,
    this.failure,
  });

  static const signedOut = SyncStatus(signedIn: false, fromCache: false, serverConfirmed: true);

  /// Serving cache after the server was seen, or the server never answered
  /// within the grace period.
  bool get offline => signedIn && fromCache && (serverConfirmed || graceOver);

  /// Cannot tell "no favorites" from "could not load": the server has not
  /// confirmed anything and the grace period is over.
  bool get unconfirmed => signedIn && !serverConfirmed && graceOver;

  /// Still waiting for the first server answer (not yet worth an alarm).
  bool get connecting => signedIn && !serverConfirmed && !graceOver;

  SyncPhase get phase {
    if (failure != null) return SyncPhase.failed;
    if (!signedIn) return SyncPhase.synced;
    if (offline) return SyncPhase.offline;
    if (hasPendingWrites && pendingStalled) return SyncPhase.stalled;
    if (hasPendingWrites) return SyncPhase.pending;
    if (connecting) return SyncPhase.connecting;
    return SyncPhase.synced;
  }

  SyncStatus copyWith({
    bool? fromCache,
    bool? hasPendingWrites,
    bool? serverConfirmed,
    bool? graceOver,
    bool? pendingStalled,
    SyncFailure? failure,
    bool clearFailure = false,
  }) =>
      SyncStatus(
        signedIn: signedIn,
        fromCache: fromCache ?? this.fromCache,
        hasPendingWrites: hasPendingWrites ?? this.hasPendingWrites,
        serverConfirmed: serverConfirmed ?? this.serverConfirmed,
        graceOver: graceOver ?? this.graceOver,
        pendingStalled: pendingStalled ?? this.pendingStalled,
        failure: clearFailure ? null : (failure ?? this.failure),
      );
}
