# 84 - Perfil social (Fase 2), Fatia 0: regras do Firestore e testes

> Autor: Dev Backend · Data: 2026-10-10 · Branch: `feat/social-profile` (base `origin/main` 9c57327, Fase 1 em produção)
> Entradas: [docs/81](./81-especificacao-perfil-social.md), [docs/82](./82-design-perfil-social.md) §4/§13/§15 item 0, [docs/83](./83-testabilidade-perfil-social.md), [ADR-006](./adr/adr-006-snapshot-perfil-social.md) (Aceita). Decisões D1–D17 aprovadas pelo Manager (2026-10-10).
> Escopo: **só** `firestore.rules`, `firestore.indexes.json`, `firestore_rules_test/` e docs. Nenhuma linha de Dart. **Nada foi publicado** (sem `firebase deploy`, sem push).
> **Rodada 2** (Code Review e QA de 6a96a3b, ambos REPROVADO com 🟡): ver "Rodada 2" no fim; os números abaixo já são os da rodada 2.

## HANDOFF
De: Dev Backend → Para: Code Reviewer e QA (re-review), depois Orquestrador para publicar as regras
Demanda: Fase 2 (perfil social), Fatia 0: regras + índices + testes
Fluxo: feature | Etapa: Fatia 0 (gate: Orquestrador publica as regras pela CLI)
Prioridade: P1 (bloqueia as Fatias 1 a 4)

### O que foi feito
- `firestore.rules`: **359 → 468 linhas (+110/−1 contra produção)**. sha256 `6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612`.
  - A única linha "removida" do texto de produção é a do `hasOnly` de `validFavorite`, reescrita com `'epsAt'` a mais na lista (aditivo). Todo o resto que existia está byte a byte igual; o bloco novo entra antes do `match /{document=**}` final.
  - `validFavorite`: `'epsAt'` no `hasOnly` + `&& (!('epsAt' in d) || (d.epsAt is map && d.epsAt.size() <= 5000))` (docs/82 §4.2). `users/{uid}/favorites` continua só do dono.
  - `shared_profiles/{uid}`: funções `rankOk`, `validStats`, `validActivities`, `validRecs`, `validShared`, `sharedSectionsOk`, `sharedUpdateOk` e o `match` com get/list/create/update/delete, semanticamente o docs/82 §4.3 com 2 desvios que **só restringem** e otimizações **equivalentes** para o limite de expressões (ver "Desvios").
- `firestore.indexes.json`: **nenhum índice composto**. Só uma **isenção de índice de campo único** para `favorites.epsAt` (`fieldOverrides`, `indexes: []`). Justificativa abaixo.
- Testes de regras (`firestore_rules_test/`):
  - `fixtures/firestore.rules.v3` = regras de produção (`origin/main` 9c57327), sha256 `7cf76481ff498171f11ad40a950065323dec34877afa710146d7fbd20132f0f3` (o mesmo do checklist docs/80).
  - `shared_profile.test.mjs` (novo, 94 testes): matriz de leitura, só o dono escreve, criação, schema linha a linha da tabela §4.4 (linhas R) incluindo tipos errados (prova das otimizações), hora do servidor (passado **e futuro** negados), seções, atualização/consentimento/aparelho atrasado (com leitura do amigo depois de desligar), apagar (inclusive sem `social` e sem Google), resíduo A8, revogação imediata.
  - `favorites_epsat.test.mjs` (novo, 8 testes): as 6 formas de escrita atuais do `FirestoreFavoritesDataSource` com e sem `epsAt` no documento; `epsAt` ausente/vazio/5000 aceitos; 5001 e não-mapa negados; favoritos continuam fechados.
  - `shared_profile_helpers.mjs` (novo): construtores de payload (oráculo até existir o serializador Dart).
  - `shared_profile_payloads.test.mjs` (novo): **harness** de replay do golden Dart com **TODO** (gate da Fatia 1).
  - `social_compat.test.mjs`: + fixture v3; app novo × regras v1/v2/v3: sonda, interruptores e `epsAt` negados **sem efeito colateral** (inclusive `lastWatchedAt`/`updatedAt` intactos); regras novas × dados/payloads do app de produção.
  - `rules_budget.test.mjs`: custo de chamadas das expressões **reais** de `shared_profiles` (extraídas do texto) e **folga de expressões travada** pelo NFR revisto.
  - `mutations.mjs`: + 83 mutações `SP*` (uma por cláusula nova + as sugeridas por Code Review/QA), baseline com as suítes novas, checagem "aplica exatamente uma vez".
