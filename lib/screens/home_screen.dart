import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/discovery_category.dart';
import '../widgets/continue_watching_section.dart';
import '../widgets/discovery_section.dart';
import '../widgets/favorites_section.dart';
import '../providers/providers.dart';

/// The app's entry screen: a vertical list of sections — local data
/// (Continue assistindo, Meus favoritos) renders instantly with no network
/// dependency, while each discovery carousel (Em Alta, Novidades, one per
/// category) resolves independently, so a slow/failed section never blocks
/// the rest of the page.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('CineTrack')),
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
          const FavoritesSection(),
        ],
      ),
    );
  }
}
