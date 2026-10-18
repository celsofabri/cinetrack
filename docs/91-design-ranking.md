# 91 - Design: Ranking entre amigos (Fase 3 de 5)

> Autor: Arquiteto · Data: 2026-10-18 · Base: `main` 827cec5 (Fases 1 e 2 em produção; `firestore.rules` publicado = sha256 `6135322e…e612`) · Branch: `feat/social-ranking`
> Entradas: [docs/90](./90-especificacao-ranking.md) (PA, D1–D16, A1–A11), [docs/82](./82-design-perfil-social.md) (§4.4 tetos, §5.1 períodos, §7.2 perfil de amigo, §11.1 cota), [ADR-006](./adr/adr-006-snapshot-perfil-social.md), [docs/87](./87-fatia3-perfil-de-amigo.md) (cache do perfil de amigo), [docs/50 §7](./50-design-amizades.md) (limites de chamadas), código em `lib/`.
> Decisão de arquitetura: [ADR-007](./adr/adr-007-ranking-no-cliente.md) (**Proposta**).
> **Nenhum código, regra ou arquivo existente do projeto foi alterado.** Os dois spikes (§4.3 e §5.1) rodaram em cópias descartáveis em `/tmp` (emulador do Firestore e `flutter test --platform chrome`). Onde divirjo do PA, digo onde e por quê (§17.3); o docs/90 não foi editado.
> ⚠️ **Achado de produção (A2, §5.1):** no Flutter web, `Infinity` e `1e300` passam em `v is int`. Hoje um amigo com cliente modificado consegue quebrar a seção de estatísticas do próprio perfil para os amigos dele. Severidade **baixa (P3)**, sem perda de dados nem vazamento. Proponho um hotfix só de app, independente da Fase 3 (§5.2, N2).

## Sumário
1. Contexto e NFR · 2. Opções · 3. Solução · 4. Acesso a dados e regras (spike) · 5. Leitor estrito (spike A2, hotfix) · 6. Função pura de ranking · 7. Períodos, fusos e relógio · 8. Sinal "≥ 1 amigo" e proteção da rota · 9. Navegação · 10. Controller, cache e concorrência · 11. Estados de UI · 12. Cota · 13. Rollout e rollback · 14. Plano de testes · 15. Riscos · 16. Fatias · 17. Respostas A1–A11 e posição sobre D1–D16 · 18. Decisões para o Manager

---

## 1. Contexto e requisitos não funcionais
O ranking compara **eu + amigos mútuos que compartilham "Estatísticas"** usando o snapshot `shared_profiles/{uid}.stats` da Fase 2 (fonte única, ADR-006). Spark: sem Cloud Functions, então a montagem é no cliente. Produção = **Flutter web (dart2js)**: os números chegam como números JS, e isso muda o comportamento de `is int` (§5.1).

| NFR | Alvo |
|---|---|
| Privacidade | só documentos que a regra atual libera (`isOwner \|\| isGoogle && isFriend`); `list` continua negado; nada gravado em disco; offline não mostra nenhum amigo |
| Escritas | **zero** (o ranking só lê) |
| Regras | **nenhuma mudança** (sha256 `6135322e…e612` mantido; orçamento de expressões intocado, ≈ 64% na pior escrita) |
| Cota | abrir a frio com N ≤ 50 amigos: 2N leituras (lista em memória) ou 3N (lista fria); trocar filtro = 0; reabrir no TTL = 0 |
| Latência | 50 amigos com 10 leituras simultâneas: ≈ 5 rodadas de ≈ 100–300 ms (estimativa, não medida); timeout de 8 s por leitura; pior caso de erro total ≈ 8 s (disjuntor, §10.3) |
| Robustez | valor não inteiro, não finito, acima do teto ou incoerente = desconhecido ("—"), nunca 1º lugar |
| Remoção | minha remoção ou bloqueio tira a pessoa na hora, sem leitura; a do outro lado vale na próxima leitura do servidor (risco D8 aceito) |
| Layout/a11y | 320–1440 px × fonte 1×/2×/3× × claro/escuro, teclado e leitor de tela (RNF7 do docs/90) |

## 2. Opções consideradas

**Eixo 1: como ler os N snapshots**
| Opção | Prós | Contras | Custo/Esforço |
|---|---|---|---|
| **A. `get` por id, até 10 em paralelo, sem mudar regra** | regra atual já permite (1 `exists` por leitura); ex-amigo afeta só a própria leitura; reaproveita `readFriend` e o cache do perfil de amigo; nada a publicar | N requisições (simultaneidade limitada a 10) | 2 leituras cobradas por amigo; esforço baixo |
| B. `list` com `documentId in [≤ 10]` (regra nova `allow list: if isFriend(resource.id, …)`) | menos requisições | **regra nova** (deploy antes do app, mais orçamento de expressões); um ex-amigo no lote **nega o lote inteiro** (docs/50 §7), então seria preciso refazer por `get` mesmo assim; mesmo custo cobrado (10 docs + 10 leituras de regra) | igual a A, com mais esforço e mais risco |
| C. Documento agregado "ranking" gravado por cada dono (fan-out) | 1 leitura | escrita em documento de terceiros (precisaria de regra por amigo); desfazer amizade exigiria reescrever dados (viola o §7 item 4 do docs/50); sem Functions | alto; descartada |
| D. Coleção `rank_entries` com consulta por amigo | consulta ordenável no servidor | 2ª fonte de estatísticas (o prompt proíbe); regras novas; sincronia | descartada |

**Eixo 2: sinal "tenho ≥ 1 amigo"**
| Opção | Prós | Contras |
|---|---|---|
| **a. Contagem agregada 1×/sessão + pista local + ajustes locais + recontagem quando algo foi revogado** | 1 leitura por sessão; segue o padrão do `ReceivedCountController` | remoção feita pelo outro lado só aparece quando o app descobre |
| b. Listener `friendships limit(1)` | tempo real | quebra o "sem listener" da Fase 1; +1 leitura por mudança; conexão aberta em todas as telas |
| c. Ler a lista inteira ao iniciar | sabe tudo | até 51 leituras por sessão para mostrar um ícone |

**Eixo 3: cache** — (i) **reaproveitar `FriendProfileCache`** (mesmo `Friend` + `FriendSharedView` + `at`, TTL 5 min, já limpo em troca de conta, período social, remoção e bloqueio); (ii) cache próprio do ranking (duplicaria a limpeza em 4 pontos e não daria "perfil aberto pelo ranking = 0 leituras"). Escolha: (i).

## 3. Solução escolhida
`get` por id (A), sinal por contagem (a), cache compartilhado (i). Ordenação e períodos ficam numa **função pura**, e os filtros só recalculam o que já está em memória.

