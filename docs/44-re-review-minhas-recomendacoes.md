# Re-review: Fatia 1 "Minhas recomendações" (Code Reviewer)

Veredito: **APROVADO**

Base: main 9a1e027 + mudanças não commitadas em feat/minhas-recomendacoes. Contrato: docs/35, docs/36, adr-004, docs/40. Parecer anterior: docs/43.

## Resultados executados por mim
- `flutter analyze`: No issues found.
- `flutter test`: 694 passaram, 0 falhas.
- `flutter build web`: ok.
- Regras (`npm test`, emulador): 64/64 (inclui o teste de regras v1 antigas x app novo).
- Diff de regras: 3 linhas adicionadas + 1 alterada (`recommended` em `hasOnly` e `recommended is bool`), intacto.
- `git diff --stat` 508+/68- vs `git diff -w --stat` 476+/36-: a diferença (32/32) é só reindentação legítima de `empty_state.dart` (LayoutBuilder), `tv_details_screen.dart` e `favorites_section.dart` (Wrap). Nenhum ruído de formatação.

## Status por item
| Item | Status | Evidência |
|---|---|---|
| 🟡-1 semântica em /search | RESOLVIDO | `app_shell.dart`: `/search` => índice 1 (Explorar), indicador visual e semântica. Teste "magnifier ... Explorar is the selected tab" verifica `selectedIndex == 1` e que exatamente um destino é `isSelected`, sendo Explorar. **Mutação real** (cópia em scratchpad, removi a linha): o teste quebra. Tocar em Explorar a partir de /search chama `onDestinationSelected(1)` => `/catalog`, sem confusão. Desktop não tem tab bar; /search continua no menu superior. |
| 🟡-2 EmptyState / fonte grande | RESOLVIDO | `EmptyState` usa `LayoutBuilder`: altura limitada => `SingleChildScrollView` + `minHeight` + `Center` (rola se não cabe, centraliza se cabe); altura ilimitada (ListView/Column) => `Center` como antes, sem rolagem aninhada. Matrizes 2x/3x para /search, /catalog (769–1440), mobile 320–768 e Favoritos/Recomendações vazios (claro/escuro). **Mutação real** (EmptyState original): os testes de 3x/2x em 320–768 quebram. Teclado aberto: o corpo encolhe (bounded) e rola. |
| 🟡-3 Desfazer ao desmarcar | RESOLVIDO | Ver abaixo. |
| Regras / rollout / não perda de dados | OK | Rollout regras-antes-do-app mantido no docs/40; teste de regras v1 verde; `recommended` nunca `false` (payload testado: `FieldValue.delete()`). |

## Desfazer: análise de perda/criação indevida de dados
- Escrita: `repo.setRecommended(..., true)` => `get` + `update` por field path (`recommended: true` + `updatedAt`). Nunca `set`; `update` em documento inexistente é rejeitado (servidor e rules), logo nunca recria.
- Item removido de Favoritos entre desmarcar e Desfazer: `get == null` => `FavoriteGoneException`, mensagem, nada recriado (teste existe e quebraria se recriasse).
- Troca de conta: snackbar descartado pelo `ref.listen(currentUidProvider)`; mesmo que o toque ocorra, `_undoUnrecommend` compara o uid capturado e não escreve (teste existe).
- Dois toques rápidos: o chip tem `_pending` (uma escrita por toque); desmarcar outro item esconde o snackbar anterior (só o último é desfazível, sem escrita dupla).
- Item com progresso: só `recommended`/`updatedAt` são tocados; teste confirma `watchedEpisodes` e `addedAt` intactos.
- Offline: `update` fica na fila local; se o doc sumiu no servidor, a rejeição vai ao sink de sincronização e nada é criado.
- Sair da tela: `dispose` fecha o snackbar (teste existe). Outras telas não oferecem Desfazer (teste existe).
- Payload `recommendedUpdate`: exatamente `recommended` e `updatedAt`, testado.

## Regressões gerais
Nenhuma encontrada: 694 testes verdes, cobertura de overflow em 320/360/390/768/769 para as rotas (inclusive /recommendations), deep links existentes, Perfil continua índice 4.

## Sugestões 🟢 (não bloqueantes)
- Se o usuário sair da tela durante a escrita (latência), `_offered` registra um snackbar após o `dispose` e ele não é descartado; continua seguro (mesmas guardas de uid e de existência) e expira em 30 s.
- A mensagem de Favoritos vazio diz "Toque na lupa"; correto agora que a lupa fica no topo. Sem ação.

Nenhum 🔴, nenhum 🟡. Restrições absolutas atendidas: nenhum usuário perde dados e nenhum precisa fazer nada.
