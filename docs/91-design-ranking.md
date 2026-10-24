# 91 - Design: Ranking entre amigos (Fase 3 de 5)

> Autor: Arquiteto · Data: 2026-10-18 · **Revisão 2026-10-24** (decisões aprovadas pelo Manager; testabilidade do QA, [docs/93](./93-testabilidade-ranking.md), incorporada) · Base: `main` 9389bc5 (Fases 1 e 2 em produção + hotfix A2 do [docs/92](./92-hotfix-leitor-inteiro-seguro.md); `firestore.rules` publicado = sha256 `6135322e…e612`) · Branch: `feat/social-ranking`
> Entradas: [docs/90](./90-especificacao-ranking.md) (PA, D1–D16, T1–T3), [docs/82](./82-design-perfil-social.md) (§4.4 tetos, §5.1 períodos, §7.2 perfil de amigo, §11.1 cota), [ADR-006](./adr/adr-006-snapshot-perfil-social.md), [docs/87](./87-fatia3-perfil-de-amigo.md) (cache do perfil de amigo), [docs/50 §7](./50-design-amizades.md) (limites de chamadas), [docs/93](./93-testabilidade-ranking.md) (QA), código em `lib/`.
> Decisão de arquitetura: [ADR-007](./adr/adr-007-ranking-no-cliente.md) (**Aceita (Manager, 2026-10-24)**).
> **Nenhum código, regra ou arquivo de código do projeto foi alterado por este documento.** Os spikes de 2026-10-18 (§4.3 e §5.1) rodaram em cópias descartáveis em `/tmp`; na revisão de 2026-10-24 nada foi executado (só leitura de código em `feat/social-ranking` = `main` 9389bc5 + docs).
> **Status:** D1–D16, N1–N5 aprovadas em 2026-10-24 (§18). O achado A2 (§5.1) virou o hotfix já publicado (`main` 9389bc5); a antiga "Fatia H" saiu do plano.
> **Oráculos deste documento** (copiados 1:1 para testes parametrizados): O1 empates (§6), O2 leitor estrito e O3 coerência (§5.3), O4 períodos e O5 relógio (§7), O6 marcador (§7.4), O7 transições do sinal e O8 acesso (§8), O9 fases da carga (§10.3), O10 cooldown (§10.4), O11 leituras (§12). Textos (T1), URL (T2) e foco (T3) estão no docs/90.

## Sumário
1. Contexto e NFR · 2. Opções · 3. Solução · 4. Acesso a dados e regras · 5. Leitor estrito · 6. Função pura de ranking · 7. Períodos, fusos, relógio e marcador · 8. Sinal "≥ 1 amigo" e rota · 9. Navegação · 10. Controller, cache e concorrência · 11. Estados de UI · 12. Cota · 13. Rollout e rollback · 14. Plano de testes · 15. Riscos · 16. Fatias · 17. Respostas A1–A11 e posição sobre D1–D16 · 18. Decisões aprovadas

---

## 1. Contexto e requisitos não funcionais
O ranking compara **eu + amigos mútuos que compartilham "Estatísticas"** usando o snapshot `shared_profiles/{uid}.stats` da Fase 2 (fonte única, ADR-006). Spark: sem Cloud Functions, então a montagem é no cliente. Produção = **Flutter web (dart2js)**: os números chegam como números JS (§5.1).

| NFR | Alvo |
|---|---|
| Privacidade | só documentos que a regra atual libera (`isOwner \|\| isGoogle && isFriend`); `list` continua negado; nada gravado em disco além da pista booleana; offline não mostra nenhum amigo |
| Escritas | **zero** no servidor (o ranking só lê) |
| Regras | **nenhuma mudança** (sha256 `6135322e…e612` mantido; orçamento de expressões intocado, ≈ 64% na pior escrita) |
| Cota | O11: abrir a frio com N ≤ 50 amigos = N `get` (≈ 2N cobradas) com a lista em memória, ≈ 3N com a lista fria; trocar filtro = 0; reabrir no TTL = 0 |
| Latência | 50 amigos com janela de 10: ≈ 5 rodadas de ≈ 100–300 ms (estimativa, não medida); timeout de 8 s por leitura; erro total ≈ 8 s (disjuntor, §10.3) |
| Robustez | valor não inteiro, não finito, acima do teto, incoerente ou de chave ilegível/futura = desconhecido ("—"), nunca 1º lugar |
| Remoção | minha remoção ou bloqueio tira a pessoa na hora, sem leitura; a do outro lado vale na próxima leitura do servidor (D8) |
| Layout/a11y | 320–1440 px × fonte 1×/2×/3× × claro/escuro, teclado e leitor de tela (RNF7, T3 do docs/90) |

## 2. Opções consideradas

**Eixo 1: como ler os N snapshots**
| Opção | Prós | Contras | Custo/Esforço |
|---|---|---|---|
| **A. `get` por id, janela de 10, sem mudar regra** | regra atual já permite (1 `exists` por leitura); ex-amigo afeta só a própria leitura; reaproveita `readFriend` e o cache do perfil de amigo; nada a publicar | N requisições (simultaneidade limitada a 10) | 2 leituras cobradas por amigo; esforço baixo |
| B. `list` com `documentId in [≤ 10]` (regra nova) | menos requisições | **regra nova**; um ex-amigo no lote **nega o lote inteiro** (docs/50 §7); mesmo custo cobrado | igual a A, com mais esforço e risco |
| C. Documento agregado "ranking" gravado por cada dono | 1 leitura | escrita em documento de terceiros; desfazer amizade exigiria reescrever dados; sem Functions | alto; descartada |
| D. Coleção `rank_entries` | ordenável no servidor | 2ª fonte de estatísticas (proibido); regras novas | descartada |

**Eixo 2: sinal "tenho ≥ 1 amigo"**
| Opção | Prós | Contras |
|---|---|---|
| **a. Contador: agregada 1×/sessão + pista local + ajustes locais + recontagem em revogação** | 1 leitura por sessão; segue o padrão do `ReceivedCountController` | remoção feita pelo outro lado só aparece quando o app descobre |
| b. Listener `friendships limit(1)` | tempo real | quebra o "sem listener" da F1; +1 leitura por mudança |
| c. Ler a lista inteira ao iniciar | sabe tudo | até 51 leituras por sessão para mostrar um ícone |

**Eixo 3: cache** — (i) **reaproveitar `FriendProfileCache`** (TTL 5 min, já limpo em troca de conta, período social, remoção e bloqueio); (ii) cache próprio (duplicaria a limpeza e não daria "perfil aberto pelo ranking = 0 leituras"). Escolha: (i).

## 3. Solução escolhida
`get` por id (A), sinal por contador (a), cache compartilhado (i). Ordenação, períodos e relógio ficam numa **função pura**; os filtros só recalculam o que já está em memória.

```mermaid
flowchart LR
  subgraph Sessão
    FC[FriendsCountController\ncount() 1x/sessão + pista Hive\n+ ajustes locais] --> RA[rankingAccessProvider\npending/allowed/noSession/inactive/noFriends]
  end
  RA --> NAV[4 entradas: menu do topo, MobileTopBar,\nAmigos, Perfil]
  RA --> RT[go_router redirect /ranking\nrefreshListenable]
  RC[RankingController] --> FL[FriendsController\n50 primeiros de state.items]
  RC --> CACHE[(FriendProfileCache\nmemória, TTL 5 min)]
  RC -->|faltantes: janela de 10 get Source.server, 8 s, disjuntor| SP[(shared_profiles/{uid})]
  RC --> ME[SharingController.doc\nminha linha, 0 leituras]
  RC --> PURE[RankingReading + RankingTable.rank\nfunção pura: métrica × período × serverNow]
  PURE --> UI[RankingScreen\n?estatistica=&periodo=]
  SP -. permission-denied .-> REV[_revoked: cache.remove +\nfriends.dropLocal + 1 recontagem por carga]
```

Componentes novos (nomes sugeridos; o dev pode ajustar):
| Peça | Onde | Tipo |
|---|---|---|
| `RankingMetric`, `RankingPeriod` (enums com slug da URL, rótulo, teto) | `lib/ranking/ranking_models.dart` | puro |
| `RankingReading` (chave estrita, coerência, marcador; reusa `readCount`) | `lib/ranking/ranking_reading.dart` | puro |
| `RankingTable.rank(...)` (relógio, ordenação, empates) | `lib/ranking/ranking_table.dart` | puro |
| `RankingTexts` (T1) | `lib/ranking/ranking_texts.dart` | puro |
| `RankingFilter.parse/canonical` (T2) | `lib/ranking/ranking_filter.dart` | puro |
| `FriendsCountController` + pista local | `lib/providers/social_lists_providers.dart` + `LocalStore` | Notifier |
| `rankingAccessProvider`, `rankingLastFilterProvider` (memória da sessão) | `lib/providers/ranking_providers.dart` | Provider |
| `RankingController` | `lib/providers/ranking_providers.dart` | AutoDispose Notifier |
| `RankingScreen` e widgets | `lib/screens/ranking_screen.dart`, `lib/widgets/ranking_widgets.dart` | UI |
| `FriendSharedView.calc` (novo campo `int?`, `readSafeInt(min: 1)`; aditivo, a F2 não usa) | `lib/shared_profile/shared_stats_reading.dart` | puro |

Já existe e é reutilizado sem mudança: `readSafeInt` (`lib/shared_profile/safe_int.dart`), `readCount(v, max:)` e `SharedStatsReading.read` (`shared_stats_reading.dart`, já com os tetos por métrica desde o hotfix A2), `periodKey`, `SharedProfileTexts.notePlacementFor`, `collationKey`, `ServerClock`, `kListJustRefreshedMessage`.

## 4. Acesso a dados e regras

### 4.1 Leitura
- **Amigos considerados** = **os 50 primeiros de `FriendsController.state.items` no momento da carga** (`kRankingMaxFriends = 50`). Correção do QA (docs/93 §2): isso **não** é "a 1ª página": `add()` insere por nome entre os itens (`social_lists_providers.dart:473`) e `dropLocal` faz o 51º em memória subir; páginas de "Ver mais" são anexadas no fim. O oráculo dos testes é exatamente `state.items.take(50)` lido no início da carga. Se a lista não está fresca, `ensureLoaded()` (TTL 5 min). Lista vinda do cache (`fromCache`) ⇒ trata como offline (D10 da F2).
- `limitedTo = 50` quando `state.items.length > 50 || state.hasMore`; `totalFriends` = contagem **confirmada** do `FriendsCountController` (senão null; texto sem N, T1).
- **Snapshot de cada amigo**: `SharedProfileRepository.readFriend(uid)` (já existe: `Source.server`, timeout `friendTimeout` = 8 s, falhas mapeadas em `SharedProfileFailureKind`). Resultado: `FriendSharedView?` (null = `not-found`).
- **Minha linha**: `sharingControllerProvider` → `SharingState.doc` confirmado (A1, §10.6). 0 leituras.
- **Nada de `list`/consulta** em `shared_profiles`.

