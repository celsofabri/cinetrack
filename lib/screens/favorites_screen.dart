import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/favorites_section.dart';

/// Second top-level screen ("/favorites"), reached from the Home top menu.
class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meus favoritos'),
        actions: [
          IconButton(
            tooltip: 'Buscar',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: ListView(children: const [FavoritesSection()]),
    );
  }
}
