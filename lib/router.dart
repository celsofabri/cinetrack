import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import 'models/media_type.dart';
import 'providers/providers.dart';
import 'screens/cast_screen.dart';
import 'screens/catalog_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/home_screen.dart';
import 'screens/movie_details_screen.dart';
import 'screens/not_found_screen.dart';
import 'screens/person_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/search_screen.dart';
import 'screens/tv_details_screen.dart';
import 'widgets/app_shell.dart';

/// Positive integer id of the `:id` path parameter, null when it is not one.
int? _parseId(GoRouterState state) {
  final id = int.tryParse(state.pathParameters['id'] ?? '');
  return id == null || id <= 0 ? null : id;
}

/// The catalog is public; only `/profile` needs a session. While the
/// session is still being restored we don't redirect (the profile screen
/// handles "not connected" itself); once known, signed-out goes home.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authStateProvider, (_, _) => refresh.value++);
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
      // Main destinations share the shell (mobile: logo bar + bottom tab bar).
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          GoRoute(path: '/favorites', builder: (context, state) => const FavoritesScreen()),
          GoRoute(path: '/catalog', builder: (context, state) => const CatalogScreen()),
          GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
          GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
        ],
      ),
      // Detail screens sit outside the shell: no tab bar, back button kept.
      // A non-numeric id (typed URL) shows "not found" instead of throwing.
      GoRoute(
        path: '/movie/:id',
        builder: (context, state) {
          final id = _parseId(state);
          return id == null
              ? const NotFoundScreen(message: 'Filme não encontrado')
              : MovieDetailsScreen(movieId: id);
        },
        routes: [
          GoRoute(
            path: 'cast',
            builder: (context, state) {
              final id = _parseId(state);
              return id == null
                  ? const NotFoundScreen(message: 'Filme não encontrado')
                  : CastScreen(titleKey: (id: id, type: MediaType.movie));
            },
          ),
        ],
      ),
      GoRoute(
        path: '/tv/:id',
        builder: (context, state) {
          final id = _parseId(state);
          return id == null
              ? const NotFoundScreen(message: 'Série não encontrada')
              : TvDetailsScreen(tvId: id);
        },
        routes: [
          GoRoute(
            path: 'cast',
            builder: (context, state) {
              final id = _parseId(state);
              return id == null
                  ? const NotFoundScreen(message: 'Série não encontrada')
                  : CastScreen(titleKey: (id: id, type: MediaType.tv));
            },
          ),
        ],
      ),
      GoRoute(
        path: '/person/:id',
        builder: (context, state) {
          final id = _parseId(state);
          return id == null
              ? const NotFoundScreen(message: 'Pessoa não encontrada')
              : PersonScreen(personId: id);
        },
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