```mermaid
flowchart LR
  subgraph Sessão
    FC[FriendsCountController\ncount() 1x/sessão + pista Hive\n+ ajustes locais] --> RA[rankingAccessProvider\npending/allowed/noSession/inactive/noFriends]
  end
  RA --> NAV[Entradas: menu do topo (desktop),\nMobileTopBar, Amigos, Perfil]
  RA --> RT[go_router redirect /ranking\nrefreshListenable]
  RC[RankingController] --> FL[FriendsController\n1ª página, ≤ 50, TTL 5 min]
  RC --> CACHE[(FriendProfileCache\nmemória, TTL 5 min)]
  RC -->|faltantes: pool de 10 get Source.server, 8 s| SP[(shared_profiles/{uid})]
  RC --> ME[SharingController.doc\nminha linha, 0 leituras]
  RC --> PURE[RankingReading.strict + RankingTable.rank\nfunção pura: métrica × período × agora]
  PURE --> UI[RankingScreen\n?estatistica=&periodo=]
  SP -. permission-denied .-> REV[_revoked: cache.remove +\nfriends.dropLocal + recontagem]
```

Componentes novos (nomes sugeridos; o dev pode ajustar):
| Peça | Onde | Tipo |
|---|---|---|
| `RankingMetric`, `RankingPeriod` (enums com slug da URL, rótulo, teto) | `lib/ranking/ranking_models.dart` | puro |
| `RankingReading.strict(...)` (leitor estrito, §5.3) | `lib/ranking/ranking_reading.dart` | puro |
| `RankingTable.rank(...)` (ordenação e empates, §6) | `lib/ranking/ranking_table.dart` | puro |
| `RankingTexts` (posição "3º", horas "1.234 h 05 min", Semantics) | `lib/ranking/ranking_texts.dart` | puro |
| `FriendsCountController` + pista local | `lib/providers/social_lists_providers.dart` (ao lado do `ReceivedCountController`) + `LocalStore` | Notifier |
| `rankingAccessProvider` | `lib/providers/ranking_providers.dart` | Provider |
| `RankingController` | `lib/providers/ranking_providers.dart` | AutoDispose Notifier |
| `RankingScreen` e widgets | `lib/screens/ranking_screen.dart`, `lib/widgets/ranking_widgets.dart` | UI |
| Correção `readSafeInt` (hotfix, §5.2) | `lib/shared_profile/shared_stats_reading.dart` e `shared_profile_models.dart` | puro |

Por que `lib/ranking/` e não `lib/shared_profile/` (A9): o leitor estrito é **só do ranking** (RF-L4) e a pasta `shared_profile` é o domínio do snapshot (dono e leitor tolerante). A correção de `readCount`, que vale para todos, fica em `shared_profile`.

## 4. Acesso a dados e regras

### 4.1 Leitura
- **Amigos considerados**: `FriendsController.state.items.take(kRankingMaxFriends = 50)`. As páginas são anexadas em ordem (docs/62), então os 50 primeiros são exatamente a 1ª página, seja qual for o "Ver mais" já carregado. Se a lista não está fresca, `ensureLoaded()` (TTL 5 min, ≤ 51 documentos com o `limit + 1`). Lista vinda do cache (`fromCache`) ⇒ trata como offline (D10 da F2).
- **Snapshot de cada amigo**: `SharedProfileRepository.readFriend(uid)` (já existe: `Source.server`, timeout `friendTimeout` = 8 s, falhas mapeadas em `SharedProfileFailureKind`). Resultado: `FriendSharedView?` (null = `not-found`).
- **Minha linha**: `sharingControllerProvider` → `SharingState.doc` confirmado (A1, §17.1). 0 leituras.
- **Nada de `list`/consulta** em `shared_profiles`.

### 4.2 Regras: nenhuma mudança (confirmado por raciocínio e spike)
`allow get: if isOwner(uid) || (isGoogle() && isFriend(uid, request.auth.uid))` cobre o ranking:
- amigo mútuo Google ⇒ lê (1 `exists`, dentro do limite de 10 por requisição de documento único, docs/50 §7);
- não amigo, ex-amigo (par apagado), bloqueado nos dois sentidos (o bloqueio apaga o par, invariante da F1), anônimo, conta não Google ⇒ negado;
- `allow list: if false` ⇒ qualquer consulta, inclusive `documentId in [amigos]`, negada;
- "Estatísticas" desligado ⇒ `stats` ausente, porque as regras exigem `('stats' in d) == ('stats' in s)` em toda escrita (`validShared`).

### 4.3 Spike no emulador (cópia descartável em `/tmp/spike_rules`, regras com sha idêntico ao da `main`)
| Experimento | Resultado |
|---|---|
| Ana lê 12 amigos por `get`, em lotes de 10 paralelos (`Promise.all`) | ✔ todos lidos |
| Não amigo / Ana bloqueou Dora / Bruno bloqueou Ana / ex-amigo (par apagado) / conta `password` | ✔ todos negados |
| `getDocs(collection)` e `where(documentId(), 'in', [3 amigos])` | ✔ negados |
| Criar documento com `stats` mas `sharing: {activity}` | ✔ negado (sem consentimento, sem `stats`) |
| Criar com `total.minutes` = `Infinity` / `1e300` / `1.5` | **aceito** (o amigo lê `Infinity` como número JS) |
| Criar com `NaN` / `-Infinity` | negado |
| Criar com `month.watchedMovies = 999999 > total = 1` | **aceito** |

Conclusão: o acesso já é o que o ranking precisa, e as regras **não** garantem números sãos. O leitor estrito (§5) é obrigatório e não opcional. Endurecer `rankOk` (`is int` + tetos nos 15 campos) custaria ≈ 30 expressões a mais numa escrita que já está em ≈ 64% do limite e exigiria publicar regras. Não recomendo nesta fase (registrado como opção rejeitada no ADR-007).

## 5. Leitor estrito, achado A2 e hotfix

### 5.1 Spike A2 (`/tmp/spike_a2`, cópia de `lib/`, Flutter 3.47.5)
`flutter test --platform chrome` (dart2js) × `flutter test` (VM), com valores criados por `double.parse`, `jsonDecode`, `eval` JS + `dartify()` e `jsify().dartify()` (o caminho do plugin web):

| Valor | web: `is int` | web: `readCount` | VM: `readCount` |
|---|---|---|---|
| `Infinity` | **true** | **Infinity** | null |
| `NaN` | false | null | null |
| `1e300` | **true** | **1e+300** | null |
| `12.5` | false | null | null |
| `12.0` | true | 12 | **null** |
| `-Infinity` | true | null (`< 0`) | null |
| `2^53 + 2` | true | 9007199254740994 | null |

Efeito no código de produção (mesmo spike):
- `FriendSharedView.parse` com `Infinity` em `total.minutes`/`watchedEpisodes` ⇒ `minutes = Infinity`, `episodes = Infinity`.
- `WatchTimeFormatter.format(Infinity)` e `accumulatedHours(Infinity)` ⇒ **`UnsupportedError: Infinity`** (o `~/` do dart2js). `SharedStatsView.build` chama `format` ⇒ a **seção de estatísticas inteira do perfil daquele amigo** vira o `ErrorWidget` (caixa cinza no release) para todos os amigos dele. As contagens aparecem como "Infinity".
- `1e300` não quebra, mas vira texto absurdo ("1.9025875190258753e+294 anos, 10 meses e 24 dias").
- Itens de atividade/recomendados (`id`, `count`, `season`, `episode` com `is int`) também aceitam `Infinity`/`1e300`. As regras não validam esses itens (docs/82 §4.4, camada D). Efeito: links `/tv/Infinity` (a rota cai em "não encontrado") e textos absurdos. Não encontrei travamento nesse caminho, mas não verifiquei todos os usos (confiança média).
- `recs.count` está protegido: a regra exige `count is int` (um `Infinity` é float nas regras).
- O leitor do **próprio** documento (`_nonNegInt`, `SharedProfileDoc`) tem o mesmo padrão, mas só o dono grava ali (autodano).

