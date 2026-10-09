# 72 - Parecer QA: Amizades, Fase 1 (fatias 0 a 5)

> Autor: QA Engineer (gate) · Data: 2026-10-08 · Branch `feat/social-friends` (HEAD `5755b85`, base `main` `c60a393`) · Contrato: [docs/49](./49-especificacao-amizades.md), [docs/50](./50-design-amizades.md), [ADR-005](./adr/adr-005-modelo-social-amizades.md), [docs/51](./51-regras-sociais-fatia-0.md), implementação [55](./55-social-fatia-1-implementacao.md)/[59](./59-social-fatia-2-implementacao.md)/[62](./62-social-fatia-3-implementacao.md)/[65](./65-social-fatia-4-implementacao.md)/[68](./68-social-fatia-5-implementacao.md), reviews 52 a 70.
> Somente leitura: nenhum arquivo de código ou teste foi alterado. Experimentos (mutações Dart, suíte da `main`) rodaram em cópias no scratchpad. `git status` antes e depois: limpo, exceto este documento.

---

## Parecer QA: Amizades Fase 1 — ❌ REPROVADO

- **Critérios de aceite (docs/49):** 32 cenários Gherkin. **29 cobertos** por teste que falha quando o comportamento quebra; **3 com lacuna** (L1, L2, L3 abaixo). Requisitos do Manager: 17/18 cobertos (o 18º é o mesmo L2).
- **Regressão:** passou. Os 880 testes da `main` estão todos na suíte da branch; só 3 arquivos antigos mudaram, e as mudanças são legítimas (ver §3). As regras novas só acrescentam linhas (o `diff` das regras não remove nenhuma). As suítes de regras antigas rodam sem alteração contra as regras novas. Existe teste de compatibilidade nos dois sentidos: app novo com regras v1/v2, e regras novas com documentos legados.
- **Números reais (rodados por mim):** ver §4. `flutter analyze` 0 problemas · `flutter test` **1490/1490 nas 2 execuções** (sem flaky) · `npm test` **364/364** · `npm run test:mutations` **48/48 mortas** (JDK 24 via `JAVA_HOME`).
- **Bugs abertos:** S1: 0 | S2: 0 | S3: 2 | S4: 2
- **Motivo da reprovação:** o Manager não aceita "aprovado com ressalvas". Encontrei 4 lacunas. Nenhuma põe dados em risco nem abre vazamento. Duas delas (L1 e L2) são critérios de aceite sem teste capaz de falhar. As 4 são correções pequenas e estão detalhadas na §5, com o arquivo e o caso de teste a criar.
- **Riscos residuais (não bloqueiam; o smoke da §7 cobre):** o SDK Firestore real nunca rodou contra o emulador. O contrato está provado por golden e replay dos payloads Dart contra as regras reais, mas leituras, consultas, paginação e transações do `FirestoreSocialDataSource` só rodaram com fakes. Os índices compostos não são exigidos pelo emulador. A cobrança das leituras de regra e o `existsAfter` em produção também não foram verificados.

---

## 1. Plano de testes

**Escopo:** as fatias 0 a 5 inteiras. Isso inclui regras, índices, ativação e privacidade, busca, pedidos, amizades, contador, remoção, bloqueio, convite, refresh de apelido/foto, desativação, exclusão de conta, exportação, navegação e estados de UI (320 a 1440 px, teclado, leitor de tela, pt-BR). Também entram a regressão das features existentes e o roteiro de rollout e smoke.
**Fora de escopo:** F2 a F5; execução em produção (é do Manager, roteiro na §7); leitor de tela real; aparência visual em navegador (não abri o app em navegador).

**Riscos priorizados**
1. Vazamento de dado para não amigo, bloqueado ou anônimo (regras). Cobertura: `social.test.mjs` + replay + 48 mutações de regras/payload.
2. Perda de dados atuais (favoritos, progresso, apelido). Cobertura: regras só aditivas, `social_compat.test.mjs`, suíte antiga intacta.
3. Exclusão e exportação incompletas (LGPD). Cobertura: testes de repositório, controller e AccountDeleter com dados reais do app; mutações D2, D3 e D6 mortas.
4. Divergência fake × SDK real (L1) e emulador × produção. Cobertura: smoke da §7.
5. Rollout fora de ordem (app antes das regras ou dos índices). Cobertura: §6.

