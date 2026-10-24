# 97 - Fatia 2 do ranking: dados, sinal "≥ 1 amigo" e RankingController

> Dev (Fatia 2) · 24/10/2026 · Branch `feat/social-ranking` · Entradas: [docs/90](./90-especificacao-ranking.md), [docs/91](./91-design-ranking.md) §4, §8, §10, §12 (oráculos O7–O11), [ADR-007](./adr/adr-007-ranking-no-cliente.md), [docs/95](./95-simplificacao-compartilhamento.md) (interruptor único, Fatia S).
> **Nada visível ao usuário.** Nenhuma regra, índice ou payload do servidor mudou; o ranking não grava nada (asserção de 0 escritas em todo teste do controller). Única escrita nova: a pista local `friendsHint:{uid}` no Hive.

## 1. O que foi entregue

| Peça | Arquivo | Observação |
|---|---|---|
| `FriendsCountController` (sinal O7) + `socialConnectivityProvider` + `friendsCountReaderProvider` | `lib/providers/friends_count_providers.dart` (novo) | arquivo próprio em vez de `social_lists_providers.dart` (menos conflito entre devs); mesmo comportamento do §8.1 |
| `rankingAccessProvider` (O8), `RankingController` (O9/O10), seams `rankingMeProvider`, `rankingFriendSharesProvider`, `rankingFriendReaderProvider`, `rankingReadTimeoutProvider` (8 s), `rankingCooldownProvider` (60 s) | `lib/providers/ranking_providers.dart` (novo) | |
| Pista `friendsHint:{uid}` (`y`/`n` + epoch ms) | `lib/services/local_store.dart` | apagada ao desativar amizades (`SocialController.deactivate`) e ao excluir a conta (`AccountController`) |
| `SocialRepository.friendsCount()` | `lib/repositories/social_repository.dart` | usa o `countFriends()` existente (agregada com limite 300 = 1 leitura) |
| Ganchos | `social_lists_providers.dart`, `friend_profile_providers.dart` | ver §2 |
| Testes | `test/friends_count_controller_test.dart` (42), `test/ranking_controller_test.dart` (53), `test/ranking_me_test.dart` (4) | fakes; harness `friends_harness.reads` agora separa `countFriends` (`friendsCountReads`) |
| Mutações R2-1…R2-30 | `tool/dart_mutations.py` | todas mortas (§5) |

## 2. Sinal "≥ 1 amigo" (O7) e acesso (O8)

- Estado `{count, confirmed, inFlight, dirty, hint}`; `hint` = pista fresca (idade ≤ 24 h, nunca negativa) do uid atual.
- **Contagem só com amizades CONFIRMADAS** (`SocialPhase.active`). Uma sessão que roda pela pista "amizades ligadas" (docs/59) continua com **0 leituras** até algo confirmar; nesse intervalo vale a pista `friendsHint` (O8 linhas 5 e 8). Consequência: a contagem da sessão sai quando a tela de Perfil/Amigos (ou o ranking, Fatia 3, que deve chamar `confirm()`) confirma o estado. Sem pista social, sai no 1º frame do shell (O11 linha 19).
- Gatilhos de `ensureConfirmed()`: `onShellShown()` (chamado pelo `refreshBadge`, só o 1º de cada geração conta), reconexão real (offline → online) e `onResume()` (`BadgeRefresher`). Navegar não recontabiliza.
- Gancho de `FriendsController.add` **antes** do retorno antecipado; deduplicação por uid (`_addedHere`) e pela lista carregada. `removed(uid)` libera o uid para uma nova amizade.
- `remove`: sucesso ⇒ `removed`; `uncertain` ⇒ `invalidate`. `afterBlock`: amigo saiu da lista (inclusive pelo `runFor` do `FriendsController.block`, via `alreadyDroppedFriend`) ⇒ `removed` uma vez; lista carregada completa do servidor ⇒ nada; senão ⇒ `invalidate`. **Refinamento**: bloquear o remetente de um pedido recebido não recontabiliza (`mayBeFriend: false`: quem tem pedido pendente não é amigo, invariante das regras) — economiza 1 leitura e mantém o teste existente de 0 leituras.
- `onFirstPage` (só servidor) ⇒ `fromFirstPage`; `_revoked` do perfil de amigo ⇒ `invalidate`.
- `invalidate` com contagem em voo marca `dirty` e pede **uma** nova contagem depois, **sem** sair de "em voo" (nada pisca). Resposta com `dirty` é descartada.
- Troca de conta / desativar / reativar: o controller observa `currentUidProvider` e `socialPeriodProvider`; respostas de outra geração são ignoradas.
- `rankingAccessProvider` é um `Provider<RankingAccess>` puro: a Fatia 3 faz `ref.listen(rankingAccessProvider, (_, _) => refresh.value++)` no `routerProvider`.

## 3. RankingController (O9, O10)

- Considerados = `FriendsController.state.items.take(50)` lidos no início da carga (`ensureLoaded`, ou `refresh` no "Atualizar"); lista com erro ⇒ fase pela falha, 0 `get`; lista `fromCache` ⇒ `offline`.
- Cache compartilhado `FriendProfileCache` (TTL 5 min), nunca servido com `fromCache` ou `force`.
- Janela: `iniciados = min(N, 10 + R)`, R contado a partir da 1ª `ok`/`denied` (inclusive); antes disso nada além das 10 primeiras; 10 primeiras respostas `failed` (com fila restante) ⇒ disjuntor: o resto vira `failed`.
- Timeout de 8 s no próprio controller (`Future.timeout`, injetável); resposta tardia é ignorada.
- `quota`/`unauthenticated` ⇒ para tudo, fase terminal, em voo descartado (o que chegou antes fica no cache). Queda da conexão ⇒ idem com `offline`.
- `denied` ⇒ `cache.remove` + `dropLocal` + **uma** `invalidate` no fim da carga; todos negados ⇒ `awaitingRecount` até a recontagem (0 ⇒ o router sai; > 0 ⇒ recarrega).
- "Tentar novamente": parcial ⇒ só os `failed` (`force`); erro/cota/sessão ⇒ carga completa. Nunca com cooldown.
- "Atualizar": `RankingRefresh.cooldown` se `agora − freshAt < 60 s`; `joined` se já há carga; senão lista (com os 15 s dela) + todos com `force`. `freshAt` = leitura mais antiga entre todas as respostas `ok` (com ou sem stats, servidor ou cache).
- Geração: troca de conta, desativar amizades ou sair da tela (AutoDispose) ⇒ nada tardio grava estado ou cache.

