# 43 - Code review: Minhas recomendações (Fatia 1)

Revisor: Code Reviewer (gate). Escopo: `git diff main` + arquivos novos não rastreados do worktree `cinetrack-recs` (branch `feat/minhas-recomendacoes`, base 9a1e027, sem commit). Somente leitura: nenhum arquivo de código alterado.

## Veredito: REPROVADO

Motivo: nenhum 🔴 (a não perda de dados está provada), mas há 3 🟡 e, pela regra do Manager ("só APROVADO limpo, sem ressalvas"), qualquer 🟡 reprova. As 3 correções são pequenas e localizadas.

## Resultados reais (rodados por mim)

| Verificação | Resultado |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | 651 testes, All tests passed |
| `flutter build web` | OK (`build/web`) |
| Rules no emulador (`npm test`, JAVA_HOME openjdk@24) | 64 pass, 0 fail (suíte existente + `recommended.test.mjs` T1-T13 contra regra nova e contra `fixtures/firestore.rules.v1`) |
| `fixtures/firestore.rules.v1` vs `firestore.rules` da main | idênticos (diff vazio): o "app antigo" é testado contra as regras de produção de fato |

## 🔴 Bloqueantes

Nenhum.

## 🟡 Importantes (corrigir antes do merge)

### 🟡-1 Leitor de tela anuncia "Início" como selecionado em `/search` (acessibilidade, WCAG 4.1.2)
- `lib/widgets/app_shell.dart:202, 232-239`. O `NavigationBar` exige `selectedIndex` válido; o código usa 0 e só neutraliza o visual (indicador transparente, ícone não preenchido). A árvore de semântica continua com Início `selected: true`. O dev declarou isso em docs/40 ("Não verificado"). Estado exposto errado = defeito de a11y, não só estético, e a regra "sem ressalvas" não admite deixar declarado.
- Cenário: usuário de TalkBack/VoiceOver toca na lupa; ouve "Busca" (campo) e, ao navegar até a barra, "Início, selecionado".
- Correção concreta (a mais simples e sem hack de semântica): tratar `/search` como parte de Explorar, i.e. `selected = 1` quando `location.startsWith('/search')` (busca é descoberta de títulos; estado visual e semântico passam a ser verdadeiros, e some o código `noTab`/`indicatorColor` transparente). Alternativa se o Manager quiser "nenhuma aba": trocar `NavigationBar` por barra própria com `Semantics(selected:)` por item. Ajustar o teste `magnifier ... no tab is highlighted` (hoje afirma `indicatorColor == transparent`) para afirmar o índice/semântica (`tester.getSemantics(...)` com `isSelected`).

### 🟡-2 `/search` estoura na vertical com fonte >= 2x (falha pré-existente, mas agora há um caminho novo e direto até ela: a lupa em todas as telas)
- Causa: `lib/widgets/empty_state.dart:20` usa `Column(mainAxisSize.min)` dentro de `Center`, sem rolagem; no shell mobile `/search` é `Column[TextField, Expanded(EmptyState)]` (`lib/screens/search_screen.dart` ~linha 91-97), então com 2x/3x o conteúdo passa da altura disponível (dev mediu 104/600/336 px de overflow na main). O teste exclui `/search` (`test/recommendations_ui_test.dart:908-910`).
- Como o Manager exige "sem ressalvas" e a lupa torna `/search` a porta de entrada de todo usuário mobile, corrigir agora.
- Correção: em `EmptyState`, envolver o `Padding/Column` em `LayoutBuilder` + `SingleChildScrollView` com `ConstrainedBox(minHeight: constraints.maxHeight)` + `Center` (ou `Center` + `SingleChildScrollView`), sem mudar a aparência com fonte 1x; depois remover a exclusão `if (scale == 1)` do teste para incluir `/search` em 1x/2x/3x. Verificar que nenhum outro uso de `EmptyState` dentro de `ListView` quebra (a tela de recomendações usa dentro de `ListView`: rolagem aninhada com altura ilimitada precisa ser tratada, p.ex. só rolar quando `constraints.hasBoundedHeight`).

### 🟡-3 Desmarcar Recomendo na aba some o cartão na hora, sem Desfazer
- `lib/widgets/detail_actions.dart:372, 409-418` (`setRecommendedFromUi`): o snackbar "Removido das suas recomendações." não tem ação. Na aba, o chip fica ao lado de uma área toda clicável e o cartão desaparece da lista a cada toque acidental; para religar é preciso lembrar o título e abrir o detalhe ou a aba Favoritos. Nenhum dado de progresso se perde (só o campo), por isso não é 🔴, mas é perda silenciosa de curadoria do usuário, e o Manager pediu "sem ressalvas". O custo é baixo e a operação é segura (field path).
- Correção: `SnackBar` com `SnackBarAction(label: 'Desfazer', onPressed: () => ... setRecommended(id, type, true))` apenas no caso `!recommended` (usar `inFavorites: true`; se o item foi removido entretanto, `FavoriteGoneException` já é tratada pelo caminho `runDetailWrite`). Adicionar teste: desmarcar na aba -> "Desfazer" -> item volta, demais campos idênticos.

