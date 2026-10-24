import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import 'models/media_type.dart';
import 'providers/providers.dart';
import 'providers/ranking_providers.dart';
import 'providers/social_lists_providers.dart';
import 'social/social_models.dart';
import 'screens/add_friend_screen.dart';
import 'screens/cast_screen.dart';
import 'screens/catalog_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/friend_profile_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/home_screen.dart';
import 'screens/invite_screen.dart';
import 'screens/movie_details_screen.dart';
import 'screens/not_found_screen.dart';
import 'screens/person_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/ranking_screen.dart';
import 'screens/recommendations_screen.dart';
import 'screens/search_screen.dart';
import 'screens/tv_details_screen.dart';
import 'widgets/app_shell.dart';

/// Positive integer id of the `:id` path parameter, null when it is not one.
int? _parseId(GoRouterState state) {
  final id = int.tryParse(state.pathParameters['id'] ?? '');
  return id == null || id <= 0 ? null : id;
}

/// The catalog is public; only `/profile` and `/friends*` need a session. While the
/// session is still being restored we don't redirect (the profile screen
/// handles "not connected" itself); once known, signed-out goes home.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authStateProvider, (_, _) => refresh.value++);
  // `/ranking` follows the ranking access live (docs/91 §8.3): the last
  // friend removed sends it to `/friends` without a reload.
  ref.listen(rankingAccessProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final location = state.matchedLocation;
      if (location == '/ranking') {
        // docs/91 O8: pending (session, friendships or the signal still
        // loading) stays and shows the skeleton; the query is kept.
        return switch (ref.read(rankingAccessProvider)) {
          RankingAccess.noSession => '/',
          RankingAccess.inactive || RankingAccess.noFriends => '/friends',
          RankingAccess.pending || RankingAccess.allowed => null,
        };
      }
      if (location != '/profile' && location != '/friends' && !location.startsWith('/friends/')) {
        return null;
      }
      final auth = ref.read(authStateProvider);
      if (auth.isLoading) return null;
      return auth.valueOrNull == null ? '/' : null;
    },
    routes: [
      // Main destinations share the shell (mobile: logo bar + bottom tab bar).
      ShellRoute(
        builder: (context, state, child) => BadgeRefresher(
          child: AppShell(location: state.uri.path, child: child),
        ),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          GoRoute(path: '/favorites', builder: (context, state) => const FavoritesScreen()),
          GoRoute(
            path: '/recommendations',
            builder: (context, state) => const RecommendationsScreen(),
          ),
          GoRoute(path: '/catalog', builder: (context, state) => const CatalogScreen()),
          GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
          GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
          GoRoute(path: '/friends', builder: (context, state) => const FriendsScreen()),
          // The ranking (docs/90 RF-V): opened with `go` so the filter stays in
          // the address (T2); `extra` = where "Voltar" leads (a string).
          GoRoute(
            path: '/ranking',
            builder: (context, state) {
              final extra = state.extra;
              return RankingScreen(from: extra is String ? extra : null);
            },
          ),
          // A sibling, not a child: a nested route keeps the parent page alive under it, and the
          // list behind the search would be read although the search must read nothing.
          GoRoute(path: '/friends/add', builder: (context, state) => const AddFriendScreen()),
          // A friend's profile (docs/82 §9, D14): also a sibling. The uid is
          // validated by the screen (malformed = "não disponível", no read);
          // the own uid goes to the own profile, without a read.
          GoRoute(
            path: '/friends/u/:uid',
            redirect: (context, state) {
              final me = ref.read(currentUidProvider);
              return me != null && state.pathParameters['uid'] == me ? '/profile' : null;
            },
            builder: (context, state) {
              final uid = state.pathParameters['uid'] ?? '';
              final extra = state.extra;
              return FriendProfileScreen(
                key: ValueKey('friend-profile-$uid'),
                uid: uid,
                friend: extra is Friend && extra.uid == uid ? extra : null,
              );
            },
          ),
          // Public on purpose (no redirect): somebody signed out opens a link and the code stays
          // in the address while they sign in / turn friendships on (docs/68).
          GoRoute(
            path: '/invite/:code',
            builder: (context, state) => InviteScreen(code: state.pathParameters['code'] ?? ''),
          ),
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