### 4.2 Regras: nenhuma mudança
`allow get: if isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid))` cobre o ranking:
- amigo mútuo Google ⇒ lê (1 `exists`); documento inexistente de amigo ⇒ `get` permitido, documento não existe (inclui conta em exclusão com o par ainda presente);
- não amigo, ex-amigo, bloqueado nos dois sentidos, anônimo, conta não Google ⇒ negado;
- `allow list: if false` ⇒ qualquer consulta, inclusive `documentId in [amigos]`, negada;
- "Estatísticas" desligado ⇒ `stats` ausente (`validShared` exige `('stats' in d) == ('stats' in s)`);
- `calc is int && calc >= 1` é exigido em toda escrita (por isso `calc < 1` só chega por leitura ilegível; RF-L3 é defesa).

### 4.3 Spike no emulador (2026-10-18, cópia em `/tmp/spike_rules`, sha idêntico ao da `main`)
| Experimento | Resultado |
|---|---|
| Ana lê 12 amigos por `get`, em lotes de 10 paralelos | ✔ todos lidos |
| Não amigo / Ana bloqueou Dora / Bruno bloqueou Ana / ex-amigo / conta `password` | ✔ todos negados |
| `getDocs(collection)` e `where(documentId(), 'in', [3 amigos])` | ✔ negados |
| Criar documento com `stats` mas `sharing: {activity}` | ✔ negado |
| Criar com `total.minutes` = `Infinity` / `1e300` / `1.5` | **aceito** |
| Criar com `NaN` / `-Infinity` | negado |
| Criar com `month.watchedMovies = 999999 > total = 1` | **aceito** |

Conclusão: o acesso já é o que o ranking precisa, e as regras **não** garantem números sãos. Endurecer `rankOk` custaria ≈ 30 expressões numa escrita em ≈ 64% do limite e exigiria publicar regras: rejeitado (ADR-007, opção D).

## 5. Leitor estrito

### 5.1 Achado A2 (spike de 2026-10-18) — resolvido
No dart2js, `Infinity` e `1e300` passavam em `v is int`; `WatchTimeFormatter.format(Infinity)` lançava `UnsupportedError` e quebrava a seção de estatísticas do perfil de um amigo. **Resolvido pelo hotfix A2** (docs/92, `main` 9389bc5): `readSafeInt(v, {min, max})` em `lib/shared_profile/safe_int.dart` (limites checados antes de tudo; inteiro e `double` inteiro aceitos; NaN, ±Infinity, fração e fora da faixa = null; nunca lança), aplicado em todos os leitores do lado do amigo com os tetos do docs/82 §4.4; `WatchTimeFormatter` nunca lança; passo `Test (web semantics, Chrome)` na CI.

### 5.2 O que o ranking reaproveita
`SharedStatsReading.read` já entrega, por métrica e período, exatamente a regra RF-L1 (inteiro, finito, 0..teto da métrica). O ranking **não** reaplica o teto aos amigos (seria código morto e os mutantes "sem teto" sobreviveriam); os mutantes de teto continuam sendo os B1–B9 do docs/92, e a tabela O2 reconfere o caminho inteiro (documento ⇒ linha) nas duas plataformas. A **minha** linha vem de `SharedStatsReading.of(doc.stats!)`, cujo leitor do documento próprio não tem tetos: para ela, `RankingReading.fromOwn` reaplica `readCount(v, max: teto(m))`, para que "Você" mostre o que os amigos veem.

### 5.3 `RankingReading` (RF-L)
Entrada: `SharedStatsReading`, `tz` (fora de −840..840 ⇒ 0, também para mim), `updatedAt`, `calc`, `agora` (O5). Saída: `RankingStats` = mapa `(métrica, período) → int?` + `stale` + `staleDays` + `undatedPlacement`.
1. **Chave de período estrita** (O4): `month.key` válido = `^\d{4}-(0[1-9]|1[0-2])$`; `year.key` válido = `^\d{4}$`. Com as chaves atuais do dono `periodKey(agora, tz)`: igual ⇒ valor gravado; válida e **menor** (comparação de texto, formatos de tamanho fixo) ⇒ **0**; ausente, ilegível ou **maior** (futura) ⇒ desconhecido. Diferença consciente para `PeriodReading.current` da F2 (que dá 0 para qualquer string diferente da atual e só "—" para chave não string): o ranking não usa `current` e a F2 não muda (RF-L4).
2. **Valor**: o de `SharedStatsReading` (já estrito para amigos; reaplicado com `readCount` para mim, §5.2).
3. **Coerência por métrica** (O3): só valores de chave atual são comparados.
4. **Marcador** (O6): `stale` = `updatedAt == null` **ou** `calc == null || calc < 1` **ou** `agora.difference(updatedAt).inDays > 7`.
5. **Nota de datas**: `undatedPlacement = SharedProfileTexts.notePlacementFor(undated: undatedMovies + undatedEpisodes, datedFrom, updatedAt, tz, now: agora)`.
O leitor não lança: qualquer entrada vira número ou desconhecido.

**O2 — Leitor estrito** (`ranking_reading_test`, VM **e** Chrome; vale para total, ano e mês de cada métrica; valores produzidos por literais Dart, `jsonDecode`, `double.parse('Infinity')`/`double.infinity` e, no Chrome, `jsify().dartify()`):
| Valor gravado | Resultado |
|---|---|
| `12` | 12 |
| `12.0` (double) | 12 |
| `-0.0` | 0 (não negativo; texto "0 …") |
| `12.5`, `Infinity`, `-Infinity`, `NaN`, `1e300`, `-1`, `2^53 + 2`, `"12"`, `true`, `null`, ausente | desconhecido ("—") |
| filmes / séries assistidas / séries concluídas = `100000` / `100001` | 100000 / desconhecido |
| episódios = `1000000` / `1000001` | 1000000 / desconhecido |
| minutos = `52560000` / `52560001` | 52560000 / desconhecido |
| minutos = `1000001` (acima do teto de episódios) | 1000001 (mata o mutante "teto trocado") |
| episódios = `100001` (acima do teto de filmes) | 100001 (idem) |
| minha linha: filmes = `100001` em `SharedStats` | desconhecido (reaplicação de §5.2) |

**O3 — Coerência** (`ranking_reading_test`; agora = 2026-10-15T15:00Z, tz −180 ⇒ chaves atuais "2026-10"/"2026"; "anterior" = "2026-09"/"2025"; "ausente" inclui ilegível e futura; valores gravados T = 100, Y = 40, M = 10 salvo indicação; saída = Total / Este ano / Este mês **da métrica testada**):
| # | Chave do mês | Chave do ano | Valores | Saída |
|---|---|---|---|---|
| 1 | atual | atual | T100 Y40 M10 | 100 / 40 / 10 |
| 2 | atual | anterior | T100 Y40 M10 | — / — / — (combinação impossível pelo motor) |
| 3 | atual | ausente | T100 M10 | 100 / — / 10 |
| 4 | anterior | atual | T100 Y40 M10 | 100 / 40 / 0 |
| 5 | anterior | anterior | T100 Y40 M10 | 100 / 0 / 0 |
| 6 | anterior | ausente | T100 M10 | 100 / — / 0 |
| 7 | ausente | atual | T100 Y40 | 100 / 40 / — |
| 8 | ausente | anterior | T100 Y40 | 100 / 0 / — |
| 9 | ausente | ausente | T100 | 100 / — / — |
| 10 | atual | atual | T100 Y40 **M50** (mês > ano, ano ≤ total) | — / — / — |
| 11 | atual | atual | T100 **Y150** M10 | — / — / — |
| 12 | atual | ausente | T100 **M150** | — / — / — |
| 13 | anterior | atual | T100 **Y150** M(gravado)999 | — / — / — (o 0 do mês não salva) |
| 14 | anterior | atual | T100 Y40 M(gravado)**999** | 100 / 40 / 0 (valor de mês antigo nunca é comparado) |
| 15 | atual | atual | **T12.5** Y40 M10 | — / 40 / 10 (sem total, só mês ≤ ano é checado) |
| 16 | atual | atual | T100 **Y1e300** M10 | 100 / — / 10 (mês ≤ total checado) |
| 17 | atual | atual | T100 **Y1e300** M150 | — / — / — (mês > total) |
| 18 | — | — | filmes incoerentes (linha 10), episódios coerentes (linha 1) | filmes — / — / —; episódios 100 / 40 / 10 |

## 6. Função pura de ranking
```dart
class RankingParticipant {
  final String uid; final String name; final String? photoUrl;
  final bool isMe; final RankingStats stats; final DateTime? updatedAt; final int tz;
}
class RankingRow {
  final RankingParticipant who;
  final int? value;      // null = desconhecido ("—")
  final int? position;   // competição: 1, 1, 3; null para desconhecido
  final bool tied;       // outra linha CONHECIDA com o mesmo valor (vale para todo o grupo)
  final bool stale;      // sempre false para isMe
  final int? staleDays;  // dias inteiros quando conhecido
}
class RankingResult {
  final List<RankingRow> rows;
  final int ranked;          // linhas com posição ("de N"), inclui eu
  final int? myPosition;     // null: não estou ou meu valor é desconhecido
  final bool nobodyScored;   // ranked > 0 e todos os valores conhecidos == 0
  final bool undatedNote;    // período ≠ total e algum participante com placement no período
  final DateTime now;        // o agora usado (O5), exposto para teste
}
RankingResult rank(List<RankingParticipant> ps, RankingMetric m, RankingPeriod p, DateTime serverNow);
```
Algoritmo (determinístico, O(n log n), n ≤ 51):
1. `agora = max(serverNow, max(updatedAt de ps))` (O5). Lê cada participante com `RankingReading` nesse `agora`.
2. `value = stats[(m, p)]`.
3. Conhecidos: `value` desc, depois `collationKey(name)` asc, depois `uid` asc. "Você" não tem prioridade e ordena pelo `name` que recebe, que é o `displayLabelProvider` (o mesmo texto da linha; o que cada amigo vê de mim vem da cópia dele do par e pode atrasar depois de uma troca de apelido, docs/68; cada leitor tem uma ordem coerente com o que vê).
4. `position = 1 + |{conhecidos com valor > v}|`; `tied = |{conhecidos com valor == v}| > 1`.
5. Desconhecidos no fim, por `collationKey(name)` e `uid`, sem posição, `tied = false`.
6. Horas: ordena e empata por **minutos**; a exibição (D14) é só formatação.
7. Propriedade: a saída não depende da ordem de entrada.