| Caso | Tipo | Nível | Automatizado? | Critério ligado |
|---|---|---|---|---|
| Regras: um lado não cria amizade, terceiro não usa pedido, bloqueio parcial negado, não amigo não lê, bloqueio nos 2 sentidos, schema e payloads maliciosos | Segurança | integração (emulador) | ✅ | Cenários de regras |
| Replay dos payloads Dart contra as regras reais (golden) | Contrato | integração | ✅ | Todos os de escrita |
| Mutações de regras e payloads (48) | Qualidade de teste | integração | ✅ | Regras |
| Mutações Dart (8, minhas) | Qualidade de teste | unit/widget | ✅ (scratchpad) | Exclusão, exportação, bloqueio, contador, busca |
| Repositório e controllers (cache, TTL, falhas, troca de conta) | Funcional/negativo | unit | ✅ | Busca, pedido, lista, remover, bloquear, convite |
| Telas `/friends`, `/friends/add`, `/invite/:code`, Perfil > Amizades | Funcional, estados de UI | widget | ✅ | Todos os de UI |
| Matriz 320/390/768/1024/1440 px × fonte 1x/2x/3x × claro/escuro, alvos ≥ 48 px | NFR | widget | ✅ | Teclado e leitor de tela |
| Compatibilidade de regras antigas com app novo (v1/v2) e de documentos legados com regras novas | Regressão | integração | ✅ | Usuário atual não faz nada |
| Suíte antiga (880 testes da `main`) | Regressão | unit/widget | ✅ | Restrição "ninguém perde dados" |
| Smoke em produção com 2 contas Google | E2E manual | e2e | ❌ (Manager, §7) | Emulador × produção, índices |

---

## 2. Matriz de rastreabilidade

Legenda: ✅ coberto (o teste falha se o comportamento quebrar) · ⚠️ lacuna. Abreviações de arquivo: `t/` = `test/`, `r/` = `firestore_rules_test/`.

### 2.1 Critérios de aceite do docs/49