## 🟢 Sugestões / observações

- 🟢-1 `lib/data/firestore_favorites_data_source.dart` `setRecommended` (4 linhas, lido e correto: `update` com `FieldValue.delete()` ou `true` + `updatedAt`) não é exercitado por nenhum teste (não há fake do SDK); T4/T5 usam payload escrito à mão com o mesmo formato. Risco baixo; se algum dia houver `fake_cloud_firestore`, cobrir.
- 🟢-2 `lib/widgets/app_shell.dart:93`: a lupa continua visível e clicável quando já se está em `/search` (`context.go` para a mesma rota, inofensivo). Poderia ficar desabilitada ou marcada como atual.
- 🟢-3 `lib/screens/search_screen.dart:64`: `autofocus: !inShell` significa que, ao tocar a lupa, o usuário ainda precisa tocar no campo. Como a lupa é intenção explícita de buscar, focar o campo quando a rota é aberta pela lupa seria melhor (no web mobile o teclado só abre por gesto, avaliar).
- 🟢-4 Tab bar com 5 itens a 320 px e fonte 3x: os testes garantem ausência de overflow, mas não que o rótulo "Recomendo" não é truncado (ninguém viu num dispositivo; docs/40 admite). Conferir visualmente antes de publicar.
- 🟢-5 Confirmação de remoção no detalhe usa `hasProgress/recommended` do build (se outro aparelho marcar Recomendo no meio do caminho, a confirmação não menciona). Em listas (`toggleFavoriteFromList`) é relido; no detalhe é o mesmo comportamento já existente para progresso. Aceitável.

## Verificações por tópico

### (1) Não perda de dados: provada
- Escrita sempre por field path: `setRecommended` = `update({'recommended': true | FieldValue.delete(), 'updatedAt'})`; não toca `eps`, `watchedMovie`, `addedAt`, `lastWatchedAt`, `seasonSummaries`. Os writes de progresso (`setWatchedMovie`, `setEpisodes`, `setSeasonSummaries`) não incluem `recommended`: Desfazer/bulk/assistido rápido não podem apagar a marca e a marca não pode apagar progresso. Nunca é gravado `recommended: false` (`FavoriteMapper.toMap` só emite `true`).
- Repositório: `setRecommended` lê antes (`get`); item ausente -> `FavoriteGoneException`, nada recriado; leitura impossível -> `FavoritesUnavailableException` propaga (não vira no-op silencioso nem `set`).
- `addAndRecommend`: `_exists` primeiro; se existe, só o campo; senão UM `add` (`set`) com `recommended:true`. Cache frio/defasado: se o doc existe no servidor e o cache diz que não, o `set` seria um clobber, mas a regra o nega (`request.resource.data.addedAt <= resource.data.addedAt`, com `addedAt = now`, é negado: T10 confirmado no emulador); T11 documenta o resíduo igual ao do `add` que já existia. Idempotente (teste "marking is idempotent" e "stale screen"). Falha do add não deixa em lista nenhuma (teste).
- Remover de Favoritos: todos os caminhos de `repo.remove` (detalhe filme/série, coração em Explorar/Busca/Descoberta via `toggleFavoriteFromList`) passam por `confirmRemoveFavorite` com texto sobre a recomendação; Cancelar com foco inicial. Readicionar cria doc novo sem a marca (documentado e confirmado).
- Troca de conta e exclusão: data source é ligada ao uid; teste "another account never sees the mark" e "account deletion removes documents that carry the mark"; T13 no emulador (lote de 400 com docs marcados).
- Sync/offline: `update` offline fica na fila; doc removido em outro aparelho -> rejeitado pelo servidor (not-found), vai ao sink/banner, nada recriado.
- App ANTIGO em produção: leitura ignora o campo extra (mapper antigo lê campos conhecidos). Escrita do app antigo em doc com `recommended`: com regras NOVAS publicadas passa (T3/T9 contra a regra nova); com regras v1 o `hasOnly` antigo nega (T9, documentado). Por isso a ordem é regras ANTES do app e nunca reverter regras depois da primeira marcação. T9b: desmarcar continua aceito sob v1 (contingência).
- Observação de risco operacional (não é defeito de código): se as regras forem revertidas depois que existirem docs marcados, o app antigo perde a capacidade de gravar progresso nesses docs (falha visível, nenhum dado apagado). README e docs/40 já advertem; manter essa advertência no plano de release.