**O1 — Empates** (`ranking_table_test`, 1:1; Episódios / Este mês salvo indicação; "eu" = `isMe`; resumo pela T1 do docs/90, com `meSharing = true` salvo indicação):
| # | Participantes (uid, apelido, valor) | Ordem das linhas | position | tied | ranked | myPosition | nobodyScored | Resumo |
|---|---|---|---|---|---|---|---|---|
| 1 | u1 Ana 10; u2 Bia 10; u3 Caio 8 (eu) | Ana, Bia, Caio | 1, 1, 3 | T, T, F | 3 | 3 | F | "Sua posição: 3º de 3" |
| 2 | u9 Zé 5 (eu); u1 Ana 5 | Ana, Zé | 1, 1 | T, T | 2 | 1 | F | "Sua posição: 1º de 2" |
| 3 | u1 Ana 0 (eu); u2 Bia 0 | Ana, Bia | 1, 1 | T, T | 2 | 1 | **T** | "Sua posição: 1º de 2" + RF-E13 |
| 4 | u1 Ana 3 (eu); u2 Bia —; u3 Caio 1 | Ana, Caio, Bia | 1, 2, null | F, F, F | 2 | 1 | F | "Sua posição: 1º de 2" |
| 5 | u1 "Álvaro" 4; u2 "Ana" 4; u3 "alice" 4; eu não compartilho (`meSharing = false`) | alice, Álvaro, Ana | 1, 1, 1 | T, T, T | 3 | null | F | "Você não está no ranking" |
| 6 | u2 "ana" 4; u1 "Ana" 4; u3 "ANA" 4 (eu) | Ana(u1), ana(u2), ANA(u3) | 1, 1, 1 | T, T, T | 3 | 1 | F | "Sua posição: 1º de 3" |
| 7 | u1 A 10; u2 B 8; u3 C 8; u4 D 8 (eu); u5 E 3 | A, B, C, D, E | 1, 2, 2, 2, 5 | F, T, T, T, F | 5 | 2 | F | "Sua posição: 2º de 5" |
| 8 | u1 Ana 5; u2 Bia 2; u9 Zé — (eu) | Ana, Bia, Zé | 1, 2, null | F, F, F | 2 | null | F | "Sua posição: sem informação" |
| 9 | u1 Ana —; u2 Bia — (eu) | Ana, Bia | null, null | F, F | 0 | null | F | "Sua posição: sem informação" (sem mensagem extra) |
| 10 | u1 Ana —; u2 Bia —; eu não compartilho | Ana, Bia | null, null | F, F | 0 | null | F | "Você não está no ranking" |
| 11 | u1 Ana 0 (eu); u2 Bia — | Ana, Bia | 1, null | F, F | 1 | 1 | **T** | "Sua posição: 1º de 1" + RF-E13 |
| 12 | u01…u51, apelidos distintos, todos 7; eu = u51 | por `collationKey`, depois uid | 1 × 51 | T × 51 | 51 | 1 | F | "Sua posição: 1º de 51" |
| 13 | Horas/Total: u1 Ana 600; u2 Bia 659; u3 Caio 659 (eu) | Bia, Caio, Ana | 1, 1, 3 | T, T, F | 3 | 1 | F | "Sua posição: 1º de 3"; valores "10 h 59 min", "10 h 59 min", "10 h 00 min" |
| 14 | u9 Zé 12 (eu), sem amigos participando | Zé | 1 | F | 1 | 1 | F | "Sua posição: 1º de 1" |
| 15 | u1 Ana 4 (eu); u2 Ana 4 | Ana(u1, "Você"), Ana(u2) | 1, 1 | T, T | 2 | 1 | F | "Sua posição: 1º de 2" |
Mais: embaralhar a entrada 20 vezes (semente fixa) dá a mesma saída em todas as linhas acima.

## 7. Períodos, fusos, relógio e marcador

### 7.1 "Este mês" entre amigos em fusos diferentes
Cada participante é medido **no próprio mês, no fuso dele** (`periodKey(agora, tz_dono)`, regra B1 da F2). É a única leitura possível com o snapshot (ele guarda só **um** recorte de mês). Consequência aceita: perto da virada (até 28 h, com fusos de −14 h a +14 h), os "este mês" cobrem intervalos diferentes. No Brasil (−3/−5), poucas horas.

### 7.2 Chave de período velha: **0**; ilegível ou futura: "—"
O motor da F2 regrava o mês ao virar (wake no app aberto) e em toda mudança de favoritos; o pulso de 24 h só grava `updatedAt` quando o conteúdo, incluindo a chave, não mudou. Logo, **chave velha ⇔ o dono não abriu o app desde a virada**, e o que o app registrou dele neste mês é 0 (coerente com o perfil de amigo; ranqueado normalmente). Chave **futura** só aparece com o relógio do dono adiantado ou manipulação: não dá para saber o que ele fez neste mês ⇒ "—". Chave ilegível (schema estranho, mês 13, não string) ⇒ "—" (decisão do Manager sobre B2, conforme recomendação).

**O4 — Períodos e fusos** (`ranking_period_test`; `agora` dado; chaves calculadas por `periodKey(agora, tz)`):
| # | agora (UTC) | tz do dono | Chaves atuais | Gravado | Este mês / Este ano |
|---|---|---|---|---|---|
| 1 | 2026-10-15T15:00Z | −180 | "2026-10" / "2026" | month "2026-10" = 7; year "2026" = 30 | 7 / 30 |
| 2 | idem | −180 | idem | month "2026-09" = 40; year "2026" = 90 | 0 / 90 |
| 3 | idem | −180 | idem | month "2026-11" (futura) | — / (ano conforme a chave) |
| 4 | idem | −180 | idem | month "abc" / "2026-13" / "2026-1" / `12` (não string) / ausente | — |
| 5 | idem | −180 | idem | year "2025" / "2027" / "26" | 0 / — / — |
| 6 | 2026-11-01T02:30Z | −180 | "2026-10" | — | (chave atual "2026-10") |
| 7 | 2026-11-01T02:30Z | 0 | "2026-11" | — | (chave atual "2026-11") |
| 8 | 2026-11-01T02:30Z | +840 | "2026-11" | — | (chave atual "2026-11") |
| 9 | 2026-11-01T02:30Z | −840 | "2026-10" | — | (chave atual "2026-10") |
| 10 | 2026-11-01T02:30Z | 900 (fora da faixa ⇒ 0) | "2026-11" | — | (chave atual "2026-11") |
| 11 | 2027-01-01T02:59Z | −180 | "2026-12" / "2026" | month "2026-12" = 5; year "2026" = 80 | 5 / 80 |
| 12 | 2027-01-01T03:00Z | −180 | "2027-01" / "2027" | idem | 0 / 0 |
| 13 | 2027-01-05T15:00Z | −180 | "2027-01" / "2027" | month "2026-12"; year "2026"; total 300 | 0 / 0 (Total 300) |
| 14 | 2026-11-01T02:30Z | Ana −180 "2026-10" = 4; Carla 0 "2026-11" = 2 | — | — | Ana 4, Carla 2 |

### 7.3 Relógio (N4)
`agora` do ranking = `max(serverClock.now(), maior updatedAt entre os participantes passados a rank)`. **Conjunto**: os participantes da chamada, isto é, eu (se participo) + amigos com `stats` em memória, vindos do servidor **ou** do cache; ficam de fora quem falhou, foi negado ou não compartilha. A dependência do conjunto (um amigo que carregou pode corrigir o mês de outro) é aceita e determinística para um mesmo conjunto.
- `ServerClock` (já existe) corrige o relógio pelo desvio do servidor quando há amostra; sem amostra, é o relógio do aparelho.
- O `max` com `updatedAt` (hora do servidor, sempre ≤ agora real) corrige o relógio **atrasado**. Um relógio **adiantado** continua errado (aceito).
- O perfil de amigo (F2) continua com `sharedProfileClockProvider` (N4). O provider do relógio do ranking é injetável.
- Virada com a tela aberta: o `agora` é recalculado em cada `build` (sem rede), e um `Timer` agenda um rebuild para a **próxima virada de mês entre os fusos de todos os participantes e o do leitor** (não só a do leitor), reagendado a cada build.

**O5 — Relógio** (`ranking_period_test`, `ServerClock` falso):
| # | Relógio do aparelho / amostra | Participantes (tz 0 salvo indicação) | agora | Resultado em Este mês |
|---|---|---|---|---|
| 1 | 2026-10-31T23:00Z, sem amostra | Carla `updatedAt` 2026-11-01T01:00Z, month "2026-11" = 3 | 2026-11-01T01:00Z | Carla 3 (o `max` corrige) |
| 2 | idem | Carla (linha 1) + Davi `updatedAt` 2026-10-30T12:00Z, month "2026-10" = 9 | 2026-11-01T01:00Z | Carla 3, Davi 0 |
| 3 | idem | só Davi (Carla falhou) | 2026-10-31T23:00Z | Davi 9 |
| 4 | 2026-10-31T23:00Z | eu `updatedAt` 2026-11-01T00:10Z + Davi | 2026-11-01T00:10Z | Davi 0 (minha linha entra no `max`) |
| 5 | 2026-10-31T22:30Z, amostra com desvio +2 h | Davi | 2026-11-01T00:30Z | Davi 0 |
| 6 | 2026-11-02T00:00Z (adiantado) | Carla `updatedAt` 2026-10-31T20:00Z, month "2026-10" = 5 | 2026-11-02T00:00Z | Carla 0 (aceito) |

### 7.4 Marcador de desatualizado (D11)
`staleDays = agora.difference(updatedAt).inDays` (mesma contagem de `SharedProfileTexts.ago`), com o `agora` do §7.3. Marcador quando `staleDays > 7`, ou `updatedAt` ausente/ilegível, ou `calc` ilegível/< 1. Texto (T1): `staleDays` conhecido e > 7 ⇒ "Atualizado há N dias"; senão ⇒ "Atualização desconhecida". **Nunca** na minha linha.

