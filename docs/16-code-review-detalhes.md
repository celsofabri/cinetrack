# 16 - Code review: detalhes antes de favoritar

Branch `feat/details-before-favorite` (mudanças não commitadas). Revisor: Code Reviewer.

**Veredito: REPROVADO (mudanças solicitadas). Bloqueia o push: o finding 🔴1.** Os demais 🟡 devem entrar neste PR ou virar tarefa registrada.

## Verificação executada por mim
- `flutter analyze`: No issues found.
- `flutter test`: 289/289 passam.
- `flutter build web --release`: OK (só avisos de wasm-dry-run, sem relação).
- Visual (390 e 1024 px): **NÃO verificado**. A extensão do Chrome não está conectada. Layout só coberto pelo teste de 320 px (sem overflow, botão >= 48 px).
- Verificação extra, em cópia fora do repositório (nada alterado no projeto): removi o `GestureDetector` do `FavoriteButton` e o teste 1 do dev falha. Esse teste pega a regressão que deveria pegar. Também reproduzi com testes de widget os findings 🔴1 e 🟡1.

Tamanho: ~300 linhas alteradas em 8 arquivos, mais 4 novos. Revisável. `providers.dart` tem reformatação de quebra de linha sem relação (`searchResultsProvider`, `seasonProvider`), o que é ruído no diff (🟢).

## Requisito x origens
- Início, Explorar e Descoberta usam `_DiscoveryCard` e `FavoriteButton`. O toque no cartão abre o detalhe. Início/Favoritos/Continuar assistindo já navegavam.
- Catálogo (`catalog_screen.dart:280`) já navegava e usa o mesmo `FavoriteButton`. Sem alteração e sem teste novo.
- Busca (`search_screen.dart:145`) agora sempre abre o detalhe.
- Filme e série, logado e deslogado: os caminhos existem. Deslogado, `addResult` falha com `AuthRequiredException`, vira `PendingIntent` e o popup é chamado direto do toque (sem `await` antes). Correto.

## 🔴 Bloqueante

### 🔴1. Desfavoritar uma série mantém os episódios "assistidos" na tela
- Local: `tv_details_screen.dart:175` (`onRemove`) e `:287-296`. `seasonProvider` não observa os favoritos e não é invalidado após `repo.remove`.
- Cenário: série não favorita, expandir a temporada, marcar E1 (favorita e marca). Tocar em "Remover dos favoritos" e confirmar. O documento é apagado (confirmado no cloud), mas o E1 continua marcado na tela. Antes a tela voltava ao remover; agora ela permanece, então o estado velho fica visível.
- Efeito: mostra progresso que não existe. Ao tocar em E1 de novo, o código usa `watched: !episode.watched` (= false). Recria o favorito, grava "desmarcado" e o usuário vê o clique "não fazer nada". Reproduzido: depois do re-toque o doc volta a existir e o check aparece desmarcado.
- Correção: no `onRemove` da série, chamar `ref.invalidate(seasonProvider)` para todas as temporadas (ou tornar o provider dependente de `favoritesListProvider`). Repetir no filme se houver estado análogo (no filme não há; ele lê do `item`). Adicionar teste: marcar, remover, esperar check desmarcado.

## 🟡 Importantes

### 🟡1. Deslogado: episódio salvo, mas o check não atualiza
- Local: `tv_details_screen.dart:299-327` e `:237-250`.
- Cenário: deslogado, marca E1, faz login. `runWrite` retorna logo após o `signIn`, e a repetição roda em `Future.microtask` (não aguardada). O `ref.invalidate(seasonProvider)` ocorre antes da escrita terminar. O doc fica certo (`{1_1}`), mas o check permanece desmarcado. Reproduzido. Na temporada inteira acontece o mesmo.
- Correção: invalidar `seasonProvider` quando o documento do favorito mudar (`ref.listen` em `favoriteDocsProvider`, ou `seasonProvider` assistindo à lista). Isso também resolve o 🔴1.

### 🟡2. Acessibilidade do `GestureDetector` absorvedor
- Local: `discovery_section.dart:~205`.
- `onTap: () {}` cria uma ação de toque semântica. Um coração desabilitado ("Já é favorito") passa a ser anunciado como acionável sem fazer nada. O toque legítimo não é bloqueado (o `IconButton` habilitado ganha a arena; confirmado pelo teste).
- Correção: `excludeFromSemantics: true` no `GestureDetector`. O nó semântico do `IconButton` e o `Semantics` do cartão continuam valendo.

