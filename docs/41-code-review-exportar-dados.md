# 41 - Code review: Exportar meus dados (Fatia 0)

Revisor: Code Reviewer. Branch `feat/export-my-data` (commit 6a9c0c9 sobre main 9a1e027). Revisão somente leitura.

## Veredito: REPROVADO (2 pendências 🟡, nenhuma 🔴)

A feature está bem construída e segura; as pendências são pequenas e baratas de corrigir. Pela regra do Manager (só aprovação limpa), voltam ao dev.

## Resultados executados
| Passo | Resultado |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | 549 testes, All tests passed |
| `flutter build web --release` (Flutter local; CI usa 3.47.5) | Built build/web (só avisos habituais de wasm dry run e tree-shake) |
| Estático Android/iOS | Os testes rodam na VM e resolvem o import condicional para o stub; `web` só é importado em `file_saver_web.dart`; analyze limpo. NÃO verificado: build nativo apk/ipa |
| Diff | 18 arquivos, sem churn de formatação em arquivos existentes (Perfil: +3 linhas; README, política e pubspec só o necessário) |

## Verificado e correto
- Leitura apenas: nenhuma escrita/`set`/`update`/`delete` no código novo. Nada em Hive/IndexedDB/log (só `e.code` via `debugPrint`). Sem uid/e-mail/foto no arquivo (teste de cabeçalho). `web ^1.1.1` fixo no lock em 1.1.1 (SDK do lock >=3.12, compatível); mudança no lock é só `transitive` para `direct main`.
- Completude: `data` é o mapa bruto (eps, seasonSummaries, campos futuros, aninhados); corrompidos entram crus e vão para `issues` sem derrubar; NaN/Infinity viram marcador listado. `firestore.rules` só permite primitivos, timestamp, list e map, então GeoPoint/Bytes/Reference/int64 enorme não podem existir nos dados do app (o marcador `unsupportedType` é suficiente).
- Paginação: `orderBy(documentId)` + `startAfter([id])`, limite 300, sem teto, guarda de cursor parado; tamanhos 0/1/299/300/301/600/1000+ cobertos no fake; documento removido/adicionado durante o export não quebra o cursor por id. Timeout 30 s por página. Memória: poucos MB para milhares de itens.
- Segurança: uid reconferido a cada await e antes de entregar; cancelar/troca de conta descarta; `revokeObjectURL` agendado (30 s); nome `cinetrack-export-AAAA-MM-DD.json`; aviso para guardar com segurança; política de privacidade atualizada e coerente.
- UI: foco em Cancelar, Esc fecha o diálogo sem exportar, botão desabilitado durante a execução, estados carregando/sucesso/erro/offline/retry, live regions, não-web com texto claro, sem overflow de 320 a 1440 px.

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes (corrigir para aprovar)

### 1. `FirestoreExportDataSource` não tem nenhum teste (caminho real de produção)
`lib/data/firestore_export_data_source.dart:60-67` (`_convert`/`_value`) e `:45-57` (`_guard`).
Cenário: o fake devolve `DateTime` direto, então toda a conversão `Timestamp -> DateTime` (topo, aninhada em Map/List) e o mapeamento de erros (`unavailable`/`deadline-exceeded`/`cancelled` => unreachable, `permission-denied`/`unauthenticated` => denied, timeout) nunca são executados. Mutação mental: apagar a linha `Timestamp() => value.toDate()` deixa os 549 testes verdes e produz, em produção, `addedAt: {"unsupportedType":"Timestamp"}` em todos os documentos (perda de dado no arquivo de segurança). Também não há teste de que o offline cai em "pergunta" a partir de um `FirebaseException` real.
Correção: tornar `_convert` acessível (`@visibleForTesting static`) e testar com `Timestamp(...)` reais (campo de topo, dentro de Map, dentro de List, null), e testar `_guard` com `FirebaseException(plugin:'cloud_firestore', code:...)` e `TimeoutException`. Se possível, também um teste da query (`orderBy documentId`, `startAfter`, `Source`) com um fake do Firestore; se não for viável, manter o roteiro manual do doc 39 como critério de aceite do QA.

### 2. Alvos de toque e cenários de acessibilidade incompletos
`lib/widgets/export_data_section.dart:125` ("Cancelar" durante a leitura, `TextButton` sem `minimumSize`). Os demais botões da seção usam 48 px; este não, e fica com 40 px de altura em navegador desktop (o preenchimento de 48 só existe em plataformas móveis). O teste de layout (`test/export_data_section_test.dart:408-467`) usa fonte 2x em 320 px (pedido: 3x), não cobre o estado "carregando" nem o tema escuro, e não mede o tamanho do alvo desse botão.
Correção: `style: TextButton.styleFrom(minimumSize: const Size(48, 48))` em "Cancelar"; ampliar o teste para fonte 3x em 320 px, incluir o estado de carregamento (com gate) e o tema escuro, e afirmar altura >= 48 nos botões de cada estado.

## 🟢 Sugestões (não bloqueiam)
- `export_serializer.dart:130`: `timestampFields` lista só campos de topo de `favorites`; timestamps em `profile.data` ou aninhados viram string ISO sem marca (a restauração do perfil não distingue). Hoje o app não grava timestamps aninhados; considere marcar também `profile.timestampFields`.
- `Timestamp.toDate()` na web trunca para milissegundos; o doc 39 poderia citar a perda de sub-milissegundo (inofensiva para a regra `addedAt <=`, pois só diminui).
- `hadPendingWrites` é lido só no início; escritas feitas durante a leitura não geram aviso. Aceitável (arquivo é foto do servidor), vale uma linha no doc.
- Política de privacidade: foi removida a frase "para uma cópia, escreva ao contato". Quem usar Android/iOS (sem exportação) perde esse caminho; mantenha uma frase de contato para cópia fora da versão web.
- `dart format` (largura padrão) reformataria os arquivos novos; o projeto não fixa a largura, então só informativo.

## Não pôde ser verificado
Firestore real/emulador (`Source.server`, `startAfter` com `documentId`, erro offline na web), download real em navegadores, build nativo Android/iOS, aparência visual em claro/escuro, leitor de tela real.
