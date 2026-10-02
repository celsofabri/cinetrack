import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

/// Build-time kill switch for login + cloud data
/// (`--dart-define=CLOUD_SYNC=false`). On by default; it only has an effect
/// when Firebase is also configured.
const kCloudSyncEnabled = bool.fromEnvironment('CLOUD_SYNC', defaultValue: true);

/// Initializes Firebase when the build has a configuration and cloud sync is
/// on. Never throws: returns false (app runs as a free catalog browser,
/// login unavailable) when disabled, not configured or initialization fails.
///
/// [purgeCache]: wipe the Firestore local database first (requested by an
/// account deletion in a previous session). [onPurgeResult] gets the outcome
/// so the caller keeps the request when it failed (e.g. another tab still
/// has the database open). Cost: unsent offline writes of ANY account on this
/// browser are lost; accepted because it only follows an explicit deletion.
Future<bool> initFirebase({bool purgeCache = false, void Function(bool ok)? onPurgeResult}) async {
  if (!kCloudSyncEnabled) return false;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    // Offline cache + write queue. Off by default on web, so enable it
    // explicitly (multi-tab for duplicate browser tabs). Must run before any
    // other Firestore call.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      webPersistentTabManager: kIsWeb ? WebPersistentMultipleTabManager() : null,
    );
    if (purgeCache) {
      try {
        await FirebaseFirestore.instance.clearPersistence();
        onPurgeResult?.call(true);
      } catch (e) {
        debugPrint('Could not clear the local cache (${e.runtimeType}); will retry next start.');
        onPurgeResult?.call(false);
      }
    }
    return true;
  } catch (e) {
    // Type only: messages may be long and are not actionable at runtime.
    debugPrint('Firebase unavailable (${e.runtimeType}); login disabled.');
    return false;
  }
}
