# 29 - Code review: botões do detalhe, coração que alterna, grade do Perfil

Branch `fix/favorite-button-and-heart` (alterações não commitadas). Contrato: docs/28, 15-18.

## Veredito: APROVADO COM RESSALVAS
Nada bloqueia o push do ponto de vista de correção. Antes do merge: resolver o 🟡1 (feedback/duplo toque durante a espera de até 3 s) ou registrá-lo como tarefa, e fazer a verificação visual (não feita, ver abaixo).

## Verificação própria
- `flutter analyze`: sem problemas. `flutter test`: 429 passando. `flutter build web --release`: ok.
- Visual: NÃO verificado (não conectei o Chrome; só testes de widget e build). Pendente a conferência em ~390 e ~1024 px.
- Rebase sobre main (de836f0): sem conflito textual previsível. A main alterou nos mesmos arquivos só `(_, __)` -> `(_, _)` (catalog_screen.dart:165 e dois testes, `details_before_favorite_test.dart:81`, `favorites_polish_test.dart:575`), em linhas distantes das alteradas aqui (git deve mesclar sozinho; no teste favorites_polish o grupo reescrito é outro trecho). Após o rebase, rodar analyze/test de novo (lints 6 + SDK 3.12; ver se `directives_ordering`/imports novos de detail_actions.dart passam, hoje passam com a config antiga).

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes
1. `lib/widgets/detail_actions.dart` `toggleFavoriteFromList` / `favoriteHasProgress` (~l.99-141): ao desfavoritar uma série cujo progresso não está no cache, aguarda `favoriteDocsProvider.future` até 3 s SEM nenhum estado pendente. Cenário: stream lento/offline, usuário toca, nada acontece; toca de novo; cada toque dispara outra espera e, ao fim, dois diálogos "Remover dos favoritos?" empilhados (o pendente só começa após a confirmação). Correção: marcar pendente (`setPending(true)`) já antes da checagem e liberar ao cancelar, ou guardar um flag de "toggle em andamento" por chave. Não trava o usuário (máx. 3 s) e não apaga sem avisar (falha/timeout assume progresso e confirma), ou seja o lado seguro está correto.
2. `toggleFavoriteFromList` não trata falha de escrita que não seja `AuthRequiredException`/`FavoritesUnavailableException` (`runWrite` em auth_gate.dart:21-36): uma exceção do repositório sobe como erro assíncrono não tratado, sem snackbar. O `finally` libera o pendente, então não trava, mas o usuário não vê mensagem. Herdado do fluxo de adicionar; agora também vale para remover (mais grave: o usuário confirmou e nada acontece). Correção: capturar e mostrar snackbar genérico em `toggleFavoriteFromList` (ou em `runWrite`).
3. Estado obsoleto durante a espera/confirmação: `isFavorite` é capturado no toque. Se o item mudar (outra aba/dispositivo remove, ou progresso é marcado durante o diálogo), o `remove` é idempotente (ok), mas a decisão de confirmar foi tomada com progresso antigo. Risco baixo; mitigação: reavaliar `favoriteHasProgress` após o diálogo ou aceitar e documentar.
4. Testes fracos (item d): (a) `test/discovery_section_test.dart:~225` e `test/details_before_favorite_test.dart:~115` foram adaptados mas só verificam "não navega"/"addMovie não rechama"; não afirmam que o segundo toque realmente removeu (o teste do discovery nem chega a verificar remoção). O comportamento coberto de verdade está no novo `favorite_heart_toggle_test.dart` (3 hospedeiros x filme/série, com/sem progresso, Cancelar/Remover), que é legítimo e passa pelo motivo certo. Reforçar asserindo remoção. (b) Lacunas: não há teste para o caminho timeout/erro de `favoriteDocsProvider` (assume progresso e confirma), nem para duplo toque durante a espera, nem para a falha de escrita (item 2), nem para o login pendente a partir do coração (add sem await antes do popup).

## 🟢 Sugestões
1. `DetailToggleChip` (detail_actions.dart ~l.150): `materialTapTargetSize: padded` força caixa de 48 px também no desktop; o comentário diz "M3 default elsewhere". O chip visual de ~32 px com alvo de 48 px é aceitável (padrão M3 e atende o requisito de alvo); só corrigir o comentário/teste (`>= 32` no 1024 px não prova nada).
2. Diferença selecionado/não selecionado: favorito usa `primaryContainer`/`onPrimaryContainer` (par M3, contraste adequado em claro e escuro) mais ícone cheio; assistido usa o `secondaryContainer` padrão, que com seed deepPurple é um lilás parecido. Em tela de filme, os dois selecionados ficam visualmente próximos; ícone e rótulo diferenciam, mas confira na verificação visual. Teste de roxo só compara `selectedColor`, não contraste.
3. Semântica do chip: `button`, `selected`, `enabled`, rótulo com título; ok. Pendente desabilita o tap. Tela de série só com favorito e filme com favorito + assistido em `Wrap` (sem overflow nos testes a 320 px).
4. `FavoriteButton` (discovery_section.dart ~l.193): o `GestureDetector` absorvedor continua; o `IconButton` ativo vence a arena, não vaza para o cartão (testado nos 3 hospedeiros). Alvo 48 px no mobile / 40 px compacto no desktop, preservado. Tooltip correto ("Adicionar/Remover X ..."); não expõe `selected`/toggled, opcional adicionar via `Semantics(toggled:)`.
5. `ProfileStatsGrid` (profile_stats_card.dart ~l.45-75): `IntrinsicHeight` só em linhas de 2 tiles simples (poucos itens, ~3 linhas), custo desprezível; fonte 2x coberta por teste (320 px, escuro), item ímpar ocupa a linha inteira, largura da grade == cartão "Tempo assistido" (testado 320-1440). Remover `maxWidth: 480` é o pedido do Manager; em 1440 px o cartão fica bem largo (texto curto num cartão esticado), mas depende do container pai (conferir na tela real; se o Perfil já limita a largura do conteúdo, ok). Julgamento: aceitável, ajuste visual opcional.
6. `detail_actions.dart` imports fora de ordem (`providers`, `progress_calculator` antes de `models/title_details`); lint atual não reclama.

## Regressões checadas
- Detalhe antes de favoritar (`details_before_favorite_test`), confirmação ao desfavoritar no detalhe (agora `confirmRemoveFavorite` compartilhado, texto idêntico), Favoritos (sem coração, sem mudança), escrita/sync offline (fluxo de `runWrite`/repositório inalterado), tab bar: sem mudança no código e testes verdes.
- Login/intenção pendente: o caminho de adicionar chama `runWrite` sem await antes (popup preservado); porém `setPending(true)` com `setState` síncrono é aceitável. Intent pós-login reaproveita `addResult` (idempotente).
- Duplo toque após a confirmação: bloqueado pelo pendente por chave; antes dela, ver 🟡1.
