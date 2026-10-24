# 96 - Fatia 1: domínio puro do ranking (Fase 3)

> Autor: Dev · Data: 2026-10-24 · Branch: `feat/social-ranking` · Commits: `8a6d17b` (domínio, testes, CI, mutantes) + `250eb03` (restauração do arquivo da Fatia 2, ver Riscos) + o commit deste documento (correção da âncora do L19).
> Entradas: [docs/90](./90-especificacao-ranking.md) (T1), [docs/91](./91-design-ranking.md) (§5, §6, §7, oráculos O1–O6), [ADR-007](./adr/adr-007-ranking-no-cliente.md), [docs/93](./93-testabilidade-ranking.md).
> Nada visível ao usuário. Nenhuma regra, payload ou escrita mudou.

## HANDOFF
De: Dev → Para: Code Reviewer + QA
Demanda: Fase 3 (Ranking), Fatia 1: domínio puro
Fluxo: feature | Etapa: 3 (fatias)
Prioridade: P2

### O que foi feito
| Peça | Arquivo | Conteúdo |
|---|---|---|
| Modelos | `lib/ranking/ranking_models.dart` | `RankingMetric` (ordem do seletor, slug T2, teto do docs/82 §4.4, `of(PeriodReading)`), `RankingPeriod` (`mes`/`ano`/`total`) |
| Leitor estrito | `lib/ranking/ranking_reading.dart` | `RankingReading.read` (chave estrita O4: atual = valor, anterior válida = 0, ausente/ilegível/futura = "—"; coerência O3 por métrica; marcador O6; `undatedPlacement`; tz fora de −840..840 = 0), `RankingReading.fromOwn` (tetos reaplicados à minha linha), `RankingStats` |
| Função pura | `lib/ranking/ranking_table.dart` | `RankingParticipant` (`.friend` a partir de `FriendSharedView`, `.me` a partir de `SharedStats`), `RankingRow`, `RankingResult` (`rows`, `ranked`, `myPosition`, `nobodyScored`, `undatedNote`, `now`), `RankingTable.agora` (O5: `max(serverNow, updatedAt de todos, inclusive eu)`), `RankingTable.rank` (competição 1, 1, 3; desempate `collationKey` e depois uid; "Você" sem prioridade; desconhecidos no fim, sem posição; independe da ordem de entrada), `kRankingMaxFriends = 50` |
| Textos | `lib/ranking/ranking_texts.dart` | T1 inteira: constantes, períodos e métricas, `position`, `summary`/`summaryFor` (3 variantes + nenhum com `meSharing == null`), RF-E6/E11/R12 com plural, marcador RF-E12, valores visíveis (milhar pt-BR) e Semantics (sem milhar), horas "H h MM min", Semantics de linha (normal, empatado, eu, desconhecido, sufixo de desatualizado) |
| Aditivo | `lib/shared_profile/shared_stats_reading.dart` | `FriendSharedView.calc` (`readSafeInt(min: 1)`; a F2 não usa) |
| Refactor | `lib/social/collation_key.dart` | `collationKey` saiu de `social_lists_providers.dart` (que o reexporta) para o domínio não puxar Riverpod/Firebase no teste do Chrome; comportamento idêntico |
| CI | `.github/workflows/deploy-pages.yml` | só a linha do passo `Test (web semantics, Chrome)`: + os 4 arquivos do ranking (o passo de sha da Fatia 0 foi preservado) |
| Mutantes | `tool/dart_mutations.py` | L1–L39 |

Regras de decisão que não estavam explícitas nos oráculos (todas derivadas deles):
- **Coerência O3**: compara só valores de chave atual e conhecidos (mês ≤ ano, ano ≤ total, mês ≤ total); qualquer violação apaga a métrica nos 3 períodos. "Mês atual + ano anterior" (linha 2) é regra explícita, independe dos valores; acrescentei a linha **2b** (mesma combinação com mês = 0 ⇒ "— / — / —") para matar o mutante "comparar o 0 da chave antiga" (L18).
- **Marcador**: `stale` é calculado para todos; a linha `isMe` nunca o exibe (`RankingRow.stale = !isMe && stale`). Texto: "Atualizado há N dias" só com N conhecido e > 7, senão "Atualização desconhecida" (linha 8 do O6: calc 0 com 8 d ⇒ "há 8 dias").
- **Nota de datas**: `undatedNote` só em Este mês/Este ano e só de quem foi passado ao `rank`.