| # | Cenário | Teste(s) | Status |
|---|---|---|---|
| 1 | Usuário atual não precisa fazer nada | `t/friends_navigation_test.dart` "a user who never turned friendships on: every screen … reads and writes nothing social"; `r/social_compat.test.mjs` "legacy documents (no new fields) keep working", "nobody else reads legacy data"; `r/social.test.mjs` "request to a user without social is denied" | ✅ |
| 2 | Ativar com handle livre | `t/social_repository_test.dart` activate "writes card + pointer with a sanitized photo"; `t/social_section_test.dart` "activation: validates, then creates card + pointer with consent text"; `r/social.test.mjs` "activation by batch (card + pointer) succeeds" | ✅ |
| 3 | Handle já em uso | `t/social_section_test.dart` "taken handle: field error, nothing created"; `t/social_repository_test.dart` "taken handle: nothing is created" | ⚠️ **L1**: o ramo real "handle de pessoa oculta ou que me bloqueou = em uso" (`permission-denied` → `handleTaken`) não tem teste (mutações D4 e D5 sobrevivem) |
| 4 | Handle inválido ("Ab", "a b", "_ana", "ana_", "admin", > 20) | `t/social_validation_test.dart` "accepts the valid format and rejects the rest with pt-BR messages", "the 31 reserved handles are identical to firestore.rules"; `t/social_section_test.dart` activation (botão desabilitado); `r/social.test.mjs` "invalid handle … is denied" | ✅ |
| 5 | Disputa simultânea | `r/social.test.mjs` "3 concurrent transactions on the same handle: exactly 1 wins" | ✅ nas regras / ⚠️ L1 no cliente (a mensagem do perdedor depende do ramo sem teste) |
| 6 | Ficar fora da busca | `t/social_requests_test.dart` "missing, hidden, blocked either way, yourself, reserved: the SAME answer"; `r/social.test.mjs` "hidden card: denied to others (even friends)" | ⚠️ **L2**: falta "**eu, oculto,** continuo podendo buscar, enviar e aceitar" (nenhum teste usa um ator com `discoverable: false`) |
| 7 | Trocar handle (> 30 dias) | `t/social_repository_test.dart` "30-day interval: blocked at 29 days, allowed at 30, old handle freed"; `t/social_section_test.dart` "changes the handle after 30 days"; `t/social_friends_test.dart` "changing the handle keeps the lists"; `r/social.test.mjs` "change after >= 30 days succeeds and frees the old handle for others" | ✅ |
| 8 | Trocar cedo demais | `t/social_section_test.dart` "handle change inside 30 days is disabled with the date"; `r/social.test.mjs` "change within 30 days is denied" | ✅ |
| 9 | Remover apelido com amizades ativas | `t/social_section_test.dart` "nickname dialog also updates the card and cannot be cleared" | ✅ |
| 10 | Buscar e enviar pedido | `t/friends_screens_test.dart` "found: card with photo slot, nickname, @handle; 'Enviar pedido' sends"; `t/social_requests_test.dart` "finds a discoverable person with ONE read; handle is normalized", "sent list …" | ✅ |
| 11 | Mesma mensagem: bloqueado, oculto, inexistente | `t/friends_screens_test.dart` "missing / hidden / blocked / yourself / reserved: IDENTICAL text"; `t/friends_slice4_screens_test.dart` "somebody who blocked ME is not found" | ✅ no comportamento / ⚠️ **L3**: o texto ("Não encontramos ninguém com esse apelido") difere do contrato ("Nenhum usuário encontrado") e fala de "apelido" numa busca por identificador |
| 12 | Pedido duplicado | `t/social_requests_test.dart` "duplicate: 'já enviou', and no second document"; `t/friends_screens_test.dart` "already sent …"; `r/social.test.mjs` "duplicate (same direction) is an update: denied" | ✅ |
| 13 | Já são amigos | `t/friends_slice3_screens_test.dart` "a person already in the loaded friends list says so, with no send button"; `r/social.test.mjs` "already friends: new request in either direction is denied" | ✅ |
| 14 | Pedido cruzado | `t/social_friends_test.dart` "one batch; no request is left in either direction"; `t/friends_screens_test.dart` "they already asked me (D4)"; `r/social.test.mjs` "crossed request by transaction", "concurrent crossed transactions never leave a pending request" | ✅ |
| 15 | Cancelar pedido enviado | `t/social_requests_test.dart` "cancel deletes only my request …; repeating is harmless"; `t/friends_screens_test.dart` "cancel asks first …"; `r/social.test.mjs` "cancel (sender) and decline (recipient) succeed" | ✅ |
| 16 | Aceitar | `t/social_friends_test.dart` group "accept (ONE batch …)"; `t/friends_slice3_screens_test.dart` Pedidos recebidos (aceitar); `r/social.test.mjs` "recipient accepts only if the same batch consumes the request(s)" | ✅ |
| 17 | Recusar | `t/social_friends_test.dart` "decline deletes only that request; nobody is notified"; `t/friends_slice3_screens_test.dart` "decline: silent for the sender" | ✅ |
| 18 | Um lado não cria amizade (regras) | `r/social.test.mjs` "neither side can create a friendship alone", "the sender cannot confirm his own request", "a third party cannot use someone else's request"; mutações M1 "friendship without the other side's request" e M2 "accept does not consume the request" (`mutations.mjs`) mortas no resumo 48/48 | ✅ |
| 19 | Lista de amigos em ordem alfabética | `t/friends_slice3_screens_test.dart` "lists friends by name …", group "Amigos: order and 'Atualizar'" | ✅ |
| 20 | Indicador de pedidos recebidos + leitor de tela | `t/friends_slice3_screens_test.dart` group "badge on the Amigos icon …" (rótulo "N pedidos de amizade recebidos"; mutação D7 morta) | ✅ |
| 21 | Remover amigo | `t/friends_slice3_screens_test.dart` "remove: asks first … confirming deletes"; `t/social_friends_test.dart` "remove deletes the one pair document: both lists lose it"; `r/social.test.mjs` "after unfriending, the pair is gone for both reads right away" | ✅ |
| 22 | Bloquear amigo | `t/social_block_test.dart` group "block (ONE batch …)", "what the blocked person (and the blocker) can do afterwards"; `t/friends_slice4_screens_test.dart` "block from a friend card"; `r/social.test.mjs` "block of a friend with pending requests …", "after the block: requests in both directions and the pair are denied"; mutação D1 morta | ✅ |
| 23 | Desbloquear | `t/social_block_test.dart` "unblock deletes only the block: friendship and requests do NOT come back"; `t/friends_slice4_screens_test.dart` group "unblock"; `r/social.test.mjs` "unblocking does not restore friendship; a new request is possible" | ✅ |
| 24 | Bloqueio parcial impossível (regras) | `r/social.test.mjs` "block of a friend … succeeds only if the batch removes all three"; mutação M4 morta | ✅ |
| 25 | Excluir conta | `t/social_repository_test.dart` "door first, then sweeps; user disappears from friends' lists", "AccountDeleter runs the social step between marker and favorites"; `t/social_friends_test.dart`/`t/social_block_test.dart`/`t/social_invite_account_test.dart` "AccountController.deleteAccount sweeps real …"; `r/social.test.mjs` "closes the door first …"; mutações D2/D3 mortas | ✅ |
| 26 | Exclusão interrompida e retomada | `t/social_repository_test.dart` "failure maps to AccountDeletionFailure and a rerun resumes", "AccountDeleter: social failure stops before favorites; retry completes" | ✅ |
| 27 | Exportar meus dados | `t/social_export_test.dart` "with friendships: handle, preferences, raw docs and uid + nickname of friends", "a version-1 file … still a valid subset"; `t/social_invite_account_test.dart` export group; mutação D6 morta | ✅ |
| 28 | Sem login | `t/friends_navigation_test.dart` "signed out: $path goes home", "only signed in AND friendships on"; `t/friends_slice3_screens_test.dart`/`t/friends_slice4_screens_test.dart` redirect | ✅ |
| 29 | Offline | `t/friends_slice3_screens_test.dart` "offline: the saved list with the notice; removing is disabled", "accept offline …"; `t/friends_screens_test.dart` "offline: search and send are disabled with the reason"; `t/friends_slice4_screens_test.dart` "offline: 'Bloquear' is disabled" | ✅ |
| 30 | Regras ainda não publicadas | `t/social_section_test.dart` "rules not published: visible message, retry"; `t/friends_screens_test.dart` "rules not published …"; `r/social_compat.test.mjs` "NEW app x OLD rules: every social operation is denied" | ✅ no portão de carregamento / ⚠️ L1: `t/social_repository_test.dart` "rules not published: visible failure" (activate) só passa no fake. No código real a mesma negação vira "Esse identificador não está disponível" |
| 31 | Cota diária esgotada | `t/friends_screens_test.dart`, `t/friends_slice3_screens_test.dart`, `t/friends_slice4_screens_test.dart` (mensagem "Muitas operações hoje…") | ⚠️ **L4**: falta provar "e favoritos continuam funcionando" com o social em cota esgotada |
| 32 | Teclado e leitor de tela | `t/friends_screens_test.dart` "the field has focus on open; Tab reaches 'Buscar'; Enter …"; `t/friends_slice3_screens_test.dart` "keyboard: arrows move focus AND selection …", remove dialog (`autofocus` em Cancelar, Esc); `t/friends_slice4_screens_test.dart` block dialog, "semantic labels … name the person"; matrizes de layout 320 a 1440; mutação D8 (Enter no campo) morta | ✅ |

