import 'dart:async';

import 'package:cinetrack/account/account_deletion_failure.dart';
import 'package:cinetrack/data/favorites_data_source.dart';
import 'package:cinetrack/data/profile_data_source.dart';
import 'package:cinetrack/data/sync_status.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/services/favorite_mapper.dart';

typedef CloudOp = void Function(Map<String, FavoriteDoc> docs);

/// Fake "Firestore" shared by every [InMemoryFavoritesDataSource] of a test:
/// one document space per uid, field-level merge for episodes (same
/// semantics as the real server) and an optional offline mode.
///
/// Offline model (an ASSUMPTION about the SDK, premise 5b of the design —
/// to be verified in spike S1, not proven by these fakes): writes made while
/// offline are queued per uid, are visible to that uid immediately
/// (optimistic) and only reach the server on `flush(uid)`.
class FakeCloud {
  final Map<String, Map<String, FavoriteDoc>> server = {};
  final Map<String, List<CloudOp>> pending = {};
  bool _offline = false;
  bool get offline => _offline;
  set offline(bool value) {
    _offline = value;
    _changes.add(null);
  }

  /// Connected but the server never acknowledges writes (what the SDK does
  /// when it keeps retrying `resource-exhausted`/`unauthenticated`): writes
  /// stay pending while `fromCache` is false.
  bool stuck = false;

  /// Profile documents (`users/{uid}`) per uid.
  final Map<String, UserProfile> profiles = {};

  /// Order of the account-deletion operations that reached the "server".
  final List<String> deletionLog = [];

  /// Makes the named deletion step ('markDeleting', 'deleteAllFavorites',
  /// 'deleteProfile') throw once.
  final Map<String, AccountDeletionFailure> deletionFailures = {};

  /// Simulates a cold cache while offline: `get` cannot tell whether the
  /// document exists and throws [FavoritesUnavailableException].
  bool readsUnavailable = false;
  final _changes = StreamController<void>.broadcast();

  Map<String, FavoriteDoc> view(String uid) {
    final docs = {...?server[uid]};
    for (final op in pending[uid] ?? const <CloudOp>[]) {
      op(docs);
    }
    return docs;
  }

  void write(String uid, CloudOp op) {
    if (offline || stuck) {
      (pending[uid] ??= []).add(op);
    } else {
      flush(uid, notify: false);
      op(server[uid] ??= {});
    }
    _changes.add(null);
  }

  /// Sends [uid]'s queued writes to the server (that user is back online).
  void flush(String uid, {bool notify = true}) {
    final ops = pending.remove(uid) ?? const <CloudOp>[];
    for (final op in ops) {
      op(server[uid] ??= {});
    }
    if (notify) _changes.add(null);
  }

  Stream<void> get changes => _changes.stream;
}

class InMemoryFavoritesDataSource implements FavoritesDataSource {
  final FakeCloud cloud;
  final String uid;

  InMemoryFavoritesDataSource(this.cloud, {required this.uid});

  @override
  Stream<List<FavoriteDoc>> watchAll() {
    late final StreamController<List<FavoriteDoc>> controller;
    StreamSubscription<void>? sub;
    controller = StreamController<List<FavoriteDoc>>(
      onListen: () {
        controller.add(cloud.view(uid).values.toList());
        sub = cloud.changes.listen((_) => controller.add(cloud.view(uid).values.toList()));
      },
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }

  @override
  Stream<SyncMeta> watchSyncMeta() {
    late final StreamController<SyncMeta> controller;
    StreamSubscription<void>? sub;
    SyncMeta current() => SyncMeta(
          hasPendingWrites: (cloud.pending[uid] ?? const []).isNotEmpty,
          fromCache: cloud.offline,
        );
    controller = StreamController<SyncMeta>(
      onListen: () {
        controller.add(current());
        sub = cloud.changes.listen((_) => controller.add(current()));
      },
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }

  @override
  Future<FavoriteDoc?> get(String key) async {
    if (cloud.readsUnavailable) throw const FavoritesUnavailableException();
    return cloud.view(uid)[key];
  }

  @override
  Future<void> add(FavoriteDoc doc) async => cloud.write(uid, (docs) => docs[doc.key] ??= doc);

  @override
  Future<void> remove(String key) async => cloud.write(uid, (docs) => docs.remove(key));

  @override
  Future<void> setWatchedMovie(String key, bool watched) async => cloud.write(uid, (docs) {
        final doc = docs[key];
        if (doc != null) {
          docs[key] = doc.copyWith(watchedMovie: watched, lastWatchedAt: DateTime.now());
        }
      });

  @override
  Future<void> setEpisodes(String key, Map<String, bool> changes) async => cloud.write(uid, (docs) {
        final doc = docs[key];
        if (doc == null) return;
        docs[key] = doc.copyWith(
          watchedEpisodes: FavoriteMapper.applyEpisodeChanges(doc.watchedEpisodes, changes),
          lastWatchedAt: DateTime.now(),
        );
      });

  @override
  Future<void> setSeasonSummaries(String key, List<TvSeasonSummary> summaries) async =>
      cloud.write(uid, (docs) {
        final doc = docs[key];
        if (doc != null) docs[key] = doc.copyWith(seasonSummaries: summaries);
      });

  @override
  Future<void> setRecommended(String key, bool recommended) async => cloud.write(uid, (docs) {
        final doc = docs[key];
        // Like `update` on the server: a missing document is never recreated.
        if (doc != null) docs[key] = doc.copyWith(recommended: recommended);
      });
}

/// In-memory profile document + account-deletion operations over [FakeCloud].
class InMemoryProfileDataSource implements ProfileDataSource {
  final FakeCloud cloud;
  final String uid;

  InMemoryProfileDataSource(this.cloud, {required this.uid});

  @override
  Stream<UserProfile> watch() {
    late final StreamController<UserProfile> controller;
    StreamSubscription<void>? sub;
    UserProfile current() => cloud.profiles[uid] ?? UserProfile.empty;
    controller = StreamController<UserProfile>(
      onListen: () {
        controller.add(current());
        sub = cloud.changes.listen((_) => controller.add(current()));
      },
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }

  @override
  Future<void> setNickname(String? nickname) async {
    final old = cloud.profiles[uid] ?? UserProfile.empty;
    cloud.profiles[uid] = UserProfile(nickname: nickname, deleting: old.deleting);
    cloud.write(uid, (_) {});
  }

  void _step(String name) {
    final failure = cloud.deletionFailures.remove(name);
    if (failure != null) throw failure;
    cloud.deletionLog.add(name);
  }

  @override
  Future<void> ensureOnline() async {
    if (cloud.offline) {
      throw const AccountDeletionFailure(AccountDeletionFailureKind.offline);
    }
    cloud.deletionLog.add('ensureOnline');
  }

  @override
  Future<void> markDeleting() async {
    _step('markDeleting');
    final old = cloud.profiles[uid] ?? UserProfile.empty;
    cloud.profiles[uid] = UserProfile(nickname: old.nickname, deleting: true);
    cloud.write(uid, (_) {});
  }

  @override
  Future<void> deleteAllFavorites() async {
    _step('deleteAllFavorites');
    cloud.server[uid]?.clear();
    cloud.pending.remove(uid);
    cloud.write(uid, (_) {});
  }

  @override
  Future<void> deleteProfile() async {
    _step('deleteProfile');
    cloud.profiles.remove(uid);
    cloud.write(uid, (_) {});
  }
}
