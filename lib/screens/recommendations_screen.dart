import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/app_shell.dart';
import '../widgets/recommendations_section.dart';

/// "Minhas recomendações" ("/recommendations"): the titles the user marked
/// "Recomendo". Private for now.
class RecommendationsScreen extends StatelessWidget {
  const RecommendationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: MobileShellScope.active(context)
          ? null
          : AppBar(
              title: const Text('Minhas recomendações'),
              actions: [
                IconButton(
                  tooltip: 'Buscar',
                  icon: const Icon(Icons.search),
                  onPressed: () => context.push('/search'),
                ),
              ],
            ),
      body: ListView(children: const [RecommendationsSection()]),
    );
  }
}