### (2) Regras
- Diff de 3 linhas, confirmado: `'recommended'` no `hasOnly` e `(!('recommended' in d) || d.recommended is bool)`. Nada de isolamento por uid, limites, `addedAt` monotônico, tipos dos outros campos foi tocado. T7 (não-bool), T8 (campos desconhecidos), T12 (outros usuários e anônimo) verdes.
- App novo com regras antigas: marcar (T2/T4/T6) é negado com falha visível (banner de recusa do servidor); como `setRecommended` só escreve `recommended` e `updatedAt` numa operação própria, a falha não carrega nenhum write de progresso: nada de misturar campos numa escrita que falharia inteira. Desmarcar (delete do campo) funciona sob v1 (T5/T9b).
- Nota: o `npm test` agora usa `--test-concurrency=1` (necessário, dois arquivos no mesmo emulador); correto.

### (3) Navegação / UX
- Tab bar: Início, Explorar, Recomendo, Favoritos, Perfil/Entrar (5), `/favorites` e demais rotas intactas (teste de deep links 390 e 1280 px verde); lupa 48x48 no `MobileTopBar`, presente em todas as telas do shell mobile; detalhe continua sem tab bar.
- Desktop: rótulos só >= 960 px x fator de fonte (`kTopMenuLabelsMinWidth`), abaixo ícone com tooltip; testes 769-1440 px a 1x/2x sem overflow, verdes. Decisão aceita.
- Problemas: 🟡-1, 🟡-2, 🟡-3.

### (4) UI
- Chip "Recomendo/Recomendado" reutiliza `DetailToggleChip` (mesmo do assistido), rótulo acessível começa pelo texto visível ("Recomendo: ..." / "Recomendado: ..."), alvo >= 48 px (testes), pendente próprio sem duplo toque. Cartão de Favoritos com `Wrap` de dois chips (matriz 320-1440 x 1x/2x/3x x claro/escuro verde). Estado vazio ensina e informa privacidade; carregando/erro nunca viram vazio (`FavoritesGate`). Ordem `byRecentActivity` e filtros Todos/Filmes/Séries ok. Ajuste em `quick_watched_test.dart` (filtrar só chips "Marcar como assistido") é legítimo: o teste continua afirmando alinhamento dos chips de assistido.

### (5) Privacidade / LGPD
- `web/privacidade.html`: novo dado listado, "privada, só você, por enquanto, não compartilhada nem publicada", frase "Pediremos seu consentimento antes de qualquer compartilhamento", exclusão e acesso atualizados, data 03/10/2026. `PrivacySummary`, diálogo de exclusão e README coerentes. Nenhum compartilhamento implementado (nenhuma rota/campo público; regras só permitem o dono). Parecer jurídico fica fora do escopo.

### (6) Regressões gerais e qualidade dos testes
- Suíte inteira 651/651; nenhum teste antigo foi enfraquecido (os 2 ajustes são consequência direta da mudança de UI). Mutação mental: (a) trocar `FieldValue.delete()` por `false` em `setRecommended` -> não detectado pela suíte Dart (fake), mas detectado pelas regras só se o payload real fosse usado: ver 🟢-1; (b) fazer `toMap` gravar `recommended:false` -> teste "toMap writes recommended ONLY when true" falha; (c) fazer `setRecommended` criar o doc se ausente -> "title gone: NOTHING is recreated" falha; (d) remover a mensagem da confirmação ao remover recomendado -> testes de diálogo falham. Exportar (Fatia 0) não foi tocado neste worktree.

### (7) Diff
- Sem ruído de formatação; mudanças confinadas ao escopo (25 arquivos tocados + 6 novos, ~430 linhas alteradas fora dos novos). PR é revisável, porém grande: ok por ser uma fatia coesa.

## Segurança
OK: sem novos campos ou superfícies; regra aceita só booleano no campo novo; isolamento por uid preservado; nenhum PII em log (o data source só loga códigos de erro). `.env` não lido.

## O que corrigir para virar APROVADO
1. 🟡-1: `/search` selecionar Explorar (ou semântica própria sem seleção) + teste de semântica.
2. 🟡-2: `EmptyState` rolável quando a altura é limitada; incluir `/search` na matriz de fontes 2x/3x.
3. 🟡-3: Snackbar com "Desfazer" ao desmarcar Recomendo + teste.
Após isso, reexecutar analyze, test, build e `npm test`; nenhuma mudança de regras é necessária.
