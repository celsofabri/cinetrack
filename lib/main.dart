import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/providers.dart';
import 'auth/firebase_auth_repository.dart';
import 'router.dart';
import 'services/firebase_bootstrap.dart';
import 'services/local_store.dart';
import 'widgets/app_shell.dart';
import 'widgets/app_splash.dart';
import 'widgets/auth_gate.dart';
import 'widgets/sync_widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Web builds get the key via --dart-define (dotfile assets are not served
  // by GitHub Pages); local runs fall back to the .env asset.
  var apiKey = const String.fromEnvironment('TMDB_API_KEY');
  if (apiKey.isEmpty) {
    try {
      await dotenv.load(fileName: '.env');
      apiKey = dotenv.env['TMDB_API_KEY'] ?? '';
    } catch (_) {
      // Missing .env: the app still opens, search shows a config error.
    }
  }

  final localStore = LocalStore();
  await localStore.init();

  // False when Firebase is not configured / CLOUD_SYNC=false: the app then
  // runs as a free catalog browser with login unavailable.
  final firebaseReady = await initFirebase(
    purgeCache: localStore.firestoreCachePurgePending,
    onPurgeResult: (ok) {
      if (ok) localStore.clearFirestoreCachePurgeFlag();
    },
  );

  runApp(
    ProviderScope(
      overrides: [
        if (firebaseReady) authRepositoryProvider.overrideWithValue(FirebaseAuthRepository()),
        localStoreProvider.overrideWithValue(localStore),
        tmdbApiKeyProvider.overrideWithValue(apiKey),
      ],
      child: const CineTrackApp(),
    ),
  );
}

class CineTrackApp extends ConsumerWidget {
  const CineTrackApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Splash stays until the first auth event (session restored or none).
    final sessionKnown = !ref.watch(authStateProvider).isLoading;
    return MaterialApp.router(
      title: 'CineTrack',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => AppSplash(
        ready: sessionKnown,
        child: PendingIntentRunner(
          child: Column(
            children: [
              Expanded(child: child ?? const SizedBox.shrink()),
              // On mobile the banner lives inside the shell (above the tab
              // bar) and in detail screens; here only for desktop widths.
              if (!isMobileWidth(context))
                SyncBanner(onOpenProfile: () => ref.read(routerProvider).go('/profile')),
            ],
          ),
        ),
      ),
    );
  }
}