**Severidade: baixa (P3).** Quem explora é um **amigo mútuo** que grava o próprio documento por fora do app oficial (SDK JS com o próprio login). O efeito é a seção de estatísticas **do perfil dele** quebrada ou absurda para os amigos. Não há perda de dados, não há vazamento, nada se propaga para outras telas da F2 e o resto do app continua funcionando. **Na F3 seria pior** sem o leitor estrito: um `Infinity` ficaria em 1º e o formatador quebraria a tela de ranking de todos os amigos do atacante. O leitor estrito (§5.3) protege o ranking por conta própria (tetos), com ou sem o hotfix.

Por que os testes atuais não pegaram: a CI (`deploy-pages.yml`) roda só `flutter test` (VM). Na VM, `Infinity is int` é falso, mas a produção é dart2js.

### 5.2 Hotfix proposto (independente da Fase 3; só app; sem regra)
Um único leitor de inteiro seguro, válido nas duas plataformas (validado no spike, VM e Chrome):
```dart
const kMaxSafeInt = 9007199254740991; // 2^53 - 1

/// A non-negative whole number within [max], else null. Web: a JS number
/// that is integral "is int" (Infinity and 1e300 too), hence the bound;
/// VM: a Firestore doubleValue like 12.0 is a double, hence the second arm.
int? readSafeInt(Object? v, {int min = 0, int max = kMaxSafeInt}) {
  int? n;
  if (v is int) {
    n = v;
  } else if (v is double && v.isFinite && v == v.truncateToDouble()) {
    n = v.toInt();
  }
  if (n == null || n < min || n > max) return null;
  return n == 0 ? 0 : n; // -0 on the web
}
int? readCount(Object? v) => readSafeInt(v);
```
- Aplicar em `readCount`, `_nonNegInt`, `ActivityItem.tryParse` (`id` 1..`kMaxSharedId`, `count` 1..`kMaxActivityCount`, `season` 0..`kMaxSeasonNumber`, `episode` 0..`kMaxEpisodeNumber`) e nos dois leitores de item de recomendado (`id` 1..`kMaxSharedId`). Os tetos são os da tabela docs/82 §4.4.
- Defesa em profundidade: `WatchTimeFormatter.format/accumulatedHours` passam a limitar a entrada a `kMaxSharedMinutes` (nunca lançam).
- Testes: `test/shared_reading_web_safe_test.dart` (sem `dart:io`/Hive), rodado **na VM e com `--platform chrome`**, com as linhas da tabela §5.1 + widget `SharedStatsView.reading` com `Infinity` (não lança, mostra "—").
- CI: passo novo `flutter test --platform chrome test/shared_reading_web_safe_test.dart test/ranking_reading_test.dart` (os runners `ubuntu-latest` do GitHub trazem Chrome). Dono: SRE (N3).
- Compatibilidade: um `12.0` vindo da VM passa a ser 12 (antes "—"); nada mais muda para dados gravados pelo app oficial (inteiros ≤ tetos).

### 5.3 Leitor estrito do ranking (RF-L)
Entrada: `SharedStatsReading` (já tolerante e, com o hotfix, só inteiros seguros), `tz`, `updatedAt`, `calc`, chaves atuais `(monthKey, yearKey)` do dono. Saída: `RankingStats` = mapa `(métrica, período) → int?` + `stale` + `undated`.
1. Valor por período: Total = `total.<m>`; Este ano/mês = `PeriodReading.current(key)` (chave antiga ⇒ 0; chave ausente ⇒ desconhecido, §7.2).
2. **Estrito**: aceita só se `readSafeInt(v, max: teto(m))`, com teto = `kMaxSharedWatchedEpisodes` (1 000 000) para episódios, `kMaxSharedMinutes` (52 560 000) para minutos e `kMaxSharedFavorites` (100 000) para filmes, séries assistidas e concluídas. É redundante com o hotfix de propósito: o ranking não depende de o hotfix ter entrado.
3. **Coerência por métrica** (RF-L2): se `month` e `year` são do período atual e `month > year`, ou `year > total`, ou (`year` é antigo e `month` atual, o que é impossível pelas regras de chave) ⇒ os três valores **dessa métrica** ficam desconhecidos. Com `year` atual e `month` antigo (mês virou), só `year ≤ total` é checado.
4. `stale` = `updatedAt == null` **ou** dias inteiros desde `updatedAt` > 7 **ou** `calc < kMinRankingCalc (1)` (§11, D11).
5. `undated` = `undatedMovies + undatedEpisodes > 0` (nota RF-R9).
6. `tz` fora da faixa já vira 0 no `FriendSharedView.parse` (inalterado).
O leitor não lança: qualquer entrada vira número ou desconhecido.

## 6. Função pura de ranking
```dart
class RankingParticipant {
  final String uid; final String name; final String? photoUrl;
  final bool isMe; final RankingStats stats; final DateTime? updatedAt;
}
class RankingRow {
  final RankingParticipant who;
  final int? value;      // null = desconhecido ("—")
  final int? position;   // competição: 1, 1, 3; null para desconhecido
  final bool tied;       // outra linha com o mesmo valor
  final bool stale;
}
class RankingResult {
  final List<RankingRow> rows;
  final int ranked;          // linhas com posição ("de N")
  final int? myPosition;     // null: não estou ou meu valor é desconhecido
  final bool nobodyScored;   // ranked > 0 e todos os valores == 0
  final bool undatedNote;    // período ≠ total e algum participante com undated
}
RankingResult rank(List<RankingParticipant> ps, RankingMetric m, RankingPeriod p);
```
Algoritmo (determinístico, O(n log n), n ≤ 51):
1. `value = who.stats[(m, p)]`.
2. Conhecidos: ordena por `value` desc, depois `collationKey(name)` asc (a mesma da lista de Amigos), depois `uid` asc. "Você" não tem prioridade e ordena pelo **próprio apelido** (exemplo do docs/90: "Zé = Você, Ana 5" ⇒ Ana, Zé).
3. `position = 1 + |{conhecidos com valor > v}|` (competição). `tied = |{conhecidos com valor == v}| > 1`.
4. Desconhecidos no fim, ordenados por `collationKey(name)`, depois `uid`, sem posição.
5. Horas: ordena e empata por **minutos** (o valor da métrica `hours` é `minutes`). A exibição (D14) é só formatação.
Testes 1:1 com a tabela de empates do docs/90 (§14).

## 7. Períodos, fusos e relógio

### 7.1 "Este mês" entre amigos em fusos diferentes
Cada participante é medido **no próprio mês, no fuso dele** (`periodKey(agora, tz_dono)`, a mesma regra B1 da F2). É a única leitura possível com o snapshot: ele guarda só **um** recorte de mês (o do momento do cálculo, no fuso do dono). Usar o mês do **leitor** para todos daria 0 ou "—" justamente para quem já virou o mês. Consequência aceita: perto da virada (até 28 h, com fusos de −14 h a +14 h), os "este mês" cobrem intervalos diferentes. No Brasil (−3/−5) o efeito é de poucas horas. Nenhuma mudança de schema.