**O6 — Marcador** (`ranking_reading_test`; serverNow = 2026-10-15T15:00Z):
| # | `updatedAt` | `calc` | Linha | Marcador |
|---|---|---|---|---|
| 1 | 2026-10-08T15:00:00Z (7 d) | 1 | amigo | nenhum |
| 2 | 2026-10-07T15:00:01Z (7 d 23:59:59) | 1 | amigo | nenhum |
| 3 | 2026-10-07T15:00:00Z (8 d) | 1 | amigo | "Atualizado há 8 dias" |
| 4 | 2026-09-15T15:00:00Z | 1 | amigo | "Atualizado há 30 dias" |
| 5 | 2026-10-16T00:00:00Z (depois do serverNow) | 1 | amigo | nenhum (o `agora` vira 2026-10-16T00:00Z, O5) |
| 6 | ausente | 1 | amigo | "Atualização desconhecida" |
| 7 | 2026-10-15T14:00Z | ausente / `"x"` / 0 | amigo | "Atualização desconhecida" |
| 8 | 2026-10-07T15:00Z (8 d) | 0 | amigo | "Atualizado há 8 dias" |
| 9 | 2026-10-15T14:00Z | 2 (mais nova) | amigo | nenhum |
| 10 | 2026-09-15T15:00Z | 1 | **eu** | nenhum |

## 8. Sinal "≥ 1 amigo" e proteção da rota

### 8.1 `FriendsCountController` (A3)
Estado: `{int? count, bool confirmed, bool inFlight, bool dirty, Set<String> addedHere}` + pista `friendsHint:{uid}` = `{has, at}` no Hive (`_discoveryBox`, TTL 24 h, padrão do `socialHint`). `confirmed` = o valor veio do servidor (agregada ou 1ª página completa) e só mudou depois por ajustes locais certos. `dirty` = houve ajuste local com uma contagem em voo (a resposta dela será descartada). Sem listener.

**Ganchos** (Fatia 2):
- `FriendsController.add(friend)`: o gancho `friendsCount.added(uid)` fica **antes** do `if (state.phase != SentPhase.loaded || contains(friend.uid)) return;` (`social_lists_providers.dart:474`), para valer com a lista não carregada; o contador deduplica por uid (`addedHere` e, com a lista carregada, `contains`).
- `FriendsController.remove`: só com sucesso (`failure == null`) ⇒ `removed(uid)`; `uncertain` ⇒ `invalidate()`; outras falhas ⇒ nada.
- `afterBlock` (único ponto para bloqueio, inclusive o `FriendsController.block`, que já passa por ele: não há decremento em dobro): sucesso e `dropLocal` verdadeiro ⇒ `removed(uid)`; sucesso, `dropLocal` falso e lista carregada sem `hasMore` ⇒ nada (não era amigo); sucesso nos demais casos ⇒ `invalidate()`.
- `FriendsController.onFirstPage` (só leitura do **servidor**; a de cache não chama, `social_lists_providers.dart:208`) ⇒ `fromFirstPage(items.length, complete: !hasMore)`.
- `_revoked` (perfil de amigo) ⇒ `invalidate()`; no ranking, **uma** `invalidate()` no fim da carga se houve ≥ 1 negação.
- Gatilhos de `ensureConfirmed()` (só se `!confirmed && !inFlight`): 1º frame do shell com amizades ativas na sessão (gancho do `BadgeRefresher`), reconexão real (offline → online) e retorno ao app (oculto → visível). No máximo 1 agregada por gatilho.
- `invalidate()`: se `inFlight`, marca `dirty` e agenda **uma** recontagem depois; senão, inicia a recontagem. **Não muda `count` nem `confirmed` até a resposta** (sem piscar).

**O7 — Transições** (`friends_count_controller_test`, `fake_async` + `Completer` na contagem; sessão Google e amizades ativas salvo indicação; "agora" = 2026-10-15T15:00Z):
| # | Estado antes `{count, confirmed, inFlight, dirty}` + pista | Evento | Estado depois | Leituras | `rankingAccess` | Entrada |
|---|---|---|---|---|---|---|
| 1 | — | build, pista ausente | `{null, F, F, F}` | 0 | pending | oculta |
| 2 | — | build, pista `{has: T, at: −1 h}` | `{null, F, F, F}` + pista | 0 | allowed | visível |
| 3 | — | build, pista `{has: T, at: −24 h −1 s}` | pista ignorada | 0 | pending | oculta |
| 4 | — | build do uid B com pista só do uid A | sem pista | 0 | pending | oculta |
| 5 | linha 1 | gatilho (1º frame do shell) | `{null, F, T, F}` | **1 agregada** | pending | oculta |
| 6 | linha 5 | resposta 3 | `{3, T, F, F}`; pista `{has: T}` gravada | 0 | allowed | visível |
| 7 | linha 5 | resposta 0 | `{0, T, F, F}`; pista `{has: F}` | 0 | **noFriends** | oculta (redirect) |
| 8 | linha 5 | falha offline/unavailable | `{null, F, F, F}` | 0 | pending (ou pela pista) | conforme pista |
| 9 | linha 8 | reconexão real | `{null, F, T, F}` | 1 agregada | idem | idem |
| 10 | linha 5 | `added(Carla)` (aceite, lista não carregada) | `{1, F, T, T}` | 0 | **allowed** | visível |
| 11 | linha 10 | resposta n (qualquer) | descartada ⇒ `{1, F, F, F}` | 0 | allowed | visível |
| 12 | `{3, T, F, F}` | `added(Carla)` | `{4, T, F, F}` | 0 | allowed | visível |
| 13 | linha 12 | `added(Carla)` de novo (pedido cruzado + aceite) | `{4, T, F, F}` (sem mudança) | 0 | allowed | visível |
| 14 | `{1, T, F, F}` | `removed(Carla)` (remover ou bloquear com sucesso) | `{0, T, F, F}` | 0 | **noFriends** | oculta |
| 15 | `{3, T, F, F}` | `removed(Carla)` | `{2, T, F, F}` | 0 | allowed | visível |
| 16 | `{0, T, F, F}` | `removed(x)` | `{0, T, F, F}` | 0 | noFriends | oculta |
| 17 | `{null, F, F, F}` | `removed(Carla)` | `{null, F, T, F}` (recontagem) | 1 agregada | pending/pista | conforme pista |
| 18 | `{null, F, T, F}` | `removed(Carla)` | `{null, F, T, T}`; recontagem depois da resposta | 1 agregada a mais | idem | idem |
| 19 | `{1, F, F, F}` (só ajuste local) | `removed(Carla)` | `{0, F, T, F}` (0 não confirmado ⇒ recontagem) | 1 agregada | pending | oculta |
| 20 | `{2, T, F, F}` | `afterBlock` sucesso, `dropLocal` falso, lista carregada sem `hasMore` | sem mudança | 0 | allowed | visível |
| 21 | `{2, T, F, F}` | `afterBlock` sucesso, lista não carregada (busca/pedido) | `{2, T, T, F}` | 1 agregada | allowed (sem piscar) | visível |
| 22 | `{2, T, F, F}` | `invalidate()` por negação (1 ou k na mesma carga do ranking) | `{2, T, T, F}` | **1** agregada | allowed (sem piscar) | visível |
| 23 | linha 22 | resposta 0 | `{0, T, F, F}` | 0 | noFriends | oculta |
| 24 | `{null, F, T, F}` | `fromFirstPage(2, complete)` | `{2, T, T, T}` (a agregada em voo será descartada) | 0 | allowed | visível |
| 25 | qualquer, inclusive `{null, F, T, F}` (contagem em voo) | `fromFirstPage(0, complete)` | `{0, T, inFlight, dirty = inFlight}`: se havia contagem em voo, ela continua em voo e a resposta será **descartada** (como na linha 24) | 0 | noFriends | oculta |
| 26 | `{null, F, F, F}` | `fromFirstPage(50, hasMore)` | `{51, F, F, F}` (`max(count ?? 0, 51)`) | 0 | allowed | visível |
| 27 | qualquer | 1ª página `fromCache` | sem mudança (`onFirstPage` não é chamado) | 0 | — | — |
| 28 | `{3, T, F, F}` | retorno do background | sem mudança | 0 | allowed | visível |
| 29 | `{3, T, F, F}` | troca de conta (uid B) | linhas 1–4 para B; respostas da geração de A ignoradas | 0 (+1 do gatilho de B) | — | — |
| 30 | qualquer | desativar amizades | estado descartado; pista do uid apagada | 0 | inactive | oculta |
| 31 | linha 30 | reativar | linha 1 + gatilho | 1 agregada | pending → resposta | — |
| 32 | qualquer | excluir a conta | `friendsHint`, `socialHint`, `sharedHint` apagadas | 0 | noSession | oculta |
| 33 | — | recarregar a aba | nova sessão: linhas 1–2 + gatilho | 1 agregada | — | — |

**Cobrança da contagem no Spark:** 1 leitura por lote de até 1000 entradas de índice, mínimo 1 por consulta (documentação de preços; já usada na F1). Com limite 300: **1 leitura**. Não medido em produção.

### 8.2 `rankingAccessProvider`
**O8 — Acesso** (primeira condição verdadeira vence; `router_ranking_redirect_test`):
| # | Condição | Valor | Redirect de `/ranking` | Entrada |
|---|---|---|---|---|
| 1 | sessão carregando | `pending` | nenhum (esqueleto) | oculta |
| 2 | sem sessão | `noSession` | `/` | oculta |
| 3 | conta não Google, ou `SocialPhase.inactive/unavailable` | `inactive` | `/friends` | oculta |
| 4 | `SocialPhase.loadFailed` | `pending` | nenhum | oculta |
| 5 | `SocialPhase.loading` sem pista fresca `has = true` | `pending` | nenhum | oculta |
| 6 | `count != null && count > 0` (confirmado **ou** ajuste local) | `allowed` | nenhum | visível |
| 7 | `count == 0 && confirmed` | `noFriends` | `/friends` | oculta |
| 8 | `count == null` e pista fresca (≤ 24 h) `has = true` | `allowed` | nenhum | visível |
| 9 | restante (sem pista, pista `has = false`, `count == 0` não confirmado) | `pending` | nenhum | oculta |
**Entrada visível ⇔ `allowed`.** As 4 entradas fazem `watch` no provider: a entrada some no mesmo frame em que o valor muda.

### 8.3 Rota (A6) e saída quando empilhado
- `redirect` global ganha `/ranking` conforme O8. `routerProvider`: `ref.listen(rankingAccessProvider, (_, _) => refresh.value++)`; o go_router reavalia o redirect da rota **do topo**.
- **Ranking visível** (`ModalRoute.of(context)!.isCurrent`) e transição `allowed/pending → noFriends`: a `RankingScreen` mostra o SnackBar "Você não tem mais amigos no CineTrack." no `ScaffoldMessenger` raiz (sobrevive à navegação) e o redirect leva a `/friends`.
- **Ranking empilhado** (outra rota por cima, ex.: `/friends` ou `/friends/u/:uid` abertos a partir dele): o redirect não alcança a rota de baixo. A `RankingScreen` é `RouteAware`; no `didPopNext` (voltou a ser visível) com `noFriends`, sai sem SnackBar: `context.pop()` se `canPop` (volta à rota anterior ao ranking), senão `context.go('/friends')`. Nenhum frame do ranking com `noFriends` é exibido (o build com `noFriends` desenha o esqueleto).
- Recarregar `/#/ranking?estatistica=horas&periodo=ano`: `pending` no início ⇒ sem redirect; a query é preservada.

