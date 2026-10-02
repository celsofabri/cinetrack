import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import 'providers/providers.dart';
import 'screens/catalog_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/home_screen.dart';
import 'screens/movie_details_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/search_screen.dart';
import 'screens/tv_details_screen.dart';

/// The catalog is public; only `/profile` needs a session. While the
/// session is still being restored we don't redirect (the profile screen
/// handles "not connected" itself); once known, signed-out goes home.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authStateProvider, (_, __) => refresh.value++);
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      if (state.matchedLocation != '/profile') return null;
      final auth = ref.read(authStateProvider);
      if (auth.isLoading) return null;
      return auth.valueOrNull == null ? '/' : null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(path: '/favorites', builder: (context, state) => const FavoritesScreen()),
      GoRoute(path: '/catalog', builder: (context, state) => const CatalogScreen()),
      GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
      GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
      GoRoute(
        path: '/movie/:id',
        builder: (context, state) =>
            MovieDetailsScreen(movieId: int.parse(state.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/tv/:id',
        builder: (context, state) => TvDetailsScreen(tvId: int.parse(state.pathParameters['id']!)),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
