import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/firestore_shared_profile_data_source.dart';
import '../data/server_clock.dart';
import '../data/shared_profile_data_source.dart';
import '../data/shared_rules_gate.dart';
import '../firebase_options.dart';
import 'providers.dart';

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

/// The `epsAt` gate (docs/82 §4.2, D17): created with the account session,
/// it probes the rules once (unless this device already saw them published).
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
  );
  gate.start();
  return gate;
});
