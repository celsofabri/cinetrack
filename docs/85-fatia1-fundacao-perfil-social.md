# 85 - Perfil social (Fase 2), Fatia 1: fundação de dados (nada visível a amigos)

> Autor: Dev (Backend + Frontend) · Data: 2026-10-10 · Branch: `feat/social-profile` (base 42fcd7a)
> Entradas: [docs/81](./81-especificacao-perfil-social.md), [docs/82](./82-design-perfil-social.md) §4.2, §5, §8, §9, §15 item 1, [docs/83](./83-testabilidade-perfil-social.md), [docs/84](./84-fatia0-regras-perfil-social.md) ("Registro para as próximas fatias"), [ADR-006](./adr/adr-006-snapshot-perfil-social.md).
> **`firestore.rules` não foi alterado** (sha256 `6135322e…e612`, o publicado). Nada foi publicado: sem push, sem deploy, sem `firebase deploy`.

## HANDOFF
De: Dev (Backend + Frontend) → Para: Code Reviewer e QA, depois Orquestrador
Demanda: Fase 2 (perfil social), Fatia 1: fundação de dados
Fluxo: feature | Etapa: Fatia 1
Prioridade: P1 (bloqueia as Fatias 2 a 4)

### O que foi feito
**Data de marcação (`epsAt`, docs/82 §4.2)**
- `FavoriteDoc.watchedAt` (`Map<String, DateTime>`, padrão vazio), `markedAt(k)` (data **só** se `k ∈ eps`: órfã nunca conta) e `orphanDates`. `FavoriteMapper.fromMap` lê `epsAt` tolerante (valor que não é data e chave malformada são ignorados); `toMap` **não** emite `epsAt` (o `add` segue bit a bit igual). `_fromFirestore` agora converte `Timestamp` aninhado.
- `EpisodeDates.plan` (puro, `lib/services/episode_dates.dart`): **um único instante por escrita**; desmarcar apaga a data; órfãs apagadas (≤ 500 por escrita); estado desconhecido (`current == null`) = sem data nova; nunca passa de 5000 (se passaria, a marcação vai **sem** data, nunca é recusada); `restore` para o Desfazer.
- `FavoritePayloads.setEpisodes` (puro) = o `update` exato: `eps.k`, `epsAt.k` (data ou delete), `lastWatchedAt`/`updatedAt` = `serverTimestamp` (só esses dois: nenhum `serverTimestamp` por episódio). `FirestoreFavoritesDataSource.setEpisodes` usa esse payload, com o instante de `ServerClock.now()` e o portão de regras.
- `FavoritesDataSource.setEpisodes(key, changes, {current, restoreDates})`: o repositório passa o documento que já leu (`toggleEpisodeWatched`, `setSeasonWatched`, `applySeriesBulk`, `undoSeriesBulk`; `setEpisodeWatched` agora faz um `get` do cache e, se indisponível, marca sem data).
- **Desfazer**: `SeriesBulkUndo.restoreDates` guarda as datas que a massa apagou; o Desfazer remarca com elas (sem data para quem não tinha). "Desmarcar série + Desfazer" não rejuvenesce o histórico; Desfazer de uma marcação em massa apaga as datas.
- `ServerClock` (`lib/data/server_clock.dart`): hora do aparelho + desvio. O `ActivityOverlay` já guardava o carimbo local do `lastWatchedAt`; agora, na **primeira** foto sem pendências **depois** de uma com pendências, amostra `servidor − local` (descarta confirmação que chegou > 60 s depois, medido por relógio monotônico, e desvio > 2 dias).
- **Sonda de regras** (`SharedRulesGate` + `sharedRulesGateProvider`): ao criar a sessão de uma conta, 1 `get` do próprio `shared_profiles/{uid}` no servidor; lido (existe ou não) = regras novas, gravado no Hive **por projeto** (`sharedRules:<projectId>`), e nunca mais lido no aparelho; `permission-denied` = regras antigas, `unavailable`/timeout/erro = sem resposta: portão fechado (marcações sem data) e nova tentativa na próxima sessão. O portão entra no `FirestoreFavoritesDataSource` como `datesEnabled`.

