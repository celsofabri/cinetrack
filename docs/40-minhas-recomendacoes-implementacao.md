# 40 - Minhas recomendações: implementação (Fatia 1)

Autor: squad Dev FE/BE + QA. Branch `feat/minhas-recomendacoes` (worktree `cinetrack-recs`), sem commit. Contrato: [docs/35 REVISÃO](./35-especificacao-biblioteca-e-favoritos.md), [docs/36 REVISÃO R.1 a R.13 e "Decisões do Manager 2026-10-04"](./36-design-biblioteca-e-favoritos.md), [ADR-004](./adr/adr-004-biblioteca-e-favoritos.md). Favoritos não mudou (nome, rota, coração).

## O que foi feito

**Dados e regras (zero perda)**
- `firestore.rules`: o diff mínimo do design (`'recommended'` no `hasOnly` e `(!('recommended' in d) || d.recommended is bool)`). Nada mais mudou.
- Campo opcional `recommended: bool` no documento do item. `FavoriteMapper.toMap` só grava quando `true` (um `add` comum é idêntico ao de antes); `fromMap` lê `== true` (ausente, `false` ou lixo = não).
- `FavoritesDataSource.setRecommended(key, bool)`: `update` por field path (`true` ou `FieldValue.delete()` + `updatedAt`); nunca `set`, nunca toca `addedAt`/`lastWatchedAt` (não reordena).
- `FavoritesRepository.setRecommended` (item ausente: `FavoriteGoneException`, nada recriado; estado ilegível: `FavoritesUnavailableException`) e `addAndRecommend` (fora de Favoritos: um único `add` com `recommended:true`; já existe: só o campo). `addMovie`/`addTvShow` mantêm a assinatura (fakes existentes intactos).
- Bulk, Desfazer, assistido rápido, episódios e catálogo só usam `eps.*`, `watchedMovie`, `lastWatchedAt`, `seasonSummaries` por field path: não tocam o campo (testado).
- Exclusão de conta: apaga os documentos inteiros; o campo vai junto (regra T13 + teste). Exportar (Fatia 0, outro worktree) exporta o mapa bruto: não depende deste código.

**UI**
- `RecommendToggleChip` ("Recomendo"/"Recomendado", polegar, mesmo `DetailToggleChip` do assistido, estado pendente próprio, uma escrita por toque) no detalhe de filme e de série e nos cartões de Favoritos (em `Wrap` ao lado do chip de assistido; quebra para a linha de baixo em cartão estreito).
- `setRecommendedFromUi`: em Favoritos faz `setRecommended`; fora, `addAndRecommend` (também é a intenção repetida após login: explícita, nunca toggle). Snackbars: "Adicionado aos favoritos e às suas recomendações.", "Adicionado às suas recomendações.", "Removido das suas recomendações."; falhas pelo caminho existente (`writeErrorMessage`, banner de sync para recusa de regras).
- Remover de Favoritos um título recomendado (detalhe, coração das listas): `confirmRemoveFavorite` agora cita a recomendação; "Cancelar" com foco inicial; Esc/fora cancelam.
- `RecommendationsScreen` / `RecommendationsSection` (`/recommendations`): cabeçalho com contador do filtro e "Só você vê esta lista, por enquanto.", Todos/Filmes/Séries, ordem `byRecentActivity`, cartão com pôster 2:3 inteiro, chip para desmarcar, vazio que ensina (CTA "Ver meus favoritos" ou "Buscar um título"), carregando/erro nunca viram vazio (mesmo `FavoritesGate`), deslogado vê convite de login.
- Navegação: tab bar mobile = Início, Explorar, Recomendo (tooltip "Minhas recomendações"), Favoritos, Perfil/Entrar (Perfil fica onde estava); Busca virou a lupa da barra superior (48 px, `/search`, abre dentro do shell). Em `/search` nenhuma aba fica destacada (indicador transparente). Desktop: item "Minhas recomendações" no menu do topo; Busca segue nele. Nenhuma rota removida.
- Perfil: contador "Recomendações" (último tile da grade). `PrivacySummary` e diálogo de exclusão citam as recomendações.
- `web/privacidade.html` (data 03/10/2026): novo dado, "privada, só você vê, por enquanto", "Pediremos seu consentimento antes de qualquer compartilhamento", exclusão e acesso. README atualizado.

**Decisão de implementação que o Reviewer deve olhar:** o menu do topo do desktop agora tem 4 ações com rótulo; com os rótulos o AppBar estourava a 769 px. Os rótulos só aparecem a partir de 960 px (multiplicado pelo fator de fonte do sistema, `kTopMenuLabelsMinWidth`); abaixo disso as ações são só ícone com tooltip (como já eram abaixo de 640 px). Antes o limiar era 640 px.