## 9. Navegação (A5, A11)
**Desktop (> 768 px)**: no menu do topo da Início, `_NavAction(label: 'Ranking', icon: Icons.leaderboard)` **depois de Amigos**, só com `allowed`, com `context.push('/ranking')`. Largura mínima de rótulos: `kTopMenuLabelsMinWidth (960) + Amigos (120) + kTopMenuRankingExtraWidth`. O valor (proposta 130 px) é do dev; o teste trava o **comportamento**: sem overflow em 1× exatamente na largura mínima, só ícones 1 px abaixo.
**Mobile (≤ 768 px)**: na `MobileTopBar`, `IconButton(Icons.leaderboard_outlined, tooltip: 'Ranking')` **à esquerda de Amigos**. Regra de encaixe:
```dart
bool topBarFits(BuildContext c, int extraIcons) {
  const padding = 32.0, button = 48.0, sync = 32.0, logo = 32.0, gap = 8.0;
  final room = width - padding - button /*busca*/ - sync - button * extraIcons;
  return room >= logo + gap + kBrandNameMinWidth * scale;
}
friendsIconFits(c) == topBarFits(c, 1)   // inalterado
rankingIconFits(c) == topBarFits(c, 2)   // Ranking é o primeiro a sair
```
Contas: em 320 px os dois cabem até ≈ 1,28× de fonte; em 375 px, até ≈ 2,27×. Teste: a escala exata de saída calculada pela fórmula, ±0,01, em 320 e 375 px.
**Entradas alternativas sempre presentes com `allowed`**: "Ver ranking" no topo de Amigos (todas as larguras) e "Ranking" na seção Amizades do Perfil.
**Barra inferior**: inalterada. Em `/ranking`, o selecionado é **Perfil** (`AppShell` trata `location.startsWith('/ranking')` como `/friends`).
**Filtros (T2 do docs/90)**:
- Parse puro `RankingFilter.parse(Uri, last)`: por chave exata (`estatistica`, `periodo`), primeira ocorrência (`queryParametersAll[k].first`), valor sem diferenciar maiúsculas; ausente ou inválido ⇒ último filtro da sessão (`rankingLastFilterProvider`, memória, por uid) ⇒ padrão `episodios`/`ano`. `canonical(uri, filter)` reescreve só `estatistica`/`periodo` e preserva os outros parâmetros na ordem.
- Ao abrir com URL não canônica e a cada troca de filtro: `Router.neglect(context, () => context.replace(canonical))`. `replace` do go_router 14.8.1 (versão travada no `pubspec.lock`) **reusa a chave da página**: não refaz a pilha (o "voltar" do AppBar continua), não recria a tela (o `RankingController` não é descartado; 0 leituras) e não anima. As abas de Amigos já usam `context.replace` (`friends_screen.dart:107`), mas **sem** `Router.neglect`: o `Router.neglect` (evitar entrada nova no histórico do navegador) é um **mecanismo novo** no app, não usado em nenhum lugar de `lib/` hoje, e por isso entra no spike da Fatia 3 (abaixo) e no smoke ("Voltar" do navegador sai do ranking, docs/93 §5).
- **Não verificado**: com `GoRouter.optionURLReflectsImperativeAPIs = false` (padrão), a barra de endereço do web pode não refletir rotas imperativas (`push`/`replace`). Primeira tarefa da Fatia 3: spike de 30 min em `/tmp` (via `git archive`) confirmando que `/#/ranking?…` aparece na barra depois do `push` e do `replace` e que recarregar mantém o filtro. Se não refletir, a alternativa é abrir o ranking com `go` e um `extra`/parâmetro de origem para o "voltar" (decisão minha, sem mudar o comportamento da T2).
- Seletores: dois menus suspensos ("Período", "Estatística"), um foco cada (T3). `SegmentedButton` foi descartado: 3 a 5 segmentos não cabem em 320 px com fonte 3×.
**Cabeçalho**: desktop, AppBar "Ranking" com voltar (como Amigos); mobile, sem AppBar (`MobileShellScope`), título no corpo.

## 10. Controller, cache e concorrência (A4)

### 10.1 Estado
```dart
enum RankingPhase { loading, content, offline, error, quota, sessionExpired }
class RankingState {
  final RankingPhase phase;
  final List<RankingParticipant> friends;   // só quem tem stats
  final RankingParticipant? me;             // null: não compartilho / não confirmado
  final bool? meSharing;                    // null = ainda não confirmado (faixa D9, resumo e RF-E8/E9 esperam)
  final int notSharing;                     // respostas ok sem stats (D10)
  final Set<String> failed;                 // unavailable/timeout/unknown/não iniciados pelo disjuntor (D13)
  final int? limitedTo; final int? totalFriends; // RF-R12
  final DateTime? freshAt;                  // leitura de servidor mais antiga entre TODAS as respostas ok dos considerados (O10)
  final bool refreshing;
  final bool awaitingRecount;               // todos os considerados negados: esqueleto até a recontagem
}
```
A tela calcula `RankingTable.rank(participantes, filtro, serverClock.now())` no `build` (0 leituras ao trocar filtro).

### 10.2 Carga
1. Geração (`_generation`) incrementada em `build`, que observa `currentUidProvider` e `socialPeriodProvider`; também no `dispose` (AutoDispose). Depois de cada `await`, e **antes de qualquer `cache.put`**: `if (gen != _generation) return`. Sair da tela, trocar de conta ou desativar amizades no meio da carga ⇒ nenhuma resposta tardia grava estado ou cache, e nada lança.
2. Offline (`syncStatus.offline`) ⇒ `offline` (nem a minha linha). `ref.listen` no offline durante a tela (cai para offline; ao voltar, recarrega, do cache se fresco).
3. Lista de amigos (`ensureLoaded`, ou `refresh` no "Atualizar"). Falha ⇒ fase pela falha (quota/sessão/erro/offline), **0 `get`**. Lista vazia e completa ⇒ `onFirstPage` leva o contador a 0 ⇒ redirect.
4. Considerados = `state.items.take(50)`. Para cada um: se `!force && !status.fromCache` e `cache.fresh(uid, agora, 5 min)` ⇒ usa a entrada. Os demais entram na fila.
5. **Janela de 10** e **disjuntor** (§10.3). Resultado por amigo: `ok(view?)` / `denied` / `failed(kind)` / `quota` / `unauthenticated`.
   - `ok` ⇒ `cache.put(uid, FriendProfileEntry(friend, view, at: agora))`. `view == null` ou `view.stats == null` (não mapa) ⇒ `notSharing++`.
   - `denied` ⇒ `cache.remove`, `friendsController.dropLocal`; some em silêncio; ao fim da carga, **uma** `friendsCount.invalidate()`.
   - `quota` / `unauthenticated` ⇒ para tudo (nenhuma leitura nova), fase `quota`/`sessionExpired`, nada parcial; respostas em voo descartadas.
   - `unavailable`/timeout/desconhecido ⇒ `failed`. Resposta que chega depois do timeout de 8 s é ignorada (continua `failed`, não entra no cache).
6. Fim: ver O9. Se todos os considerados foram negados ⇒ `awaitingRecount = true` (esqueleto) até a recontagem responder.
7. Uma carga por vez: um segundo pedido (inclusive "Atualizar" ou a tela pedindo de novo) se junta à carga em curso (`_inFlight`).
8. "Tentar novamente" do aviso parcial ⇒ relê só `failed` (`force` para esses uids), com a mesma janela e o mesmo disjuntor; do erro ⇒ carga completa (entradas frescas do cache valem); da cota ⇒ carga completa. **Nunca** com cooldown.
9. "Atualizar" ⇒ cooldown do ranking (O10); fora dele, `FriendsController.refresh()` (que respeita os 15 s **dela**) + todos os considerados com `force`. O ranking anterior fica visível, com progresso no botão.

### 10.3 Janela e disjuntor
- **Janela deslizante de 10**: no máximo 10 leituras em voo; quando uma termina, a próxima da fila começa (sem lotes em degraus), **desde que já tenha chegado ao menos uma resposta `ok` ou `denied`** nesta carga.
- **Antes da primeira `ok`/`denied`**, a janela não desliza: as 10 primeiras leituras correm e nenhuma 11ª começa. Se as **10 primeiras respostas** forem `failed`, o disjuntor dispara: nenhuma leitura nova, os não iniciados entram em `failed`. Assim o pior caso de erro total é ≈ 8 s e exatamente 10 `get` (QA B6: X = 10).
- **Contagem exata** (oráculo dos testes): enquanto a carga segue, `iniciados = min(N_fila, 10 + R)`, onde R = número de respostas `ok`/`denied`/`failed` chegadas **a partir da primeira `ok`/`denied`, inclusive**. Uma resposta terminal (`quota`, `unauthenticated`) ou a queda da conexão não libera vaga e congela `iniciados`; `em voo` = `iniciados − respostas chegadas` (a terminal conta como chegada). Ex.: 20 amigos, respostas `ok`, `ok`, `quota` ⇒ iniciados = 10 + 2 = 12, em voo = 12 − 3 = 9.
- Menos de 10 leituras na fila: todas começam; o disjuntor não se aplica (vale "todas terminaram em falha").
- Fase final: há ≥ 1 amigo com dado `ok` (servidor ou cache) ⇒ `content` (+ aviso se `failed` não vazio); nenhum ⇒ `error` (ou `offline`, se a conexão caiu enquanto as respostas viajavam).

