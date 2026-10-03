# Conferência do F1 (docs/33) - marcar assistido rápido

Revisor: Code Reviewer. Branch `feat/quick-watched-toggle` (não commitada). Somente leitura; nenhum código alterado.

Veredito: **APROVADO** (nenhum 🔴, nenhum 🟡 em aberto; só 🟢).

## Resultados reais rodados
- `flutter analyze`: No issues found.
- `flutter test`: 480/480 verdes.
- `flutter build web`: ok (`build/web`).
- `git diff --stat` 761+/33-; `git diff -w --stat` 751+/23-. A diferença de 10 linhas é o reaninhamento em `detail_actions.dart` (já visto no docs/33), sem reformatação de código antigo.

## Conferência dos itens
| # | Item | Status | Evidência |
|---|------|--------|-----------|
| 1 | F1 fechado sem contexto desmontado | ✅ | `favorites_section.dart:86-101`: `dispose` copia `_undoSnack` e `_savingSnack` para uma lista local, zera os campos e fecha no `addPostFrameCallback` (roda no fim do mesmo frame de desmontagem), dentro de `try/catch`. Não usa `context`, `ref` nem `mounted`; só os controllers capturados (o `ScaffoldMessenger` é o da raiz e sobrevive à rota). Não há lookup de ancestral em widget desativado. Nos ramos desmontados de `_afterBulkWrite` (`:221`) e `_awaitAck` (`:264`) nada é usado depois do `await`: o snackbar já foi fechado pelo `dispose`. |
| 2 | Desfazer e finais só fecham ao sair | ✅ | O `ShellRoute` (`router.dart:44`) não é stateful: trocar de aba desmonta Favoritos, o que está alinhado ao docs/30 ("sair da tela descarta"). Com a tela montada nada fecha o Desfazer, exceto ação nova ou troca de conta (`ref.listen(currentUidProvider)`). As mensagens finais (falha, "Progresso restaurado") não são rastreadas e seguem a vida normal do snackbar. Teste :519 cobre o Desfazer ao sair. |
| 3 | Conflitos / race | ✅ | Ação nova: `++_actionSeq`, `_discardUndo` fecha o "salvando…" e o Desfazer anteriores, depois `clearSnackBars` e novo snackbar; a ação antiga, ao acordar, vê `seq` diferente e retorna sem tocar `_savingSnack` (que agora é da nova). `_savingSnack = null` antes do `clearSnackBars` no caminho normal, então o `dispose` não refecha. Fechamento duplo cai no `try/catch` (assert só em debug) ou é no-op. Sem `closed-future` esperado em nenhum ponto novo. |
| 4 | Teste prova a correção | ✅ | `quick_watched_test.dart:676`: `stuck=true`, "salvando…" visível, `go('/other')` com o mesmo app (messenger sobrevive), 1,6 s de frames, exige "salvando…" ausente e "Desfazer" ausente após `kAckWait`. Mutação mental: sem o fechamento no `dispose` o snackbar (duração 1 min) continua e o `findsNothing` falha; o teste anterior com `pumpWidget(MaterialApp)` não pegava isso porque troca o messenger. |
| 5 | Regressões / diff | ✅ | 480/480; sem churn em código antigo (ver acima). |
| 6 | Abertos nos docs/31-33 | ✅ | 🟡 do docs/31 e do docs/32 fechados e conferidos no docs/32 e 33; N1 fechado; F1 fechado agora. Nenhum 🔴/🟡 resta. |

## 🟢 Sugestões (não bloqueiam)
1. Se outro fluxo chamar `clearSnackBars()` e o "salvando…" for removido de fora, `_savingSnack` não é zerado (não há listener de `closed`, diferente do `_undoSnack`). Ao sair da tela, em release, o `close()` poderia esconder o snackbar atual de outro fluxo. Janela estreita (só com messenger compartilhado e outro snackbar no meio da espera). Opcional: espelhar o `closed.then(identical...)` do Desfazer.
2. Dívida já registrada no docs/33 (SyncStatus guarda só a última falha): manter como tarefa.
3. `dart format` rodado só nos arquivos novos, conforme combinado; nada a fazer.

## O que ainda impede publicar
Nada. Segurança/LGPD sem novidades; `.env` não lido. Limites já conhecidos: sem teste contra Firestore real/visual em dispositivo (QA).