### 7.2 Chave de período velha: **0** (decisão)
O motor da F2 regrava o mês ao virar (wake no app aberto) e em toda mudança de favoritos. O pulso de 24 h só grava `updatedAt` quando o conteúdo, **incluindo a chave do mês**, não mudou. Logo, **chave velha ⇔ o dono não abriu o app (com o motor) desde a virada**. Nesse caso, o que o app registrou dele neste mês é de fato 0.
- **0** (escolhido): coerente com o perfil de amigo (todos os leitores veem o mesmo número), ranqueado normalmente (quase sempre empatado em 0) e, se `updatedAt` passou de 7 dias, com o marcador "Atualizado há N dias".
- "Desconhecido" (rejeitado): esconderia do ranking do mês, no dia 1, todo mundo que ainda não abriu o app, e jogaria essas pessoas para o fim sem posição.
- Resíduo: marcações feitas num app antigo (sem motor) ou paradas na fila offline não aparecem até o próximo recálculo (risco já aceito na F2).
- Chave **ausente ou ilegível** (schema antigo/novo) ⇒ desconhecido (RF-R3).

### 7.3 Relógio (A7)
`agora` do ranking = `max(serverClock.now(), maior updatedAt entre os documentos carregados)`.
- `ServerClock` (já existe) corrige o relógio pelo desvio do servidor quando há amostra (escritas do próprio usuário). Sem amostra, é o relógio do aparelho.
- O `max` com `updatedAt` (hora do servidor, sempre ≤ agora real) corrige o caso **relógio atrasado**: um amigo que já gravou "2026-11" nunca é lido como "mês antigo" por um aparelho ainda em outubro. Um aparelho **adiantado** continua errado (vê 0 em "este mês"); não há fonte de hora melhor sem leitura extra (aceito).
- O perfil de amigo (F2) continua com `sharedProfileClockProvider`. Divergência possível só com relógio do aparelho errado em horas ou dias (aceito, N4). O provider de relógio do ranking é injetável para testes (relógio falso nos dois).
- Virada de mês com a tela aberta: o `agora` é lido em cada `build` da tela (sem leitura de rede) e um `Timer` para a próxima virada do **leitor** força um rebuild (barato). As viradas dos amigos aparecem na próxima renderização.

## 8. Sinal "≥ 1 amigo" e proteção da rota

### 8.1 `FriendsCountController` (A3)
Estado: `{int? count, bool confirmed, bool loading}`; `hasFriends = (count ?? 0) > 0`. Segue o padrão do `ReceivedCountController` (sem listener).
| Evento | Efeito | Leituras |
|---|---|---|
| `build` (troca de uid / `socialPeriodProvider`) | estado vazio; carrega a **pista** `friendsHint:{uid}` (Hive `_discoveryBox`, `{has, at}`, TTL 24 h como `socialHint`) | 0 |
| Shell visível e `socialActiveProvider` verdadeiro (pós-frame, mesmo gancho do `BadgeRefresher`) | `ensureConfirmed()`: se não confirmado nesta sessão, `countFriends()` (agregada, `AggregateSource.server`, limite 300) | **1 por sessão** |
| Resposta da contagem | se **nenhum ajuste local aconteceu enquanto ela viajava** ⇒ `count = n, confirmed`; senão **descarta** (fica o valor local, ainda não confirmado; nova tentativa no próximo gatilho) | — |
| Falha (offline, unavailable) | mantém pista/valor; nova tentativa na próxima reconexão real (`fromCache` → servidor) ou retorno ao app, no máximo 1 por evento | ≤ 1 por evento |
| `FriendsController.onFirstPage` (lista lida do **servidor**) | `!hasMore` ⇒ `count = items.length, confirmed`; `hasMore` ⇒ `count = max(count, items.length + 1)` | 0 |
| `FriendsController.add` (aceite, pedido cruzado, convite; chamado também quando a lista não está carregada) | `count = (count ?? 0) + 1` | 0 |
| `FriendsController.remove` / `block` com sucesso (sabe que era amigo) | `count = max(0, count − 1)` | 0 |
| `afterBlock` vindo de busca/pedido | `dropLocal` retornou true ⇒ −1; lista carregada e completa sem a pessoa ⇒ nada; senão **invalida** (recontagem) | 0–1 |
| `_revoked` (perfil de amigo ou ranking receberam `permission-denied`) | **invalida** e reconta (o outro lado pode já ter saído da contagem; −1 poderia contar em dobro) | 1 por revogação |
| Confirmado | grava a pista `has` (só se mudou) | 0 |

Limpeza: `account_providers` (exclusão) e a desativação de amizades apagam `friendsHint:{uid}` junto com `socialHint`/`sharedHint`.

**Cobrança da contagem no Spark:** 1 leitura por lote de até 1000 entradas de índice, com mínimo de 1 por consulta (documentação de preços do Firestore, já usada na F1 para o badge). Com o limite de 300 amigos: **1 leitura**. Não medido em produção.

### 8.2 `rankingAccessProvider`
| Condição (em ordem) | Valor |
|---|---|
| sessão carregando | `pending` |
| sem sessão | `noSession` |
| não Google ou `SocialPhase.inactive/unavailable` | `inactive` |
| `SocialPhase.loading` sem pista ativa, ou `loadFailed` | `pending` |
| amizades ativas (ou pista ativa) e `confirmed && count == 0` | `noFriends` |
| amizades ativas e `count > 0` (confirmado **ou** pista `has = true`) | `allowed` |
| restante (sem pista, sem confirmação) | `pending` |
**Entrada visível ⇔ `allowed`.** Todos os pontos de entrada fazem `watch` no provider. Por isso a entrada **some sem recarregar** quando o último amigo sai por ação deste aparelho, ou quando a recontagem confirma 0.

### 8.3 Rota (A6)
- `redirect` global ganha `/ranking`: `noSession ⇒ '/'`; `inactive | noFriends ⇒ '/friends'`; `pending | allowed ⇒ null` (a tela mostra o esqueleto enquanto `pending`, como `/profile`).
- `routerProvider`: `ref.listen(rankingAccessProvider, (_, _) => refresh.value++)` além de `authStateProvider`. O go_router reavalia o redirect da rota atual; com `/ranking` aberto e o sinal indo a `noFriends`, vai para `/friends`.
- Aviso RF-V3: a `RankingScreen` faz `ref.listen(rankingAccessProvider)` e, ao ver `allowed/pending → noFriends`, mostra o SnackBar "Você não tem mais amigos no CineTrack." no `ScaffoldMessenger` raiz, que sobrevive à navegação. Assim o aviso só aparece para quem estava no ranking.
- Recarregar `/#/ranking?estatistica=horas&periodo=ano`: `pending` no início ⇒ sem redirect; a query é preservada.

