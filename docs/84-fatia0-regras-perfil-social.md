# 84 - Perfil social (Fase 2), Fatia 0: regras do Firestore e testes

> Autor: Dev Backend · Data: 2026-10-10 · Branch: `feat/social-profile` (base `origin/main` 9c57327, Fase 1 em produção)
> Entradas: [docs/81](./81-especificacao-perfil-social.md), [docs/82](./82-design-perfil-social.md) §4/§13/§15 item 0, [docs/83](./83-testabilidade-perfil-social.md), [ADR-006](./adr/adr-006-snapshot-perfil-social.md) (Aceita). Decisões D1–D17 aprovadas pelo Manager (2026-10-10).
> Escopo: **só** `firestore.rules`, `firestore.indexes.json` e `firestore_rules_test/`. Nenhuma linha de Dart. **Nada foi publicado** (sem `firebase deploy`, sem push).

## HANDOFF
De: Dev Backend → Para: Code Reviewer (depois QA, depois Orquestrador para publicar as regras)
Demanda: Fase 2 (perfil social), Fatia 0: regras + índices + testes
Fluxo: feature | Etapa: Fatia 0 (gate: Orquestrador publica as regras pela CLI)
Prioridade: P1 (bloqueia as Fatias 1 a 4)

### O que foi feito
- `firestore.rules`: **359 → 461 linhas (+103, −1)**. sha256 `4a2c148ffa486a9bdf6a27b1117ff4906e0a1287eed6b942368df8ed0c0a8f5f`.
  - A única linha "removida" é a do `hasOnly` de `validFavorite`, reescrita com `'epsAt'` a mais na lista (aditivo). Todo o resto que existia está byte a byte igual; o bloco novo entra antes do `match /{document=**}` final.
  - `validFavorite`: `'epsAt'` no `hasOnly` + `&& (!('epsAt' in d) || (d.epsAt is map && d.epsAt.size() <= 5000))` (docs/82 §4.2). `users/{uid}/favorites` continua só do dono.
  - `shared_profiles/{uid}`: funções `rankOk`, `validStats`, `validActivities`, `validRecs`, `validShared`, `sharedSectionsOk` e o `match` com get/list/create/update/delete, como no docs/82 §4.3, com 2 desvios que **só restringem** (ver "Desvios").
- `firestore.indexes.json`: **nenhum índice composto**. Só uma **isenção de índice de campo único** para `favorites.epsAt` (`fieldOverrides`, `indexes: []`), recomendada no docs/82 §4.7 e listada na Fatia 0 (§15 item 0). Justificativa abaixo.
- Testes de regras (`firestore_rules_test/`):
  - `fixtures/firestore.rules.v3` = regras de produção (`origin/main` 9c57327), sha256 `7cf76481ff498171f11ad40a950065323dec34877afa710146d7fbd20132f0f3` (o mesmo do checklist docs/80).
  - `shared_profile.test.mjs` (novo, 85 testes): matriz de leitura, só o dono escreve, criação, schema linha a linha da tabela §4.4 (linhas R), seções, atualização/consentimento/aparelho atrasado, apagar, revogação imediata.
  - `favorites_epsat.test.mjs` (novo, 8 testes): payloads atuais do app (todas as 6 formas de escrita do `FirestoreFavoritesDataSource`) com e sem `epsAt` no documento; `epsAt` ausente/vazio/5000 aceitos; 5001 e não-mapa negados; favoritos continuam fechados.
  - `shared_profile_helpers.mjs` (novo): construtores de payload (oráculo até existir o serializador Dart).
  - `shared_profile_payloads.test.mjs` (novo): **harness** de replay do golden Dart com **TODO** (ver "O que você precisa fazer").
  - `social_compat.test.mjs`: + fixture v3; app novo × regras v1/v2/v3: sonda, interruptores e `epsAt` negados **sem efeito colateral**; regras novas × dados/payloads do app de produção.
  - `rules_budget.test.mjs`: + custo de chamadas das expressões **reais** de `shared_profiles` (extraídas do texto das regras) e teste de **folga de expressões**.
  - `mutations.mjs`: + 74 mutações `SP1`–`SP75` (sem a SP46, equivalente; uma por cláusula nova), baseline ampliado com as suítes novas, checagem "aplica exatamente uma vez" nas mutações novas.

### Números (emulador local, JDK 24, portas padrão)
| Comando | Resultado |
|---|---|
| `npm test` (antes, base 9c57327) | **376/376** |
| `npm test` (depois) | **478 pass, 0 fail, 1 todo** (479 testes, 57 suítes) — os 376 antigos inalterados e passando |
| `npm run test:mutations` | baseline 460 ok / 0 not ok; **127 mutações executadas: 126 mortas** (40 M + 12 F antigas, 74 SP novas), **1 sobrevivente equivalente** (SP46, removida da lista; ver abaixo), 0 erros. Lista atual: 126 mutações, todas mortas nessa execução |
| `flutter analyze` | No issues found |
| `flutter test` | All tests passed (1531) |