**Relógio único (B1)**: `EpisodeCache.hasAiredAt(DateTime now)` (o getter antigo delega), `ProgressCalculator.compute(..., now:)`, `ProfileStats.isCompleted(..., now:)` e `sharedProfileClockProvider` (também alimenta o `ServerClock`).

**Funções puras do perfil compartilhado** (`lib/shared_profile/`)
- `period_key.dart`: `periodKey(instante, tz)` no fuso do **dono**; `normalizeTz` (int, −840..840, **−0 → 0**); `deviceTzMinutes`.
- `shared_profile_models.dart`: `SharedStats`/`TotalStats`/`PeriodStats`, `ActivityItem` (com `tryParse`/`parseList` defensivos: tipo desconhecido ou malformado é ignorado), `RecItem`/`SharedRecs`, `SharedProfileContent`.
- `shared_profile_builder.dart`: `SharedProfileBuilder.build` (só as seções pedidas; Total = mesmas fórmulas do Perfil ao vivo; mês/ano pelo §5.2; `undated*`, `datedFrom`, `memberSince`; recomendados na ordem da aba, 50 + total). Saída sempre passa pelo `clamp` do validador.
- `activity_deriver.dart`: `ActivityDeriver.derive` (D1 + tabela B8, derivado dos dados; ≤ 10, mais novo primeiro; `at < actSince` fora; `at` futuro limitado a `now`).
- `shared_profile_validator.dart`: `violations` (oráculo) e `clamp` com a tabela §4.4 **inteira**, inclusive o que as regras não pagam: tetos, coerência mês ≤ ano ≤ total, margem de data de 24 h, itens de lista (id, mediaType, título ≤ 300 sem partir emoji, pôster `^/[A-Za-z0-9._-]+$` ≤ 200, count/season/episode), listas 10/50, `count ≥ items`.
- `shared_profile_payloads.dart`: `turnOn` (set/update em transação), `turnOff` (update ou delete da última seção), `recalc` (nunca `sharing`/`actSince`), `pulse`, `deleteOwn`; recusam conteúdo fora da tabela (`ArgumentError`); `toJson` do golden (datas aninhadas como `$ts:`).

**`SharedProfileDataSource`** (inerte nesta fatia): interface (`readOwn`, `probeRules`, `deleteOwn`, `readFriend`), `FirestoreSharedProfileDataSource` (mesmo `guard`/mapeamento de erros do social; leitura do servidor que vier do cache = `unavailable`; `deleteOwn` aguardado, `permission-denied` = regras antigas = sucesso, timeout = `uncertain`), `SignedOutSharedProfileDataSource`, fake `InMemorySharedProfileDataSource`/`FakeSharedProfileCloud` (log de operações compartilhável, contador de leituras, falhas injetáveis por operação, modo "regras antigas", entrega posterior de delete incerto, amizades para `readFriend`). Nenhuma escrita de conteúdo compartilhado existe no app.

**Exclusão e desativação (D11, docs/82 §8)**
- `AccountDeleter`: `reauth → ensureOnline → markDeleting → deleteOwn → wipeForAccountDeletion → deleteOwn → favoritos → perfil → usuário` (falha mapeada para `AccountDeletionFailure`; retomável).
- `SocialRepository.deactivate`: `deleteOwn → sweepAll → closeSocial → deleteOwn → sweepAll` (falha do 1º = amizades continuam ligadas; falha do 2º = `cleanup-pending`); `finishCleanup` = `deleteOwn` + varredura. `socialRepositoryProvider` e `AccountController` recebem o `sharedProfileDataSourceProvider`.

**Exportação (schema 3)**: `kExportSchemaVersion` 2 → 3; `"sharedProfile": null | {"id", "timestampFields", "data"}` (1 leitura do servidor, a mesma `readOwn`; regras antigas = `null`). `epsAt` sai nos favoritos brutos (datas ISO dentro de `data`).