### 2.2 Requisitos do Manager (fase 1)

| Requisito | Teste(s) | Status |
|---|---|---|
| Descoberta por handle exato | linhas 10/11 acima; `r/social.test.mjs` "visible card … list is denied" | ✅ |
| Convite por link | `t/social_invite_test.dart` (código, validade, criar/substituir/revogar/abrir/usar); `t/invite_ui_test.dart`; `r/social.test.mjs` group "convite por link"; mutações M34 a M38 e F5 a F10 mortas | ✅ |
| "Não aparecer na busca" | linha 6 | ⚠️ L2 |
| Pedido enviar/cancelar/aceitar/recusar, sem duplicados, cruzado vira amizade | linhas 10, 12, 14 a 17 | ✅ |
| Lista de amigos e pendentes com indicador | linhas 19, 20; `t/social_friends_test.dart` "lists: received requests and friends" | ✅ |
| Remover amigo sem notificar, dos dois lados | linha 21 | ✅ |
| Bloquear: desfaz, cancela, invisível, sem aviso, tela de bloqueados, desbloquear não restaura | linhas 22 a 24; `t/friends_slice4_screens_test.dart` "Bloqueados tab: states" | ✅ |
| Regras com isFriend/isBlocked reutilizáveis | `r/social.test.mjs` "isFriend / isBlocked em outras features (sondas)"; `r/rules_budget.test.mjs` | ✅ |
| AccountDeleter e exportação cobrindo tudo (inclui convite e refresh) | linhas 25 a 27; `t/social_invite_account_test.dart` | ✅ |
| Rollout regras antes do app | `r/social_compat.test.mjs` (app novo com regras antigas: nada é gravado, legado segue); §6 | ✅ |
| Docs antigos funcionando | `r/social_compat.test.mjs` (documentos legados sem `schemaVersion`/`updatedAt`); `r/firestore.rules.test.mjs` e `r/recommended.test.mjs` **sem alteração** contra as regras novas; `fixtures/firestore.rules.v2` idêntico às regras da `main` (`diff` vazio, conferido) | ✅ |
| Layout 320 a 1440 px | matrizes em `t/friends_screens_test.dart`, `t/friends_slice3_screens_test.dart`, `t/friends_slice4_screens_test.dart`, `t/social_section_test.dart`, `t/invite_ui_test.dart`, `t/friends_navigation_test.dart` | ✅ |
| Teclado | linha 32 | ✅ |
| UI em português | todos os testes de widget comparam textos pt-BR | ✅ (ver L3: um texto diverge do contrato) |
| Regras: um lado não cria amizade | linha 18 | ✅ |
| Regras: não amigo não lê | `r/social.test.mjs` "only members read (get/list)", "only sender and recipient read", "the pointer is private"; `r/social_compat.test.mjs` (favoritos fechados a amigo/bloqueado/convidante) | ✅ |
| Regras: bloqueio nas duas direções | `r/social.test.mjs` "block in either direction hides the card", "after the block: requests in both directions … denied", "block in either direction hides the invite" | ✅ |
| Regras: schema, maliciosos e compatibilidade com as anteriores | `r/social.test.mjs` "schema …", "malicious payloads are denied", "endurecimento"; `r/social_compat.test.mjs` | ✅ |

