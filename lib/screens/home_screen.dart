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
        title: const Text('CineTrack'),
        actions: [
          TextButton.icon(
            onPressed: () => context.push('/favorites'),
            icon: const Icon(Icons.favorite),
            label: const Text('Meus favoritos'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/search'),
        child: const Icon(Icons.search),
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