Novos testes: +102 (85 `shared_profile`, 8 `favorites_epsat`, +7 `rules_budget`, +2 `social_compat`; os testes v1/v2 de compatibilidade ganharam asserções de Fase 2) e 1 `todo` (golden Dart).

### Evidência de compatibilidade
- **Payloads antigos × regras novas**: as suítes existentes (`firestore.rules.test`, `recommended`, `social`, `social_compat`, `rules_budget`, `dart_payloads`: 376 testes) passam **sem alteração** contra as regras novas. `favorites_epsat.test.mjs` repete as 6 formas de escrita do app de produção (`add` com `set`, `setEpisodes` marcar/desmarcar, `setWatchedMovie`, `setSeasonSummaries`, `setRecommended` liga/desliga, `remove`), inclusive sobre documentos que já têm `epsAt` (escritos pela versão nova; o app antigo deixa data órfã e o `set` do `add` descarta `epsAt`: ambos aceitos). `social_compat` "NEW rules x data written by the production app (v3)": dados da Fase 1 + favoritos sem `epsAt` seguem funcionando; nenhum documento compartilhado aparece sozinho; amigo continua sem ler favoritos.
- **Payloads novos × regras v3 (produção) e v1/v2**: `get` do próprio `shared_profiles` (sonda) = `permission-denied`; criar perfil (uma seção ou todas) negado e nada é gravado; `update` de favorito com `eps.1_1 + epsAt.1_1` negado **atomicamente** (o episódio **não** fica marcado, `epsAt` não aparece) e `set` com `epsAt` negado sem criar documento; a mesma marcação **sem** `epsAt` passa. É exatamente o motivo da sonda de regras (docs/82 §4.2, D17): o app só pode enviar `epsAt` depois de constatar as regras novas.
- **Nunca abrir favoritos**: testes em `shared_profile`, `favorites_epsat` e `social_compat` (amigo, estranho, anônimo, bloqueado) + mutações M10 e SP75.

### Orçamento (emulador; produção pode divergir)
| Operação | Chamadas de regra (medido) |
|---|---|
| Amigo lê perfil | **exatamente 1** (passa com +9 `exists`, negado com +10) |
| Dono lê / apaga | 0 |
| Criar (1º interruptor) | exatamente 1 |
| Mudar consentimento (`sharing`/`actSince`) | exatamente 1 |
| Recálculo (só seções) | 0 |

Expressões (método: N comparações extras agrupadas em funções de 10, sobre a expressão real; uma requisição vazia comporta ≈ 123):
| Escrita | Comparações que ainda cabem | Uso aproximado |
|---|---|---|
| Criar com as 3 seções, 10 atividades, 50 recomendados (pior documento **legal**; o app nunca faz isso: cada interruptor liga uma seção) | ≈ 37 | **≈ 70%** |
| Ligar recomendados + recalcular as 3 seções (pior escrita **do app**) | ≈ 66 | ≈ 46% |
| Recálculo das 3 seções | ≈ 70 | ≈ 43% |
| Criar só estatísticas / só 10 atividades / só 50 recomendados | ≈ 65 / 73 / 86 | ≈ 47% / 41% / 30% |
O teste de folga trava: pior documento + 30 comparações e pior escrita do app + 55 comparações passam; 140 comparações sozinhas estouram (prova de que o limite é real e contado). As mesmas medidas com o texto exato do docs/82 (sem o desvio 2) deram os mesmos números: o desvio não custa folga mensurável.

### Desvios do docs/82 §4.3 (só restringem; nada que funcionava passa a ser negado)
1. **Leitura de amigo exige conta Google**: `isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid))` (o docs/82 tinha `request.auth != null && isFriend(...)`). Motivo: a matriz do QA (docs/83 §4, docs/82 §13) pede "não Google negado" na leitura; com o texto original o teste só seria verdadeiro por acaso (um não-Google não tem amizade). Custo: 0 chamadas, poucas expressões. O dono continua lendo o próprio documento com qualquer provedor (sonda, exclusão, exportação). Mutações SP1/SP2.
2. **Atividades revalidadas também quando `actSince` muda**: em `sharedSectionsOk`, `((!('activity' in ch) && !('actSince' in ch)) || ...)`. Com o texto original, um `update` que trocasse `actSince` para agora **sem** mexer na lista manteria itens anteriores ao novo consentimento (contraria "nada anterior ao consentimento é publicado"). O app (religar = lista vazia) não é afetado. Teste "a new actSince never keeps items from before it"; mutação SP61.
Fora isso o texto é o do docs/82 §4.3, incluindo os comentários.