**Privacidade**: `PrivacySummary` ganha a frase "Quando você marca um episódio, guardamos também a data dessa marcação, só para você, para as estatísticas por mês e por ano." (teste literal); `web/privacidade.html` com linha nova na tabela e data 10/10/2026.

**Golden + regras**: `test/shared_profile_payloads_golden_test.dart` gera `firestore_rules_test/fixtures/shared_profile_payloads.json` (24 cenários: ligar cada seção com `set`/`update`, dono UTC `tz = 0`, sem `social` negado, desligar com update e com delete, recálculo sem `social`, recálculo de 3 seções, aparelho atrasado negado, pulso, apagar existente/inexistente, `setEpisodes` com data / documento antigo / desmarcar / órfã / regras não confirmadas / massa com instante único / Desfazer com datas). `shared_profile_payloads.test.mjs` deixou de ser `todo`: replay real, e fixture ausente agora **falha**.

**Mutações**: Dart `G1–G23` em `tool/dart_mutations.py`; payload `SPF1–SPF9` em `mutations.mjs` (fixture do perfil compartilhado quebrada e reproduzida contra as regras reais); `shared_profile_payloads.test.mjs` entrou na lista `SP` (toda mutação de regra SP também roda o replay).

### Números
| Comando | Resultado |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` (2 rodadas) | **1635/1635** nas duas (antes: 1531; +104) |
| `flutter build web --base-href /cinetrack/` | ✓ Built build/web |
| `npm test` (emulador, JDK 24, portas padrão) | **518 pass, 0 fail, 0 todo** (antes 489 pass + 1 todo); o `todo` virou 24 testes de replay |
| `npm run test:mutations` | baseline 496 ok / 0 not ok; rodada completa: **143 de 144 mortas**, 1 sobrevivente (`SPF5`, mutação **equivalente** como escrita: regravar `sharing.stats: true` que já existia não entra em `affectedKeys`). `SPF5` reescrita para mudar de fato o consentimento (desligar Atividades no recálculo, sem `social`) e reexecutada (`ONLY=SPF5`): **KILLED**. Total: **144/144** (40 M + 12 F da Fase 1, 83 SP da Fatia 0, 9 SPF novas) |
| `python3 tool/dart_mutations.py` (cópia em /tmp) | **39/39 KILLED** (16 da Fase 1 + 23 novas `G1–G23`), "All Dart mutations were killed." |

Mutações Dart novas (docs/83 §4 "Dart" aplicáveis a esta fatia): teto removido (violations e clamp, favoritos; episódios), margem de data removida (violations e clamp), item fora do schema aceito, período em UTC, tipo desconhecido lança, "Recomendações" sem opt-in, atividades com interruptor desligado, atividades antes do consentimento, datas antes de confirmar as regras, órfãs nunca limpas, Desfazer rejuvenesce, passo da exclusão só depois das varreduras / sem o 2º apagar, desativação sem o 1º apagar / 2º apagar fora do "limpeza pendente", exportação omite, sonda nunca lembrada, `deleteOwn` com regras antigas falha a exclusão, conclusão ignora o relógio injetado, vários instantes numa escrita.
Não aplicáveis nesta fatia (o motor `SharedProfileSync`, os interruptores e o perfil de amigo são das Fatias 2/3): "snapshot no mesmo batch do favorito", "grava com `fromCache`", "desligar só esconde", "cache servido após `permission-denied`/offline", "coalescência desligada", "só grava se mudou removido", "incerta tratada como falha". Ficam para as fatias que criam esse código.

### Decisões tomadas (e por quem)
- Dev (sujeitas a review):
  1. `SharedProfileDataSource` lança `SocialFailure` (como o `SocialDataSource`), reaproveitando `FirestoreSocialDataSource.guard`/`convert` (deixaram de ser `@visibleForTesting`). O `SharedProfileRepository` com `SharedProfileFailure` (docs/82 §9) fica para a Fatia 2, quando houver tela que precise dele.
  2. A interface desta fatia **não** tem `toggle`/`writeSections`: nada escreve conteúdo compartilhado ainda. Os payloads existem (puros, golden e replay nas regras) para a Fatia 2 só executá-los.
  3. `SocialRepository` recebe o `SharedProfileDataSource` como parâmetro opcional (padrão inerte, para os testes da Fase 1 que não tratam do assunto); `AccountDeleter` o exige. Teste de fiação (`the app wires the REAL shared source…`) garante que os providers passam o real.
  4. Exportação: além de `id` e `data`, `sharedProfile` leva `timestampFields` (mesmo padrão de `profile`/favoritos; aditivo).
  5. `ServerClock` aprende só com escritas do próprio aparelho confirmadas em ≤ 60 s (monotônico) e desvio ≤ 2 dias; sem amostra = relógio do aparelho (como o design).
  6. Datas: `epsAt.k` só é apagado ao desmarcar quando o documento lido tinha data para `k` (payload mínimo; uma data criada em paralelo por outro aparelho vira órfã e é limpa depois).
  7. Ao gravar uma data numa chave que era órfã, a chave recebe a data nova (não é apagada).

### Desvios do docs/82 (com justificativa)
- §4.2 "Para quem tem amizades ativas, a leitura de sessão do próprio documento já serve de sonda": nesta fatia não existe a leitura de sessão (é da Fatia 2), então a sonda é sempre o `get` dedicado, **1 vez por aparelho** depois do sucesso (D17 respeitado). A Fatia 2 pode reaproveitar a leitura de sessão.
- §9 `SharedProfileRepository`/`SharedProfileFailure`: adiado (decisão 1).
- §8 exportação: `timestampFields` a mais (decisão 4).
- Nenhum desvio de regra: `firestore.rules` intacto.

### Suposições (não verificadas)
- Um `update` com até 5000 caminhos `eps.*` + 5000 `epsAt.*` (marcação de série inteira grande) cabe nos limites do Firestore (10 MiB por requisição; só 2 transformações por escrita). O emulador aceitou 24 + 24; não medi 5000 + 5000 em produção.
- Comportamento real do SDK web (`Source.server` com `isFromCache`, `-0` como double): seguem a documentação; `normalizeTz` cobre o `-0`.
- Emulador = produção nas regras (risco 10 do docs/82).

### Riscos / atenção
- **Rollout**: as regras da Fase 2 já estão publicadas; o app desta fatia só envia `epsAt` depois da sonda. App antigo em outra aba continua funcionando (marca sem data; desmarca deixando órfã, que a versão nova limpa).
- A data é privada mas é **dado novo para todos** (D5): política e `PrivacySummary` atualizados nesta fatia; publicar a política junto do app (docs/82 §12 passo 4).
- Rollback do app: o app antigo ignora `epsAt` (mapper antigo ignora campos desconhecidos) e `shared_profiles` (não existe ainda).
- Folga de expressões das regras inalterada (nenhuma cláusula nova).

### Perguntas abertas
1. Fatia 2: reaproveitar a leitura de sessão do próprio documento como sonda (economiza a leitura única só para quem nunca rodou esta versão) ou manter a sonda dedicada? Recomendo reaproveitar.
2. A linha nova da política diz "marcações feitas antes desta versão ficam sem data". O Manager quer citar também que filmes usam a data da última marcação (`lastWatchedAt`, que já existia)?

### Artefatos
- Código: `lib/shared_profile/*`, `lib/data/{server_clock,shared_rules_gate,shared_profile_data_source,firestore_shared_profile_data_source,favorite_payloads}.dart`, `lib/services/episode_dates.dart`, `lib/providers/shared_profile_providers.dart` e os arquivos alterados listados no commit.
- Testes: `test/{period_key,server_clock,episode_dates,activity_deriver,shared_profile_builder,shared_profile_validator,shared_profile_data,shared_profile_payloads_golden}_test.dart`, `test/support/fake_shared_profile_cloud.dart`.
- Regras (testes): `firestore_rules_test/fixtures/shared_profile_payloads.json`, `shared_profile_payloads.test.mjs`, `mutations.mjs`.

### Critério de aceite deste handoff
- Code Review e QA aprovados; `flutter analyze` limpo, `flutter test`, `npm test` e as duas suítes de mutação verdes no ambiente do revisor. Depois, merge (sem publicar nada além do app e da política).

## Rodada 2 (gates de bc4c85e: Code Review APROVADO com 5 🟢; QA REPROVADO com 5 🟡 de lacunas de teste)
Todos os achados fechados nesta rodada, sem ressalvas. `firestore.rules` continua intacto (sha256 `6135322e…e612`); fixture do golden inalterada.

| Achado | Correção |
|---|---|
| QA F1 fiação do portão sem teste (E1, E2 sobreviviam) | `favoritesDatesEnabledProvider` (e `favoritesDatesRefusedProvider`) extraídos; a fábrica real usa os dois. Testes com a **fábrica real** (o `FirestoreFavoritesDataSource` e o `FirestoreExportDataSource` passaram a buscar o `FirebaseFirestore` de forma preguiçosa, então constroem sem Firebase): regras antigas = sem datas, regras novas = datas depois da sonda; o provider do portão sonda sozinho (ninguém chama `start`) |
| QA F2 `setEpisodeWatched` (favoritar e marcar) sem teste de data (E11) | teste: a marcação leva a data do relógio |
| QA F3 guarda da amostra do relógio (E3) | teste: foto assentada nunca vista pendente não é amostra (offset 0) |
| QA F4 teste local × instante vazio (E10) | teste das 48 h em volta de 31/10 + teste independente do fuso da máquina (`DateTime` não UTC montado a partir do instante, inclusive pelo builder) |
| QA F5 §5.3.3 favoritar + episódio em ≤ 10 min (E7) | teste: só "assistiu episódios" |
| QA 🟢 G1 limite superior dos 10 min | 10 min = mesmo gesto; 11 min = dois itens |
| QA 🟢 G2 fronteira exata de 5000 | 4999 datas + 1 nova = a nova recebe data |
| QA 🟢 G3 segunda amostra substitui a primeira | teste (E12) |
| QA 🟢 G4 exportação | `FirestoreExportDataSource.readSharedProfile`: negado = `null`, offline = `unreachable`, documento = bruto; exportação abandonada durante a leitura do compartilhado não entrega nada (E5, E8) |
| QA 🟢 G6 fábrica usa o `ServerClock` da sessão | teste de identidade (E9) |
| CR 🟢1 autocorreção do portão | `FavoritePayloads.sendWithDatesFallback`: se o servidor recusar (`permission-denied`) uma marcação **que levava datas**, o portão fecha (`SharedRulesGate.invalidate`: fecha na sessão e apaga a marca do Hive, a próxima sessão sonda de novo) e a **mesma** marcação é reenviada **sem** datas. Outros erros seguem para o banner como antes. O fake de favoritos usa o mesmo helper (modo `rejectDates`); testes do helper, do fake e da fiação; mutações E13–E15 |
| CR 🟢3 tz −0 | `SharedProfilePayloads` aplica `normalizeTz` em todo `tz`; o validador recusa `tz` que não é o próprio `normalizeTz` (inclui −0 e fora de −840..840); teste e mutação E16 |
| CR 🟢4 `timestampFields` | documentado abaixo |
| Política | as duas linhas sobre datas viraram uma só em `web/privacidade.html`; `PrivacySummary` sem mudança (teste literal segue igual) |

**`timestampFields` da exportação**: lista só os campos de **primeiro nível** que eram timestamp (`updatedAt`, `actSince`). Datas aninhadas (`stats.datedFrom`, `stats.memberSince`, `activity[].at`, `epsAt.*` nos favoritos) saem como texto ISO 8601 UTC dentro de `data`, sem marcação; quem restaurar precisa conhecer o schema (mesma convenção dos favoritos desde o schema 1).

**Risco da autocorreção** (só existe se as regras regredirem, o que o processo proíbe; revisto na rodada 3):
- O reenvio sem datas sai quando a recusa chega. Offline, várias escritas ficam na fila e as recusas podem chegar **depois** de um desmarcar posterior já aceito: o reenvio marca de novo o episódio. Pode acontecer com mais de um episódio de uma vez.
- A persistência offline está ligada (`lib/services/firebase_bootstrap.dart`). Uma marcação com data ainda na fila quando a página fecha é reenviada pelo SDK na sessão seguinte **sem** o callback de autocorreção; se as regras tiverem regredido, ela é recusada e **a marcação se perde**.
- O fallback também dispara com `permission-denied` que não tem nada a ver com a data (corrida de sessão encerrada, `eps` acima de 5000). Custo: a sessão segue sem datas e a próxima sessão faz 1 leitura de sonda; a marcação é reenviada sem datas (e, se o motivo era outro, é recusada de novo e vai para o banner, como antes).
Conclusão: aceitável porque depende de regressão de regras; a proteção real é a ordem do rollout (regras antes do app, nunca voltar).

**Decisões do Orquestrador nas perguntas abertas**
1. Fatia 2: **sim**, reaproveitar a leitura de sessão do próprio documento como sonda quando vier do servidor (`isFromCache == false`): existe/não existe = `ready`, `permission-denied` = `oldRules`, alimentando a **mesma** instância de `SharedRulesGate`. A sonda dedicada continua para quem não tem amizades ativas.
2. Não é preciso citar `lastWatchedAt` à parte na política.

**Checklist de release (Fase 2)**
- Isenção de índice `favorites.epsAt`: **já publicada** (2026-10-10).
- Smoke em produção: marcar em massa uma série longa (**≥ 1000 episódios**) e conferir que a marcação e as datas gravam (limites de requisição não verificados no emulador).

### Números da rodada 2
| Comando | Resultado |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` (2 rodadas) | **1654/1654** nas duas (+19) |
| `npm test` | **518 pass, 0 fail, 0 todo** (regras e testes de regra inalterados; `test:mutations` não foi rodado de novo por isso) |
| `python3 tool/dart_mutations.py` (lista completa, cópia em /tmp) | lista completa: 55 de 56 mortas; a sobrevivente `E14` (`invalidate` sem `_refused`) passava porque o fake limpa a marca do Hive na hora. Teste novo ("invalidate closes the gate at once, even if forgetting the device flag fails") e reexecução de `E13 E14 E15`: todas **KILLED**. Total: **56/56** (16 da Fase 1 + 23 `G` + 17 `E`) |


## Rodada 3 (gates de aa7729c: Code Review APROVADO com 2 🟢 de documentação; QA REPROVADO com 1 🟡)
| Achado | Correção |
|---|---|
| QA 🟡 F6 autocorreção sem teste no `FirestoreFavoritesDataSource` real (X1, X2, X5, X8 sobreviviam) | seam `@visibleForTesting updater(path, data)` usado por `setEpisodes`. Testes: (1) datas recusadas com `permission-denied` = exatamente 2 escritas, a 2ª sem `epsAt.*` e com `eps.1_1 == true`, `onDatesRefused` 1 vez, nada no banner; (2) `unavailable` = 1 escrita, sem recusa, erro no sink; (3) escrita **sem** datas recusada = 1 escrita, sem reenvio, erro no sink. Mutações X1–X8 do QA em `tool/dart_mutations.py` |
| QA 🟢 G7 teste "independente do fuso" não era (CI em UTC) | `TZ: America/Sao_Paulo` no passo `flutter test` de `.github/workflows/deploy-pages.yml` (único workflow com testes); comentário do teste corrigido (as asserções valem em qualquer fuso; só detectam a E10 fora de UTC). Conferido também com `TZ=UTC` (passa) |
| QA 🟢 G8 e CR 🟢 (1)(2) risco da autocorreção subestimado | texto revisto acima ("Risco da autocorreção") |

### Números da rodada 3
| Comando | Resultado |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` (2 rodadas) | **1657/1657** nas duas (+3) |
| `npm test` | não rodado de novo (regras, testes de regra e fixture inalterados; rodada 2: 518/0/0) |
| `python3 tool/dart_mutations.py` (lista completa, cópia em /tmp) | **64/64 KILLED** (16 da Fase 1 + 23 `G` + 17 `E` + 8 `X`), "All Dart mutations were killed." |