## 9. Navegação (A5, A11)
**Desktop (> 768 px)**: no menu do topo da Início, `_NavAction(label: 'Ranking', icon: Icons.leaderboard)` **depois de Amigos**, só com `allowed`, com `context.push('/ranking')` (padrão de Amigos). Nova largura mínima de rótulos: `kTopMenuLabelsMinWidth (960) + Amigos (120) + kTopMenuRankingExtraWidth`. Proposta de **130 px**, a confirmar por teste de widget (sem overflow em 1× exatamente na largura mínima, só ícones 1 px abaixo). Com tudo ligado, os rótulos aparecem a partir de ≈ 1210 px; em 1024 o menu fica só com ícones e tooltips.
**Mobile (≤ 768 px)**: na `MobileTopBar`, `IconButton(Icons.leaderboard_outlined, tooltip: 'Ranking')` **à esquerda de Amigos** (Amigos e Buscar não mudam de lugar quando o Ranking aparece ou some). Regra de encaixe generalizada:
```dart
bool topBarFits(BuildContext c, int extraIcons) {
  const padding = 32.0, button = 48.0, sync = 32.0, logo = 32.0, gap = 8.0;
  final room = width - padding - button /*busca*/ - sync - button * extraIcons;
  return room >= logo + gap + kBrandNameMinWidth * scale;
}
friendsIconFits(c) == topBarFits(c, 1)   // inalterado
rankingIconFits(c) == topBarFits(c, 2)   // Ranking é o primeiro a sair
```
Contas: em 320 px os dois cabem até ≈ 1,28× de fonte; em 375 px, até ≈ 2,27×. Abaixo disso, o Ranking some (Amigos continua, como hoje).
**Entradas alternativas sempre presentes com `allowed`**: botão "Ver ranking" no topo da tela Amigos (todas as larguras) e item "Ranking" na seção Amizades do Perfil. Com fonte 3× em 320 px, o ranking fica a 1 toque de Amigos/Perfil.
**Barra inferior**: inalterada (5 destinos). Em `/ranking`, o selecionado é **Perfil**: `AppShell` passa a tratar `location.startsWith('/ranking')` como `/friends` (A11: confirmo, mesmo padrão).
**Filtros na URL (D15)**: `/ranking?estatistica=<filmes|series|concluidas|episodios|horas>&periodo=<total|ano|mes>`. A troca de filtro usa `Router.neglect(context, () => context.go(uri))`, que **não cria entrada no histórico** do navegador: "Voltar" sai do ranking em vez de percorrer os filtros (testável). Valor inválido ⇒ padrão (D3).
**Desktop, cabeçalho da tela**: AppBar "Ranking" com voltar (como Amigos). Mobile: sem AppBar (`MobileShellScope`), título no corpo.

## 10. Controller, cache e concorrência (A4)

### 10.1 Estado
```dart
enum RankingPhase { loading, content, offline, error, quota, sessionExpired }
class RankingState {
  final RankingPhase phase;
  final List<RankingParticipant> friends;   // só quem tem stats
  final RankingParticipant? me;             // null: não compartilho / não confirmado
  final bool? meSharing;                    // null = ainda não confirmado (faixa D9 espera)
  final int notSharing;                     // not-found + sem stats (D10)
  final Set<String> failed;                 // unavailable/timeout (D13)
  final int? limitedTo; final int? totalFriends; // RF-R12
  final DateTime? loadedAt; final bool refreshing;
}
```
A tela calcula `RankingTable.rank(...)` no `build` a partir de `state` + filtros da URL + `agora` (0 leituras ao trocar filtro).

### 10.2 Carga
1. Geração (`_generation`) incrementada em `build`, que observa `currentUidProvider` e `socialPeriodProvider` (troca de conta ou desativação ⇒ estado novo; o `FriendProfileCache` também é recriado). Depois de cada `await`: `if (gen != _generation) return`.
2. Offline (`syncStatus.offline`) ⇒ `offline` (nem a minha linha aparece, RF-E3). `ref.listen` no offline durante a tela, igual ao `FriendProfileController` (cai para offline; ao voltar, recarrega, do cache se fresco).
3. Lista de amigos (`ensureLoaded`, ou `refresh` no "Atualizar"). Falha ⇒ fase pela falha (quota/sessão/erro/offline). Lista vazia e completa ⇒ o `FriendsCountController` recebe 0 pelo `onFirstPage` ⇒ redirect.
4. Para cada um dos ≤ 50: se `!force && !status.fromCache` e `cache.fresh(uid, agora, 5 min)` ⇒ usa. Os demais entram na fila de leitura.
5. **Pool de 10 leituras simultâneas** (janela deslizante, não lotes em degraus: um lento não segura os outros 9), cada uma com o timeout de 8 s já existente. Resultado por amigo: `ok(view?)` / `denied` / `failed(kind)`.
   - `ok` ⇒ `cache.put(uid, FriendProfileEntry(friend, view, at: agora))`, e o perfil aberto pelo ranking custa 0 leituras dentro do TTL (RF-R8). `view == null` ou `view.stats == null` ⇒ `notSharing++`.
   - `denied` ⇒ `_revoked(uid)`: `cache.remove`, `friendsController.dropLocal`, `friendsCount.invalidate()`. Some em silêncio (não entra em `notSharing` nem em `failed`).
   - `quota` ⇒ **cancela o resto** (não inicia novas leituras), fase `quota`, nada parcial (RF-E4). `sessionExpired` ⇒ idem, fluxo existente.
   - `unavailable/timeout/unknown` ⇒ `failed`.
6. **Disjuntor**: se as **primeiras 10 respostas** forem todas `failed` (nenhum `ok`/`denied`), cancela o resto e vai para `error` (ou `offline`, se o aparelho souber). O erro total fica em ≈ 8 s, não 40 s.
7. Fim: `failed` vazio ⇒ `content`; parcial ⇒ `content` + aviso (D13); todos falharam ⇒ `error`. Se a conexão caiu enquanto as respostas viajavam ⇒ `offline` (como o perfil de amigo).
8. Uma carga por vez: um segundo pedido se junta à carga em curso (`_inFlight`).
9. "Tentar novamente" do aviso parcial ⇒ relê só `failed` (`force` para esses uids).
10. **"Atualizar"** ⇒ lista (`FriendsController.refresh`, com o cooldown de 15 s **dela**) + todos os snapshots com `force`, com cooldown **do ranking de 60 s** (N1) desde `loadedAt`. Dentro do cooldown: "A lista já está atualizada." O ranking anterior fica visível com progresso no botão.

### 10.3 Concorrência com o perfil de amigo
Os dois controllers escrevem no mesmo cache, e a última escrita vence (as duas leituras são do servidor e equivalentes). Abrir o perfil de alguém enquanto o ranking ainda o lê pode gerar 1 leitura duplicada: aceito (raro, ≤ 2 leituras). Não proponho "single-flight" compartilhado, porque mexeria no `FriendProfileController`, que está em produção e testado.

### 10.4 Minha linha
`ref.watch(sharingControllerProvider)`: `confirmed && doc.sharing.contains(stats) && doc.stats != null` ⇒ participante "Você" com `SharedStatsReading.of(doc.stats!)`, `tz = doc.tz` e `updatedAt = doc.updatedAt`, pelo mesmo leitor estrito (os números são os que os amigos veem, inclusive no atraso de W = 5 s). `confirmed && !stats` ⇒ `meSharing = false` (faixa D9). `!confirmed` ⇒ `meSharing = null` (a faixa não pisca). Desligar "Estatísticas" e voltar ⇒ a transação já atualizou o `doc` ⇒ a linha sai sem leitura.

