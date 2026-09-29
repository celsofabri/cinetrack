import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/discovery_category.dart';
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
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/logo.png',
              width: 28,
              height: 28,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            const Text('CineTrack'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Buscar',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => context.push('/favorites'),
            icon: const Icon(Icons.favorite),
            label: const Text('Meus favoritos'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        children: [
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
