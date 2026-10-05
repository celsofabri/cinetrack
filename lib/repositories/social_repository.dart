import '../account/account_deletion_failure.dart';
import '../data/social_data_source.dart';
import '../social/social_models.dart';
import '../social/social_validation.dart';

/// Result of reading the user's social state.
class SocialLoad {
  /// Null = friendships are not activated for this account.
  final SocialProfile? profile;

  /// The answer came from this device (no server confirmation).
  final bool fromCache;

  const SocialLoad({this.profile, this.fromCache = false});
}

/// Rules of the friendships feature for the signed-in user, over a
/// [SocialDataSource]: validation that matches `firestore.rules`, the 30-day
/// interval, and the sweeps that the rules cannot do (they never iterate).
///
/// Nothing here writes for a user who did not turn friendships on: the only
/// calls that reach the server for them are reads.
class SocialRepository {
  final SocialDataSource _data;
  final DateTime Function() _now;

  /// Documents deleted per batch (Firestore allows 500).
  final int pageSize;

  /// Guard so a bug can never loop forever (400 * 500 = 200k documents).
  final int maxPages;

  SocialRepository(this._data, {DateTime Function()? now, this.pageSize = 400, this.maxPages = 500})
    : _now = now ?? DateTime.now;

  /// Server first; when the server cannot be reached, whatever the device has.
  /// Throws [SocialFailure] ([SocialFailureKind.denied] = the rules that allow
  /// the feature are not published yet).
  Future<SocialLoad> load() async {
    try {
      final raw = await _data.read(fromServer: true);
      return SocialLoad(profile: SocialProfile.fromRaw(raw.social, raw.card));
    } on SocialFailure catch (e) {
      if (e.kind != SocialFailureKind.offline && e.kind != SocialFailureKind.uncertain) rethrow;
      try {
        final raw = await _data.read(fromServer: false);
        return SocialLoad(profile: SocialProfile.fromRaw(raw.social, raw.card), fromCache: true);
      } on SocialFailure {
        throw e;
      }
    }
  }

  /// pt-BR reason why [rawHandle] cannot be used, or null when it is valid
  /// and free. Throws on network errors.
  Future<String?> handleProblem(String rawHandle, {String? current}) async {
    final error = Handle.errorFor(rawHandle);
    if (error != null) return error;
    final handle = Handle.normalize(rawHandle);
    if (handle == current) return null;
    final free = await _data.isHandleFree(handle);
    return free ? null : const SocialFailure(SocialFailureKind.handleTaken).message;
  }

  /// Turns friendships on. [googlePhotoUrl] is copied to the card only when
  /// it passes the same test as the rules; otherwise the card has no photo.
  Future<void> activate({
    required String rawHandle,
    required String rawNickname,
    String? googlePhotoUrl,
    required bool showPhoto,
    required bool discoverable,
  }) {
    final handleError = Handle.errorFor(rawHandle);
    if (handleError != null) return _invalid(handleError);
    final nicknameError = SocialNickname.errorFor(rawNickname);
    if (nicknameError != null) return _invalid(nicknameError);
    return _data.activate(
      SocialDraft(
        handle: Handle.normalize(rawHandle),
        nickname: SocialNickname.normalize(rawNickname)!,
        photoUrl: showPhoto ? SocialPhoto.sanitize(googlePhotoUrl) : null,
        discoverable: discoverable,
      ),
    );
  }

  /// Changes the handle (at most once every 30 days, checked by the rules
  /// with the server clock; checked here too for a clear message).
  Future<void> changeHandle(String rawHandle, {required SocialProfile current}) {
    final error = Handle.errorFor(rawHandle);
    if (error != null) return _invalid(error);
    final handle = Handle.normalize(rawHandle);
    if (handle == current.handle) return _invalid('Esse já é o seu identificador.');
    if (!current.canChangeHandle(_now())) {
      return Future.error(
        SocialFailure(SocialFailureKind.tooSoon, retryAt: current.nextHandleChange),
      );
    }
    return _data.changeHandle(handle);
  }