**O9 — Fases da carga** (`ranking_controller_test`; resultados na ordem de chegada; cache vazio e lista em memória salvo indicação; "eu" compartilho):
| # | Cenário | Fase | Linhas | Aviso RF-E6 | `notSharing` | `failed` | `get` iniciados | Entradas gravadas no cache |
|---|---|---|---|---|---|---|---|---|
| 1 | 5 amigos, todos `failed` | `error` | nenhuma (nem a minha) | — | 0 | 5 | 5 | 0 |
| 2 | 50 amigos, 10 primeiras respostas `failed` | `error` | nenhuma | — | 0 | 50 | **10** | 0 |
| 3 | 50 amigos, 10 primeiras = 9 `failed` + 1 `ok` (a 10ª), resto `ok` com `stats` | `content` | eu + 41 | "…carregar 9 amigos…" | 0 | 9 | 50 | 41 |
| 4 | 10 amigos, todos `denied` | esqueleto (`awaitingRecount`) → recontagem 0 ⇒ `noFriends` ⇒ redirect + SnackBar (se visível) | — | — | 0 | 0 | 10 (+1 agregada) | 0; 10 `dropLocal` |
| 5 | 20 amigos; respostas na ordem: 1ª `ok`, 2ª `ok`, 3ª `quota` (9 em voo) | `quota` | nenhuma (nem a minha) | — | — | — | **12** (10 + 2) | 2 (as 9 em voo descartadas) |
| 6 | 5 amigos; Carla com timeout de 8 s e resposta `ok` aos 9 s | `content` | eu + 4 | "…carregar 1 amigo…" | 0 | {Carla} | 5 | 4 (Carla não) |
| 7 | 5 amigos com 2 `failed` (Carla, Davi) + "Tentar novamente": Carla `ok`, Davi `denied` | `content` | eu + 4 (Carla entra, Davi some) | — | 0 | ∅ | 2 (+1 agregada) | +1 |
| 8 | 2 `failed` + "Tentar novamente": os 2 `failed` de novo | `content` | as mesmas | "…carregar 2 amigos…" | 0 | 2 | 2 | 0 |
| 9 | 20 amigos; respostas 1ª–3ª `ok`, a conexão cai antes da 4ª | `offline` | nenhuma | — | — | — | **13** (10 + 3) | 3 (as 10 em voo descartadas) |
| 10 | 20 amigos; respostas 1ª–3ª `ok`, 4ª `unauthenticated` (9 em voo) | `sessionExpired` (fluxo existente) | nenhuma | — | — | — | **13** (10 + 3) | 3 (as 9 em voo descartadas) |
| 11 | 20 amigos, 12 frescos no cache, 8 leituras todas `failed` | `content` | eu + 12 | "…carregar 8 amigos…" | 0 | 8 | 8 | 0 |
| 12 | 9 amigos considerados: 7 `ok` (3 com `stats`, 1 `not-found`, 1 sem `stats`, 1 `stats: 3`, 1 `stats: {}`), 2 `failed` | `content` | eu + 4 (o de `{}` com "—") | "…carregar 2 amigos…" | **3** | 2 | 9 | 7 |
| 13 | falha da lista (unavailable) | `error` | nenhuma | — | — | — | **0** | 0 |
| 14 | lista `resource-exhausted` | `quota` | nenhuma | — | — | — | 0 | 0 |
| 15 | todos os 3 amigos sem `stats` e eu não compartilho | `content` (RF-E8 + faixa + rodapé 3) | nenhuma | — | 3 | 0 | 3 | 3 |
| 16 | troca de conta com 6 em voo | estado novo da conta B | — | — | — | — | — | 0 no cache de B |
| 17 | sair da tela com 6 em voo; reabrir | nova carga | — | — | — | — | só os não cacheados antes de sair | só as respostas anteriores à saída |
| 18 | 20 amigos, todos `ok` | `content` | eu + 20 | — | 0 | 0 | 20, pico 10; a 11ª começa quando a 1ª termina | 20 |
Rodapé RF-E11: conta só respostas `ok` sem `stats` (linha 12: `not-found` + sem `stats` + `stats: 3`); nunca falhas, negados ou amigos além do limite (com 80 amigos, só os 50 considerados podem entrar na contagem).

### 10.4 Cooldown (N1)
`freshAt` = a leitura de servidor **mais antiga** (`FriendProfileEntry.at`) entre **todas** as respostas `ok` dos amigos considerados, com ou sem `stats` (inclui `not-found` e `stats` ausente/não mapa, para que "ninguém compartilha" e "só eu" também tenham cooldown; inclui entradas servidas do cache, inclusive as gravadas pelo perfil de amigo; exclui `failed`, negados e a minha linha). Sem nenhuma entrada `ok` ⇒ `freshAt = null` ⇒ sem cooldown. "Atualizar" bloqueado ⇔ `freshAt != null && agora − freshAt < 60 s` (mesma comparação estrita do `PagedListController.refresh`). A lista mantém o `refreshCooldownProvider` (15 s) dela.

**O10 — Cooldown** (`ranking_controller_test`, relógio falso; N = 20; lista e snapshots lidos em t0 salvo indicação):
| # | Situação | Ação | Leituras | Resultado |
|---|---|---|---|---|
| 1 | carga do servidor em t0 | "Atualizar" em t0+10 s | 0 | SnackBar "A lista já está atualizada (atualizada há instantes)." |
| 2 | idem | em t0+59 s | 0 | idem |
| 3 | idem | em t0+60 s | 1 consulta da lista + 20 `get` | `freshAt = t0+60 s` |
| 4 | lista relida pela tela Amigos em t0+50 s | "Atualizar" do ranking em t0+60 s | 20 `get`, 0 lista | lista no cooldown dela |
| 5 | reaberto em t0+4 min (servido do cache) | "Atualizar" em t0+4 min | 1 lista + 20 `get` | `freshAt` = t0, então livre |
| 6 | lista e 12 entradas lidas em t0−3 min (cache) + 8 entradas lidas em t0 | "Atualizar" em t0+1 s | 1 lista + 20 `get` | `freshAt` = t0−3 min |
| 7 | parcial em t0 (2 `failed`) | "Tentar novamente" em t0+1 s | 2 `get` | sem cooldown |
| 8 | linha 7 | "Atualizar" em t0+1 s | 0 | SnackBar (`freshAt` = t0) |
| 9 | erro em t0 | "Tentar novamente" em t0+1 s | carga completa | sem cooldown |
| 10 | cota em t0 | "Tentar novamente" em t0+1 s | carga completa | sem cooldown |
| 11 | carga em curso | "Atualizar" | 0 adicionais | junta-se à carga (botão desabilitado) |
| 12 | "ninguém compartilha": 3 amigos `ok` sem `stats` (1 `not-found`) lidos em t0 | "Atualizar" em t0+10 s | 0 | SnackBar (`freshAt` = t0) |
| 13 | idem | "Atualizar" em t0+60 s | 1 lista + 3 `get` | `freshAt = t0+60 s` |

### 10.5 Concorrência com o perfil de amigo
Os dois controllers escrevem no mesmo cache, e a última escrita vence (leituras do servidor equivalentes). Abrir o perfil de alguém enquanto o ranking ainda o lê pode gerar 1 leitura duplicada (≤ 2 `get` do mesmo uid): aceito. Sem "single-flight" compartilhado, para não mexer no `FriendProfileController` em produção.

### 10.6 Minha linha
`ref.watch(sharingControllerProvider)`: `confirmed && doc.sharing.contains(stats) && doc.stats != null` ⇒ participante "Você" com `RankingReading.fromOwn(SharedStatsReading.of(doc.stats!))` (tetos reaplicados, §5.2), `tz = doc.tz` (fora da faixa ⇒ 0), `updatedAt = doc.updatedAt`, `name = displayLabelProvider`. `confirmed && !stats` ⇒ `meSharing = false` (com a Fatia S, docs/95: busca desligada ou "falta confirmar"; a faixa escolhe a variante pelo `sharingModeProvider`). `!confirmed` ⇒ `meSharing = null` (ranking como 1ª tela: espera o `readOwn`, 1 leitura **de sessão**, não do ranking). Desligar/religar "Estatísticas" ⇒ a transação já atualizou o `doc` (otimista) ⇒ a linha sai/volta sem leitura.

## 11. Estados de UI
Mapeamento do quadro do docs/90 para `RankingState` (textos literais da T1; foco da T3):
| Estado | Condição | UI |
|---|---|---|
| sem sessão / inativo / 0 amigos | `rankingAccess` (O8) | redirect; entrada ausente |
| sinal pendente | `pending` | esqueleto, sem redirect |
| carregando a frio | `loading` ou `awaitingRecount` | filtros habilitados + esqueleto (+ minha linha se confirmada) |
| dono não confirmado | `meSharing == null` | esqueleto; sem faixa, resumo, RF-E8/E9 |
| conteúdo | `content` | resumo (N = `ranked`), linhas, rodapé D10 se > 0 |
| meu valor desconhecido | `myPosition == null && me != null` | "Sua posição: sem informação" |
| eu não compartilho | `meSharing == false` | faixa RF-E10 + botão |
| só eu | `friends.isEmpty && me != null` | linha "Você" em 1º + RF-E9 |
| ninguém compartilha | `friends.isEmpty && meSharing == false` | RF-E8 + faixa |
| falha parcial | `content && failed.isNotEmpty` | linhas + aviso RF-E6 + "Tentar novamente" |
| erro / offline / cota / sessão | fase | só a mensagem (+ "Tentar novamente" em erro e cota); sem filtros, resumo ou linhas |
| atualizando | `refreshing` | ranking anterior + progresso |
| desatualizado | `row.stale` | marcador (O6) |
| desconhecido | `row.value == null` | no fim, "—", sem posição |
| marcações sem data | `undatedNote` | nota RF-R9 |
| período sem movimento | `nobodyScored` | RF-E13 |
| limite | `limitedTo != null` | RF-R12 (com N só se `totalFriends` confirmado) |
| último amigo removido | `noFriends` | §8.3 |

## 12. Cota
"Regra" = leitura de documento feita pelas regras. Estimativa pela documentação; **não medida em produção**.

