import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/discovery_category.dart';
import '../widgets/account_widgets.dart';
import '../widgets/app_shell.dart';
import '../widgets/continue_watching_section.dart';
import '../widgets/discovery_section.dart';
import '../providers/providers.dart';

/// The app's entry screen: a vertical list of sections — local data
/// (Continue assistindo) renders instantly with no network dependency,
/// "Meus favoritos" lives on its own screen (top menu), and each discovery carousel (Em Alta, Novidades, one per
/// category) resolves independently, so a slow/failed section never blocks
/// the rest of the page.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: MobileShellScope.active(context)
          ? null
          : AppBar(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/logo.png',
                    width: 28,
                    height: 28,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 8),
                  const Flexible(child: Text('CineTrack', overflow: TextOverflow.ellipsis)),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: 'Buscar',
                  icon: const Icon(Icons.search),
                  onPressed: () => context.push('/search'),
                ),
                _NavAction(
                  label: 'Explorar',
                  icon: Icons.explore,
                  onPressed: () => context.push('/catalog'),
                ),
                _NavAction(
                  label: 'Minhas recomendações',
                  icon: Icons.thumb_up,
                  onPressed: () => context.push('/recommendations'),
                ),
                _NavAction(
                  label: 'Meus favoritos',
                  icon: Icons.favorite,
                  onPressed: () => context.push('/favorites'),
                ),
                const AccountAction(),
                const SizedBox(width: 8),
              ],
            ),
      body: ListView(
        children: [
          const SignInInvite(),
          const ContinueWatchingSection(),
          DiscoverySection(title: 'Em Alta', provider: trendingProvider),
          DiscoverySection(title: 'Novidades', provider: noveltiesProvider),
          for (final category in kDiscoveryCategories)
            DiscoverySection(title: category.label, provider: categoryProvider(category)),
        ],
      ),
    );
  }
}

/// Narrowest width (logical px) at which the top menu shows labels: with
/// Explorar, Minhas recomendações and Meus favoritos spelled out the app bar
/// needs about 940 px; below that the actions are icon-only.
const double kTopMenuLabelsMinWidth = 960;

/// Top-menu button: icon + label on wide screens, icon-only (with tooltip)
/// on narrow ones so the actions never overflow the app bar.
class _NavAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const _NavAction({required this.label, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    // Larger system fonts widen the labels: ask for proportionally more room.
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final wide = MediaQuery.sizeOf(context).width >= kTopMenuLabelsMinWidth * textScale;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: wide
          ? FilledButton.tonalIcon(onPressed: onPressed, icon: Icon(icon), label: Text(label))
          : IconButton.filledTonal(tooltip: label, onPressed: onPressed, icon: Icon(icon)),
    );
  }
}