### Mutações equivalentes (não podem morrer)
- **SP46** (formato de `year.key` removido) **sobreviveu** na execução de 2026-10-10 e é equivalente: `month.key` precisa casar `^20YY-MM` e `month.key.split('-')[0] == year.key`, o que já obriga `year.key = '20YY'`. A regex de `year.key` fica no texto (defesa em profundidade, como no docs/82) e a mutação saiu da lista, com comentário no `mutations.mjs`.
- Não incluídas: removem uma checagem cuja ausência gera erro de avaliação (= negado) na expressão seguinte: `d.keys().hasAll([...])` de `validShared` (todas as 5 chaves são lidas adiante), `r.keys().hasAll(['count','items'])` de `validRecs`, `s is map` / `s.total is map` (etc.) e `l is list` (o acesso seguinte falha). Ficam no texto como defesa em profundidade, como no docs/82. Por D12/D16 e a correção do docs/83 §4, "teto removido" e "margem de data removida" são mutações do validador Dart (Fatia 1), não das regras.

### Índices: por que mexi em `firestore.indexes.json`
Não há índice composto novo (nenhuma consulta nova, só `get` por id). Acrescentei a **isenção** `favorites.epsAt` (docs/82 §4.7, recomendada e listada na Fatia 0): sem ela o Firestore indexaria cada subcampo de `epsAt` (até 5000 por documento, ≈ 20 000 entradas com `eps` numa série longa: abaixo do limite de 40 000, mas custo de armazenamento e escrita sem uso). Não muda dado nem regra; é inofensiva se publicada antes ou depois das regras e reversível. Publicação **opcional** (`firebase deploy --only firestore:indexes`); se o Orquestrador preferir não publicar, nada quebra.

### O que você precisa fazer
- **Code Reviewer**: revisar `git diff firestore.rules` (bloco novo + `validFavorite`), os 2 desvios e a lista de mutações equivalentes.
- **QA**: conferir a matriz de leitura e as linhas R da tabela §4.4 contra `shared_profile.test.mjs`.
- **Fatia 1 (Dev)**: criar `SharedProfilePayloads` + `test/shared_profile_payloads_golden_test.dart` gerando `firestore_rules_test/fixtures/shared_profile_payloads.json` no formato documentado no topo de `shared_profile_payloads.test.mjs` (o harness já foi testado com um fixture provisório; enquanto o arquivo não existir aparece como 1 `todo`). Depois, acrescentar mutações de payload (como F1–F12) para o golden novo.
- **Orquestrador**: publicar as regras pela CLI só depois de Code Review e QA aprovados (docs/82 §12: regras antes do app, nunca voltar). Conferir `shasum -a 256 firestore.rules` = `4a2c148f…0c0a8f5f`.

### Artefatos
- `firestore.rules`, `firestore.indexes.json`
- `firestore_rules_test/{shared_profile,favorites_epsat,shared_profile_payloads}.test.mjs`, `shared_profile_helpers.mjs`, `fixtures/firestore.rules.v3`, `social_compat.test.mjs`, `rules_budget.test.mjs`, `mutations.mjs`

### Decisões tomadas (e por quem)
- D1–D17 e ADR-006: Manager (2026-10-10).
- Desvios 1 e 2 e a isenção de índice: Dev Backend (restritivos/inofensivos; sujeitos ao Code Review).

### Suposições (não verificadas)
- Emulador = produção quanto a limite de chamadas, de expressões e semântica de `affectedKeys`/`request.time` (risco 10 do docs/82).
- `sign_in_provider == 'google.com'` para quem entra com Google (já assumido e em produção na Fase 1).

### Riscos / atenção
- **NFR "pior escrita ≤ 65%"**: medi ≈ 70% para o pior documento **legal** (criar as 3 seções de uma vez), contra ≈ 62% do spike (método diferente: comparações em funções). O app não produz esse payload (pior escrita real ≈ 46%). Pergunta aberta abaixo.
- Regras **nunca voltam** depois de publicadas (o app novo enviaria `epsAt` e as regras antigas negariam a marcação inteira).
- Um `.env` fictício (`TMDB_API_KEY=test`, como no CI) foi criado no worktree para `flutter analyze/test`; é ignorado pelo git e não contém chave real.

### Perguntas abertas
1. Aceitar ≈ 70% no pior documento legal (pior escrita real ≈ 46%), ou o Arquiteto quer reduzir o custo (por exemplo, limitar a criação a uma seção por vez nas regras)?
2. Publicar a isenção de índice `epsAt` junto das regras (recomendado) ou adiar?

### Critério de aceite deste handoff
- Code Review aprovado sobre o diff das regras e os testes; QA confirma a matriz e a tabela R; `npm test` e `npm run test:mutations` verdes no ambiente do revisor; então o Orquestrador publica as regras (e, se aprovado, a isenção de índice) antes de qualquer app da Fase 2.