## Testes e resultados reais (rodados neste worktree)

- `flutter analyze`: ver "Resultados" no handoff (zero issues).
- `flutter test`: 502 testes anteriores passando, mais os novos. Ajustes em testes antigos, todos por dependência da tab bar/chips:
  - `mobile_tabbar_test.dart`: rótulos esperados (Recomendo no lugar de Busca), 5 destinos, lupa no topo; `/recommendations` na matriz de layout.
  - `quick_watched_test.dart` (matriz de layout): comparava `chips.at(0)` e `chips.at(1)` como "vizinhos na mesma linha"; agora cada cartão tem o chip "Recomendo" a mais, então a comparação passou a filtrar só os chips "Marcar como assistido".
- Novos: `test/recommended_data_test.dart` (mapper, modelo, repositório, não perda de dados, offline, troca de conta, exclusão) e `test/recommendations_ui_test.dart` (detalhe filme/série, cartões, tela, login pendente, falha, duplo toque, tab bar, lupa, desktop 769 a 1440, deep links, acessibilidade, matriz 320 a 1440 x fonte 1x/2x/3x x claro/escuro).
- Regras no emulador: `firestore_rules_test/recommended.test.mjs` (T1 a T13 contra as regras novas E contra `fixtures/firestore.rules.v1`, as regras antigas; T14 = a suíte existente, sem edição). `npm test` agora usa `--test-concurrency=1` (os dois arquivos compartilham o emulador).
- App antigo x regra nova: T1/T3/T9 (payloads que o app antigo envia, inclusive em documento já recomendado). App novo x regra antiga: T2/T4/T6 negados, T5 e T9b (desmarcar) aceitos, T9 documenta a irreversibilidade.
- Falha conhecida e anterior a esta mudança: `/search` estoura verticalmente com fonte >= 2x em 320 a 768 px (medi na `main`: 104/600/336 px). Não corrigi; meus testes de escala excluem `/search`.

## Rollout (ordem obrigatória)
1. Manager exporta a própria conta (Fatia 0) e anota os números do Perfil.
2. Manager publica `firestore.rules` (console ou `firebase deploy --only firestore:rules`) e confere com o app ATUAL que marcar episódio segue sem banner.
3. Só então merge/deploy do app. Se o app for antes: só "Recomendo" falha, com aviso visível; nada se perde.
4. Nunca reverter as regras depois da primeira marcação (a v1 nega qualquer `update` em documento marcado). Rollback é sempre do app; contingência em docs/36 R.7.

## Não verificado
- Nada foi visto num navegador/dispositivo real: layout, cores, modo escuro e a lupa só foram checados por testes de widget (overflow, tamanhos de alvo, semântica), não visualmente. O indicador "sem aba selecionada" em `/search` e o aspecto do `Wrap` dos dois chips em 320 px merecem olhar humano.
- `FirestoreFavoritesDataSource.setRecommended` não roda contra Firestore real nem contra o SDK do emulador (não há fake do SDK no repo); o formato exato do payload é coberto pelos testes de regras (T4/T5), e a reversão otimista/`not-found` seguem o comportamento do SDK documentado.
- Semântica da aba da NavigationBar em `/search`: o item Início continua anunciado como selecionado por leitores de tela (o `NavigationBar` exige um índice válido); só o visual é neutralizado.
- Pacote de exportação, build mobile (Android/iOS) e `flutter build web` ver handoff para o resultado.
- Parecer jurídico (LGPD) sobre o dado de gosto e a frase de consentimento: não verificado.
- Desfazer ao desmarcar na aba não foi implementado (religar é um toque no detalhe).

## Correções do code review (docs/43)
- `/search` agora conta como **Explorar** (índice 1) na tab bar, visual e semântica; removido o indicador transparente. Teste de semântica: em `/search` exatamente "Explorar" é anunciado como selecionado.
- `EmptyState` rola quando a altura é limitada (e continua centralizado quando cabe). `/search` real passa nas matrizes de fonte 1x/2x/3x (320 a 768 px na tab bar; 769 a 1440 px no desktop); Favoritos/Recomendações vazios na matriz 320–1440 x claro/escuro x 1x/2x/3x. A falha pré-existente de `/search` a 2x+ está resolvida.
- Desmarcar na aba traz "Desfazer" (janela `kUndoWindow`, 30 s): religa só o campo por field path; descartado ao sair da tela ou trocar de conta; se o título saiu de Favoritos mostra "Este título não está mais nos favoritos." e não recria nada. Só na aba (detalhe e cartões de Favoritos não oferecem).
- `FirestoreFavoritesDataSource.recommendedUpdate` (estático, `@visibleForTesting`) é o payload real de `setRecommended`; testado: mark = `recommended:true` + `updatedAt`; unmark = campo deletado, nunca `false`.