### Testes (números)
| Arquivo | Oráculos | Testes VM | Chrome |
|---|---|---|---|
| `test/ranking_reading_test.dart` | O2 (20 valores × 5 métricas × 3 períodos, fontes literal/`jsonDecode`/`double.parse`, com e sem `jsify().dartify()`), O3 (18 linhas + 2b, "ausente" em 3 variantes: sem chave, ilegível, futura), O6 (10 linhas), `calc` | 355 | 355 |
| `test/ranking_table_test.dart` | O1 (15 linhas 1:1 + embaralhamento 20× semente fixa) + complementos + `undatedNote` | 23 | 23 |
| `test/ranking_period_test.dart` | O4 (14 linhas + virada com a tela aberta + tz do dono fora da faixa) e O5 (6 linhas, `ServerClock` falso com amostra +2 h) | 23 | 23 |
| `test/ranking_texts_test.dart` | T1 (constantes, valores por métrica, horas 0…52 560 000, Semantics de linha, marcador, plural) | 47 | 47 |

No Chrome os documentos passam por um objeto JS real (`test/support/js_roundtrip*.dart`, import condicional); um teste garante que o caminho é real no web (`jsRoundTripIsReal == kIsWeb`).

### Verificação (em cópia `/tmp` por `git archive` de `250eb03`, `.env` fictício)
- `flutter analyze`: **No issues found**.
- `TZ=America/Sao_Paulo flutter test`: **2463 passaram**, 0 falhas. `TZ=UTC flutter test`: **2463 passaram**, 0 falhas.
- Passo Chrome da CI inteiro (6 arquivos): **480 passaram**.
- Mutantes da fatia: **39/39 mortos** (L1–L39; L35 é o "`is int` sem `isFinite`", só morre no Chrome e roda com `--platform chrome`). A lista completa fica para o fechamento (aceleração combinada).

Mutantes por grupo: ordenação L1–L10 (densa, "Você" primeiro, sem `collationKey`, `compareTo` cru, horas pela hora exibida, desconhecido = 0, 0 = desconhecido, desconhecidos antes, `tied` falso no 1º do grupo, `nobodyScored` exigindo todos conhecidos); chaves L11–L14 (futura = 0, ilegível = 0, antiga = "—", mês em UTC); relógio L15–L16 (sem `max`, `max` sem a minha linha); coerência L17–L22 (removida, 0 antigo comparado, todas as métricas juntas, ano > total, mês > total, mês > ano); minha linha L23; marcador L24–L27 (`>= 7`, sem `updatedAt`, `calc` ignorado, na minha linha); tz L28; nota L29; leitor/tetos/`isFinite` L30–L35; textos L36–L39 (plural, milhar, zero à esquerda, "há 7 dias").

### O que você precisa fazer
- Code Review e QA da fatia (código em `lib/ranking/`, testes acima).
- Conferir que o comando do Chrome no `CLAUDE.md` (lista de arquivos) seja atualizado por quem cuida do arquivo; não alterei `CLAUDE.md`.

### Decisões tomadas (e por quem)
- `RankingFilter` (T2) **não** entrou: a tarefa desta fatia não o lista e o docs/90 §Fatiamento também não; fica para a fatia da tela (Dev). O docs/91 §16 o citava na Fatia 1.
- `collationKey` movido para arquivo puro, com reexport (Dev).
- Linha 2b do O3 acrescentada (Dev, derivada da linha 2).

### Suposições (não verificadas)
- O Fatia 2/3 vai montar os participantes com `RankingParticipant.friend/.me` e chamar `RankingTable.rank(…, serverClock.now())` em cada `build`.
- Os textos RF-E10 ("Compartilhar estatísticas") podem mudar com a Fatia S (docs/95, interruptor único); mantive a T1 atual.

### Riscos / atenção
- **Colisão de commits no checkout compartilhado**: para não levar as mudanças da Fatia 2 em `social_lists_providers.dart`, montei o commit `8a6d17b` num índice privado; a Fatia 2 commitou (`47f63b2`) no meio e o meu commit voltou as linhas dela nesse arquivo. Corrigido em seguida por `250eb03`, que restaura o arquivo exatamente como em `47f63b2` (`git diff 47f63b2 250eb03 -- lib/providers/social_lists_providers.dart` vazio). Nenhum outro arquivo foi afetado.
- A `collationKey` agora é compartilhada pela lista de amigos e pelo ranking (mudança nela afeta os dois, de propósito).

### Critério de aceite deste handoff
- CR e QA APROVADO sem ressalvas; analyze 0; suíte verde nos dois fusos; passo Chrome verde; L1–L39 mortos.
