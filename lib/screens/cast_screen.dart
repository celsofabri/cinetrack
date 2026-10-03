import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../widgets/app_shell.dart';
import '../widgets/cast_widgets.dart';
import '../widgets/error_state.dart';
import 'movie_details_screen.dart' show detailsErrorMessage;

/// Full cast of a movie/show (the "Ver todos" of the details), TMDB order.
/// Outside the shell: logo + back button stay in the AppBar.
class CastScreen extends ConsumerWidget {
  final TitleKey titleKey;

  const CastScreen({super.key, required this.titleKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cast = ref.watch(titleCastProvider(titleKey));
    final title = ref.watch(titleDetailsProvider(titleKey)).valueOrNull?.title;
    return Scaffold(
      appBar: detailAppBar(context, title: title == null ? 'Elenco' : 'Elenco · $title'),
      bottomNavigationBar: const DetailBottomBanner(),
      body: cast.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          message: detailsErrorMessage(e),
          retryLabel: 'Tentar novamente',
          onRetry: () => ref.invalidate(titleCastProvider(titleKey)),
        ),
        data: (members) => members.isEmpty
            ? const Center(child: Text('Elenco não disponível.'))
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView.builder(
                    itemCount: members.length,
                    itemBuilder: (_, i) => CastRow(member: members[i]),
                  ),
                ),
              ),
      ),
    );
  }
}
