# 28 - Ajustes: botão Favoritar no detalhe, coração que alterna, grade do Perfil

Branch `fix/favorite-button-and-heart` (worktree `cinetrack-ui-fixes`).

## 1. Botões do detalhe com o mesmo padrão
- Antes: "Favoritar/Remover" era `FilledButton` (pílula, 48 px) e "Marcar como assistido" um `FilterChip` (raio 8, 32 px).
- Agora os dois são o mesmo componente-base `DetailToggleChip` (`lib/widgets/detail_actions.dart`), um `FilterChip` com ícone de 18 px à esquerda (`showCheckmark: false`), `materialTapTargetSize: padded` (alvo 48 px no mobile), mesma tipografia/raio/espaçamento do tema.
- `FavoriteToggleButton` (favorito: roxo `primaryContainer` quando selecionado, coração cheio/vazio) e novo `WatchedToggleChip` (assistido: `check_circle`, cor padrão de selecionado do tema). Ambos têm estado pendente com spinner 18 px (anti-duplo-toque; o assistido não tinha pendente antes).
- Semântica: `button`, `selected`, `enabled`, rótulo "Remover X dos favoritos" / "Favoritar X" / "Marcar X como assistido" / "Desmarcar X como assistido". Lado a lado em `Wrap` (quebra de linha sem overflow). Modo escuro usa `onPrimaryContainer`.
- Série: o detalhe de série só tinha o botão de favorito (o "assistido" de série é por episódio/temporada); ele agora usa o mesmo chip.
- Decisão: a "mesma forma" foi tomada como a do chip existente (o pedido diz "acompanhar o assistido"), em vez de transformar o assistido em botão preenchido.

## 2. Coração da listagem alterna (bug)
- Causa: `onPressed: isFavorite ? null : ...` desabilitava o coração dos favoritos; só adicionava.
- `toggleFavoriteFromList` (detail_actions.dart) usado por Início/Descoberta (`DiscoverySection`), Explorar (`CatalogScreen`) e Busca (`SearchScreen`): não favorito -> adiciona via `runWrite` (login/intent preservados, sem `await` antes); favorito -> se há progresso pede a mesma confirmação "Remover dos favoritos?" (`confirmRemoveFavorite`, agora compartilhada com o detalhe), senão remove direto. Pendente por chave (anti-duplo-toque) só começa após a confirmação.
- Progresso (`favoriteHasProgress`): filme assistido; série com episódios assistidos no cache ou no documento (`favoriteDocsProvider`, aguardado até 3 s; se falhar/demorar, assume que há progresso e confirma).
- O `GestureDetector` absorvedor continua só para o estado pendente (o `IconButton` ativo ganha o toque sozinho). Tooltip/semântica: "Adicionar X aos favoritos" / "Remover X dos favoritos" (Busca: "Favoritar X"). Coração favorito na Busca agora usa a cor primária.
- "Meus favoritos" não tem coração (só cartões); nada a mudar. Início e Descoberta usam o mesmo `DiscoverySection`.

## 3. Perfil: grade de estatísticas em 100% da largura
- `ProfileStatsGrid`: linhas com 2 `Expanded` iguais (espaço 12), `IntrinsicHeight` (linhas de altura igual, fonte grande não corta); último item ímpar ocupa a linha inteira. O cartão "Tempo assistido" perdeu o `maxWidth: 480`/`minWidth` e ocupa a largura toda: grade e cartão têm a mesma largura. Semântica dos tiles preservada.

## Testes (405 -> 429, todos passando)
- Novo `test/favorite_heart_toggle_test.dart`: 3 hospedeiros (Início/Descoberta, Explorar, Busca) x filme/série, com e sem progresso (Cancelar mantém, Remover apaga), sem navegar, semântica acionável.
- `favorites_polish_test.dart` (grupo item 1 reescrito: altura/forma iguais a 320 e 1024, roxo claro/escuro, semântica, spinner), `profile_screen_test.dart` (largura grade == cartão a 320/360/768/1024/1440; ímpar + fonte 2x + escuro).
- Ajustados por dependerem do comportamento antigo: `details_before_favorite_test.dart` (coração desabilitado agora é acionável; botão é FilterChip), comentário em `discovery_section_test.dart`.

## Não verificado
Visual real em navegador/dispositivo (sem screenshot); só testes de widget e build.
