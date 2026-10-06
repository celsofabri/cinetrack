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
          'listas e recomendações são privadas: só você as vê, por enquanto. Nome e e-mail '
          'vêm do Google e não são copiados para o banco. A foto também não, a menos que você '
          'ative as amizades e deixe a foto marcada: aí copiamos o endereço da foto, seu '
          'apelido e seu identificador para o cartão que outras pessoas veem. Se você pedir '
          'amizade a alguém, o pedido guarda seu apelido e foto e os da pessoa até ela '
          'responder ou você cancelar; ninguém é avisado de uma recusa. Quem vira seu amigo '
          'vê só o seu cartão (apelido e foto), e remover um amigo não o avisa. Se você bloquear '
          'alguém, guardamos o apelido e a foto dessa pessoa só para a sua lista de bloqueados '
          '(só você a vê) e ela não é avisada. Sem ativar as '
          'amizades, nada disso é gravado. Não usamos anúncios nem telemetria. '
          'Você pode excluir sua conta e todos os dados a qualquer momento, aqui no perfil.',
        ),
        const Align(alignment: Alignment.centerLeft, child: PrivacyPolicyLink()),
      ],
    );
  }
}