## 11. Estados de UI
Mapeamento do quadro do docs/90 para `RankingState` (textos literais do docs/90; os ❓ continuam com o PA/Manager):
| Estado | Condição | UI |
|---|---|---|
| sem sessão / inativo / 0 amigos | `rankingAccess` | redirect; entrada ausente |
| sinal carregando | `pending` | esqueleto, sem redirect |
| carregando a frio | `loading` | filtros habilitados + esqueleto (+ minha linha se confirmada) |
| conteúdo | `content` | "Sua posição: Xº de N" (N = `ranked`), linhas, rodapé D10 |
| meu valor desconhecido neste filtro | `myPosition == null && me != null` | "Sua posição: sem informação" (texto novo ❓, N5) |
| eu não compartilho | `meSharing == false` | faixa RF-E10 + botão para `/profile` |
| só eu | `friends.isEmpty && me != null` | linha "Você" em 1º + RF-E9 |
| ninguém compartilha | `friends.isEmpty && meSharing == false` | RF-E8 + faixa |
| falha parcial | `failed.isNotEmpty` | linhas + "Não foi possível carregar N amigos. As posições podem mudar." |
| erro / offline / cota / sessão | fase | RF-E2 / RF-E3 / RF-E4 / fluxo existente |
| atualizando | `refreshing` | ranking anterior + progresso |
| desatualizado | `row.stale` | "Atualizado há N dias" (N = dias inteiros; `updatedAt` ausente: "Atualização desconhecida" ❓) |
| desconhecido | `row.value == null` | no fim, "—", Semantics "Ana, sem informação" |
| marcações sem data | `undatedNote` | nota RF-R9 |
| período sem movimento | `nobodyScored` | RF-E13 |
| limite | `limitedTo != null` | RF-R12 (N da contagem, quando confirmada; senão "50 dos seus amigos") |
| último amigo removido com a tela aberta | `noFriends` | SnackBar + redirect (§8.3) |

**Formato de horas (D14)**: `< 60` ⇒ "45 min"; `≥ 60` ⇒ "1.234 h 05 min" (milhar com ponto, minutos com 2 dígitos). Semantics: "1234 horas e 5 minutos". Entrada já limitada pelo teto.

## 12. Cota
"Regra" = leitura de documento feita pelas regras (cobrada). Estimativa pela documentação; **não medida em produção**.
| Ação | Leituras do app | Regra | Escritas |
|---|---|---|---|
| Sinal "≥ 1 amigo" (agregada) | 1 por sessão (+1 por revogação; +1 por reconexão se a 1ª falhou) | 0 | 0 |
| Lista de amigos fria | min(N, 50) + 1 se N > 50 (`limit + 1`); 1 mínimo se N = 0 | 0 | 0 |
| Snapshot por amigo a frio (existe ou não) | 1 | 1 (`isFriend`) | 0 |
| Snapshot negado (ex-amigo) | 0 doc; cobrança da negação **não verificada** (assumo ≤ 1) | ≤ 1 | 0 |
| Minha linha / trocar filtro / reabrir no TTL / offline | 0 | 0 | 0 |
| Perfil aberto pelo ranking no TTL | 0 | 0 | 0 |
| "Atualizar" (fora do cooldown de 60 s) | lista (se fora do cooldown dela) + min(N, 50) | min(N, 50) | 0 |

**Abrir a frio** (cache vazio):
| N amigos | Lista fria + snapshots | Lista em memória | % de 50 mil/dia |
|---|---|---|---|
| 1 | 3 | 2 | 0,006% |
| 5 | 15 | 10 | 0,03% |
| 10 | 30 | 20 | 0,06% |
| 20 | 60 | 40 | 0,12% |
| 50 | 150 | 100 | 0,30% |
| 100 / 300 (limite 50) | 151 | 100 | 0,30% |

**Por dia** (hipótese do PA: 100 usuários sociais ativos, 3 sessões, 2 aberturas frias/dia, 10 amigos em média): 100 × 2 × 30 = 6 000 + sinal 300 ⇒ **≈ 6 300 (12,6%)**. Somado às Fases 1–2 (≈ 10,3 mil, docs/82 §11.1): **≈ 16,6 mil/dia (≈ 33%)**. Bytes: 3–8 KB por documento típico (≤ 30 KB com 50 recomendados; o `get` traz o documento inteiro): 50 amigos ≈ 0,15–1,5 MB por abertura fria.
**Uso pesado acidental**: com cooldown de 15 s, alguém com 50 amigos que toca "Atualizar" sem parar por 1 h faria 240 × 100 = **24 mil leituras** (48% da cota do projeto). Com **60 s** (N1): 6 mil por hora, o teto prático de uma pessoa insistente. Um script mal-intencionado lê o que quiser com o próprio login de qualquer forma (risco de plataforma, fora do app).
**Limite prático: 50 amigos** (D5). Acima de 50, o subconjunto é a 1ª página da lista (ordem do id do par: estável, sem critério visível) + aviso.

## 13. Rollout e rollback
1. **Hotfix A2** (se aprovado, N2): PR pequeno para `main`, só app, sem regra, publicável a qualquer momento. Corrige a F2 em produção.
2. **Regras: nada a publicar.** Gate da Fatia 0: `shasum -a 256 firestore.rules` = `6135322e…e612` e suíte de regras inteira verde (a atual + `ranking.test.mjs`). "Regras antes do app" fica satisfeito trivialmente: as regras de que o ranking precisa já estão em produção desde a F2.
3. **Índices: nada.** A contagem e a lista usam o índice automático de `members` (array-contains).
4. **Política** (`web/privacidade.html`, RF-V6, data nova) **junto ou antes** do app da Fatia 3.
5. App (merge/deploy das Fatias 1–3; a 1 e a 2 não mostram nada ao usuário).
**Rollback**: só do app (o ranking não grava nada). A pista `friendsHint` fica no Hive e é ignorada pela versão anterior (chave nova, sem colisão).