  Future<void> updateNickname(String rawNickname) {
    final error = SocialNickname.errorFor(rawNickname);
    if (error != null) return _invalid(error);
    return _data.updateCard(CardPatch(nickname: SocialNickname.normalize(rawNickname)));
  }

  Future<void> setDiscoverable(bool value) => _data.updateCard(CardPatch(discoverable: value));

  Future<void> setPhotoVisible(bool visible, {String? googlePhotoUrl}) {
    final url = visible ? SocialPhoto.sanitize(googlePhotoUrl) : null;
    if (visible && url == null) {
      return _invalid('Não foi possível usar a foto da sua conta Google.');
    }
    return _data.updateCard(CardPatch(changePhoto: true, photoUrl: url));
  }

  /// Turns friendships off: sweep (friends, requests sent and received,
  /// blocks), close the door (card, invite and pointer in one batch), sweep
  /// AGAIN. The first sweep keeps friendships visibly "on" if it fails (retry
  /// from the UI). Once the pointer is gone nobody can create requests or
  /// pairs involving this user, so the second sweep removes whatever was
  /// created between the first sweep and the close: no residue is possible,
  /// except when that last sweep itself fails. Then this throws a
  /// [SocialFailure] with code [cleanupPendingCode] (the UI offers
  /// [finishCleanup]; account deletion also always sweeps). Retryable and
  /// idempotent; pages of [pageSize].
  Future<void> deactivate() async {
    await sweepAll();
    await _data.closeSocial();
    try {
      await sweepAll();
    } on SocialFailure catch (e) {
      throw SocialFailure(e.kind, code: cleanupPendingCode);
    }
  }

  /// Code of the failure thrown when friendships are already off but the
  /// final sweep did not finish.
  static const cleanupPendingCode = 'cleanup-pending';

  /// Removes any friends, requests and blocks still involving this user.
  Future<void> sweepAll() async {
    for (final kind in SweepKind.values) {
      await _sweep(kind);
    }
  }

  /// Completes a deactivation whose last sweep failed.
  Future<void> finishCleanup() => sweepAll();

  /// Account deletion: the pointer goes FIRST ("close the door": without
  /// `social` nobody can send or accept a request for this uid), then the
  /// sweeps. Throws [AccountDeletionFailure]. Retryable and idempotent: a
  /// second run finds no pointer and just finishes the sweeps.
  ///
  /// Rollout: while the rules are not published the first read is denied and
  /// no social data can exist, so there is nothing to delete.
  Future<void> wipeForAccountDeletion() async {
    try {
      try {
        await _data.closeSocial();
      } on SocialFailure catch (e) {
        if (e.kind == SocialFailureKind.denied) return;
        rethrow;
      }
      for (final kind in SweepKind.values) {
        await _sweep(kind);
      }
    } on SocialFailure catch (e) {
      throw toAccountDeletionFailure(e);
    }
  }

  Future<void> _sweep(SweepKind kind) async {
    for (var i = 0; i < maxPages; i++) {
      final page = await _data.readSweepPage(kind, limit: pageSize);
      if (page.isEmpty) return;
      await _data.deleteRefs(page);
    }
    throw const SocialFailure(SocialFailureKind.unknown, code: 'too-many-pages');
  }

  Future<T> _invalid<T>(String detail) =>
      Future.error(SocialFailure(SocialFailureKind.invalid, detail: detail));
}

/// Account deletion speaks [AccountDeletionFailure].
AccountDeletionFailure toAccountDeletionFailure(SocialFailure e) =>
    AccountDeletionFailure(switch (e.kind) {
      SocialFailureKind.offline => AccountDeletionFailureKind.offline,
      SocialFailureKind.uncertain => AccountDeletionFailureKind.uncertain,
      SocialFailureKind.quotaExceeded => AccountDeletionFailureKind.quotaExceeded,
      SocialFailureKind.sessionExpired => AccountDeletionFailureKind.sessionExpired,
      _ => AccountDeletionFailureKind.unknown,
    }, code: e.code);