- README (seção de testes de regras) atualizado; docs/82 §4.5 e ADR-006 (decisão 9 e "Evidência") com o NFR e as medidas revistos.

### Números (emulador local, JDK 24, portas padrão)
| Comando | Resultado |
|---|---|
| `npm test` (antes, base 9c57327) | **376/376** |
| `npm test` (depois) | **489 pass, 0 fail, 1 todo** (490 testes, 57 suítes) — os 376 antigos passam sem alteração |
| `npm run test:mutations` | baseline 471 ok / 0 not ok; **All 135 mutations were killed** (40 M + 12 F da Fase 1, 83 SP novas), 0 sobreviventes, 0 erros, exit 0. (Rodada 1: 127 executadas, 126 mortas; a sobrevivente SP46 era equivalente e saiu da lista) |
| `flutter analyze` | No issues found |
| `flutter test` | All tests passed (1531) |

Novos testes: +113 (94 `shared_profile`, 8 `favorites_epsat`, +9 `rules_budget`, +2 `social_compat`; os testes v1/v2 de compatibilidade ganharam asserções de Fase 2) e 1 `todo` (golden Dart).

### Evidência de compatibilidade
- **Payloads antigos × regras novas**: as suítes existentes (376 testes) passam **sem alteração**. `favorites_epsat.test.mjs` repete as 6 formas de escrita do app de produção (`add` com `set`, `setEpisodes` marcar/desmarcar, `setWatchedMovie`, `setSeasonSummaries`, `setRecommended` liga/desliga, `remove`), inclusive sobre documentos que já têm `epsAt` (o app antigo deixa data órfã e o `set` do `add` descarta `epsAt`: ambos aceitos). `social_compat` "NEW rules x data written by the production app (v3)": dados da Fase 1 + favoritos sem `epsAt` seguem funcionando; nenhum documento compartilhado aparece sozinho; amigo continua sem ler favoritos.
- **Payloads novos × regras v3 (produção) e v1/v2**: `get` do próprio `shared_profiles` (sonda) = `permission-denied`; criar perfil negado e nada gravado; `update` de favorito com `eps.1_1 + epsAt.1_1` negado **atomicamente** (episódio não marcado, `epsAt` ausente, `lastWatchedAt`/`updatedAt` iguais) e `set` com `epsAt` negado sem criar documento; a mesma marcação **sem** `epsAt` passa. É o motivo da sonda de regras (docs/82 §4.2, D17).
- **Nunca abrir favoritos**: testes em `shared_profile`, `favorites_epsat` e `social_compat` (amigo, estranho, anônimo, bloqueado) + mutações M10, SP75, SP84.

### Orçamento (emulador; produção pode divergir)
| Operação | Chamadas de regra (medido) |
|---|---|
| Amigo lê perfil | **exatamente 1** (passa com +9 `exists`, negado com +10) |
| Dono lê / apaga | 0 |
| Criar (1º interruptor) | exatamente 1 |
| Mudar consentimento (`sharing`/`actSince`) | exatamente 1 |
| Recálculo (só seções) | 0 |

Expressões. Método (corrigido na rodada 2): **todas as seções mudam** (o probe da rodada 1 mandava estatísticas iguais às gravadas, então `validStats` não era avaliada); unidade = 1 comparação extra, agrupada 10 por função, sobre a expressão real; uma requisição vazia comporta ≈ 123.
| Escrita (todas as seções mudando) | Rodada 1 (texto docs/82) | Rodada 2 (otimizado) |
|---|---|---|
| Criar 3 seções, 10 atividades, 50 recomendados (pior documento legal; o app nunca faz) | ≈ 70% | **≈ 65%** (43 livres) |
| `set` do dono sobre documento existente, 3 seções | ≈ 66% (revisor) | ≈ 62% (47) |
| Mudar consentimento + 3 seções (pior escrita **do app**) | ≈ 69% | **≈ 64%** (44) |
| Recálculo das 3 seções | ≈ 67% | ≈ 62% (47) |
**NFR revisto** (decisão do Orquestrador, em nome do Arquiteto; registrado no docs/82 §4.5 e no ADR-006): pior escrita do app ≤ 65%, pior documento legal ≤ 70%, folga travada por teste. `rules_budget.test.mjs` exige: requisição vazia comporta ≥ 120 comparações e 140 estouram; pior escrita do app e recálculo + 44 (35%) passam; pior documento legal e `set` sobre existente + 37 (30%) passam. Conferido: as regras da rodada 1 **falham** esse teste (2 testes vermelhos), as da rodada 2 passam. (As medidas foram feitas antes de tirar o `r.size() == 2` de `validRecs`, que só reduz custo.)