## 14. Plano de testes
**Regras (Fatia 0, emulador)** — `firestore_rules_test/ranking.test.mjs`, sem mudar regras:
- Ana lê N = 12 amigos por `get` em lotes de 10 paralelos; documento inexistente de amigo = "não existe".
- Negados: não amigo, ex-amigo (par apagado depois de ter sido amigo), bloqueado (Ana→X e X→Ana), anônimo, conta `password`, sem claim.
- `getDocs(collection)` e `where(documentId(), 'in', [≤ 10 amigos])` negados (amigos apenas e misto).
- Documento sem consentimento de "Estatísticas" não carrega `stats` (create e update que removem `sharing.stats` mantendo `stats` negados).
- Documentário (positivo) de `rankOk`: `Infinity`, `1e300`, `1.5` e `month > total` **aceitos**; `NaN`/`-Infinity`/negativo negados. Fixa no teste o motivo do leitor estrito: se um dia as regras endurecerem, o teste avisa.
- Gate de sha256 (teste que lê o arquivo e compara com `6135322e…e612`).
- `mutations.mjs`: mutantes `allow list: if false` → `if request.auth != null` e → `if isFriend(resource.id, request.auth.uid)` têm de ser **mortos** pelo `documentId in` negado; `isFriend` → `true` no `get` morto pelo não amigo.
**Unitário (VM e `--platform chrome`)** — arquivos sem `dart:io`/Hive/Firebase:
- `ranking_reading_test.dart`: tabela do leitor estrito do docs/90 (12, 12.5, 12.0, `Infinity`, `NaN`, 1 000 001, "12", ausente) **construída a partir de valores JS** (`double.parse`, `jsonDecode`) para exercitar o dart2js; coerência (`month > year`, `year > total`, só a métrica afetada); chave velha = 0; chave ausente = "—"; `stale` (6, 7 e 8 dias; ausente; `calc` 0).
- `ranking_table_test.dart`: tabela de empates do docs/90 1:1; horas por minuto (600 × 659); desconhecidos no fim por `collationKey`; "Você" sem prioridade; `nobodyScored`; `myPosition`; estabilidade por uid com apelidos iguais.
- `ranking_period_test.dart`: fusos (01/11 02:30 UTC, −180 × 0), dezembro lido em janeiro, `agora = max(serverClock, updatedAt)` com relógio atrasado/adiantado.
- `ranking_texts_test.dart`: "1º", "1.234 h 05 min", "45 min", Semantics.
- `shared_reading_web_safe_test.dart` (hotfix): §5.2.
- `friends_count_controller_test.dart`: 1 contagem por sessão; ajustes; **corrida** (contagem em voo + aceite ⇒ resposta descartada); revogação ⇒ recontagem; pista com TTL; troca de conta limpa; `onFirstPage` completo/incompleto; nunca para conta sem amizades.
**Controller (fakes com log de operações)** — `ranking_controller_test.dart`: 20 amigos ⇒ 20 `get` com no máximo 10 simultâneos (o fake mede o pico) e 0 `list`; TTL 4:59 = 0 e 5:00 = 20; perfil aberto pelo ranking = 0; filtros = 0; parcial (2 timeouts) e "Tentar novamente" = 2 leituras; cota cancela o resto; disjuntor (10 primeiras falham ⇒ `error` sem iniciar as outras 40); `denied` ⇒ some, `dropLocal`, invalida contagem; troca de conta no meio (geração) não escreve no cache novo; offline não mostra nada (nem a minha linha); minha linha sem leitura; **0 escritas** em todo o arquivo.
**Widget** — `ranking_screen_test.dart`, `ranking_navigation_test.dart`:
- Entrada aparece e some sem recarregar (aceitar ⇒ aparece; remover o último ⇒ some; recontagem 0 ⇒ some) em 1024 e 375 px; pista local enquanto confirma.
- Redirect (padrão `router_profile_redirect_test.dart`): sem sessão ⇒ `/`; inativo ⇒ `/friends`; 0 confirmado ⇒ `/friends`; `pending` ⇒ fica; recarregar com query mantém filtros; filtro inválido ⇒ padrão; "Voltar" depois de trocar 3 filtros sai do ranking.
- Barra inferior com Perfil selecionado em `/ranking`; `rankingIconFits` em 320/375 × 1×/1,3×/2×/3×; menu do topo com rótulos na largura mínima nova sem overflow.
- Todos os estados do §11 com textos literais; matriz 320/375/768/1024/1440 × 1×/2×/3× × claro/escuro com apelidos de 40 caracteres; ordem de foco e Semantics (RNF7).

## 15. Riscos
| # | Risco | Mitigação | Residual |
|---|---|---|---|
| 1 | `Infinity`/`1e300`/não inteiro no snapshot de um amigo (regras aceitam) | leitor estrito com tetos e coerência; hotfix `readSafeInt` na F2; testes no Chrome | número falso **plausível** (risco D12 já aceito) |
| 2 | Bug só de dart2js passa pela CI (VM) | passo `--platform chrome` na CI (N3) | testes de widget continuam só na VM |
| 3 | Ex-amigo visível pelo TTL (remoção feita pelo outro) | regras negam na próxima leitura; "Atualizar"; `denied` ⇒ revoga | ≤ 5 min do que já tinha visto (D8) |
| 4 | Entrada aparece sem amigo (pista velha) ou some com amigo (contagem descartada) | pista com TTL 24 h; confirmação 1×/sessão; descarte só quando houve ajuste local em voo; recontagem em revogação | alguns segundos de entrada errada no início da sessão |
| 5 | Remoção feita pelo outro lado não esconde a entrada até a próxima descoberta | recontagem por sessão/revogação; rota protegida com estado "sem amigos" | aceito (sem listener, D7) |
| 6 | Cota por "Atualizar" repetido | cooldown de 60 s (N1); TTL; limite 50 | 6 mil/h numa pessoa insistente |
| 7 | Erro total lento (50 timeouts) | disjuntor nas 10 primeiras | ≈ 8 s |
| 8 | Fusos diferentes na virada do mês | documentado; cada um no próprio mês | até 28 h de intervalos diferentes |
| 9 | Relógio do aparelho adiantado | `ServerClock` quando amostrado | "este mês" 0 indevido com relógio dias adiantado |
| 10 | Corrida entre ranking e perfil de amigo no mesmo uid | última escrita vence (leituras equivalentes) | ≤ 1 leitura duplicada |
| 11 | Layout do topo com mais um ícone/rótulo | regra de encaixe com prioridade; entradas alternativas | ícone ausente em 320 px com fonte > 1,28× |
| 12 | Emulador × produção (cobrança de negação, agregada) | console de uso na 1ª semana; smoke com 3 contas | — |
| 13 | Divergência de "este mês" entre ranking e perfil de amigo com relógio errado | relógio do ranking ≥ o do perfil | aceito (N4) |

## 16. Fatias (refina o fatiamento do PA)
- **H. Hotfix A2** (independente, para `main`; dev frontend; ≈ 0,5–1 dia): `readSafeInt` nos leitores (§5.2), `WatchTimeFormatter` limitado, `shared_reading_web_safe_test.dart` (VM + Chrome), passo de CI (SRE). Review + QA curtos; deploy só de app.
- **0. Testes de regra** (backend; sem mudar regras): `ranking.test.mjs` + mutantes + gate de sha (§14).
- **1. Domínio puro** (`lib/ranking/`): modelos, leitor estrito, `RankingTable.rank`, períodos e relógio, textos; testes unitários VM + Chrome. Nada visível.
- **2. Dados e sinal**: `FriendsCountController` + pista + ganchos em `FriendsController.add/remove/block/onFirstPage`, `afterBlock`, `_revoked`; `rankingAccessProvider`; `RankingController` (pool, cache, falhas, disjuntor, cooldown, minha linha); contadores de cota e pico de simultaneidade nos fakes. Nada visível.
- **3. Rota, navegação e tela**: `/ranking` + redirect + `refreshListenable`; entradas desktop/mobile/Amigos/Perfil; barra inferior; filtros com `Router.neglect`; tela, estados, a11y, matriz de layout; política (RF-V6) e README.
- **4. Fechamento**: review e QA integrados; smoke com 3 contas (uma não compartilha, uma desatualizada > 7 dias, uma com valor inválido gravado pelo console do emulador em homologação); checklist de release no modelo do docs/89 (ordem: política → app; regras: só conferir o sha).

