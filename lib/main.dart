import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/providers.dart';
import 'screens/home_screen.dart';
import 'screens/movie_details_screen.dart';
import 'screens/search_screen.dart';
import 'screens/tv_details_screen.dart';
import 'services/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: '.env');

  final localStore = LocalStore();
  await localStore.init();

  runApp(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(localStore),
        tmdbApiKeyProvider.overrideWithValue(dotenv.env['TMDB_API_KEY'] ?? ''),
      ],
      child: const CineTrackApp(),
    ),
  );
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
    GoRoute(
      path: '/movie/:id',
      builder: (context, state) =>
          MovieDetailsScreen(movieId: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/tv/:id',
      builder: (context, state) =>
          TvDetailsScreen(tvId: int.parse(state.pathParameters['id']!)),
    ),
  ],
);

class CineTrackApp extends StatelessWidget {
  const CineTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
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
      routerConfig: _router,
    );
  }
}