### Desvios do docs/82 §4.3
Restritivos (nada que funcionava passa a ser negado):
1. **Leitura de amigo exige conta Google**: `isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid))`. A matriz do QA pede "não Google negado"; custo 0 chamadas. O dono lê o próprio documento com qualquer provedor (sonda, exclusão, exportação; mutação SP80). Mutações SP1/SP2.
2. **Atividades revalidadas também quando `actSince` muda** (`sharedSectionsOk`). Sem isso, trocar `actSince` sem mexer na lista manteria itens anteriores ao novo consentimento. Mutação SP61.

Equivalentes (otimização para o limite de expressões, pedidas pelo Code Review; cada uma provada por teste com tipos errados):
3. `validStats`: sem `s.total/month/year is map` e sem `is string` antes de `.matches` (recorte que não é mapa ou chave que não é texto = erro de avaliação em `keys()`/`matches()` = negado); `let pk` para a lista de chaves de mês/ano. Testes "wrong types for a slice…", "wrong types for year.key / month.key…", "stats that is not a map…".
4. `validActivities`: `let n = l.size()`. **`l is list` foi mantido**: não é equivalente (`{}` e `''` têm `size() == 0`; QA F2). Mutação SP78.
5. `validRecs`: sem `r.keys().hasAll(['count','items'])` (redundante: `count` e `items` são lidos adiante; ausência = erro = negado). O Code Review sugeriu trocá-lo por `r.size() == 2`, mas com `hasOnly` essa checagem também é redundante (e viraria mutante equivalente); fica só `hasOnly`. Teste "closed shape…"; mutação SP62.
6. `update`: `affectedKeys()` calculado uma vez, em `sharedUpdateOk(uid, ch)`.

### Mutações equivalentes (não podem morrer)
- **SP46** (formato de `year.key` removido) sobreviveu na rodada 1 e é equivalente: `month.key` precisa casar `^20YY-MM` e ter o mesmo prefixo de `year.key`, o que já obriga `year.key = '20YY'`. A regex fica no texto (defesa em profundidade) e a mutação saiu da lista, com comentário no `mutations.mjs`.
- Não incluídas por serem equivalentes: `d.keys().hasAll([...])` de `validShared` (as 5 chaves são lidas adiante) e `s is map` de `validStats`/`s is map` de `validShared` (o acesso seguinte falha). Por D12/D16 e a correção do docs/83 §4, "teto removido" e "margem de data removida" são mutações do validador Dart (Fatia 1).

### Índices: por que mexi em `firestore.indexes.json`
Não há índice composto novo (nenhuma consulta nova, só `get` por id). Acrescentei a **isenção** `favorites.epsAt` (docs/82 §4.7, recomendada e listada na Fatia 0): sem ela o Firestore indexaria cada subcampo de `epsAt` (até 5000 por documento, ≈ 20 000 entradas com `eps` numa série longa: abaixo do limite de 40 000, mas custo de armazenamento e escrita sem uso). Não muda dado nem regra; é inofensiva se publicada antes ou depois das regras. Publicação **opcional** (`firebase deploy --only firestore:indexes`). **Ao publicar: nunca usar `--force` e responder "não" a qualquer pergunta de apagar índices** (os 2 índices da Fase 1 estão no arquivo, mas a CLI pergunta sobre qualquer índice que só exista no console).

### Registro para as próximas fatias (sem código agora)
- **F3 (ranking)**: `rankOk` aceita `double` (e não rejeita valores não inteiros); o leitor da F3 deve descartar métricas não inteiras/não finitas.
- **Fatia 1 (golden)**: incluir um dono em UTC (`tz = 0`) e o Dart normalizar `-0` para `0`.
- **Fatia 1 (exclusão)**: `AccountDeleter` tem de apagar `shared_profiles/{uid}` (docs/82 §8). A exclusão feita pelo **app antigo** não conhece o documento e o deixa órfão (não exposto: ninguém mais é amigo; a leitura exige `isFriend`): registrar no checklist de rollout da Fase 2.
- **Fatia 1**: gerar `fixtures/shared_profile_payloads.json` é gate (o `todo` precisa virar teste verde) e acrescentar mutações de payload (como F1–F12).

