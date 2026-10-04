import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/account_providers.dart';

/// Public address of the static policy page (GitHub Pages).
const kPrivacyPolicyUrl = 'https://celsofabri.github.io/cinetrack/privacidade.html';

/// On web the page sits next to the app (works on localhost and under any
/// base path); elsewhere the public address is used.
Uri privacyPolicyUri() =>
    kIsWeb ? Uri.base.resolve('privacidade.html') : Uri.parse(kPrivacyPolicyUrl);

/// "Política de privacidade" link (opens the static page).
class PrivacyPolicyLink extends ConsumerWidget {
  const PrivacyPolicyLink({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      link: true,
      child: TextButton(
        onPressed: () async {
          final messenger = ScaffoldMessenger.maybeOf(context);
          final opened = await ref.read(urlOpenerProvider)(privacyPolicyUri());
          if (!opened) {
            messenger?.showSnackBar(
              const SnackBar(content: Text('Não foi possível abrir a política de privacidade.')),
            );
          }
        },
        child: const Text('Política de privacidade'),
      ),
    );
  }
}

/// Short, plain-language summary of what is stored (full text in the page).
class PrivacySummary extends StatelessWidget {
  const PrivacySummary({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text('Privacidade', style: theme.textTheme.titleMedium)),
        const SizedBox(height: 8),
        const Text(
          'Guardamos o identificador da sua conta, o apelido (se você definir) e as suas '
          'listas (favoritos, recomendações e progresso) para sincronizar entre aparelhos. Suas '
          'recomendações são privadas: só você as vê, por enquanto. Nome, e-mail e foto '
          'vêm do Google e não são copiados para o banco. Não usamos anúncios nem telemetria. '
          'Você pode excluir sua conta e todos os dados a qualquer momento, aqui no perfil.',
        ),
        const Align(alignment: Alignment.centerLeft, child: PrivacyPolicyLink()),
      ],
    );
  }
}
