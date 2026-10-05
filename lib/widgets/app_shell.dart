import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/catalog_sync_providers.dart';
import '../providers/providers.dart';
import '../providers/social_lists_providers.dart';
import '../providers/social_providers.dart';
import 'count_badge.dart';
import 'auth_gate.dart';
import 'sync_widgets.dart';

/// Single source of truth for the mobile layout: widths up to and including
/// this value (logical px) use the bottom tab bar; wider ones keep the
/// desktop top menu.
const double kMobileBreakpoint = 768;

bool isMobileWidth(BuildContext context) => MediaQuery.sizeOf(context).width <= kMobileBreakpoint;

/// Marks the subtree rendered inside [AppShell] on a mobile width. Screens
/// use it to drop their own AppBar (the shell owns the fixed logo bar).
class MobileShellScope extends InheritedWidget {
  const MobileShellScope({super.key, required super.child});

  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MobileShellScope>() != null;

  @override
  bool updateShouldNotify(MobileShellScope oldWidget) => false;
}

/// CineTrack logo + name, used by the mobile top bar and the detail AppBars.
class BrandMark extends StatelessWidget {
  final double size;
  final bool showName;

  const BrandMark({super.key, this.size = 28, this.showName = true});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/logo.png',
          width: size,
          height: size,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => SizedBox(width: size, height: size),
        ),
        if (showName) ...[
          const SizedBox(width: 8),
          const Flexible(child: Text('CineTrack', overflow: TextOverflow.ellipsis)),
        ],
      ],
    );
  }
}

/// Width the brand name keeps at 1x font before the Amigos icon gives way.
const double kBrandNameMinWidth = 56;

/// Whether the Amigos icon fits in the mobile top bar next to the logo, the
/// name, the magnifier and the sync indicator: the name needs room in
/// proportion to the font size. When it does not (320 px with a large font),
/// the icon is hidden and the pending requests show as a dot on the Perfil
/// destination instead (docs/50 §13); Perfil -> "Gerenciar amigos" still
/// reaches the screen.
bool friendsIconFits(BuildContext context) {
  const padding = 32.0, button = 48.0, sync = 32.0, logo = 32.0, gap = 8.0;
  final width = MediaQuery.sizeOf(context).width;
  final scale = MediaQuery.textScalerOf(context).scale(1);
  final room = width - padding - button /* search */ - sync - button /* friends */;
  return room >= logo + gap + kBrandNameMinWidth * scale;
}

/// Fixed top bar of the mobile layout: logo always visible (it lives outside
/// the scrollable content), then the search magnifier (Busca is not a tab on
/// mobile any more, `/search` is unchanged) and the sync indicator.
class MobileTopBar extends ConsumerWidget {
  const MobileTopBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Only for accounts with friendships on (loads the social state once per session).
    final friends = ref.watch(socialActiveProvider) && friendsIconFits(context);
    final pending = ref.watch(receivedBadgeProvider);
    refreshBadge(ref);
    return Material(
      color: theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: DefaultTextStyle.merge(
                        style: theme.textTheme.titleLarge,
                        child: const BrandMark(size: 32),
                      ),
                    ),
                  ),
                  if (friends)
                    IconButton(
                      tooltip: friendsSemanticLabel(pending),
                      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                      icon: CountBadge(count: pending, child: const Icon(Icons.people_outline)),
                      // With requests waiting the screen opens on them.
                      onPressed: () =>
                          context.go(pending > 0 ? '/friends?tab=pedidos' : '/friends'),
                    ),
                  IconButton(
                    tooltip: 'Buscar',
                    style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                    icon: const Icon(Icons.search),
                    onPressed: () => context.go('/search'),
                  ),
                  const SyncIndicator(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Slot for the [SyncBanner] on screens that live outside the shell (detail
/// routes) on mobile. On desktop the banner is placed by the app builder.
class DetailBottomBanner extends StatelessWidget {
  const DetailBottomBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isMobileWidth(context)) return const SizedBox.shrink();
    return SyncBanner(onOpenProfile: () => GoRouter.of(context).go('/profile'));
  }
}