### 2.3 Estados de UI (docs/50 §12)

| Estado | Amigos | Pedidos | Bloqueados | Buscar | Perfil > Amizades | Convite |
|---|---|---|---|---|---|---|
| Carregando | ✅ skeleton | ✅ | ✅ | ✅ "Buscando" | ✅ "loading state comes first" | ✅ |
| Vazio | ✅ | ✅ | ✅ | ✅ (L3 no texto) | ✅ "off by default" | ✅ "no invite yet" |
| Erro | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (inclui leitura falha) |
| Offline | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Sem login | ✅ | ✅ | ✅ | ✅ | ✅ (rota já protegida) | ✅ deslogado → entrar → continua |
| 320 px / fonte 3x | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Teclado | ✅ | ✅ | ✅ | ✅ | ✅ Enter no apelido | ✅ Tab/Enter em "Enviar pedido" |

### 2.4 Testes que não podem falhar (mutações)

- **Regras e payloads:** `npm run test:mutations`: 48/48 mortas (38 de regras M1 a M38 e 10 de payload F1 a F10).
- **Dart:** rodei 8 mutações minhas numa cópia no scratchpad, cada uma contra os testes relevantes:

| Mutação | Resultado |
|---|---|
| D1 bloquear não apaga o pedido dele para mim | morta |
| D2 exclusão de conta pula as varreduras (pares, pedidos, bloqueios) | morta |
| D3 AccountDeleter não chama o passo social | morta |
| D4 `isHandleFree`: `permission-denied` (handle oculto/bloqueado) vira "livre" | **SOBREVIVEU** (suíte inteira, 1490 passam) |
| D5 transação de ativar/trocar: `permission-denied` no handle vira `denied` em vez de `handleTaken` | **SOBREVIVEU** (suíte inteira) |
| D6 exportação omite os bloqueios | morta |
| D7 rótulo do contador perde "de amizade recebidos" | morta |
| D8 Enter no campo de busca não busca | morta |

---

## 3. Regressão

- **Suíte da `main` (c60a393), rodada numa cópia limpa:** 880 testes, todos passando. A branch tem 1490, ou seja, 610 novos. Nenhum arquivo de teste antigo foi removido.
- **Testes antigos alterados** (`git diff c60a393 HEAD`): só 3, e nenhum ficou mais fraco.
  - `account_deleter_test.dart`: passa o novo parâmetro `social:`.
  - `export_serializer_test.dart`: `schemaVersion` passa de 1 para 2, que é a mudança contratada, e o stub ganhou 2 métodos.
  - `profile_screen_test.dart`: rola até o link antes de tocar, porque o resumo de privacidade cresceu.
- **Features existentes seguem cobertas e passando:** favoritos (`favorites_*`, `favorite_*`), assistido (`quick_watched_test`, `detail_watched_series_test`), progresso (`progress_calculator_test`, `season_progress_calculator_test`, `continue_watching_provider_test`), recomendações (`recommended_data_test`, `recommendations_ui_test`), exportação (`export_*`, `firestore_export_data_source_test`), exclusão de conta (`account_deleter_test`, `deletion_guard_test`, `profile_screen_test` "interrupted deletion"), perfil (`profile_screen_test`, `profile_stats_test`, `login_widgets_test`), isolamento entre contas (`account_isolation_test`).
- **Restrição "ninguém perde dados atuais":**
  - O `diff` de `firestore.rules` não remove nenhuma linha; `validProfile` e `validFavorite` estão intactos.
  - Nenhuma migração ou escrita em `users/{uid}` ou `favorites` vem do social: o teste de ativação com dados legados mostra o favorito intacto, e quem não ativa não grava nada.
  - A exportação v2 só acrescenta: um arquivo v1 continua subconjunto válido.
  - Conclusão: **nenhum caminho de perda de dados encontrado.**