## 4. Contrato com as Fatias 1 e 3 (reconciliar)

- O estado entrega **dados crus**: `friends: List<RankingFriend>` (`Friend` + `FriendSharedView` + `at`), `me: SharedProfileDoc?`, `meSharing: bool?`, `notSharing`, `failed`, `limitedTo`, `totalFriends`, `freshAt`, `refreshing`, `awaitingRecount`, `showsRows` (só `content`). A Fatia 3 monta `RankingParticipant` com `RankingReading.fromOwn`/leitor da Fatia 1 e chama `RankingTable.rank(…, serverClock.now())` no `build` (0 leituras ao trocar filtro). O `RankingState` do §10.1 (com `RankingParticipant`) foi adaptado assim porque a Fatia 1 ainda não existia quando comecei; não há tipo duplicado.
- **Desacoplado do "eu compartilho"** (docs/95): a regra fica só em `rankingMeProvider` (hoje: documento próprio confirmado com consentimento e seção `stats`) e `rankingFriendSharesProvider` (hoje: `view.stats != null`). A Fatia S troca só esses providers.
- O nome de "Você" (`displayLabelProvider`) e `rankingLastFilterProvider` ficam para a Fatia 3.
- A Fatia 3 deve chamar `socialControllerProvider.notifier.confirm()` ao abrir `/ranking` (ranking como 1ª tela, O11 linha 3).

## 5. Verificação

- `flutter analyze`: 0 issues (cópia de `HEAD` em `/tmp`).
- `TZ=America/Sao_Paulo flutter test` e `TZ=UTC flutter test`: 2562 testes, todos verdes nos dois fusos (cópia de `HEAD` = `842435e`).
- Oráculos cobertos linha a linha: O7 1–33 (29 com troca de conta; 30–31 desativar/reativar; 32 coberto pela limpeza no `AccountController` + 33 nova sessão), O8 1–9, O9 1–18 (+ janela, < 10 sem disjuntor, `take(50)`, minha linha, offline), O10 1–13 (+ sem `ok` ⇒ sem cooldown), O11 1, 2/3, 4, 5, 6, 7, 11, 12, 13, 14, 15, 16 (perfil aberto no TTL com o `FriendProfileController` real = 0 leituras), 17, 18, 19, 20 e 21–24 nos testes do sinal.
- Mutações Dart (só as da fatia, `python3 tool/dart_mutations.py <cópia> R2-1 … R2-30`): **33/33 mortas**.

| # | Mutação | Morta por |
|---|---|---|
| R2-1/2/3 | janela em degraus; janela que recompleta 10 em voo (em vez de 10 + R); janela de 50 | O9-18, teste "window", pico 10 |
| R2-4/5/6 | disjuntor removido; limiar 9; limiar 11 | O9-2, O9-3, O11-12 |
| R2-7/8/9/10 | âncora do cooldown na leitura mais nova; na reabertura; cooldown removido; cooldown no "Tentar novamente" | O10-5, O10-6, O10-1/2, O10-7 |
| R2-11 | "Tentar novamente" relê todos | O9-7 |
| R2-12/13/14 | k recontagens; negado sem `dropLocal`; sem `cache.remove` | O11-14/15, O9-4, teste de negação |
| R2-15/16 | resposta após o timeout aceita; resposta após cota/offline gravada | O9-6, O9-5/9/10 |
| R2-17/18/19/20 | TTL ignorado; offline carrega; lista do aparelho tratada como online; limite de 50 removido | O11-5, offline ao abrir, O9-14c, 80 amigos |
| R2-21 | minha linha com dono não confirmado | `ranking_me_test` |
| R2-22 | acesso `allowed` sem pista | O7-1, O8-9 |
| R2-23/24/25 | dedupe por uid removida; quem já está na lista contado; gancho depois do retorno antecipado | O7-13, 13b, teste de gancho |
| R2-26/27/28/29 | resposta em voo não descartada com `dirty`; agregada a cada navegação; recontagem que pisca; pista sem TTL | O7-11/24, O7-8/9, O7-22, O7-3 |
| R2-30 | bloqueio de amigo listado sem decremento | teste de `block()` |
| R2-31/32 | exclusão de conta / desativação mantêm `friendsHint` | `friends_hint_cleanup_test` (O7-32, O7-30) |
| R2-33 | `_revoked` do perfil de amigo sem recontagem | teste do perfil negado em `ranking_controller_test` |

## 6. Notas para review/QA

- Meu primeiro commit WIP (`47f63b2`) levou junto, em `social_lists_providers.dart`, a extração do `collationKey` que a Fatia 1 tinha em stage; o commit seguinte da Fatia 1 (`8a6d17b`) trouxe `lib/social/collation_key.dart`, então `HEAD` compila. Só `47f63b2` isolado não compila.
- O32/O30 (exclusão de conta e desativação apagam `friendsHint`) e `_revoked` do perfil chamando `invalidate`: com teste e mutação (R2-31…R2-33).