### O que você precisa fazer
- **Code Reviewer / QA**: re-review da rodada 2 (otimizações, novos testes, NFR travado, mutações).
- **Fatia 1 (Dev)**: ver "Registro para as próximas fatias".
- **Orquestrador**: publicar as regras pela CLI só depois de Code Review e QA aprovados (docs/82 §12: regras antes do app, nunca voltar). Conferir `shasum -a 256 firestore.rules` = `6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612`.

### Artefatos
- `firestore.rules`, `firestore.indexes.json`, `README.md`, docs/82 §4.5, ADR-006
- `firestore_rules_test/{shared_profile,favorites_epsat,shared_profile_payloads}.test.mjs`, `shared_profile_helpers.mjs`, `fixtures/firestore.rules.v3`, `social_compat.test.mjs`, `rules_budget.test.mjs`, `mutations.mjs`

### Decisões tomadas (e por quem)
- D1–D17 e ADR-006: Manager (2026-10-10).
- NFR de expressões revisto (app ≤ 65%, documento legal ≤ 70%, folga travada): Orquestrador, em nome do Arquiteto (2026-10-10).
- Desvios 1–2, otimizações 3–6 (5 com a variante "só `hasOnly`") e a isenção de índice: Dev Backend, sujeitos ao re-review.

### Suposições (não verificadas)
- Emulador = produção quanto a limite de chamadas, de expressões e semântica de `affectedKeys`/`request.time` (risco 10 do docs/82).
- `sign_in_provider == 'google.com'` para quem entra com Google (já em produção na Fase 1).

### Riscos / atenção
- A folga é pequena por construção (pior escrita do app ≈ 64% contra teto de 65%): qualquer cláusula nova em `shared_profiles` provavelmente quebra `rules_budget` e exige otimizar ou rever o NFR.
- Regras **nunca voltam** depois de publicadas (o app novo enviaria `epsAt` e as regras antigas negariam a marcação inteira).
- Um `.env` fictício (`TMDB_API_KEY=test`, como no CI) existe no worktree para `flutter analyze/test`; é ignorado pelo git e não contém chave real.

### Perguntas abertas
1. Publicar a isenção de índice `epsAt` junto das regras (recomendado) ou adiar?

### Critério de aceite deste handoff
- Code Review e QA aprovados; `npm test` e `npm run test:mutations` verdes no ambiente do revisor; então o Orquestrador publica as regras (e, se aprovado, a isenção de índice) antes de qualquer app da Fase 2.

## Rodada 2 (achados de 6a96a3b e como foram fechados)
| Achado | Correção |
|---|---|
| CR 🟡1 probe de folga não mudava `stats` | probes mudam todas as seções; casos novos "recálculo das 3 mudando" e "`set` sobre existente"; constantes e comentários recalibrados; números corrigidos aqui, no docs/82 §4.5 e no ADR-006 |
| CR 🟡2 NFR ≤ 65% violado | otimizações equivalentes 3–6; NFR revisto e travado no `rules_budget` |
| CR 🟢 apagar sem `social`/não Google; A8 | testes "interrupted deactivation fallback…" e "A8 residue…" |
| CR 🟢 registros para depois | seção "Registro para as próximas fatias" |
| QA F1 hora futura | testes `updatedAt`/`actSince` no futuro; SP76, SP77 |
| QA F2 `l is list` não equivalente | mantido; teste `{}`/`''`; SP78; lista de equivalentes corrigida; tipos errados testados para cada checagem removida |
| QA F3 | SP79 (`epsAt` obrigatório), SP80 (dono precisa de Google), SP81 (dono não apaga); também SP82–SP84 (limite de `rankOk` afrouxado, `at > since`, favoritos lidos por qualquer Google) |
| QA F4 | leitura do amigo depois de desligar; `lastWatchedAt`/`updatedAt` intactos; `sharing: {}` negado mesmo com `social` |
| QA F5 | teste nomeado "A8 residue…" com `exists() === false` |
| QA F6 | README; registro do `AccountDeleter` e do órfão do app antigo |