### 🟡3. Auto-favoritar: falha parcial e erros não tratados
- Filme e episódio fazem `addResult` e depois a escrita do assistido (`favorites_repository.dart:166-184`). Escrita não aguardada pelo Firestore, ou `FavoritesUnavailableException` na segunda etapa, deixa o título favoritado sem o progresso. O usuário só vê o snackbar de indisponibilidade.
- Outras exceções no `FilterChip` (`movie_details_screen.dart:127`) e no episódio (`tv_details_screen.dart:298`) não têm `try/catch`: viram erro assíncrono não tratado. A temporada tem `catch`.
- Sugestão: aceitar a falha parcial (documentada), mas envolver as três origens no mesmo tratamento com snackbar.

### 🟡4. Toque duplo rápido em episódio de não favorito
- O toque usa `!episode.watched` com `item` capturado no `build`. Antes de o stream atualizar, o segundo toque repete "true" e o usuário não consegue desmarcar. Janela curta. Mitigação: desabilitar o checkbox enquanto a escrita está em andamento, como a temporada já faz.

### 🟡5. Confirmação ao desfavoritar: falsos negativos
- Filme: `hasProgress = item.watchedMovie` (ok). Série: `progress.isStarted` (cache) OU `favoriteDocsProvider.valueOrNull ?? []` (`tv_details_screen.dart:68-71`).
- Se o stream de docs estiver em carregamento ou erro, o valor é `[]` e a remoção apaga sem aviso. Só ocorre se o cache também não indicar progresso, então é raro, mas é perda silenciosa de dados.
- Correção: se `favoriteDocsProvider` não tem valor, tratar como "pode ter progresso" e confirmar. Não há teste de confirmação para série.

### 🟡6. Remover offline sem cache do TMDB
- Favorito aberto offline (`titleDetailsProvider` com erro, ignorado). Ao remover, `item` vira `null` e `details` é `null`. A tela vira a tela de erro "Sem conexão" no lugar do conteúdo que o usuário tinha.
- Sugestão: guardar o último `item` ou aceitar e documentar.

## 🟢 Sugestões
- Custo: 1 chamada TMDB por detalhe aberto, inclusive de favorito (`titleDetailsProvider` é observado sempre). Aceitável (a série já usava `getTvDetails`), mas dá para só buscar quando faltar ano/gêneros/temporadas. `autoDispose` evita cache velho entre aberturas. Sem vazamento entre contas: o provider só depende do cliente TMDB (sem dados do usuário); `seasonProvider` depende do repositório por uid, então reconstrói na troca de conta.
- Busca: o coração desabilitado dentro do `ListTile` deixa o toque cair no `onTap` e abrir o detalhe (`search_screen.dart:138-145`). Difere do `FavoriteButton`. Decidir se é intencional.
- `ErrorState`: `retryLabel` ok.
- Reformatação sem relação em `providers.dart`: reverter.
- `detailsErrorMessage` mora em `movie_details_screen.dart` e é importada pela série. Mover para um widget/arquivo compartilhado.
- Tab bar e SyncBanner: `DetailBottomBanner` mantém o banner no mobile, detalhe fora do shell, botão voltar e logo preservados (`detailAppBar`). Sem regressão encontrada no código; **não verificado visualmente**.
- Escrita offline: `_fire` não aguarda o servidor, então o spinner do `FavoriteToggleButton` não trava offline.

## Testes (9 novos)
- Passam pelo motivo certo: teste 1 (mutação confirmada), movimentos de favoritar/desfavoritar com diálogo, auto-favoritar filme, episódio, replay pós-login (filme), login cancelado, erro com retry, busca, 320 px.
- O teste 1 usa `warnIfMissed: false` no coração preenchido. Funciona, mas o `GestureDetector` é o que o mantém honesto.
- O teste de replay pós-login cobre só filme. Falta série (que revelaria o 🟡1).
- Lacunas: temporada inteira para não favorito; confirmação ao desfavoritar série (cache vs. documento); remover e re-marcar (🔴1); toque no coração em estado pendente; Explorar/Catálogo com título não favorito; acessibilidade.

## Segurança / LGPD
Sem segredos, sem PII em log, sem mudança em regras do Firestore ou modelo. A chamada TMDB usa o cliente existente com IDs numéricos vindos da rota (`int.parse` no router; ID inválido gera exceção do router, comportamento pré-existente). Ok.

## Para destravar
1. Resolver o 🔴1 (invalidar/observar `seasonProvider` ao mudar o favorito) com teste.
2. 🟡2 é uma linha; 🟡1, 🟡3 e 🟡5 devem ir neste PR ou ser registrados. Depois nova revisão rápida e rodar a verificação visual em 390/1024 px.
