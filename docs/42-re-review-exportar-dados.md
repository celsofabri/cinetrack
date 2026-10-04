# 42 - Re-review: Exportar meus dados (Fatia 0)

Revisor: Code Reviewer. Branch `feat/export-my-data` (commit 8dd27c5 sobre main 9a1e027). Somente leitura (mutações feitas temporariamente em arquivo com backup e restauradas; `git status` limpo além do doc 41/42).

## Veredito: APROVADO (nenhum 🔴, nenhum 🟡)

## Resultados executados
| Passo | Resultado |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | 565 testes, All tests passed |
| `flutter build web --release` | Built build/web |

## Status por item do doc 41
| Item | Status |
|---|---|
| 🟡1 `FirestoreExportDataSource` sem teste | RESOLVIDO. `convert`/`convertValue`/`mapError`/`guard` estáticos `@visibleForTesting`; testes com `Timestamp` reais (topo, Map, List, nanos, null, NaN, Infinity, int grande), 7 códigos de `FirebaseException`, timeout e erro estranho propagado. |
| 🟡2 Alvo de toque / acessibilidade | RESOLVIDO. `minimumSize 48x48` + `VisualDensity.standard` em todos os botões da seção (incl. Cancelar); teste de layout 320 px com fonte 3x e 1024 px, claro/escuro, macOS, nos estados carregando/offline/sucesso/erro. |
| 🟢 | Fechadas conforme o dev; nada novo apontado. |

## Mutações do dev (reexecutadas por mim, todas quebram teste)
| Mutação | Resultado |
|---|---|
| Remover `Timestamp() => value.toDate()` | 2 testes falham (conversão e ponta a ponta) |
| Tirar `permission-denied` do mapeamento | falha `permission-denied -> denied` |
| Tirar `deadline-exceeded` | falha `deadline-exceeded -> unreachable` |
| Remover `.timeout(timeout)` | falha o teste de timeout |
| Remover o ramo `List()` | falha o teste de conversão |
Arquivo restaurado (diff vazio).

## visualDensity: sem regressão
`VisualDensity.standard` é aplicado só via `styleFrom` nos botões do próprio `ExportDataSection` (lib/widgets/export_data_section.dart). Nenhum tema global nem outro botão do Perfil foi alterado (Perfil: +3 linhas só para inserir a seção); suíte completa verde.

## Ponto aberto: a query (`orderBy(documentId)`, `startAfter`, `Source`) sem teste automatizado
Julgamento: NÃO é 🟡 bloqueante. Razões:
1. O laço de paginação (`runExport`) é testado com fake que respeita cursor por id: 0/1/299/300/301/400/401/601, 1000 e 1500 documentos sem perda nem duplicata, cursores sempre avançando, guarda `cursor-stuck`, e `fromServer` repassado.
2. `readPage` tem 3 linhas que apenas repassam `limit`, `cursor` e `Source` ao SDK. Uma costura `fetchPage(afterId, limit, source)` testaria só o repasse contra um fake escrito pelo próprio dev (o fake provaria o fake); a semântica real de `startAfter` com `documentId` e de `Source.server` só se prova com emulador/projeto real, que o ambiente não tem.
3. Falhas prováveis são ruidosas, não silenciosas: se `startAfter` fosse omitido, a página 2 repetiria o último id e a guarda lança `cursor-stuck` (erro mostrado, nada entregue); `orderBy(documentId)` é a ordem padrão do Firestore; `Source` errado cairia no fluxo offline/erro já testado.
4. O risco residual está documentado (doc 39) com roteiro manual: exportar com a conta real e conferir `counts` com o Perfil; repetir em modo avião.

### 🟢 Sugestões (não bloqueiam)
- Tornar o roteiro do doc 39 critério de aceite explícito do QA com conta de >300 favoritos (cruza a fronteira de página); se um dia houver `fake_cloud_firestore` ou emulador no CI, cobrir `readPage` ali.
- Pendências 🟢 anteriores (marcar `timestampFields` do perfil, nota sobre ms, `hadPendingWrites`, frase de contato na política) seguem opcionais.

## Não pôde ser verificado
Firestore real/emulador, download em navegadores reais, build nativo Android/iOS, leitor de tela real.
