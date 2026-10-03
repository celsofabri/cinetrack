import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/app_shell.dart';

/// Shown for a route whose id is not a valid number or whose item TMDB does
/// not know ("Pessoa não encontrada"): never an exception or a blank page.
class NotFoundScreen extends StatelessWidget {
  final String message;

  const NotFoundScreen({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: detailAppBar(context, title: 'Não encontrado'),
      bottomNavigationBar: const DetailBottomBanner(),
      body: NotFoundView(message: message),
    );
  }
}

class NotFoundView extends StatelessWidget {
  final String message;

  const NotFoundView({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(message,
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => GoRouter.of(context).go('/'),
              child: const Text('Ir para o início'),
            ),
          ],
        ),
      ),
    );
  }
}
