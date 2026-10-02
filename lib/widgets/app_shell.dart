import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/providers.dart';
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
          errorBuilder: (_, __, ___) => SizedBox(width: size, height: size),
        ),
        if (showName) ...[
          const SizedBox(width: 8),
          const Flexible(child: Text('CineTrack', overflow: TextOverflow.ellipsis)),
        ],
      ],
    );
  }
}

/// Fixed top bar of the mobile layout: logo always visible (it lives outside
/// the scrollable content), sync indicator on the right.
class MobileTopBar extends StatelessWidget {
  const MobileTopBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
  _Tab('/search', 'Busca', Icons.search, Icons.search),
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
    if (!isMobileWidth(context)) return child;

    final user = ref.watch(currentUserProvider);
    final authLoading = ref.watch(authStateProvider).isLoading;
    final signedOut = user == null && !authLoading;
    final profileIndex = _tabs.length;

    var selected = _tabs.indexWhere(
      (t) => t.path == '/' ? location == '/' : location.startsWith(t.path),
    );
    if (selected < 0 && location.startsWith('/profile')) selected = profileIndex;

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
              icon: Icon(signedOut ? Icons.login : Icons.person_outline),
              selectedIcon: const Icon(Icons.person),
              label: signedOut ? 'Entrar' : 'Perfil',
              tooltip: signedOut ? 'Entrar com Google' : 'Perfil',
            ),
          ],
        ),
      ],
    );
  }
}
