import 'package:cinetrack/auth/app_user.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/providers/providers.dart';
import 'package:cinetrack/providers/shared_profile_providers.dart';
import 'package:cinetrack/providers/sharing_providers.dart';
import 'package:cinetrack/providers/sync_providers.dart';
import 'package:cinetrack/shared_profile/shared_profile_builder.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_overrides.dart';
import 'fake_auth_repository.dart';
import 'fake_shared_profile_cloud.dart';
import 'fake_social_cloud.dart';
import 'favorites_harness.dart';
import 'in_memory_favorites_data_source.dart';

/// 15/10/2026 12:00 in America/Sao_Paulo (UTC-3, tz = -180).
final kSharingNow = DateTime.utc(2026, 10, 15, 15);
const kSaoPaulo = -180;

final kAnaSince = DateTime.utc(2025, 3, 2, 10);
final kAnaUser = AppUser(
  uid: 'uid-ana',
  displayName: 'Ana Teste',
  email: 'ana@example.test',
  createdAt: kAnaSince,
);

FavoriteDoc sharingMovie(int id, {bool watched = false, DateTime? at, String? title}) =>
    FavoriteDoc(
      id: id,
      mediaType: MediaType.movie,
      title: title ?? 'Filme $id',
      posterPath: '/p$id.jpg',
      overview: '',
      addedAt: DateTime.utc(2026, 1, 1),
      watchedMovie: watched,
      lastWatchedAt: watched ? (at ?? DateTime.utc(2026, 1, 2)) : null,
    );

/// Fakes + overrides for the sharing controller and the engine: an
/// in-memory cloud, Ana with active friendships, a fixed clock (UTC-3).
class SharingRig {
  final cloud = FakeCloud();
  final social = FakeSocialCloud();
  final store = FakeLocalStore();
  final List<String> log = [];
  late final FakeSharedProfileCloud shared = FakeSharedProfileCloud(log: log);
  late final FakeAuthRepository auth;
  DateTime now = kSharingNow;
  final List<void Function()> hidden = [];

  SharingRig({bool active = true, AppUser? user}) {
    auth = FakeAuthRepository(initialUser: user ?? kAnaUser);
    if (active) social.seedActive('uid-ana', 'ana');
    shared.clock = () => now;
    cloud.clock = () => now;
    cloud.datesEnabled = true;
    cloud.server['uid-ana'] = {};
  }

  List<Override> overrides({List<Override> extra = const []}) => [
    ...cloudOverrides(
      auth: auth,
      cloud: cloud,
      socialCloud: social,
      sharedCloud: shared,
      store: store,
    ),
    sharedProfileClockProvider.overrideWithValue(() => now),
    sharedTzProvider.overrideWithValue((_) => kSaoPaulo),
    sharedLifecycleHookProvider.overrideWithValue((cb) {
      hidden.add(cb);
      return () => hidden.remove(cb);
    }),
    ...extra,
  ];

  /// A container with the engine running (as the app shell does).
  ProviderContainer container({List<Override> extra = const []}) {
    final c = ProviderContainer(overrides: overrides(extra: extra));
    c.listen(authStateProvider, (_, _) {});
    c.listen(syncStatusProvider, (_, _) {});
    c.listen(sharedProfileSyncProvider, (_, _) {});
    c.listen(sharingControllerProvider, (_, _) {});
    return c;
  }

  void seed(FavoriteDoc doc) => cloud.server['uid-ana']![doc.key] = doc;

  /// The server document as the app itself would have written it from the
  /// current favorites (so a recalculation finds it "equal").
  void seedShared(
    Set<SharedSection> sections, {
    DateTime? updatedAt,
    DateTime? actSince,
    SharedProfileContent? content,
  }) {
    final c =
        content ??
        SharedProfileBuilder.build(
          cloud.server['uid-ana']!.values.toList(),
          catalog: store.readSeasonCatalog,
          sections: sections,
          now: now,
          tzMinutes: kSaoPaulo,
          actSince: actSince ?? now,
          memberSince: kAnaSince,
        );
    shared.docs['uid-ana'] = {
      'v': 1,
      'calc': c.calc,
      'updatedAt': updatedAt ?? now,
      'tz': c.tz,
      'sharing': {for (final s in sections) s.field: true},
      if (sections.contains(SharedSection.activity)) 'actSince': actSince ?? now,
      for (final s in sections) s.field: c.section(s),
    };
  }

  Map<String, dynamic>? get doc => shared.docs['uid-ana'];

  /// Recalculation writes that reached the fake server.
  int get writes => shared.writes.length;
}