**O11 — Leituras por cenário** (`ranking_controller_test` e widget; colunas 2–6 = chamadas no fake, que os testes contam; coluna 7 = chamadas de regra no emulador, `rules_budget`; coluna 8 = cobrança estimada, só smoke/console; N = 20 salvo indicação; escritas = 0 em **todas** as linhas):
| # | Cenário | `get` `shared_profiles` (`Source.server`) | Consultas da lista (documentos) | Agregadas | `readOwn` | Regra (`exists`) | Cobrança estimada |
|---|---|---|---|---|---|---|---|
| 1 | abrir a frio, lista em memória, dono já lido | 20 | 0 | 0 | 0 | 20 | ≈ 40 |
| 2 | abrir a frio, lista fria | 20 | 1 (20) | 0 | 0 | 20 | ≈ 60 |
| 3 | ranking como 1ª tela da sessão (aba aberta em `/#/ranking`) | 20 | 1 (20) | 1 (sessão) | 1 (sessão) | 20 | ≈ 62 |
| 4 | trocar filtro (qualquer número de vezes) | 0 | 0 | 0 | 0 | 0 | 0 |
| 5 | reabrir em 4:59 (lista e snapshots de t0) | 0 | 0 | 0 | 0 | 0 | 0 |
| 6 | reabrir em 5:00 (a lista venceu junto) | 20 | 1 (20) | 0 | 0 | 20 | ≈ 60 |
| 7 | reabrir em 5:00 com a lista relida por Amigos em t0+3 min | 20 | 0 | 0 | 0 | 20 | ≈ 40 |
| 8 | "Atualizar" em t0+10 s / t0+59 s | 0 | 0 | 0 | 0 | 0 | 0 |
| 9 | "Atualizar" em t0+60 s | 20 | 1 (20) | 0 | 0 | 20 | ≈ 60 |
| 10 | "Atualizar" em t0+60 s com a lista lida em t0+50 s | 20 | 0 | 0 | 0 | 20 | ≈ 40 |
| 11 | parcial (2 timeouts) + "Tentar novamente" | 20 + 2 | 0 | 0 | 0 | 22 | ≈ 36 + 4 (+ os 2 timeouts: cobrança não verificada) |
| 12 | disjuntor, N = 50 | 10 | 0 | 0 | 0 | ≤ 10 | ≤ 20 (não verificado) |
| 13 | cota na 3ª resposta (1ª e 2ª `ok`) | 12 | 0 | 0 | 0 | — | — |
| 14 | 1 negado | 20 | 0 | 1 | 0 | 20 | ≈ 38 + negação (≤ 1, não verificado) + 1 |
| 15 | 5 negados na mesma carga | 20 | 0 | **1** | 0 | 20 | ≈ 30 + ≤ 5 + 1 |
| 16 | perfil aberto pelo ranking no TTL | 0 | 0 | 0 | 0 | 0 | 0 (0 leitura do par: `extra`) |
| 17 | 80 amigos, lista fria, sinal já confirmado | 50 | 1 (51) | 0 | 0 | 50 | ≈ 151 |
| 18 | offline (abrir ou reabrir) | 0 | 0 | 0 | 0 | 0 | 0 |
| 19 | início de sessão com amizades ativas, sem abrir o ranking | 0 | 0 | 1 | 1 | 0 | ≈ 2 |
| 20 | início de sessão sem amizades ativas | 0 | 0 | 0 | 0 | 0 | 0 |
| 21 | remover o último amigo por mim | 0 | 0 | 0 | 0 | 0 | 0 (−1 local) |
| 22 | retorno do background (confirmado) | 0 | 0 | 0 | 0 | 0 | 0 |
| 23 | troca de conta | — | — | 1 (nova conta) | 1 (nova conta) | — | ≈ 2 |
| 24 | reconexão com a 1ª contagem falhada | 0 | 0 | 1 | 0 | 0 | 1 |
Escrita local permitida: só a pista Hive `friendsHint:{uid}`, gravada quando o valor confirmado muda.

**Abrir a frio** (cache vazio): N = 1 ⇒ 3 / 2; 5 ⇒ 15 / 10; 10 ⇒ 30 / 20; 20 ⇒ 60 / 40; 50 ⇒ 150 / 100; 100 ou 300 (limite 50) ⇒ 151 / 100 (lista fria / lista em memória). O `limit + 1` só cobra um documento a mais quando N > 50.
**Por dia** (hipótese do PA: 100 usuários sociais ativos, 3 sessões, 2 aberturas frias/dia, 10 amigos em média): 100 × 2 × 30 = 6 000 + sinal 300 ⇒ **≈ 6 300 (12,6%)**. Somado às Fases 1–2 (≈ 10,3 mil): **≈ 16,6 mil/dia (≈ 33%)**. Bytes: 3–8 KB por documento típico (≤ 30 KB com 50 recomendados): 50 amigos ≈ 0,15–1,5 MB por abertura fria.
**Uso pesado acidental**: com 15 s, 50 amigos e "Atualizar" sem parar por 1 h ⇒ 24 mil leituras; com **60 s** (N1): ≈ 6 mil/h. Um script com o próprio login lê o que quiser de qualquer forma (risco de plataforma).

## 13. Rollout e rollback
1. **Hotfix A2**: **publicado** (`main` 9389bc5, docs/92). Nada a fazer.
2. **Regras: nada a publicar.** Gate da Fatia 0: `rules_sha.test.mjs` verde (sha256 = `6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612`) e suíte de regras inteira verde (a atual + `ranking.test.mjs`). Passo novo na CI (SRE), antes do build: `echo "6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612  firestore.rules" | sha256sum -c -`.
3. **Índices: nada.** A contagem e a lista usam o índice automático de `members`.
4. **Política** (`web/privacidade.html`, RF-V6, data nova) **junto ou antes** do app da Fatia 3.
5. App (merge/deploy das Fatias 1–3; a 1 e a 2 não mostram nada ao usuário).
**Rollback**: só do app (o ranking não grava nada no servidor). A pista `friendsHint` fica no Hive e é ignorada pela versão anterior (chave nova).

## 14. Plano de testes
Os oráculos O1–O11 (aqui) e T1–T3 (docs/90) viram testes parametrizados linha a linha. Asserção global em todo arquivo de controller e widget: **0 escritas** no log (motor do snapshot parado).

### 14.1 Regras (Fatia 0, emulador, sem mudar `firestore.rules`)
`firestore_rules_test/ranking.test.mjs`:
- `get` de `shared_profiles/{x}`: dono; amigo mútuo (12, janela de 10 paralelos); não amigo; ex-amigo (par apagado depois de existir); refeito amigo (par recriado ⇒ lê de novo); bloqueado (Ana→X e X→Ana); anônimo; `password`; sem claim; **conta em exclusão com o par presente** (`get` permitido, documento inexistente).
- `getDocs(collection('shared_profiles'))`, `where(documentId(), 'in', [3 amigos])`, `in` misto (amigo + não amigo) e `in` com 10 amigos: **todos negados**.
- Consentimento: `sharing` sem `stats` não aceita `stats` (create e update); update que tira `sharing.stats` mantendo `stats` negado; o amigo lê o documento sem o campo; `get` de amigo com `stats` ausente devolve o documento sem `stats`.
- Documentário de `rankOk`: `Infinity`, `1e300`, `1.5`, `month > total` **aceitos**; `NaN`, `-Infinity`, `-1` negados (avisa se as regras endurecerem).
- **Sinal D7**: `count()` de `friendships where members array-contains <me> limit 300` permitido ao membro; a mesma consulta com o uid de outra pessoa, negada.
- Amigo não escreve no documento de outro (reexecuta o caso da F2).
- `rules_budget`: `get` de amigo ≤ 1 `exists`.
**Gate de sha em arquivo próprio**: `firestore_rules_test/rules_sha.test.mjs` (lê `../firestore.rules`, compara o sha256). Ele **não** entra em `SP`/`SUITES` nem em nenhuma lista de suítes de mutante em `mutations.mjs` (que hoje são explícitas, linhas 12 e 298); `npm test` (`node --test`) o executa junto com os demais. Motivo (QA B11): qualquer mutação muda o sha, então o gate dentro das suítes dos mutantes "mataria" todos sem provar nada.
**Mutantes RK*** (`mutations.mjs`, suítes = `ranking.test.mjs` + as atuais, nunca `rules_sha.test.mjs`): `allow list: if false` → `if request.auth != null` (morto por `getDocs`); → `if isFriend(resource.id, request.auth.uid)` (morto por `in` só de amigos); `isFriend` → `true` no `get` (morto pelo não amigo); `isGoogle()` removido do `get` (morto por `password`/anônimo); `('stats' in d) == ('stats' in s)` removido (morto pelo consentimento); agregada de `friendships` aberta a não membros (morto pela consulta com o uid de outra pessoa). Cada um precisa morrer num teste que não seja o de sha.

### 14.2 Unitário puro (VM **e** `flutter test --platform chrome`)
Arquivos sem `dart:io`, Hive ou Firebase: `ranking_reading_test` (O2, O3, O6), `ranking_table_test` (O1 + propriedade de embaralhamento), `ranking_period_test` (O4, O5), `ranking_texts_test` (T1 literal: valores, horas nos limites, Semantics, plural), `ranking_filter_test` (T2: parse e canônico). Os quatro primeiros entram no passo Chrome **já existente** da CI (`Test (web semantics, Chrome)`), ao lado de `shared_reading_web_safe_test.dart` e `qa_a2_friend_profile_test.dart`. `friends_count_controller_test` (O7, `fake_async`, `Completer`) roda na VM.

### 14.3 Controller com fakes
`ranking_controller_test` sobre `InMemorySharedProfileDataSource`/`FakeSharedProfileCloud` ampliados com: contador por uid e por tipo (get, consulta da lista com nº de documentos, agregada, `readOwn`, escrita), `Source`, **pico de simultaneidade** e instante de início/fim de cada leitura, falhas injetáveis por uid e por ordem de chegada (`ok`, `not-found`, `permission-denied`, `unavailable`, `resource-exhausted`, `unauthenticated`, timeout injetável com resposta tardia via `fake_async`), `fromCache` e conectividade falsa. Oráculos: O9, O10, O11 linha a linha.

### 14.4 Widget com fakes (VM)
`ranking_navigation_test`, `ranking_screen_test`, `router_ranking_redirect_test` (padrão `router_profile_redirect_test`):
- Entrada aparece e some **sem recarregar** (aceitar, remover o último, bloquear, recontagem 0, pista) nas **4 entradas** em 320/375/768/769/1024/1440 px; barra inferior com Perfil selecionado em `/ranking`; `rankingIconFits` na escala de saída ±0,01 em 320/375; menu do topo na largura mínima e 1 px abaixo.
- Redirect: cada linha de O8; saída quando empilhado (§8.3: sem SnackBar fora do ranking; "Voltar" não mostra o ranking); recarregar com query; T2 inteira; voltar do AppBar depois de 3 trocas de filtro.
- Filtros: troca reordena com 0 leituras; URL atualizada; anúncio do resumo.
- Todos os estados do §11 com textos literais (T1).
- Matriz 320/375/768/1024/1440 × 1×/2×/3× × claro/escuro com apelidos de 40 caracteres: `tester.takeException()` nulo, sem rolagem horizontal, reticências e texto completo no Semantics; foto que falha cai no fallback.
- Teclado e Semantics: T3 por `sendKeyEvent(Tab)` e `find.bySemanticsLabel` literal; Enter e Espaço na linha.
- Política: teste literal do `PrivacySummary`.
O histórico do navegador (`Router.neglect`) e o "Voltar" do navegador ficam no smoke (docs/93 §5).