---

## 4. Números reais (rodados por mim, 2026-10-08)

| Verificação | Resultado |
|---|---|
| `flutter analyze` | **No issues found** (exit 0) |
| `flutter test` execução 1 | **1490 passaram, 0 falharam, 0 pulados** (1 min 36 s) |
| `flutter test` execução 2 | **1490 passaram, 0 falharam, 0 pulados** (59 s): **sem flaky** |
| Suíte da `main` (cópia) | 880 passaram |
| `npm test` (emulador, JDK 24 `/opt/homebrew/opt/openjdk@24` via `JAVA_HOME` só no comando) | **364 testes, 39 suites: 364 passaram, 0 falharam, 0 pulados** (36 s), exit 0 |
| `npm run test:mutations` | **"All 48 mutations were killed."** (exit 0; o log capturado mostra 46 linhas individuais porque as linhas M1/M2 se misturaram com a saída do emulador, mas o resumo do script confirma 48/48) |
| Mutações Dart (minhas) | 8 aplicadas: 6 mortas, **2 sobreviveram** (D4, D5 → L1) |

Observação de ambiente: na primeira tentativa, `npm test` não subiu o emulador ("port taken", porta 8080 ocupada por outro processo naquele instante). Rodei de novo com a porta livre; o número acima é dessa segunda execução. JDK usado: `/opt/homebrew/opt/openjdk@24` (24.0.2), só via `JAVA_HOME` no comando.

---

## 5. Lacunas e bugs (precisam ser corrigidos para APROVADO)

### L1 · S3 · O ramo real "handle ocupado por pessoa oculta ou que me bloqueou" não tem teste, e o fake diverge do código real
- **Onde:** `lib/data/firestore_social_data_source.dart`.
  - `isHandleFree`: `permission-denied` → `false`.
  - `_txGetHandle`: `permission-denied` → `handleTaken`.
  - Esses ramos são usados em `activate` e `changeHandle`.
- **Evidência:** as mutações D4 (devolver "livre") e D5 (devolver `denied`) **sobrevivem à suíte inteira** (1490 passam). Os testes de repositório e de widget usam `InMemorySocialDataSource`, que não passa por esses ramos.
- **Divergência:** com `rulesLive = false`, o fake responde `denied` ("Amizades ainda não estão disponíveis"). O código real, com as regras antigas, recebe `permission-denied` no `tx.get(handles/h)` e mostra "**Esse identificador não está disponível**".
  - Hoje o usuário só não vê isso porque o carregamento do estado (`load`) falha antes e bloqueia o formulário.
  - Por isso o teste `t/social_repository_test.dart` "rules not published: visible failure, nothing lost" (activate) só passa por causa do fake.
- **Impacto:** se alguém quebrar esses ramos, a UI pode dizer "disponível" para um handle tomado (critérios 3 e 5) ou mostrar a mensagem errada, e nenhum teste vai acusar.
- **Correção:**
  1. Dar a `FirestoreSocialDataSource` um ponto de injeção para a leitura do handle, no mesmo padrão do `executor`/`countReader` já usados em `t/firestore_social_data_source_test.dart`.
  2. Criar no mesmo arquivo:
     - `isHandleFree: a hidden or blocking owner (permission-denied) is "taken", never "free"`;
     - `isHandleFree: a missing document is free`;
     - `activate/changeHandle: permission-denied on the handle read is handleTaken`;
     - `activate: permission-denied on the own social read (old rules) is denied, not handleTaken`.
  3. Para o último caso: ler `social/{uid}` **antes** do handle na transação. A leitura do próprio ponteiro só é negada quando as regras não estão publicadas, o que separa os dois casos.
  4. Alinhar o fake (`test/support/fake_social_cloud.dart`) com o resultado.

### L2 · S3 · Critério "Ficar fora da busca": a parte "eu continuo podendo buscar, enviar e aceitar" não tem teste
- **Evidência:** nenhum teste (Dart, regras ou replay) usa como **ator** um usuário com `discoverable: false`. Todos os `discoverable: false` são do alvo: `t/social_requests_test.dart:73`, `t/friends_screens_test.dart:274`, `t/social_block_test.dart:183`, `r/dart_payloads.test.mjs:262`.
- **Impacto:** uma mudança nas regras ou no app que exija "visível" de quem envia ou aceita passaria sem ser vista.
- **Correção:**
  - Em `firestore_rules_test/social.test.mjs`, criar `it('a hidden user ("Aparecer na busca" off) still reads visible cards, sends, cancels and accepts')`. Semear o ator com `discoverable: false`; ler o cartão visível do outro, criar pedido, cancelar e aceitar o pedido inverso por batch. Tudo deve passar.
  - Em `test/friends_screens_test.dart`, criar `testWidgets('hidden from the search: I can still search, send and accept')`. O harness deve ativar a Ana com `discoverable: false`.
  - Acrescentar uma mutação em `mutations.mjs` que exija o cartão do remetente com `discoverable == true` no `validRequest`. Essa mutação deve ser morta.

