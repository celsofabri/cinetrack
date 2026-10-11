import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/firestore_shared_profile_data_source.dart';
import '../data/server_clock.dart';
import '../data/shared_profile_data_source.dart';
import '../data/shared_rules_gate.dart';
import '../firebase_options.dart';
import 'providers.dart';
import 'sharing_providers.dart';
import 'social_providers.dart';

typedef SharedProfileDataSourceFactory = SharedProfileDataSource Function(String uid);

/// Builds the shared-profile data source for a uid. Overridden in tests.
final sharedProfileDataSourceFactoryProvider = Provider<SharedProfileDataSourceFactory>(
  (ref) =>
      (uid) => FirestoreSharedProfileDataSource(uid: uid),
);

/// Depends on the uid (recreated when the account changes); signed out =
/// inert.
final sharedProfileDataSourceProvider = Provider<SharedProfileDataSource>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return const SignedOutSharedProfileDataSource();
  return ref.watch(sharedProfileDataSourceFactoryProvider)(uid);
});

/// THE clock of the shared profile (docs/82 §5, B1): periods, activities and
/// `EpisodeCache.hasAiredAt` in the calculation. Overridden in tests.
final sharedProfileClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Device clock corrected by the server offset (mark dates, docs/82 §4.2).
/// One per account session.
final serverClockProvider = Provider<ServerClock>((ref) {
  ref.watch(currentUidProvider);
  return ServerClock(deviceNow: ref.watch(sharedProfileClockProvider));
});

/// Project whose rules the probe confirmed (the flag is per project).
final firebaseProjectIdProvider = Provider<String>((ref) => DefaultFirebaseOptions.web.projectId);

/// The `epsAt` gate (docs/82 §4.2, D17): created with the account session.
/// Unless this device already saw the rules published, ONE read decides it
/// (docs/85, decision Q1): with active friendships it is the owner's session
/// read of `shared_profiles/{uid}` (the sharing controller feeds this SAME
/// gate); without them, the dedicated probe.
final sharedRulesGateProvider = Provider<SharedRulesGate>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return SharedRulesGate.closed();
  final source = ref.watch(sharedProfileDataSourceProvider);
  final store = ref.watch(localStoreProvider);
  final project = ref.watch(firebaseProjectIdProvider);
  final gate = SharedRulesGate(
    probe: source.probeRules,
    isStoredReady: () => store.sharedRulesReady(project),
    storeReady: () => store.setSharedRulesReady(project),
    clearStored: () => store.clearSharedRulesReady(project),
  );
  if (!gate.open) {
    void decide(SocialPhase phase) {
      if (gate.open || gate.lastProbe != null) return;
      final social = ref.read(socialControllerProvider.notifier);
      final active =
          phase == SocialPhase.active || (phase == SocialPhase.loading && social.hinted == true);
      if (active) {
        // The session read is the probe: make sure it runs.
        Future.microtask(() => ref.read(sharingControllerProvider));
        return;
      }
      // Still loading with no hint: the friendships answer is on its way.
      if (phase == SocialPhase.loading && social.hinted == null) return;
      gate.start();
    }

    ref.listen(socialControllerProvider.select((s) => s.phase), (_, phase) => decide(phase));
    Future.microtask(() => decide(ref.read(socialControllerProvider).phase));
  }
  return gate;
});

/// Whether a marking may carry its date NOW (asked at every write).
final favoritesDatesEnabledProvider = Provider<bool Function()>((ref) {
  final gate = ref.watch(sharedRulesGateProvider);
  return () => gate.open;
});

/// Called when the server refused a marking because of its date.
final favoritesDatesRefusedProvider = Provider<void Function()>((ref) {
  final gate = ref.watch(sharedRulesGateProvider);
  return gate.invalidate;
});