### 14.5 Mutações Dart (todas devem morrer; `tool/dart_mutations.py`, inclusive com `--platform chrome`)
- Ordenação: numeração densa; "Você" primeiro no empate; desempate sem `collationKey`; `compareTo` cru; horas pela hora exibida; desconhecido como 0; 0 como desconhecido; desconhecidos antes; `tied` falso no 1º do grupo; `nobodyScored` exigindo todos conhecidos.
- Leitor: chave futura ⇒ 0; chave ilegível ⇒ 0; chave antiga ⇒ "—"; mês no fuso do leitor; `agora` sem `max(updatedAt)`; `max` sem a minha linha; coerência removida; coerência com o 0 de chave antiga; coerência em todas as métricas; tetos da minha linha removidos.
- Marcador: `>= 7`; `updatedAt` ausente sem marcador; `calc` ignorado; marcador na minha linha.
- Carga: janela de 50 ou sem limite; lotes em degraus; disjuntor removido; disjuntor sem segurar a janela (X = 19); cota sem cancelar; resposta após cota/offline/saída gravada no cache; resposta tardia após timeout aceita; `denied` em `notSharing` ou `failed`; `denied` sem `dropLocal`/`cache.remove`; recontagem por negação (k em vez de 1); geração removida; offline mostrando cache ou minha linha; "Tentar novamente" relendo todos; filtro disparando leitura; TTL ignorado; `force` sempre; cooldown removido; cooldown no "Tentar novamente"; âncora do cooldown = hora da reabertura; limite de 50 removido; considerados = 1ª página em vez de `items.take(50)`; minha linha lida do servidor; minha linha com `!confirmed`; faixa D9 com `meSharing == null`; qualquer escrita.
- Sinal e rota: agregada a cada navegação; resposta em voo não descartada; gancho do `add` depois do retorno antecipado; `add` duplicado contado 2×; ajuste local que tira o `confirmed`; recontagem que zera o valor enquanto viaja (pisca); pista sem TTL; pista não limpa na troca de conta/exclusão; redirect em `pending`; entrada visível em `pending` sem pista; Ranking não sai primeiro da `MobileTopBar`; SnackBar fora da rota visível; `replace` trocado por `go` (perde o voltar).
- Textos: plural errado; separador de milhar ausente; "5 min" sem zero à esquerda em "1 h 05 min".

## 15. Riscos
| # | Risco | Mitigação | Residual |
|---|---|---|---|
| 1 | `Infinity`/`1e300`/não inteiro no snapshot de um amigo | hotfix A2 publicado (`readSafeInt` + tetos); coerência e chave estrita no ranking; testes no Chrome | número falso **plausível** (D12, aceito) |
| 2 | Bug só de dart2js passa pela CI | passo Chrome existente + arquivos do ranking | testes de widget só na VM |
| 3 | Ex-amigo visível pelo TTL | regras negam na próxima leitura; "Atualizar"; `denied` ⇒ revoga | ≤ 5 min do que já tinha visto (D8) |
| 4 | Entrada errada no início da sessão | pista com TTL 24 h; confirmação 1×/sessão; ajuste local conta como `allowed`; descarte só com ajuste em voo | segundos de entrada pela pista |
| 5 | Remoção feita pelo outro lado não esconde a entrada até a próxima descoberta | recontagem por negação; 1ª página do servidor; rota protegida | aceito (sem listener, D7) |
| 6 | Cota por "Atualizar" repetido | cooldown 60 s (N1); TTL; limite 50 | ≈ 6 mil/h numa pessoa insistente |
| 7 | Erro total lento | disjuntor que segura a janela | ≈ 8 s, 10 `get` |
| 8 | Fusos diferentes na virada do mês | documentado | até 28 h de intervalos diferentes |
| 9 | Relógio do aparelho adiantado | `ServerClock` quando amostrado | 0 indevido em "este mês" |
| 10 | Corrida ranking × perfil de amigo no mesmo uid | última escrita vence | ≤ 1 leitura duplicada |
| 11 | Layout do topo com mais um ícone/rótulo | regra de encaixe; entradas alternativas | ícone ausente em 320 px com fonte > 1,28× |
| 12 | Emulador × produção (cobrança de negação, timeout, agregada) | console de uso na 1ª semana; smoke | — |
| 13 | Divergência de "este mês" entre ranking e perfil de amigo (relógio errado; chave ilegível/futura) | documentado (N4, RF-L4) | aceito |
| 14 | Barra de endereço não refletir `push`/`replace` no web (`optionURLReflectsImperativeAPIs`) | spike no início da Fatia 3 (§9) | alternativa com `go` + origem, mesma T2 |
| 15 | O `max(updatedAt)` faz o "este mês" de um amigo depender de quem carregou | conjunto definido (O5), determinístico | aceito |

## 16. Fatias (atualizado em 2026-10-24; a antiga Fatia H, hotfix A2, já está em produção)
- **S. Um interruptor só** (docs/95, decisão do Manager de 2026-10-24): primeira fatia da Fase 3 (S0 orçamento de regras, S1 dados, S2 UI, S3 política, S4 fechamento).
- **0. Testes de regra** (backend; sem mudar regras): `ranking.test.mjs` (§14.1, inclui a agregada de `friendships` e a conta em exclusão), mutantes RK*, `rules_sha.test.mjs` fora das suítes dos mutantes; passo de sha na CI (SRE).
- **1. Domínio puro** (`lib/ranking/`): modelos, `RankingReading` (chave estrita, coerência, marcador, `fromOwn`), `RankingTable.rank` com o relógio, `RankingTexts`, `RankingFilter`; `FriendSharedView.calc`; testes O1–O6, T1, T2 na VM e no Chrome. Nada visível.
- **2. Dados e sinal**: `FriendsCountController` + pista + ganchos (§8.1), `rankingAccessProvider`; `RankingController` (considerados, janela + disjuntor, cache, fases, cooldown, minha linha); fakes ampliados. Oráculos O7–O11. Nada visível.
- **3. Rota, navegação e tela**: spike do §9 (barra de endereço); `/ranking` + redirect + saída quando empilhado; 4 entradas; barra inferior; filtros (T2) com `replace` + `Router.neglect`; tela, estados, foco (T3), matriz de layout; política (RF-V6) e README.
- **4. Fechamento**: review e QA integrados; smoke (docs/93 §5); checklist de release no modelo do docs/89 (ordem: política → app; regras: só conferir o sha).

## 17. Respostas ao PA e posição sobre D1–D16

### 17.1 A1–A11
- **A1 (minha linha)**: sim. `SharingState.doc` segue as escritas do motor na mesma sessão (`noteWritten(optimistic)` antes de enviar, `revertWrite` se falhar, `reloadAfterRefusal` na recusa); a leitura de sessão (`readOwn`) e as transações dos interruptores também o atualizam. Minha linha = `doc.stats` confirmado, **0 leituras extras** (§10.6).
- **A2 (dart2js)**: confirmado no spike (§5.1) e **resolvido** pelo hotfix A2 em produção (`main` 9389bc5, docs/92).
- **A3 (sinal)**: agregada com limite 300 = 1 leitura no Spark. Pista em Hive (`friendsHint:{uid}`, TTL 24 h). Reconciliação e corrida: §8.1 e O7.
- **A4 (leitura/cache)**: `FriendProfileCache` sem mudança; janela de 10 com disjuntor, timeout de 8 s, geração, cota cancela o resto (§10).
- **A5 (encaixe)**: `topBarFits(context, extraIcons)`; Ranking sai primeiro e fica à esquerda de Amigos (§9).
- **A6 (redirect)**: `rankingAccessProvider` no `refreshListenable`; `pending` mostra o esqueleto; saída quando empilhado (§8.3).
- **A7 (relógio)**: `ServerClock` + `max(updatedAt)` dos participantes (§7.3, O5).
- **A8 ("50 mais recentes")**: exigiria `orderBy(createdAt desc)` + índice composto e mudaria a lista da F1 ou uma consulta própria (+51 leituras). **Não agora**.
- **A9 (estrutura)**: §3 e §6.
- **A10 (testes de regra)**: §14.1; nada em `firestore.rules` muda; gate em `rules_sha.test.mjs`.
- **A11 (barra inferior)**: Perfil selecionado em `/ranking`, como em `/friends`.

### 17.2 D1–D16 (aprovadas pelo Manager em 2026-10-24, com estes refinamentos)
| D | Aprovado | Refinamento do Arquiteto incorporado |
|---|---|---|
| D1 | (a) | as 5 métricas validadas |
| D2 | (a) | — |
| D3 | Episódios · **Este ano** (Orquestrador) | sem query abre o último filtro da sessão (T2); resolve a ressalva dos primeiros dias do mês |
| D4 | (a) | competição, empate por minuto em horas, "Você" pelo apelido exibido, "empatado" em todo o grupo (O1) |
| D5 | (b) 50 | = `state.items.take(50)` na carga (§4.1) |
| D6 | (a) | Ranking à esquerda de Amigos no mobile; larguras do §9; Perfil selecionado |
| D7 | (a) | contador com ajustes, descarte em voo e 1 recontagem por carga com negação (O7) |
| D8 | (a) | cache compartilhado dá o perfil a 0 leituras |
| D9 | (a) | espera a confirmação do dono |
| D10 | (a) | `not-found` + sem `stats` + `stats` não mapa; nunca negados nem falhas |
| D11 | (a) | `inDays > 7` sobre o relógio do ranking; `updatedAt` ausente e `calc` < 1; nunca na minha linha (O6) |
| D12 | (a) | + chave ilegível/futura = "—"; coerência só com chave atual (O3, O4) |
| D13 | (a) | + disjuntor que segura a janela (O9) |
| D14 | (a) | T1 |
| D15 | (a) | `replace` + `Router.neglect` (pilha e histórico preservados) |
| D16 | (a) | confirmado no emulador |

### 17.3 Divergências com a 1ª versão do docs/90
Todas incorporadas no docs/90 em 2026-10-24: cooldown 60 s (RF-R11), janela deslizante + disjuntor (RNF4), sinal como contador (RF-V2), hotfix A2 separado (já publicado), conjunto considerado = `items.take(50)` (RF-R12), chave ilegível/futura = "—" (RF-R3), nota RF-R9 com o oráculo da F2.

## 18. Decisões aprovadas (Manager, 2026-10-24)
| # | Decisão | Aprovado |
|---|---|---|
| **N1** | Cooldown do "Atualizar" do ranking | **60 s**; a lista mantém 15 s |
| **N2** | Achado A2 em produção (F2) | hotfix independente — **publicado** (`main` 9389bc5, docs/92) |
| **N3** | CI com `flutter test --platform chrome` | **feito** (passo `Test (web semantics, Chrome)`); o ranking acrescenta os arquivos dele |
| N4 | Relógio | ranking com `ServerClock` + `max(updatedAt)`; perfil de amigo inalterado |
| N5 | Texto quando meu valor é desconhecido | "Sua posição: sem informação" |
| ADR-007 | Ranking no cliente, `get` por id, sem regra nova | **Aceita** |