### L3 · S4 · O texto de "não encontrado" diverge do contrato e é enganoso
- **Onde:** `lib/social/social_models.dart:341`, `kSearchNotFoundMessage = 'Não encontramos ninguém com esse apelido'`. O README repete o texto.
- **Esperado (docs/49 e docs/50 §12):** "Nenhum usuário encontrado".
- **Obtido:** a mensagem fala em "apelido", mas a busca é só por **identificador** (o campo se chama "Identificador"). Isso sugere que buscar por apelido funcionaria, o que o D1 proíbe.
- **Correção:**
  - Trocar para "Nenhum usuário encontrado com esse identificador." (ou exatamente "Nenhum usuário encontrado", como o Product Analyst decidir).
  - Atualizar o README.
  - Os testes que usam a constante seguem iguais. Acrescentar em `test/friends_screens_test.dart` uma asserção literal do texto, para que ele não volte a divergir do contrato.

### L4 · S4 · Critério "Cota diária esgotada": falta a metade "favoritos continuam funcionando"
- **Evidência:** os testes de cota só verificam a mensagem nas telas sociais. Nenhum teste combina o social em `resource-exhausted` com uma ação em favoritos.
- **Correção:** criar em `test/friends_slice3_screens_test.dart` (ou em `friends_navigation_test.dart`) o `testWidgets('social quota exhausted: the message shows and Favoritos still lists and toggles from the device copy')`.
  - Falhar `friendsPage` com `quotaExceeded`.
  - Abrir `/favorites` e marcar e desmarcar um favorito pelo harness existente (`favorites_harness.dart`).
  - Verificar a lista e a escrita.

### Observações sem severidade (não bloqueiam; registrar)
- `SocialRepository.wipeForAccountDeletion` trata `denied` em `closeSocial` como "regras não publicadas" e **pula todas as varreduras**. Com as regras publicadas, não encontrei nenhum estado válido em que o fechamento seja negado (o código lê o ponteiro, o cartão e o convite do servidor antes). Mesmo assim, uma negação inesperada deixaria cartão, pares e pedidos órfãos depois da exclusão. Sugestão: ao receber `denied` no **batch** (e não na leitura do próprio ponteiro), interromper a exclusão com falha em vez de seguir. O smoke da §7 (passo 12) verifica o caso feliz em produção.
- Um índice faltando em produção (`failed-precondition`) aparece como "Não foi possível concluir. Tente novamente." Nada se perde, mas o diagnóstico fica difícil. O passo 3 do rollout (esperar os índices em "Enabled") é obrigatório.

---

## 6. Rollout (docs/50 §14): testabilidade

| Passo | Testável? | Verificação |
|---|---|---|
| 1. Manager exporta a própria conta e anota os números do Perfil | Sim, manual | Guardar o JSON (schema 1, app atual). Anotar filmes, séries, episódios, assistidos e recomendados do Perfil. É a linha de base do smoke (passo S13). |
| 2. Publicar `firestore.rules` | Sim | Só acrescenta regras (conferido). `r/social_compat.test.mjs` prova que o app atual segue igual com as regras novas. No console, a aba Regras deve mostrar a versão com `match /handles/{h}` e `match /invites/{code}`. Fazer smoke do app ATUAL logo após: abrir favoritos e marcar um episódio. |
| 3. Publicar os índices e esperar "Enabled" | Sim, manual | Console > Firestore > Índices: 2 índices compostos de `friend_requests` (`to` ASC + `createdAt` DESC; `from` ASC + `createdAt` DESC), **ambos "Enabled"** (não "Building"). O emulador não verifica isso. |
| 4. Só então merge na `main` | **Atenção:** o workflow `deploy-pages.yml` publica o app **a cada push na `main`** | Merge = deploy do app. Não fazer merge, nem push na `main`, antes dos passos 2 e 3 confirmados. Esperar o job "deploy" ficar verde no GitHub Actions. |
| Rollback | Sim | Só do app (reverter o merge). **Nunca** voltar as regras. |

Se o app for ao ar antes das regras, a seção mostra "Amizades ainda não estão disponíveis" e nada se perde (provado no emulador com as regras v1/v2).

---

