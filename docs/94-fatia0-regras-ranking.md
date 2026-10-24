# 94 - Ranking (Fase 3), Fatia 0: testes de regras, gate de sha e mutantes RK*

> Autor: Dev Backend · Data: 2026-10-24 · Branch: `feat/social-ranking` (base 1738dd2 = docs da Fase 3 sobre `main` 9389bc5)
> Entradas: [docs/90](./90-especificacao-ranking.md) (Fatia 0), [docs/91](./91-design-ranking.md) §4, §13, §14.1, §16 item 0, [docs/93](./93-testabilidade-ranking.md) §1 B11, §3, §4.1, §4.5, [ADR-007](./adr/adr-007-ranking-no-cliente.md) (Aceita). Fase 3 aprovada pelo Manager em 2026-10-24.
> Escopo: **só** `firestore_rules_test/`, um passo novo na CI e este documento. **`firestore.rules` não mudou** (sha256 `6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612`, o publicado em produção). Nenhuma linha de Dart. Nada publicado (sem `firebase deploy`, sem push na `main`).

## HANDOFF
De: Dev Backend → Para: Code Reviewer e QA
Demanda: Fase 3 (ranking entre amigos), Fatia 0: testes de regra (sem mudar regras)
Fluxo: feature | Etapa: Fatia 0 (gate: APROVADO sem ressalvas de CR e QA antes da Fatia 1)
Prioridade: P1 (abre as Fatias 1 a 4)

### O que foi feito
- `firestore_rules_test/ranking.test.mjs` (novo, **35 testes em 5 suítes**), matriz do docs/91 §14.1 / docs/93 §4.1:
  - **`get` de cada amigo**: dono (existe/não existe, inclusive `password`); **12 amigos mútuos Google lidos por `get` numa janela deslizante de 10** (o teste mede o pico = 10 e confere cada documento); cada `get` decidido sozinho (não amigo no meio da janela é negado, os vizinhos são lidos); amigo sem snapshot ⇒ `get` permitido e documento inexistente; não amigo negado com e sem documento (sem oráculo de existência); ex-amigo com o par apagado por **cada** lado ⇒ negado, e refeito amigo ⇒ lê de novo; bloqueio pelo batch real nos dois sentidos (Ana→Dora e Bruno→Ana: os dois lados negados); bloqueio com o par ausente nunca dá leitura; anônimo, `password`, provedor `anonymous` e sem claim negados (inclusive para amigo sem snapshot); **conta em exclusão com o par presente** (na ordem do `AccountDeleter`: `deleting = true`, apaga o snapshot, com as credenciais da própria Carla) ⇒ `get` permitido e documento inexistente; depois da varredura (par apagado) ⇒ negado; amigo não escreve no documento do outro (set, update, delete).
  - **Consultas negadas**: `getDocs(collection)` (dono, amigo, anônimo), `documentId in [3 amigos]`, `in [10 amigos]`, `in` misto (amigo + não amigo), `documentId ==` um amigo, filtro por `sharing.stats` e por `stats.total.minutes` com `limit(50)`.
  - **Consentimento ⇔ seção (`stats`)**: create com `stats` e `sharing` sem `stats` negado; create com `sharing.stats` e sem a seção negado; update que acrescenta `stats` sem consentimento negado; update que tira `sharing.stats` mantendo `stats` negado e o que tira os dois aceito (o amigo lê sem o campo); amigo lê documento sem `stats` e recebe o documento sem o campo.
  - **Documentário de `rankOk`** (por que o leitor do cliente é estrito): `Infinity`, `1e300`, `1.5` em `total.minutes` **aceitos**; `1.5` aceito nas 5 métricas × total/mês/ano; `month.watchedMovies = 999999 > total = 1` **aceito**; `NaN`, `-Infinity`, `-1`, `"10"`, `null` negados; o amigo lê `Infinity` de volta como `Infinity`. Se uma linha "aceito" falhar, as regras endureceram: rever `RankingReading` e o orçamento (comentário no arquivo).
  - **Sinal D7**: `count()` de `friendships where members array-contains <me> limit 300` permitido ao membro (Ana com 2 amigos ⇒ 2, com um par alheio no banco; quem não tem amigos ⇒ 0); a mesma consulta com o uid de outra pessoa negada (2 casos); anônimo negado.
  - Custo de regra do `get` de amigo (≤ 1 `exists`): **já travado** por `rules_budget.test.mjs` ("friend read costs exactly 1 call (passes with +9, denied with +10)", Fase 2); não dupliquei.
