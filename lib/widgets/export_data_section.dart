import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/export_providers.dart';

/// Profile section "Seus dados": downloads a JSON copy of everything stored
/// for the account (data portability, LGPD art. 18). Read-only and safe: it
/// never changes or deletes anything.
class ExportDataSection extends ConsumerWidget {
  const ExportDataSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(exportControllerProvider);
    final supported = ref.watch(exportFileSaverProvider).isSupported;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text('Seus dados', style: theme.textTheme.titleMedium)),
        const SizedBox(height: 8),
        const Text(
          'Baixe uma cópia de tudo o que o CineTrack guarda sobre você (favoritos, progresso e '
          'apelido) em um arquivo JSON. Isso não altera nem apaga nada.',
        ),
        const SizedBox(height: 12),
        if (!supported)
          const Text(
            'A exportação está disponível na versão web do CineTrack. Neste aparelho ainda não '
            'é possível salvar o arquivo.',
          )
        else ...[
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              visualDensity: VisualDensity.standard,
            ),
            onPressed: state.busy ? null : () => _confirmAndStart(context, ref),
            icon: const Icon(Icons.download_outlined),
            label: const Text('Exportar meus dados (JSON)'),
          ),
          const SizedBox(height: 12),
          _Status(state: state),
        ],
      ],
    );
  }

  Future<void> _confirmAndStart(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(exportControllerProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Exportar meus dados?'),
        content: const SingleChildScrollView(
          child: Text(
            'Vamos gerar um arquivo JSON com seus favoritos, progresso e apelido, e baixá-lo '
            'neste aparelho. O arquivo contém dados pessoais: guarde em lugar seguro e não '
            'compartilhe com quem você não conhece.\n\n'
            'Nada é enviado a terceiros e o app não guarda uma cópia do arquivo.',
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Exportar'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.start();
  }
}

class _Status extends ConsumerWidget {
  final ExportState state;

  const _Status({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(exportControllerProvider.notifier);
    final theme = Theme.of(context);

    switch (state.phase) {
      case ExportPhase.idle:
        return const SizedBox.shrink();

      case ExportPhase.running:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The visible count changes often: only the fixed label is announced.
            Semantics(
              liveRegion: true,
              label: 'Exportando seus dados',
              excludeSemantics: true,
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      state.loaded == 0
                          ? 'Lendo seus dados no servidor…'
                          : 'Lendo seus dados… ${_items(state.loaded)} até agora',
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  visualDensity: VisualDensity.standard,
                ),
                onPressed: controller.cancel,
                child: const Text('Cancelar'),
              ),
            ),
          ],
        );

      case ExportPhase.needsDeviceChoice:
        return _Notice(
          color: theme.colorScheme.tertiaryContainer,
          onColor: theme.colorScheme.onTertiaryContainer,
          icon: Icons.cloud_off_outlined,
          message:
              'Não consegui falar com o servidor para conferir seus dados. Posso exportar o '
              'que está guardado neste aparelho, mas o arquivo pode estar incompleto (alterações '
              'feitas em outro aparelho podem faltar).',
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48),
                visualDensity: VisualDensity.standard,
              ),
              onPressed: () => controller.start(),
              child: const Text('Tentar de novo'),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 48),
                visualDensity: VisualDensity.standard,
              ),
              onPressed: () => controller.start(fromDevice: true),
              child: const Text('Exportar dados deste aparelho'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                visualDensity: VisualDensity.standard,
              ),
              onPressed: controller.cancel,
              child: const Text('Cancelar'),
            ),
          ],
        );

      case ExportPhase.success:
        final summary = state.summary!;
        final lines = <String>[
          'Pronto: ${_items(summary.documents)} no arquivo ${state.fileName}. O download foi '
              'iniciado; guarde o arquivo em lugar seguro, ele contém seus dados pessoais.',
          if (state.fromDevice)
            'Este arquivo usa os dados guardados neste aparelho e pode estar incompleto.',
          if (state.hadPendingWrites)
            'Havia alterações ainda não enviadas ao servidor; elas podem não estar no arquivo.',
          if (summary.notRecognized > 0)
            '${_items(summary.notRecognized)} não puderam ser interpretados pelo app, mas '
                'foram incluídos no arquivo como estão.',
          if (!summary.lossless)
            'Alguns itens não puderam ser gravados no arquivo (veja "issues" dentro dele). '
                'Não apague nada antes de conferir.',
        ];
        return _Notice(
          color: theme.colorScheme.secondaryContainer,
          onColor: theme.colorScheme.onSecondaryContainer,
          icon: Icons.check_circle_outline,
          message: lines.join('\n'),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                visualDensity: VisualDensity.standard,
              ),
              onPressed: controller.dismiss,
              child: const Text('Fechar'),
            ),
          ],
        );

      case ExportPhase.failure:
        return _Notice(
          color: theme.colorScheme.errorContainer,
          onColor: theme.colorScheme.onErrorContainer,
          icon: Icons.error_outline,
          message: _failureMessage(state.failure),
          actions: [
            if (state.failure != ExportFailureKind.unsupported)
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  visualDensity: VisualDensity.standard,
                ),
                onPressed: () => controller.start(),
                child: const Text('Tentar novamente'),
              ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                visualDensity: VisualDensity.standard,
              ),
              onPressed: controller.dismiss,
              child: const Text('Fechar'),
            ),
          ],
        );
    }
  }

  static String _items(int n) => n == 1 ? '1 item' : '$n itens';

  static String _failureMessage(ExportFailureKind? kind) => switch (kind) {
    ExportFailureKind.unreachable =>
      'Sem conexão com o servidor. Nenhum arquivo foi gerado. Tente de novo quando estiver online.',
    ExportFailureKind.denied =>
      'O servidor recusou a leitura (sessão expirada?). Entre novamente e tente de novo. '
          'Nenhum arquivo foi gerado.',
    ExportFailureKind.emptyDevice =>
      'Não há dados guardados neste aparelho para exportar. Nenhum arquivo foi gerado. '
          'Conecte-se à internet e tente de novo.',
    ExportFailureKind.delivery =>
      'Não foi possível baixar o arquivo neste navegador. Seus dados continuam intactos. '
          'Tente de novo ou use outro navegador.',
    ExportFailureKind.unsupported =>
      'A exportação ainda não está disponível neste aparelho. Use a versão web do CineTrack.',
    _ => 'Não foi possível exportar agora. Seus dados continuam intactos. Tente de novo.',
  };
}

class _Notice extends StatelessWidget {
  final Color color;
  final Color onColor;
  final IconData icon;
  final String message;
  final List<Widget> actions;

  const _Notice({
    required this.color,
    required this.onColor,
    required this.icon,
    required this.message,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        color: color,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(child: Icon(icon, color: onColor)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(message, style: TextStyle(color: onColor)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ),
        ),
      ),
    );
  }
}