## 17. Respostas ao PA e posição sobre D1–D16

### 17.1 A1–A11
- **A1 (minha linha)**: sim. `SharingState.doc` segue as escritas do motor na mesma sessão: `SharedProfileSync._write` chama `controller.noteWritten(optimistic)` (`afterRecalc`/pulso) antes de enviar e `revertWrite` se falhar; recusa ⇒ `reloadAfterRefusal`. A leitura de sessão (`readOwn`, 1 por sessão com amizades ativas) e as transações dos interruptores também atualizam o `doc`. Minha linha = `doc.stats` confirmado, **0 leituras extras** (§10.4). Enquanto `!confirmed`, a linha e a faixa D9 esperam.
- **A2 (dart2js)**: **confirmado** (§5.1). `Infinity` e `1e300` passam em `v is int` no Chrome; `NaN` e `12.5` não; `12.0` passa no web e falha na VM. `readCount` aceita `Infinity` e o `WatchTimeFormatter` lança `UnsupportedError`, o que quebra a seção de estatísticas do perfil desse amigo em produção. Severidade **baixa (P3)**. Correção: `readSafeInt` (§5.2). Recomendo **hotfix independente** (N2); o leitor estrito do ranking protege a F3 de qualquer forma.
- **A3 (sinal)**: a agregada `count` com limite 300 custa **1 leitura** no Spark (1 por até 1000 entradas de índice, mínimo 1). Pista em Hive (`friendsHint:{uid}`, TTL 24 h, padrão do `socialHint`). Reconciliação e corrida: §8.1 (ajustes ±1 só quando a ação sabe que mexeu num amigo; recontagem em revogação; resposta em voo descartada se houve ajuste local).
- **A4 (leitura/cache)**: reaproveitar `FriendProfileCache` sem mudá-lo. Pool de 10 simultâneas, timeout de 8 s do data source, cancelamento por geração, cota cancela o resto, disjuntor nas 10 primeiras (§10).
- **A5 (encaixe)**: `topBarFits(context, extraIcons)`; Ranking com 2 ícones extras, Amigos com 1 (inalterado), Ranking sai primeiro e fica à esquerda de Amigos. Menu do topo: `+ kTopMenuRankingExtraWidth` (proposta 130, medida em teste) (§9).
- **A6 (redirect)**: `rankingAccessProvider` no `refreshListenable` do router; `pending` não redireciona e mostra o esqueleto (§8.2–8.3).
- **A7 (relógio)**: sim ao `ServerClock`, mais `max` com o maior `updatedAt` lido (§7.3).
- **A8 ("50 mais recentes")**: exigiria `orderBy(createdAt desc)` + índice composto `friendships(members array-contains, createdAt desc)` (deploy de índice antes do app; custo de armazenamento desprezível). Mas a lista de Amigos lê em ordem de id: ou ela muda de consulta (afeta a paginação da F1, que está estável) ou o ranking faz consulta própria (até +51 leituras, porque não reaproveita a lista em memória). **Não recomendo agora**: nenhum usuário perto de 50 amigos; reavaliar se aparecer.
- **A9 (estrutura)**: §3 e §6 (`lib/ranking/`, função pura `rank`, leitor estrito separado do tolerante).
- **A10 (testes de regra)**: §14; **nada** em `firestore.rules` muda (gate de sha256 `6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612`).
- **A11 (barra inferior)**: confirmo: Perfil selecionado em `/ranking`, como em `/friends` (§9).

### 17.2 Posição sobre D1–D16
| D | Posição | Observação |
|---|---|---|
| D1 | **concordo (a)** | as 5 métricas validadas; favoritos não são "assistir" e não têm período |
| D2 | **concordo (a)** | zero custo; "mês passado" exigiria schema + regras |
| D3 | **concordo (a)** | ressalva: nos primeiros dias do mês o padrão quase sempre cai em "Ninguém pontuou neste período ainda.". É aceitável, mas, se o Manager preferir, (b) Horas · Total nunca fica vazio |
| D4 | **concordo (a)** | competição, empate por minuto em horas, "Você" sem prioridade, ordena pelo apelido real |
| D5 | **concordo (b) 50** | = 1ª página em memória; A8 não recomendado agora |
| D6 | **concordo (a)**, com refinamentos | Ranking à esquerda de Amigos no mobile (posições estáveis); larguras do §9; Perfil selecionado |
| D7 | **concordo (a)**, refinado | contador (não só booleano) com ajustes, descarte em voo e recontagem em revogação (§8.1) |
| D8 | **concordo (a)** | o cache compartilhado também dá o perfil a 0 leituras |
| D9 | **concordo (a)** | reciprocidade e fonte única |
| D10 | **concordo (a)** | conta `not-found` + sem `stats`; não conta negados nem falhas |
| D11 | **concordo (a)**, precisado | "> 7 dias" em **dias inteiros** (8 ⇒ marcador; 7 ⇒ não), `updatedAt` ausente e `calc` < mínimo também |
| D12 | **concordo (a)** | o spike prova que as regras aceitam `Infinity`/`1e300`/`1.5`/`month > total`; o leitor estrito é obrigatório |
| D13 | **concordo (a)** | + disjuntor; cota e sessão continuam tudo ou nada |
| D14 | **concordo (a)** | formato do §11 |
| D15 | **concordo (a)** | + `Router.neglect` para não poluir o histórico |
| D16 | **concordo (a)** | confirmado no emulador; um ex-amigo não derruba lote |

### 17.3 Onde divirjo ou acrescento ao docs/90
- **RF-R11 (cooldown de 15 s)**: proponho **60 s** para o ranking (até 100 leituras por toque; §12). A lista de amigos mantém os 15 s dela.
- **RNF4 ("lotes de 10")**: janela deslizante de 10, não lotes em degraus, mais o disjuntor.
- **RF-V2**: o sinal é um **contador**; a remoção feita pelo outro lado é descoberta pela recontagem disparada em `permission-denied`.
- **RF-L4**: a correção de `Infinity` na F2 vira hotfix próprio, não carona da F3.

## 18. Decisões para o Manager
Além de D1–D16 (posição no §17.2):
| # | Decisão | Opções | Recomendação |
|---|---|---|---|
| **N1** | Cooldown do "Atualizar" do ranking | (a) 15 s como as listas; (b) **60 s** | **(b)**: cada toque custa até 100 leituras |
| **N2** | Achado A2 em produção (F2) | (a) **hotfix independente agora** (só app, P3); (b) dentro da Fatia 1 da F3; (c) aceitar | **(a)**: pequeno, sem regra, tira um modo de quebrar a tela do perfil de amigo e cobre atividades/recomendados |
| **N3** | CI com `flutter test --platform chrome` nos testes de leitores | (a) **sim** (SRE, passo novo no `deploy-pages.yml`); (b) só local | **(a)**: produção é dart2js e a classe de bug A2 é invisível na VM |
| N4 | Relógio | (a) **ranking com `ServerClock` + `max(updatedAt)`, perfil de amigo inalterado**; (b) alinhar os dois agora | **(a)**: não mexe na F2; divergência só com relógio errado |
| N5 | Texto quando meu valor é desconhecido num filtro | "Sua posição: sem informação" ❓ | PA/Manager validam o texto |