- `firestore_rules_test/rules_sha.test.mjs` (novo, 1 teste): lê `../firestore.rules` (ignora `RULES_PATH`) e compara o sha256 com `6135322e…e612`. Não precisa do emulador; `npm test` o executa junto com o resto.
- `firestore_rules_test/mutations.mjs`:
  - lista `RK = ['ranking.test.mjs']`; os mutantes RK* rodam **só** contra `ranking.test.mjs` (mais estrito que "ranking + as atuais" do docs/91 §14.1: a morte prova que o teste do ranking trava a cláusula sozinho); `ranking.test.mjs` entrou no baseline (`SUITES`);
  - **guarda B11**: o runner sai com erro (exit 2) se `rules_sha.test.mjs` aparecer em `SUITES`, `SP`, `RK` ou em qualquer lista de suítes de mutante;
  - **15 mutantes RK*** (tabela abaixo).
- `.github/workflows/deploy-pages.yml`: passo novo logo após o Checkout, `Ensure firestore.rules matches production (sha256)`: `echo "6135322e…e612  firestore.rules" | sha256sum -c -`. Nenhum outro passo mudou.

### Mutantes RK* (todos rodados só com `ranking.test.mjs`)
| Id | Mutação | Morto por (exemplo) |
|---|---|---|
| RK1 | `list` de `shared_profiles` → `request.auth != null` | `getDocs(collection)`, `in [3]`, `in [10]` |
| RK2 | `list` → `isGoogle() && isFriend(uid, request.auth.uid)` | `documentId in [3 amigos]` e `in [10 amigos]` (o emulador aceita a consulta com o mutante, então a negação de hoje vem do `list: if false`) |
| RK3 | `isFriend` → `true` no `get` | não amigo negado |
| RK4 | `isGoogle()` removido do `get` | `password`/anônimo/sem claim |
| RK5 | `isGoogle()` → "qualquer provedor não anônimo" | `password` |
| RK6 | `resource == null \|\|` no `get` (oráculo de existência) | não amigo sem documento |
| RK7 | ramo do dono removido do `get` | dono lê o próprio documento |
| RK8 | `get` também com bloqueio no lugar do par | bloqueio com o par ausente |
| RK9 | `('stats' in d) == ('stats' in s)` removido | consentimento |
| RK10 | só "consentimento ⇒ seção" (seção sem consentimento passa) | create/update com `stats` sem `sharing.stats` |
| RK11 | só "seção ⇒ consentimento" (consentimento sem seção passa) | create com `sharing.stats` sem `stats` |
| RK12 | `list` de `friendships` aberta a qualquer logado | `count()` com o uid de outra pessoa |
| RK13 | `list` de `friendships` fechada | `count()` do próprio membro |
| RK14 | `rankOk` endurecido: `minutes is int` | documentário (`Infinity`/`1e300`/`1.5` aceitos) |
| RK15 | `rankOk` endurecido: `minutes <= 52 560 000` | documentário (`1e300`/`Infinity` aceitos) |