/// AppBar for a detail screen (outside the shell): back button as usual and,
/// on mobile, the logo before the title so it is visible there too.
AppBar detailAppBar(
  BuildContext context, {
  required String title,
  List<Widget>? actions,
}) {
  final mobile = isMobileWidth(context);
  return AppBar(
    // A deep link has no history: the usual back button would not appear, so
    // offer one that goes home (docs/19 ❓14).
    leading: Navigator.canPop(context)
        ? null
        : IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Ir para o início',
            onPressed: () => GoRouter.of(context).go('/'),
          ),
    titleSpacing: mobile ? 0 : null,
    title: mobile
        ? Row(
            children: [
              const BrandMark(size: 28, showName: false),
              const SizedBox(width: 8),
              Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          )
        : Text(title),
    actions: actions,
  );
}

class _Tab {
  final String path;
  final String label;
  final String? tooltip;
  final IconData icon;
  final IconData selectedIcon;

  const _Tab(this.path, this.label, this.icon, this.selectedIcon, {this.tooltip});
}

const _tabs = [
  _Tab('/', 'Início', Icons.home_outlined, Icons.home),
  _Tab('/catalog', 'Explorar', Icons.explore_outlined, Icons.explore),
  _Tab(
    '/recommendations',
    'Recomendo',
    Icons.thumb_up_outlined,
    Icons.thumb_up,
    tooltip: 'Minhas recomendações',
  ),
  _Tab('/favorites', 'Favoritos', Icons.favorite_border, Icons.favorite, tooltip: 'Meus favoritos'),
];

/// Wraps the main routes (ShellRoute). Desktop: the child unchanged (each
/// screen keeps its AppBar/top menu). Mobile: fixed logo bar on top, content,
/// [SyncBanner] and a Material 3 [NavigationBar] at the bottom. The content
/// sits in an `Expanded` above the bar, so it never scrolls behind it.
class AppShell extends ConsumerWidget {
  final String location;
  final Widget child;

  const AppShell({super.key, required this.location, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Starts the background download of the favorite series' seasons (new
    // login/device) for every main screen, desktop included. read, not
    // watch: its progress must not rebuild the shell.
    ref.read(catalogSyncProvider);
    if (!isMobileWidth(context)) return child;

    final user = ref.watch(currentUserProvider);
    final pending = ref.watch(receivedBadgeProvider);
    final dotOnProfile = pending > 0 && !friendsIconFits(context);
    final authLoading = ref.watch(authStateProvider).isLoading;
    final signedOut = user == null && !authLoading;
    final profileIndex = _tabs.length;

    var selected = _tabs.indexWhere(
      (t) => t.path == '/' ? location == '/' : location.startsWith(t.path),
    );
    // Amigos "lives" in the Profile (docs/50 §13): its screens keep Perfil selected.
    if (selected < 0 && (location.startsWith('/profile') || location.startsWith('/friends'))) {
      selected = profileIndex;
    }
    // `/search` (opened from the magnifier in the top bar) is not a tab; it is
    // part of exploring, so Explorar is the selected destination there (visual
    // AND screen reader), never a wrong one.
    if (selected < 0 && location.startsWith('/search')) selected = 1;

    void onSelected(int index) {
      if (index < _tabs.length) {
        context.go(_tabs[index].path);
      } else if (signedOut) {
        // Login must start straight from the tap (popup blockers).
        signInWithFeedback(ProviderScope.containerOf(context), ScaffoldMessenger.maybeOf(context));
      } else {
        context.go('/profile');
      }
    }

    return Column(
      children: [
        const MobileTopBar(),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            child: MobileShellScope(child: child),
          ),
        ),
        MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: SyncBanner(onOpenProfile: () => context.go('/profile')),
        ),
        NavigationBar(
          selectedIndex: selected < 0 ? 0 : selected,
          onDestinationSelected: onSelected,
          destinations: [
            for (final t in _tabs)
              NavigationDestination(
                icon: Icon(t.icon),
                selectedIcon: Icon(t.selectedIcon),
                label: t.label,
                tooltip: t.tooltip ?? t.label,
              ),
            NavigationDestination(
              icon: CountBadge(
                count: dotOnProfile ? pending : 0,
                dot: true,
                child: Icon(signedOut ? Icons.login : Icons.person_outline),
              ),
              selectedIcon: CountBadge(
                count: dotOnProfile ? pending : 0,
                dot: true,
                child: const Icon(Icons.person),
              ),
              label: signedOut ? 'Entrar' : 'Perfil',
              tooltip: signedOut
                  ? 'Entrar com Google'
                  : (dotOnProfile ? profileSemanticLabel(pending) : 'Perfil'),
            ),
          ],
        ),
      ],
    );
  }
}