## 7. Roteiro de smoke pós-publicação (Manager, 2 contas Google)

Contas: **A** (a sua, com favoritos) e **B** (uma segunda conta Google, sem dados importantes). Use 2 navegadores ou 1 janela anônima. Marque cada passo como ✅ ou ❌. Qualquer ❌ deve ser reportado antes de divulgar.

0. **Antes de tudo (com o app antigo):** exporte a conta A pelo Perfil > "Exportar meus dados (JSON)" e anote os números do Perfil.
1. **App novo, conta A, sem ativar nada:** Favoritos, Recomendo, progresso de uma série e apelido estão iguais aos anotados. O ícone Amigos **não** aparece.
2. **Ativar (A):** Perfil > Amizades > "Ativar amizades". Escolha um identificador (ex.: `teste_a`), mantenha "Aparecer na busca" ligado e confirme. Aparece o cartão ativo, e o ícone Amigos surge na barra superior (celular) ou no menu do topo (computador).
3. **Ativar (B)** com outro identificador (ex.: `teste_b`). Tente antes `teste_a`: deve mostrar "Esse identificador não está disponível".
4. **Buscar (B):** Amigos > Adicionar amigo > digite ` @TESTE_A ` (com espaços e maiúsculas) e Enter. Aparece o cartão de A com apelido e foto. Busque também `naoexiste123`: deve aparecer a mensagem de "não encontrado".
5. **Pedir (B → A):** "Enviar pedido" mostra "Pedido enviado". Em Amigos > Pedidos > Enviados aparece A. Tente enviar de novo: deve mostrar o aviso de "já enviou". *(Este passo exercita o índice `from`.)*
6. **Contador e aceitar (A):** recarregue a página. O ícone Amigos mostra "1". Em Pedidos > Recebidos aparece B *(índice `to`)*. Toque "Aceitar". B aparece em Amigos para A; em B (depois de "Atualizar"), A aparece em Amigos.
7. **Remover (A):** em Amigos, "Remover amizade" no cartão de B. O diálogo abre com o foco em "Cancelar"; confirme. B some da lista de A e, depois de "Atualizar", A some da lista de B. Ninguém recebe aviso.
8. **Pedido cruzado:** A envia pedido para B. Em seguida B busca `teste_a` e toca "Enviar pedido". Deve aparecer "Vocês agora são amigos", e não sobra pedido em nenhum lado.
9. **Bloquear e desbloquear (A bloqueia B):** no cartão de B em Amigos, "Bloquear" e confirme. B some de Amigos e aparece em Bloqueados. Em B, buscar `teste_a` mostra a mesma mensagem de "não encontrado", e B não recebe aviso. Em A, "Desbloquear" B: B sai de Bloqueados e **a amizade não volta**. B pode buscar A de novo.
10. **"Aparecer na busca" desligado (A):** desligue em Perfil > Amizades. Em B, a busca por `teste_a` mostra "não encontrado". Com o interruptor desligado, A ainda consegue buscar `teste_b` e enviar pedido; B cancela depois.
11. **Convite (A):** Perfil > Amizades > Convite por link > "Criar link de convite" > "Copiar link". Abra o link logado como B: aparece o cartão de A, mesmo oculto. "Enviar pedido" cria um pedido normal, que A aceita ou recusa. Depois, A toca "Revogar convite"; o mesmo link em B passa a mostrar "Este convite não está disponível."
12. **Exportar (A):** Perfil > Exportar. O JSON tem `schemaVersion: 2` e a seção `social` com o handle, amigos (uid e apelido), pedidos, bloqueios e o convite. **Compare com o JSON do passo 0:** mesma quantidade de favoritos e os mesmos campos em cada favorito.
13. **Dados antigos intactos (A):** os números do Perfil são iguais aos do passo 0. Abra 2 favoritos antigos (um filme assistido e uma série com progresso) e confira se estão iguais.
14. **Limpeza (B, conta de teste):** em B, "Excluir conta". Em A, depois de "Atualizar", B some de Amigos e de Pedidos. Busque `teste_b`: "não encontrado" (o identificador ficou livre).
15. **Console (Manager):** Firestore > Uso. Anote as leituras e escritas do dia e compare com a estimativa do docs/50 §9 durante a primeira semana.

---

## 8. Para o re-teste
Corrigir L1 a L4 com os testes indicados e me devolver o handoff. No re-teste vou:
- rodar `flutter analyze`, `flutter test` 2 vezes, `npm test` e `npm run test:mutations`;
- reaplicar as mutações D4 e D5, que devem morrer;
- aplicar a mutação de L2 nas regras;
- conferir o texto de L3.