### Números (emulador local, JDK 24, portas padrão 8080/9150/4400/4500)
| Comando | Resultado |
|---|---|
| `npm test` (antes, base 1738dd2) | 522 testes |
| `npm test` (depois) | **558 pass, 0 fail** (64 suítes): +35 `ranking.test.mjs`, +1 `rules_sha.test.mjs`; os 522 antigos sem alteração |
| `npm run test:mutations` | baseline **536 ok / 0 not ok** (inclui `ranking.test.mjs`, exclui `rules_sha.test.mjs`); **All 159 mutations were killed** (144 anteriores + 15 RK novas), 0 sobreviventes, 0 erros, exit 0 |
| `shasum -a 256 firestore.rules` | `6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612` (= produção); `sha256sum -c` do passo da CI conferido localmente (`firestore.rules: OK`) |
| `flutter analyze` | No issues found (nenhuma mudança em Dart nesta fatia) |

### O que você precisa fazer
- **Code Reviewer**: revisar `ranking.test.mjs`, `rules_sha.test.mjs`, o diff de `mutations.mjs` (lista RK, guarda B11, baseline) e o passo da CI.
- **QA**: conferir a matriz contra o docs/91 §14.1 e o docs/93 §4.1/§4.5 (linha a linha) e rodar `npm test` + `npm run test:mutations`.
- **SRE**: ciente do passo de sha na CI (docs/91 §13 item 2). Ele roda no push da `main`, antes do build.

### Artefatos
- `firestore_rules_test/ranking.test.mjs`, `firestore_rules_test/rules_sha.test.mjs`, `firestore_rules_test/mutations.mjs`, `.github/workflows/deploy-pages.yml`.
- Commits em `feat/social-ranking`: f7884a0 (testes, gate, RK*, CI) e o commit deste documento.

### Decisões tomadas (e por quem)
- RK* rodam só com `ranking.test.mjs` (Dev Backend): mais estrito que o docs/91 §14.1; as mesmas cláusulas também morrem nas suítes da Fase 2 (SP1, SP2, SP3, SP30).
- Passo da CI logo depois do Checkout (Dev Backend): falha em segundos, antes de baixar o Flutter; o docs/91 só pede "antes do build".
- `rules_budget` não ganhou teste novo (Dev Backend): o custo de 1 `exists` no `get` de amigo já está travado desde a Fase 2.
- Mutantes extras além dos 6 do docs/91 (RK5–RK8, RK10, RK11, RK13–RK15) (Dev Backend): cobrem o lado "permitido" (dono, membro conta) e o documentário de `rankOk`.

### Suposições (não verificadas)
- O emulador representa a produção em `count()` com `limit` e em `documentId in` (spike do docs/91 §4.3 e mesma premissa da Fase 2). A conferência real fica no smoke (docs/93 §5).
- A consulta do D7 será exatamente `where('members', 'array-contains', uid)` + `limit(300)` + `count()` (Fatia 2). Se a Fatia 2 mudar a forma, este teste muda junto.

### Riscos / atenção
- O [docs/95](./95-simplificacao-compartilhamento.md) (Fatia S, um interruptor só) não muda regras: as três seções continuam com consentimento ⇔ seção, então a matriz de consentimento daqui continua válida. Se o S0 do docs/95 concluir que precisa mudar regras, o gate de sha e este documento precisam ser revistos.
- O gate de sha (teste e CI) **vai falhar de propósito** na primeira fase que mudar regras (Fase 4/5): atualizar `PRODUCTION_SHA` em `rules_sha.test.mjs` e o passo da CI no mesmo PR, depois do deploy pela CLI.
- O documentário de `rankOk` fixa um comportamento **ruim** de propósito (aceita `Infinity`/`1e300`/`1.5`): não é aprovação, é o motivo do leitor estrito (RF-L, ADR-007 opção D rejeitada).

### Critério de aceite deste handoff
- CR e QA **APROVADO sem ressalvas**; `npm test` verde, `npm run test:mutations` com todos os mutantes mortos (inclusive RK1–RK15) e 0 erros; sha256 de `firestore.rules` = `6135322e…e612`.
