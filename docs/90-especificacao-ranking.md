# 90 - Especificação: Ranking entre amigos (Fase 3 de 5)

> Autor: Product Analyst · Base: `main` em `9389bc5` (Fases 1 e 2 em produção + hotfix A2 do docs/92; `firestore.rules` publicado = sha `6135322e…e612`) · Branch: `feat/social-ranking`
> Revisões: 2026-10-18 (1ª versão) · **2026-10-24: decisões aprovadas pelo Manager e revisão de testabilidade do QA ([docs/93](./93-testabilidade-ranking.md), B1–B11 + ajustes menores + cenários que faltavam) incorporadas** junto com o [docs/91](./91-design-ranking.md).
> Entradas: prompt do Manager da Fase 3; [docs/81](./81-especificacao-perfil-social.md) (D1–D17 aprovadas), [docs/82](./82-design-perfil-social.md) (§4.4 schema, §5.1 períodos, §7.2 perfil de amigo, §11/§11.1 cota), [ADR-006](./adr/adr-006-snapshot-perfil-social.md), [docs/84](./84-fatia0-regras-perfil-social.md) (`rankOk` aceita `double`), [docs/87](./87-fatia3-perfil-de-amigo.md) (cache/TTL do perfil de amigo), [docs/50 §7](./50-design-amizades.md) (limites de chamadas em consultas).
> **Status: especificação aprovada (Manager, 2026-10-24), pronta para a reconferência do QA.** D1–D16 aprovadas com os refinamentos do Arquiteto (docs/91 §17.2), mais N1–N5 e o [ADR-007](./adr/adr-007-ranking-no-cliente.md); D3 ajustada pelo Orquestrador (padrão Episódios · Este ano; sem query abre o último filtro usado). Os ❓ de texto foram fechados como recomendado pelo PA/Arquiteto (tabela T1). A1–A11 estão respondidas no docs/91 §17.1.
> **Onde fica cada oráculo** (um lugar só; o outro documento referencia): textos (T1), filtros na URL (T2) e foco (T3) aqui; empates (O1), leitor estrito e coerência (O2, O3), períodos e relógio (O4, O5), marcador (O6), sinal e acesso (O7, O8), fases da carga (O9), cooldown (O10) e leituras (O11) no docs/91. As tabelas são copiadas 1:1 para testes parametrizados.
> **Este documento só especifica.** Nenhum código ou regra foi alterado por ele.
> Conjunto social: F1 amizades (feita) → F2 perfil (feita) → **F3 ranking** → F4 avaliações → F5 comentários.
> Legenda: **RF** requisito funcional, **RNF** requisito não funcional, **D** decisão do Manager, **A** pergunta ao Arquiteto, **N** decisão nova do docs/91, **B** bloqueante do QA (docs/93), ❓ dúvida em aberto.

---

## Etapa 1 - Análise

### 1.1 O que o snapshot da Fase 2 oferece ao ranking (lido em `main` 827cec5; reconferido em 9389bc5)

Fonte única: `shared_profiles/{uid}.stats` (docs/82 §4.1/§4.4), que só existe enquanto o dono mantém **"Estatísticas"** ligado (regra: `stats` ⇔ `sharing.stats`). Pela D13 (aprovada) esse mesmo interruptor governa o ranking, e o texto literal do consentimento já diz "…no seu perfil **e nas comparações entre amigos**". Quem já ligou "Estatísticas" consentiu com o ranking; **não é preciso consentimento novo**. **Atualização 2026-10-24 ([docs/95](./95-simplificacao-compartilhamento.md), Fatia S):** os interruptores por seção dão lugar a um só, "Aparecer na busca", com consentimento único que cita o Ranking. A fonte do ranking continua `stats` no documento.

| Métrica do snapshot | Total | Mês / Ano | Validada nas regras (`rankOk`) | Serve ao ranking? |
|---|---|---|---|---|
| `watchedMovies` (filmes assistidos) | sim | sim | ≥ 0, numérica | **sim** |
| `watchedEpisodes` (episódios assistidos) | sim | sim | ≥ 0, numérica | **sim** |
| `watchedSeries` (séries assistidas, ≥ 1 episódio) | sim | sim | ≥ 0, numérica | **sim** |
| `completedSeries` (séries concluídas) | sim | sim | ≥ 0, numérica | **sim** |
| `minutes` (tempo assistido; + `estimated`, `unknown`) | sim | sim | `minutes` ≥ 0, numérica; `estimated`/`unknown` só no app | **sim** ("horas assistidas") |
| `favorites`, `movies`, `series` (favoritos) | sim | **não** | só chave (`hasOnly`) | só no Total (ver D1) |
| `recs.count` (recomendações) | — | — | outra seção, outro consentimento | **não** (D13: ranking = interruptor Estatísticas) |
| `undatedMovies`, `undatedEpisodes`, `datedFrom` | sim | — | só chave | nota "contam só no total" |

Metadados do documento que o ranking usa: `updatedAt` (hora do servidor, exigida pelas regras; pulso de 24 h com o app aberto), `tz` (fuso do dono, −840..840), `calc` (versão da fórmula, hoje 1), `v` (schema, hoje 1).

**Períodos (já suportados, sem mudança de schema).** `stats.month.key` ("AAAA-MM") e `stats.year.key` ("AAAA") são calculados **no fuso do dono**. O leitor calcula "agora no fuso do dono" (`agoraUtc + tz`): "este mês" = `stats.month` se a chave é o mês atual do dono, senão **0**; idem para o ano (docs/82 §5.1; `PeriodReading.current` já faz isso em `lib/shared_profile/shared_stats_reading.dart`). Todos os leitores veem o mesmo número de um amigo, que é o que o ranking precisa. O ranking é **mais estrito** que o `current` da F2 para chaves ilegíveis ou futuras ("—" em vez de 0; docs/91 O4, B2). **Conclusão: Total, Este mês e Este ano são suportados pelo snapshot atual; nenhuma mudança mínima é necessária.**

**O que já existe no código e é reaproveitado**
| Peça | Onde | Uso no ranking |
|---|---|---|
| Leitura de um amigo `readFriend(uid)` com `Source.server` e mapeamento de falhas | `SharedProfileRepository`, `FirestoreSharedProfileDataSource` | 1 `get` por amigo, mesma regra (`isOwner \|\| isGoogle && isFriend`, 1 chamada) |
| Leitor tolerante `FriendSharedView.parse` / `SharedStatsReading` / `PeriodReading.current` | `lib/shared_profile/shared_stats_reading.dart` | números por período; campo ausente = desconhecido ("—") |
| Cache **de memória** por (leitor, amigo), TTL 5 min, limpo em troca de conta/período social, remoção/bloqueio | `FriendProfileCache` (`lib/providers/friend_profile_providers.dart`) | o ranking e o perfil de amigo podem compartilhar as entradas (A4) |
| Lista de amigos (`Friend{uid,name,photoUrl,since}`, página de 50, TTL 5 min, sem listener) | `FriendsController` (`lib/providers/social_lists_providers.dart`) | uids, apelido e foto (0 leitura extra se já está em memória) |
| Contagem de amigos (consulta agregada `count`) | `SocialPayloads.friendsCountQuery`, `countFriends()` | sinal "tenho ≥ 1 amigo" para a entrada (D7) |
| Estado do dono `SharingState.doc` (documento próprio lido do servidor 1×/sessão) | `sharingControllerProvider` | minha linha, sem leitura extra (A1) |
| `socialActiveProvider` (amizades ativas) | `lib/providers/social_providers.dart` | pré-condição da entrada |
| Menu do topo (desktop, só na Início) e `MobileTopBar` com ícone Amigos condicionado | `lib/screens/home_screen.dart`, `lib/widgets/app_shell.dart` | onde a entrada Ranking entra (D6) |
| `redirect` do go_router para `/profile` e `/friends*` | `lib/router.dart` | proteção de `/ranking` |
| Textos e formatos: "Atualizado há X", `WatchTimeFormatter` | `shared_profile_texts.dart`, `lib/services/watch_time.dart` | indicador de desatualizado, horas |

### 1.2 Lacunas
| # | Lacuna | Consequência | Proposta |
|---|---|---|---|
| L1 | **`list` em `shared_profiles` é negado** (`allow list: if false`) | não dá para buscar N snapshots numa consulta | N `get` por id (permitido hoje). Consulta `documentId in [...]` exigiria mudar regra e, medido na Fase 1, só passa com **≤ 10** ids por consulta com `isFriend(resource.id, …)` (20 negado; docs/50 §7); o custo cobrado seria o mesmo (D16) |
| L2 | **Não existe sinal barato e ao vivo de "tenho ≥ 1 amigo"**: a lista de amigos é lida só quando uma tela pede, sem listener; nada no app sabe a contagem ao iniciar | a entrada do ranking não tem de onde aparecer/sumir | contagem agregada 1×/sessão + pista local por uid + ajustes locais nas ações + reconciliação (D7, A3) |
| L3 | **Remoção feita pelo outro lado não chega sozinha** (sem listener; desenho da Fase 1) | se o amigo me remove em outro aparelho, só descubro na próxima leitura | aceitar o atraso até a próxima leitura (≤ TTL ou "Atualizar"), como D15 (D8) |
| L4 | **`rankOk` aceita `double`** (docs/84): `1.5`, e possivelmente `Infinity`/`1e300`, passam nas regras | um cliente modificado pode gravar valores não inteiros/infinitos que bagunçam a ordenação | leitor estrito do ranking descarta não inteiro, não finito e acima do teto (RF-L, D12) |
| L5 | ~~Leitor `readCount` usava `v is int`~~ (confirmado no spike A2: `Infinity`/`1e300` "são" `int` no dart2js) | **resolvido** pelo hotfix A2 (docs/92, `main` 9389bc5): `readSafeInt` em `lib/shared_profile/safe_int.dart`, com os tetos por métrica, e passo `--platform chrome` na CI | o ranking **reutiliza** `readSafeInt`/`readCount` (docs/91 §5) |
| L6 | **Números falsos plausíveis** (D12 da F2, risco aceito) | no ranking o incentivo a falsificar é maior (ficar em 1º) | sem servidor não há remédio completo; teto + coerência no leitor, remover/bloquear (D12 desta fase) |
| L7 | **Snapshot desatualizado** só é detectável por `updatedAt` (pulso de 24 h só com o app aberto) | "desatualizado" = o dono não abre o app há dias; os números podem estar certos | marcador neutro "Atualizado há N dias" acima de um limiar (D11) |
| L8 | **Marcações antigas sem data** contam só no Total (D5 da F2) | "este mês/ano" favorece quem começou depois da versão nova; Total favorece o histórico | aceitar; nota quando há marcações sem data (RF-R9) |
| L9 | **Fuso diferente entre amigos**: na virada do mês, um amigo já está em "novembro" e outro ainda em "outubro" | por algumas horas os "este mês" não cobrem o mesmo intervalo | aceitar e documentar (cada um no próprio mês, regra B1 da F2) |
| L10 | **A barra inferior (mobile) já tem 5 destinos** (Início, Explorar, Recomendo, Favoritos, Perfil), o máximo recomendado pelo Material 3; a barra superior mobile já esconde o ícone Amigos quando não cabe | não há lugar "natural" para uma 6ª aba | D6 |
| L11 | **Lista de amigos sem ordem definida no servidor** (`members array-contains`, sem `orderBy`): a 1ª página de 50 sai na ordem do id do par; depois, `FriendsController.add` insere por nome e `dropLocal` puxa o próximo da lista em memória | um limite de N amigos escolhe um subconjunto arbitrário (estável, mas sem critério visível) | D5; o subconjunto é definido como **os 50 primeiros de `FriendsController.state.items` no momento da carga** (RF-R12) |
| L12 | **Política diz que os números "servirão para comparações entre amigos"** (futuro) | texto fica desatualizado quando o ranking for ao ar | trocar para o presente ("são usados no ranking entre amigos"), sem mudar o que é compartilhado (RF-V6) |

### 1.3 Riscos
| # | Risco | Impacto | Mitigação proposta |
|---|---|---|---|
| R1 | **Cota de leituras** cresce linearmente com N amigos (2 cobradas por amigo a frio + lista) | estouro do Spark afeta todos | limite prático (D5), cache de memória compartilhado com o perfil de amigo (TTL 5 min), filtros sem leitura, "Atualizar" com cooldown de **60 s** (N1) |
| R2 | **Ex-amigo continua visível** no ranking por causa do TTL | viola "remove imediatamente" se mal definido | remoção/bloqueio feitos **por mim** limpam cache e lista na hora (já é assim, docs/87 🟡1); remoção feita **pelo outro** some na próxima leitura do servidor (D8); regras negam a leitura imediatamente |
| R3 | **Números falsos** levam alguém ao 1º lugar | confiança no ranking | D12; remover/bloquear; leitor estrito |
| R4 | **Falha parcial** (alguns `get` falham) dá posições erradas | ranking enganoso | aviso explícito de quantos não carregaram e "Tentar novamente" só dos que faltam (D13) |
| R5 | **Entrada aparece sem amigo** (pista local velha) ou **some com amigo** | navegação confusa | pista confirmada pelo servidor 1×/sessão; rota protegida com estado "sem amigos" (RF-V) |
| R6 | **Pressão social / exposição** de quem não compartilha | privacidade | só contagem anônima de quem não participa (D10); nada além do que o consentimento cobre |
| R7 | **Offline mostra dado de terceiro** | contradiz D10 da F2 | offline não mostra nenhum amigo, nem da memória (RF-E3) |
| R8 | **Layout**: mais um item no menu do topo e na barra superior mobile | quebra em 320 px / fonte 3× | regras de encaixe com prioridade e entrada alternativa (D6, A5) |
| R9 | **Rollout**: o app precisa de regra nova? | ordem de publicação | na recomendação (D16) **nenhuma regra muda**; só testes novos. Se o Manager escolher consulta `in`, regras antes do app (padrão das fases anteriores) |

### 1.4 Impacto
| Área | Hoje | Preciso |
|---|---|---|
| Regras | `get` de amigo permitido; `list` negado | **nada** (recomendação D16); testes de regra novos para o cenário do ranking |
| Índices | — | nada |
| Navegação | Amigos no menu do topo (desktop) e ícone na barra superior (mobile) só com amizades ativas | entrada **Ranking** só com ≥ 1 amigo mútuo (D6, D7) |
| Rotas | `/friends*`, `/profile` protegidas | `/ranking` protegida (sessão, amizades ativas, ≥ 1 amigo) |
| Dados | perfil de amigo lê 1 documento | ranking lê até `limite` documentos em lotes, com o mesmo cache |
| Perfil (dono) | interruptor "Estatísticas" | sem mudança; o ranking leva a ele quando o dono não compartilha |
| Política | "servirão para comparações" | presente do indicativo, com data nova |
| Exportação / exclusão / desativação | cobrem `shared_profiles` | **nada novo** (o ranking não grava nada) |

---

## Etapa 2 - Especificação

## Ranking entre amigos

**Problema:** quem tem amigos no CineTrack e compartilha estatísticas só consegue comparar números abrindo o perfil de cada amigo, um por um. Não existe uma visão "quem assistiu mais" no mês, no ano ou no total.
**Resultado esperado:** uma tela Ranking, visível só para quem tem ≥ 1 amigo mútuo, que ordena eu + amigos que compartilham estatísticas por uma métrica e um período escolhidos, destaca minha posição, trata empates de forma previsível, mostra quando o número de alguém pode estar velho e não mostra ninguém que não seja amigo mútuo com "Estatísticas" ligado.
**Métricas de sucesso** (sem telemetria no app; verificáveis por teste e uso real):
- **Zero vazamento**: a suíte de regras prova que não amigo, ex-amigo, bloqueado (2 sentidos), anônimo e conta não Google não leem `shared_profiles/{uid}` e que `list` (inclusive `documentId in`) continua negado; teste de widget prova que amigo sem `stats` não aparece em nenhuma linha, rótulo ou Semantics.
- **Zero escrita causada pelo ranking**: os testes rodam com o motor do snapshot (`SharedProfileSync`) parado (fake) e o log de operações não tem nenhum `set`/`update`/`delete`/transação. A única escrita local permitida é a pista Hive `friendsHint:{uid}` (docs/91 §8.1).
- **Cota**: medida pela tabela O11 do docs/91, com três colunas separadas: chamadas no fake (o que o teste conta), chamadas da regra no emulador (`rules_budget`: ≤ 1 `exists` por `get`) e cobrança real (só smoke/console). Ex.: abrir a frio com N = 20 amigos e a lista em memória = **20 `get`** no fake, ≈ 40 cobradas; trocar filtro = 0; reabrir no TTL = 0.
- **Remoção imediata**: depois de eu remover/bloquear um amigo e o `pumpAndSettle` da ação, o ranking não tem a linha dele, o cache não tem a entrada e o fake registrou 0 `get` para isso.

### Escopo
- Inclui:
  - Rota **`/ranking`** (no shell), entrada na navegação **só com ≥ 1 amigo mútuo** (D6, D7), proteção no `redirect`.
  - Ranking de **eu + amigos mútuos com "Estatísticas" ligado**, filtro por **estatística** (D1) e **período** Total / Este ano / Este mês (D2), filtro padrão **Episódios assistidos · Este ano** e último filtro da sessão (D3).
  - Destaque da minha posição, critério de empate (D4), linha de amigo leva ao perfil do amigo (`/friends/u/:uid`) e minha linha ao `/profile`.
  - Indicador de snapshot desatualizado (D11), aviso quando eu não compartilho (D9), contagem de quem não participa (D10).
  - Estados: carregando, erro, offline, cota, sessão expirada, falha parcial, todos os amigos sem compartilhamento, só eu, sem amigos (rota).
  - Leitor estrito para o ranking (D12), limite prático de 50 amigos (D5) com aviso, leitura com janela de 10 simultâneas e disjuntor.
  - Testes de regra novos (sem mudar regras) e gate de sha separado, testes de unidade (VM e Chrome) e de widget com fakes, README e trecho da política.
- Não inclui:
  - Mudança de schema do snapshot, novas métricas gravadas, "mês passado"/histórico de períodos (fora de escopo desde a F2).
  - Ranking por **recomendações** (outro consentimento) ou por **favoritos** em períodos (não existe no snapshot).
  - Ranking global, de amigos de amigos ou de não amigos; ligas, medalhas, notificações ("Fulano passou você"), histórico de posições.
  - Validação "verdadeira" dos números (impossível sem servidor; D12 da F2 continua aceito).
  - Ligar "Estatísticas" de dentro do ranking (o consentimento continua no Perfil; o ranking só leva até lá, D9).
  - Hotfix A2 e passo Chrome da CI: **já publicados** (`main` 9389bc5, docs/92). O ranking só reutiliza `readSafeInt`/`readCount` e acrescenta os próprios arquivos de teste ao passo Chrome.
  - Android/iOS (app em produção é web; nada aqui deve impedir as outras plataformas).

### Requisitos funcionais

**RF-V: Visibilidade da entrada e rota**
- RF-V1. A entrada **Ranking** aparece em **quatro** lugares (menu do topo da Início no desktop, `MobileTopBar` no mobile, botão "Ver ranking" no topo de Amigos e item "Ranking" na seção Amizades do Perfil) somente quando `rankingAccessProvider == allowed`: sessão Google, amizades **ativas** e sinal "≥ 1 amigo" positivo (docs/91 O8). Não depende de alguém compartilhar estatísticas.
- RF-V2. O sinal "≥ 1 amigo" (D7) é um **contador** (docs/91 §8.1): pista local por uid (TTL 24 h, mostrada enquanto confirma), **1 contagem agregada por sessão** e ajustes **sem leitura** pelas ações deste aparelho; qualquer primeira página da lista de amigos lida do servidor também o atualiza. Todas as transições estão na tabela **O7** do docs/91, que é o oráculo de `friends_count_controller_test`. **Sessão** = vida do `currentUid` no processo: recarregar a aba = nova sessão (1 agregada); voltar do background = 0 (se já confirmado); trocar de conta = 1 para a nova conta.
- RF-V3. Quando o acesso passa de `allowed`/`pending` a `noFriends` **com o app aberto**, a entrada some **sem recarregar** em todas as larguras (no mesmo frame em que o provider muda). Se `/ranking` é a **rota visível** (`ModalRoute.isCurrent`), aparece o SnackBar "Você não tem mais amigos no CineTrack." e o redirect leva a `/friends`. Se `/ranking` está **empilhado** sob outra rota (ex.: `/friends` aberto pelo "Ver ranking" ou pelo perfil), nenhum SnackBar aparece fora do ranking; ao voltar para ele, a tela sai sozinha: `pop` para a rota anterior ao ranking (ou `go('/friends')` se o ranking é a raiz da pilha), sem mostrar o ranking com `noFriends`.
- RF-V4. `/ranking` é protegida no `redirect` (docs/91 O8): `noSession ⇒ /`; `inactive` (inclui conta não Google) ou `noFriends ⇒ /friends`; `pending` (sessão carregando, `SocialPhase.loading` sem pista, `loadFailed`, sinal sem pista nem confirmação) e `allowed` ⇒ fica, e em `pending` a tela mostra o esqueleto. Recarregar `/#/ranking?…` funciona e preserva a query.
- RF-V5. Remoção feita pelo **outro lado** (outro aparelho): a entrada some quando o app **descobre**: recontagem por `permission-denied` (perfil ou ranking), primeira página da lista lida do servidor com 0 itens, ou confirmação de sessão pendente (reconexão/retorno ao app). Não há listener (decisão da Fase 1).
- RF-V6. A política (`web/privacidade.html`, data nova) passa a dizer, no presente, que os números de "Estatísticas" "aparecem no **Ranking** dos seus amigos mútuos"; nada novo é compartilhado. O `PrivacySummary` ganha a mesma frase se citar a seção. Oráculo: teste literal do `PrivacySummary` (padrão `shared_profile_texts_policy_test`) e conferência da data em `web/privacidade.html`.

**RF-R: Ranking**
- RF-R1. Participantes: **eu** (só se eu compartilho "Estatísticas" e o estado foi confirmado pelo servidor, D9) + cada amigo considerado (RF-R12) cuja leitura do servidor, ou entrada fresca do cache, tenha documento com `stats` **mapa**. Amigo com documento sem `stats`, sem documento (`not-found`) ou com `stats` que não é mapa (ex.: `stats: 3`) **não aparece** e entra na contagem "não participam" (D10). `stats: {}` ou `stats` com todos os campos inválidos **participa** com "—" em todas as métricas (consentiu; o documento é que está malformado).
- RF-R2. **Métricas** (D1): Filmes assistidos (`watchedMovies`), Séries assistidas (`watchedSeries`), Séries concluídas (`completedSeries`), Episódios assistidos (`watchedEpisodes`), Horas assistidas (`minutes`). Rótulos e unidades na tabela T1.
- RF-R3. **Períodos** (D2): Este mês, Este ano, Total. "Este mês/ano" de cada participante segue o fuso **dele**. Chave do período atual ⇒ valor gravado; chave válida **anterior** ⇒ **0**; chave ausente, ilegível (não string, fora do formato `AAAA-MM`/`AAAA`, mês 13) ou **futura** ⇒ desconhecido ("—"). Oráculo com datas UTC absolutas: docs/91 **O4**; o relógio do ranking: docs/91 **O5** (N4).
- RF-R4. **Ordenação e empates** (D4): valor decrescente; mesma posição para valores iguais com numeração de competição ("1º, 1º, 3º"); dentro do empate, `collationKey(apelido)` asc e depois `uid` asc ("Ana", "ana" e "ANA" têm a mesma chave e ficam pela ordem do uid); "Você" não tem prioridade e ordena pelo **mesmo texto que a linha mostra** (`displayLabelProvider`); "empatado" vale para **todas** as linhas do grupo, inclusive a 1ª. Horas ordenam e empatam por **minutos**. Oráculo: docs/91 **O1** (entrada ⇒ `RankingResult`).
- RF-R5. **Valor desconhecido** (campo ausente, ilegível, descartado pelo leitor estrito ou pela coerência): a pessoa aparece **depois** de todos os que têm valor, sem posição (célula de posição vazia, valor "—"), em ordem de `collationKey` e uid. Não conta como 0 e não entra no "de N".
- RF-R6. **Zero** é valor: participantes com 0 são ordenados normalmente (todos com 0 empatam). `nobodyScored` = há ≥ 1 posicionado **e** todos os posicionados têm 0 (desconhecidos não impedem: "Ana 0, Bia —" ⇒ mensagem RF-E13).
- RF-R7. **Linha**: posição ("1º"), avatar (`Friend.photoUrl`; o meu, a foto do Google; foto que falha ao carregar cai no avatar com inicial, sem exceção), apelido (do par: `SocialNickname.clean(...)` e "Usuário" se vazio em `SocialRepository._friendOf`, `social_repository.dart:555–560`; a lista Bloqueados usa `SocialNickname.normalize(...) ?? 'Usuário'`, `social_lists_providers.dart:618`; o meu, `displayLabelProvider`), valor formatado (T1) e marcador de desatualizado (RF-E12). Minha linha tem destaque visual **e** o rótulo visível "Você" ao lado do apelido. O resumo de posição fica no topo (T1: 3 variantes; nenhum resumo enquanto `meSharing == null`).
- RF-R8. Ativar uma linha de amigo (toque, Enter ou Espaço) abre `/friends/u/<uid>` com o `Friend` como `extra` (cabeçalho sem leitura) e, se a entrada do cache está fresca, o perfil abre com **0 `get`** e 0 leitura do par. Minha linha abre `/profile`. Linha com valor desconhecido também abre.
- RF-R9. **Nota de datas** (mesmo oráculo da F2): com período Este mês ou Este ano, a nota "Marcações anteriores a esta versão contam só no total." aparece uma vez sob os filtros se **algum participante exibido** (inclusive eu; nunca quem não participa, falhou ou ficou além do limite) tem `notePlacementFor(undated, datedFrom, updatedAt, tz, agora)` verdadeiro **para o período escolhido** (`.month` em Este mês, `.year` em Este ano). Em Total, nunca. Reutiliza `SharedProfileTexts.notePlacementFor` e o texto genérico da F2 (a versão com data é por pessoa e não cabe numa nota única).
- RF-R10. **Filtros sem leitura**: trocar métrica ou período reordena os dados já em memória (0 leituras no fake). O filtro fica no endereço (D15) com as regras da tabela **T2** (sem query ⇒ último filtro da sessão, senão o padrão; inválido ⇒ idem, com a URL reescrita; repetido ⇒ primeiro; maiúsculas aceitas; parâmetros desconhecidos preservados; troca de filtro **sem** entrada nova no histórico e sem perder o "voltar" do AppBar).
- RF-R11. **"Atualizar"** (N1): relê do servidor a lista de amigos (se fora do cooldown de 15 s **da lista**) e os snapshots, ignorando o TTL. Cooldown do ranking de **60 s** contado desde a **leitura de servidor mais antiga entre todas as respostas `ok` dos amigos considerados**, com ou sem `stats` (inclui `not-found` e entradas servidas do cache, para que "ninguém compartilha" e "só eu" também tenham cooldown; ver docs/91 **O10**). Dentro dele: 0 leituras e o SnackBar da F1 "A lista já está atualizada (atualizada há instantes)." Durante a leitura o ranking anterior fica visível, com progresso no botão (desabilitado). "Tentar novamente" (erro, parcial, cota) **nunca** tem cooldown.
- RF-R12. **Limite prático** (D5 = 50): amigos considerados = **os 50 primeiros de `FriendsController.state.items` no momento da carga** (1ª página ordenada por nome + amigos aceitos neste aparelho, inseridos por nome + páginas de "Ver mais" já carregadas, na ordem em memória). Se há mais de 50 em memória **ou** `hasMore`, aparece o aviso de limite (T1): com N confirmado pela contagem, "O ranking compara você com 50 dos seus N amigos."; sem N confirmado, "O ranking compara você com 50 dos seus amigos."

**RF-L: Leitor estrito para o ranking (D12)**
- RF-L1. Um valor de métrica só é usado se for numérico, **finito**, **inteiro**, ≥ 0 e ≤ o teto da métrica (docs/82 §4.4: `watchedEpisodes` ≤ 1 000 000; `minutes` ≤ 52 560 000; filmes, séries assistidas e concluídas ≤ 100 000). É exatamente o `readCount(v, max: teto)` do hotfix A2 (`readSafeInt`), já aplicado por `SharedStatsReading.read`; o ranking o reaplica à **minha** linha (o leitor do documento próprio não tem tetos). Senão o valor é desconhecido. Oráculo: docs/91 **O2** (valor × teto de cada métrica, limite exato e +1, nas duas plataformas).
- RF-L2. **Coerência por métrica**: só valores de chave **atual** são comparados; um 0 de chave anterior nunca é comparado. `mês > ano` (ambos atuais), `ano > total` ou `mês > total` (mês atual) ⇒ os três valores **dessa métrica** daquele participante ficam desconhecidos; as outras métricas não mudam. Mês atual com ano anterior (impossível pelo motor) ⇒ os três desconhecidos. Oráculo: docs/91 **O3** (9 combinações de chave + casos incoerentes).
- RF-L3. **Desatualizado** (D11): `updatedAt` ausente ou ilegível, `calc` ilegível ou < 1 (as regras exigem ≥ 1; defesa) ou `inDays(agora − updatedAt) > 7`, com o `agora` do ranking (O5). `tz` fora de −840..840 ⇒ 0, para amigos **e** para mim. Oráculo: docs/91 **O6**.
- RF-L4. O leitor estrito é **só do ranking**; o perfil de amigo da F2 continua como está depois do hotfix A2 (que já recusa não inteiro, não finito e acima do teto). Divergências aceitas entre as telas: chave de período ilegível ou futura (F2 mostra 0, ranking "—") e coerência (só no ranking).

**RF-E: Estados** (textos exatos na T1; fases da carga no docs/91 **O9**)
- RF-E1. **Carregando a frio**: filtros visíveis e habilitados, "Atualizar" desabilitado com progresso, esqueleto de linhas; a minha linha (se confirmada e compartilhada) já pode aparecer. As linhas de amigos aparecem **todas juntas** quando a carga termina (nada progressivo).
- RF-E2. **Erro** (online): nenhuma resposta `ok` de amigo (nem do cache) **e** (todas as leituras terminaram em falha **ou** o disjuntor disparou), ou falha da **lista** de amigos (0 `get` de snapshot). Mostra só a mensagem de erro + "Tentar novamente" (sem filtros, sem resumo, sem a minha linha).
- RF-E3. **Offline** (D10 da F2): só a mensagem offline. Sem filtros, sem "Atualizar", sem faixa D9, sem resumo, sem rodapé, **nenhuma linha** (nem a minha, nem do cache). Ao reconectar, recarrega: 0 `get` se o cache está fresco.
- RF-E4. **Cota** (`resource-exhausted` em qualquer leitura, inclusive da lista): mensagem de cota existente + "Tentar novamente"; nenhuma linha (nem a minha), sem resumo. Nenhuma leitura nova é iniciada; respostas em voo são descartadas (docs/91 O9).
- RF-E5. **Sessão expirada** (`unauthenticated` em qualquer leitura): fluxo existente; nada parcial; respostas em voo descartadas.
- RF-E6. **Falha parcial** (D13): há dado de pelo menos 1 amigo (`ok`, do servidor ou do cache) e alguns falharam (`unavailable`, timeout de 8 s, desconhecido, ou não iniciados por causa do disjuntor) ⇒ ranking com quem carregou + aviso com N = número de amigos em `failed` (singular/plural na T1) + "Tentar novamente", que relê **só** os de `failed`. O aviso aparece quando a carga termina.
- RF-E7. **Amigo negado** (`permission-denied`: me removeu, me bloqueou, conta excluída já concluída): sai do ranking em silêncio, sai da lista de amigos em memória e do cache de perfil **na hora**; não conta como "não participa" nem como falha; dispara **1 recontagem por carga** (não uma por negação). Se todos os considerados foram negados, a tela segura o esqueleto até a recontagem responder (nunca mostra "erro" nem RF-E8/E9 nesse intervalo); recontagem 0 ⇒ RF-V3.
- RF-E8. **Ninguém compartilha** (eu não compartilho, confirmado, e nenhum amigo participa): mensagem RF-E8 + faixa RF-E10 + rodapé.
- RF-E9. **Só eu** (eu compartilho e nenhum amigo participa): minha linha em 1º + mensagem RF-E9 + rodapé.
- RF-E10. **Eu não compartilho** (D9, `meSharing == false` = documento confirmado sem `stats`; com a Fatia S, docs/95 §10): faixa fixa no topo com duas variantes (T1): busca desligada ⇒ botão "Ir para o Perfil" (`/profile`); "falta confirmar" (E2 do docs/95) ⇒ botão "Revisar", que abre o aviso A do docs/95. Enquanto `meSharing == null` (estado do dono ainda não confirmado nesta sessão: ranking como 1ª tela social, esperando o `readOwn`), nem a faixa, nem a minha linha, nem o resumo, nem RF-E8/E9 aparecem: esqueleto até a confirmação (a faixa nunca pisca).
- RF-E11. **Não participam** (D10): rodapé com a contagem das respostas `ok` sem `stats` (inclui `not-found` e `stats` que não é mapa). Nunca conta falhas, negados, nem amigos além do limite. 0 ⇒ sem rodapé.
- RF-E12. **Desatualizado** (D11): marcador na linha do **amigo** (nunca na minha, porque eu vejo o Perfil ao vivo), conforme O6; a pessoa continua no ranking com os números que tem.
- RF-E13. **Período sem movimento**: `nobodyScored` ⇒ lista normal (todos "1º", "empatado") + mensagem RF-E13 acima das linhas. **Todos desconhecidos** (`ranked = 0`): linhas com "—" e o resumo correspondente, sem mensagem extra.

### Requisitos não funcionais
- RNF1 **Privacidade por construção**: só `shared_profiles/{uid}` de amigos mútuos, por `get` permitido pela regra atual (`isOwner || isGoogle && isFriend`, 1 chamada); `list` continua negado; nenhum dado de favoritos de terceiros; o ranking não grava nada no servidor.
- RNF2 **Spark**: sem Cloud Functions; sem regra nova (D16); sem índice novo.
- RNF3 **Nunca perder dados**: nenhuma escrita nesta fase; nenhuma mudança em favoritos, progresso, snapshot ou dados sociais. Abrir o ranking não altera o motor do snapshot.
- RNF4 **Cota e concorrência**: leituras de amigos numa **janela deslizante de até 10 `get` simultâneos** (antes da primeira resposta `ok`/`denied` a janela não desliza; a partir dela, inclusive, cada resposta libera a próxima: `iniciados = min(N, 10 + respostas desde a 1ª ok/denied)`), timeout de 8 s por leitura e disjuntor nas 10 primeiras respostas (docs/91 §10.3, O9). Leituras e cobrança por cenário: docs/91 O11.
- RNF5 **Revogação**: remover/bloquear por mim ⇒ fora do ranking na próxima renderização, sem leitura; pelo outro ⇒ negado pela regra na próxima leitura do servidor (D8).
- RNF6 **Isolamento de conta**: sair/trocar de conta ou desativar/reativar amizades descarta o estado de `FriendProfileCache`, `FriendsController`, `FriendsCountController` e `RankingController` e o último filtro da sessão; a pista do uid anterior não é lida para o novo; uma carga em curso na troca (geração antiga) não grava nada no cache novo.
- RNF7 **Acessibilidade e layout**: 320/375/768/769/1024/1440 px × fonte 1×/2×/3× × claro/escuro, sem overflow (`tester.takeException()` nulo) nem rolagem horizontal; apelidos de 40 caracteres com reticências e texto completo no `Semantics`. Rótulos Semantics literais na T1; ordem de foco e teclas na **T3**.
- RNF8 **Mensagens sem vazamento**: o motivo de um amigo não aparecer nunca é exposto por nome; `permission-denied` nunca mostrado cru.
- RNF9 **Relógio injetável**: o relógio do ranking (`ServerClock` + `max(updatedAt)`, docs/91 O5) e o `socialClockProvider` (TTL, cooldowns) são falsos nos testes.
- RNF10 **Textos em português**, comparados literalmente com a T1 nos testes de unidade (`ranking_texts_test`) e de widget.

### T1 - Textos (oráculo literal de `RankingTexts`)
Números visíveis com separador de milhar pt-BR ("1.234"); nos rótulos Semantics, sem separador ("1234"). Plural: 1 = singular; 0 e ≥ 2 = plural.

| Chave | Texto pt-BR exato |
|---|---|
| `entry` (menu do topo, Perfil) / tooltip (`MobileTopBar`) / título | "Ranking" |
| `seeRanking` (topo de Amigos) | "Ver ranking" |
| `periodLabel` / `metricLabel` (rótulos dos seletores) | "Período" / "Estatística" |
| períodos (ordem do seletor) | "Este mês", "Este ano", "Total" |
| métricas (ordem do seletor) | "Episódios assistidos", "Filmes assistidos", "Séries assistidas", "Séries concluídas", "Horas assistidas" |
| `refresh` | "Atualizar" |
| `refreshCooldown` (SnackBar; constante da F1 `kListJustRefreshedMessage`) | "A lista já está atualizada (atualizada há instantes)." |
| `summary(p, n)` | "Sua posição: 3º de 8" (sem ponto final; N = `ranked`) |
| `summaryNotIn` (`meSharing == false`) | "Você não está no ranking" |
| `summaryUnknown` (eu participo, meu valor é desconhecido; N5) | "Sua posição: sem informação" |
| `you` (rótulo visível na minha linha) | "Você" |
| `position(p)` | "1º", "2º", "10º", "51º" |
| `RF-E2` | "Não foi possível carregar o ranking." |
| `retry` | "Tentar novamente" |
| `RF-E3` | "Sem conexão. Conecte-se para ver o ranking." |
| `RF-E4` (texto existente `SocialFailureKind.quotaExceeded`) | "Muitas operações hoje. Tente de novo amanhã." |
| `RF-E5` (existente) | "Sessão expirada. Entre novamente." |
| `RF-E6` | 1: "Não foi possível carregar 1 amigo. As posições podem mudar." · N: "Não foi possível carregar 2 amigos. As posições podem mudar." |
| `RF-E8` | "Nenhum amigo compartilha estatísticas ainda." |
| `RF-E9` | "Nenhum amigo compartilha estatísticas ainda. Quando compartilharem, eles aparecem aqui." |
| `RF-E10` faixa / botão (busca desligada) | "Você não aparece no ranking dos seus amigos porque "Aparecer na busca" está desligado." / "Ir para o Perfil" |
| `RF-E10` faixa / botão (falta confirmar, docs/95 E2) | "Você não aparece no ranking dos seus amigos porque ainda não confirmou o que eles veem." / "Revisar" |
| `RF-E11` | 1: "1 amigo não compartilha estatísticas." · N: "2 amigos não compartilham estatísticas." |
| `RF-E12` | "Atualizado há 8 dias" (N ≥ 8 sempre, então só plural) · sem `updatedAt` ou `calc` inválido: "Atualização desconhecida" |
| `RF-E13` | "Ninguém pontuou neste período ainda." |
| `RF-R9` (texto genérico da F2) | "Marcações anteriores a esta versão contam só no total." |
| `RF-R12` | com N: "O ranking compara você com 50 dos seus 80 amigos." · sem N: "O ranking compara você com 50 dos seus amigos." |
| `RF-V3` (SnackBar) | "Você não tem mais amigos no CineTrack." |

**Valores por métrica** (visível · Semantics):
| Métrica | 0 | 1 | 1234 | teto |
|---|---|---|---|---|
| Filmes assistidos | "0 filmes" · "0 filmes assistidos" | "1 filme" · "1 filme assistido" | "1.234 filmes" · "1234 filmes assistidos" | "100.000 filmes" |
| Séries assistidas | "0 séries" · "0 séries assistidas" | "1 série" · "1 série assistida" | "1.234 séries" · "1234 séries assistidas" | "100.000 séries" |
| Séries concluídas | "0 séries" · "0 séries concluídas" | "1 série" · "1 série concluída" | "1.234 séries" · "1234 séries concluídas" | "100.000 séries" |
| Episódios assistidos | "0 episódios" · "0 episódios assistidos" | "1 episódio" · "1 episódio assistido" | "1.234 episódios" · "1234 episódios assistidos" | "1.000.000 episódios" |
| desconhecido (qualquer) | "—" · "sem informação" | | | |

**Horas assistidas** (D14; valor = minutos; `< 60` ⇒ "M min"; `≥ 60` ⇒ "H h MM min", minutos com 2 dígitos):
| Minutos | Visível | Semantics |
|---|---|---|
| 0 | "0 min" | "0 minutos de tempo assistido" |
| 1 | "1 min" | "1 minuto de tempo assistido" |
| 45 | "45 min" | "45 minutos de tempo assistido" |
| 60 | "1 h 00 min" | "1 hora de tempo assistido" |
| 61 | "1 h 01 min" | "1 hora e 1 minuto de tempo assistido" |
| 600 / 659 | "10 h 00 min" / "10 h 59 min" | "10 horas de tempo assistido" / "10 horas e 59 minutos de tempo assistido" |
| 74 045 | "1.234 h 05 min" | "1234 horas e 5 minutos de tempo assistido" |
| 52 560 000 (teto) | "876.000 h 00 min" | "876000 horas de tempo assistido" |

**Semantics de linha** (uma linha = um nó, botão):
| Caso | Rótulo exato |
|---|---|
| normal | "3º lugar, Ana, 120 episódios assistidos" |
| empatado (qualquer linha do grupo) | "1º lugar, empatado, Ana, 120 episódios assistidos" |
| eu | "Você, 3º lugar, 120 episódios assistidos" |
| eu empatado | "Você, 1º lugar, empatado, 120 episódios assistidos" |
| desconhecido / eu desconhecido | "Ana, sem informação" / "Você, sem informação" |
| desatualizado (sufixo) | "3º lugar, Ana, 120 episódios assistidos, atualizado há 8 dias" · "…, atualização desconhecida" |

### T2 - Filtros no endereço (D3, D15)
Formato canônico: `/ranking?estatistica=<filmes|series|concluidas|episodios|horas>&periodo=<mes|ano|total>`. Padrão: `episodios` · `ano`. "Último filtro da sessão" = memória (não disco) do último par escolhido nesta sessão (RF-V2), descartada na troca de conta.

| Entrada | Filtro exibido | URL depois de abrir |
|---|---|---|
| `/ranking` (sem query), 1ª vez na sessão | Episódios assistidos · Este ano | reescrita para `?estatistica=episodios&periodo=ano` |
| `/ranking` (sem query), depois de ter escolhido Horas · Total nesta sessão | Horas assistidas · Total | reescrita para `?estatistica=horas&periodo=total` |
| `?estatistica=horas&periodo=ano` | Horas · Este ano | inalterada |
| `?estatistica=xyz`, `?periodo=semana`, `?estatistica=&periodo=` (1ª vez na sessão) | o parâmetro inválido cai no último da sessão, senão no padrão; o válido vale | reescrita só nos parâmetros inválidos/ausentes |
| `?estatistica=HORAS&periodo=Ano` | Horas · Este ano (valores sem diferenciar maiúsculas) | reescrita em minúsculas |
| `?periodo=ano&periodo=mes` | Este ano (primeira ocorrência) | reescrita com uma ocorrência só |
| `?estatistica=filmes&periodo=mes&utm=x` | Filmes · Este mês | `utm=x` preservado |
| `?Estatistica=filmes` (chave com maiúscula) | chave desconhecida: preservada e ignorada; `estatistica` ausente ⇒ último/padrão | reescrita acrescenta `estatistica` |
| `/#/ranking?estatistica=horas&periodo=ano` recarregado | Horas · Este ano | inalterada |

Navegação: reescrita e troca de filtro **não criam entrada no histórico** do navegador e **não refazem a pilha**: depois de 3 trocas de filtro, o "voltar" do AppBar (desktop) continua presente e leva à rota anterior ao ranking (ex.: Início). "Voltar" do navegador sai do ranking (verificado no smoke; teste de widget na VM não observa o histórico). Mecanismo: docs/91 §9.

### T3 - Foco e leitura (RNF7, B10)
Seletores: **Período** e **Estatística** são dois menus suspensos (um foco cada): Enter/Espaço abre, setas movem dentro do menu, Enter/Espaço seleciona, Esc fecha sem mudar. Uma linha = **um** foco (avatar e apelido juntos); Enter/Espaço abre o perfil (amigo) ou `/profile` (eu). A minha linha é focável. Ao trocar um filtro com a fase `content`, o app anuncia o resumo da T1 (`SemanticsService.announce`; ex.: "Sua posição: 3º de 8"); sem resumo, não anuncia nada.

Ordem de leitura (leitor de tela); **negrito** = parada de Tab, na mesma ordem:
| Estado | Ordem |
|---|---|
| conteúdo, eu compartilho | [**Voltar** (só desktop)] → **Período** → **Estatística** → **Atualizar** → resumo → [aviso de limite] → [nota RF-R9] → [mensagem RF-E13] → **linhas**, de cima para baixo → [rodapé RF-E11] |
| conteúdo, eu não compartilho | … **Atualizar** → resumo ("Você não está no ranking") → faixa RF-E10 → **Ir para o Perfil** (ou **Revisar**) → [aviso de limite] → [nota] → **linhas** → [rodapé] |
| parcial | … resumo → [faixa + **Ir para o Perfil** (ou **Revisar**)] → aviso RF-E6 → **Tentar novamente** → [aviso de limite] → [nota] → **linhas** → [rodapé] |
| só eu | … **Atualizar** → resumo ("Sua posição: 1º de 1") → **linha "Você"** → mensagem RF-E9 → [rodapé] |
| ninguém compartilha | … **Atualizar** → resumo → faixa RF-E10 → **Ir para o Perfil** (ou **Revisar**) → mensagem RF-E8 → [rodapé] |
| carregando | [**Voltar**] → **Período** → **Estatística** → (Atualizar desabilitado, fora do Tab) → [**linha "Você"**] → esqueleto (não focável) |
| erro / cota | [**Voltar**] → mensagem → **Tentar novamente** |
| offline | [**Voltar**] → mensagem |

### Estados de UI
| Estado | O que aparece |
|---|---|
| sem sessão / amizades inativas / 0 amigos confirmados | rota redireciona (RF-V4); entrada ausente |
| sinal pendente | entrada só com pista fresca; em `/ranking`, esqueleto, sem redirect |
| carregando a frio | filtros + esqueleto (+ minha linha se confirmada) |
| conteúdo | resumo, linhas ordenadas, rodapé "não compartilham" (se > 0) |
| eu não compartilho | faixa RF-E10 + linhas dos amigos que participam |
| estado do dono não confirmado | esqueleto, sem faixa nem resumo (RF-E10) |
| só eu | minha linha em 1º + RF-E9 |
| ninguém compartilha | RF-E8 + faixa RF-E10 |
| falha parcial | linhas carregadas + aviso RF-E6 |
| erro total / offline / cota / sessão expirada | RF-E2 / RF-E3 / RF-E4 / fluxo existente (sem filtros nem linhas) |
| atualizando | ranking anterior visível + progresso no botão "Atualizar" |
| desatualizado | marcador na linha do amigo (RF-E12) |
| valor desconhecido | linha no fim, "—", sem posição |
| marcações sem data (mês/ano) | nota RF-R9 |
| mais amigos que o limite | aviso RF-R12 |
| último amigo removido | RF-V3 |

### Critérios de aceite
Convenções: relógio falso; hoje = **2026-10-15T15:00Z** (12:00 em America/Sao_Paulo, `tz = −180`) salvo indicação; "log" = log de operações dos fakes (gets por uid, consultas da lista, agregadas, `readOwn`, escritas, `Source`); filtro padrão = **Episódios assistidos · Este ano** (D3) salvo indicação; textos entre aspas = T1. Oráculos tabulares (O1–O11 no docs/91, T1–T3 aqui) são testados linha a linha; os cenários abaixo cobrem o comportamento de ponta a ponta.

```gherkin
# ================= Visibilidade da entrada e rota =================
Esquema do Cenário: Sem amigos, sem entrada
  Dado que Bruno tem amizades ativas e 0 amigos confirmados pelo servidor
  E a largura é <largura> px
  Então nenhuma das 4 entradas (menu do topo, MobileTopBar, "Ver ranking" em Amigos, item no Perfil) mostra "Ranking"
  Quando ele abre /#/ranking
  Então é levado para /friends
  Exemplos:
    | largura |
    | 320 |
    | 375 |
    | 768 |
    | 769 |
    | 1024 |
    | 1440 |

Cenário: Primeiro amigo faz a entrada aparecer sem recarregar
  Dado que Bruno tem 0 amigos confirmados, está na Início e a lista de amigos não está carregada
  Quando ele aceita um pedido de amizade
  Então a entrada "Ranking" aparece em todas as entradas da largura atual
  E o log, depois do aceite, tem 0 agregadas e 0 gets de shared_profiles

Cenário: Pedido cruzado e convite contam um amigo só
  Dado que Bruno tem 0 amigos confirmados
  Quando um pedido cruzado vira amizade com Carla e o aceite também chama o ajuste para Carla
  Então o contador vale 1 (não 2)

Cenário: Remover o último amigo faz a entrada sumir na hora
  Dado que Ana tem 1 amigo confirmado e está com /ranking visível
  Quando ela bloqueia esse amigo pelo perfil aberto a partir do ranking e volta
  Então a entrada "Ranking" some sem recarregar e sem leitura
  E abrir /#/ranking leva a /friends

Cenário: Último amigo removido em /friends empilhado sobre /ranking
  Dado que Ana abriu /friends a partir de "Ver ranking" e /ranking está empilhado embaixo
  Quando ela remove o último amigo em /friends
  Então nenhum SnackBar "Você não tem mais amigos no CineTrack." aparece em /friends
  Quando ela toca "Voltar"
  Então o ranking não é exibido e ela chega à rota anterior ao ranking

Cenário: Remoção feita pelo outro lado, com a lista no cooldown dela
  Dado que Carla é a única amiga de Ana, Carla remove Ana em outro aparelho
  E a lista de amigos de Ana foi lida há 10 s (cooldown de 15 s da lista)
  E o ranking foi lido há 60 s
  Quando Ana toca "Atualizar"
  Então a lista não é relida, o get de shared_profiles/{Carla} recebe permission-denied
  E Carla sai do ranking, da lista em memória e do cache, e há 1 agregada de recontagem
  E a recontagem responde 0, aparece "Você não tem mais amigos no CineTrack." e Ana vai para /friends

Cenário: Remoção feita pelo outro lado, com a lista fora do cooldown
  Dado o mesmo, mas a lista de amigos foi lida há 60 s
  Quando Ana toca "Atualizar"
  Então a lista relida volta vazia e completa, o contador vai a 0 confirmado sem agregada
  E o log tem 0 gets de shared_profiles
  E aparece "Você não tem mais amigos no CineTrack." e Ana vai para /friends

Cenário: Pista local enquanto confirma
  Dado que a pista de Ana é {has: true, at: há 1 h} e a contagem ainda não respondeu
  Então a entrada aparece e /ranking não redireciona (esqueleto)
  Quando a contagem responde 0
  Então a entrada some e /ranking vai para /friends

Cenário: Pista vencida ou de outra conta não vale
  Dado que a pista de Ana tem 24 h e 1 s
  Então o acesso é pending, a entrada não aparece e /ranking mostra o esqueleto sem redirect
  Dado que existe a pista {has: true} do uid de Ana e Davi entra na mesma aba
  Então a pista de Ana não é lida para Davi

Cenário: Sinal de amigos custa 1 leitura por sessão
  Dado que Ana tem amizades ativas
  Quando a sessão começa
  Então o log tem exatamente 1 agregada de friendships
  E navegar entre telas e voltar do background não fazem outra
  Quando a aba é recarregada
  Então há mais 1 agregada (nova sessão)

Esquema do Cenário: Rota protegida
  Dado <situação>
  Quando alguém abre /#/ranking
  Então <resultado>
  Exemplos:
    | situação                                               | resultado                     |
    | ninguém conectado                                      | vai para /                    |
    | sessão ainda carregando                                | fica, esqueleto               |
    | conta não Google                                       | vai para /friends             |
    | Davi com amizades desativadas                          | vai para /friends             |
    | amizades carregando (SocialPhase.loading), sem pista   | fica, esqueleto               |
    | SocialPhase.loadFailed                                 | fica, esqueleto               |
    | 0 amigos confirmados                                   | vai para /friends             |
    | sem pista e contagem em voo                            | fica, esqueleto               |
    | 1 amigo (confirmado ou ajuste local)                   | fica, ranking                 |

Cenário: Desativar amizades com o ranking aberto e reativar
  Dado que Ana está em /ranking
  Quando desativa as amizades
  Então a entrada some, ela vai para /friends e o estado do ranking e a pista são descartados
  Quando reativa
  Então há 1 agregada nova antes de a entrada voltar

Cenário: Recarregar mantém o filtro
  Dado que Ana está em /ranking?estatistica=horas&periodo=ano
  Quando recarrega a página
  Então vê "Horas assistidas" e "Este ano" selecionados

Esquema do Cenário: Filtro no endereço (tabela T2)
  Quando Ana abre <entrada> na 1ª vez da sessão
  Então vê <filtro> selecionado, sem erro, e a URL fica <url>
  Exemplos:
    | entrada                              | filtro                          | url                                          |
    | /ranking                              | Episódios assistidos · Este ano | ?estatistica=episodios&periodo=ano           |
    | /ranking?estatistica=xyz              | Episódios assistidos · Este ano | ?estatistica=episodios&periodo=ano           |
    | /ranking?periodo=semana               | Episódios assistidos · Este ano | ?estatistica=episodios&periodo=ano           |
    | /ranking?estatistica=&periodo=        | Episódios assistidos · Este ano | ?estatistica=episodios&periodo=ano           |
    | /ranking?estatistica=HORAS&periodo=Ano | Horas assistidas · Este ano    | ?estatistica=horas&periodo=ano               |
    | /ranking?periodo=ano&periodo=mes      | Episódios assistidos · Este ano | ?estatistica=episodios&periodo=ano           |
    | /ranking?estatistica=filmes&periodo=mes&utm=x | Filmes assistidos · Este mês | ?estatistica=filmes&periodo=mes&utm=x |

Cenário: Sem query abre o último filtro da sessão
  Dado que Ana escolheu Horas assistidas · Total e saiu do ranking
  Quando abre o ranking pela entrada (sem query)
  Então vê Horas assistidas · Total

Cenário: Trocar filtro não perde o voltar
  Dado que Ana abriu o ranking pela Início (desktop)
  Quando troca o filtro 3 vezes
  Então o "voltar" do AppBar continua presente e leva à Início

# ================= Participantes e privacidade =================
Cenário: Só amigos com "Estatísticas" ligado participam
  Dado que Ana compartilha estatísticas
  E Carla compartilha, Davi compartilha só atividades, Eva não tem documento, Fábio tem stats: 3
  E Gil tem stats: {} e Hugo tem stats com todos os campos inválidos
  Quando Ana abre o ranking
  Então as linhas são Ana, Carla, e no fim Gil e Hugo com "—" sem posição
  E o rodapé diz "3 amigos não compartilham estatísticas."
  E nenhuma linha, rótulo ou Semantics contém "Davi", "Eva" ou "Fábio"

Cenário: Eu não compartilho
  Dado que Ana não compartilha estatísticas (estado confirmado pelo servidor) e Carla compartilha
  Quando Ana abre o ranking
  Então vê a faixa RF-E10 e o botão "Ir para o Perfil", que leva a /profile
  E a única linha é Carla e o resumo é "Você não está no ranking"

Cenário: Minha linha sai do meu próprio documento, sem leitura extra
  Dado que Ana compartilha estatísticas e o estado do dono já foi lido nesta sessão
  Quando ela abre o ranking
  Então o log não tem get de shared_profiles/{Ana} nem readOwn novo
  E os números da linha "Você" são os de SharingState.doc pelo mesmo leitor estrito

Cenário: Ranking como 1ª tela social da sessão
  Dado que a aba abre direto em /#/ranking e o estado do dono ainda não foi lido
  Então o log tem 1 readOwn (leitura de sessão do dono, não do ranking)
  E até ele responder não há faixa RF-E10, nem minha linha, nem resumo, nem RF-E8/E9 (esqueleto)

Cenário: Desligar e religar meu "Estatísticas" com o ranking empilhado
  Dado que Ana está no ranking e abre o Perfil por cima
  Quando desliga "Estatísticas" e volta
  Então a linha "Você" sumiu, a faixa RF-E10 aparece e o log não tem leitura nova
  Quando religa "Estatísticas" e volta
  Então a linha "Você" volta com o doc otimista, sem leitura

Cenário: Bloquear um amigo pelo perfil o tira do ranking na hora
  Dado que Carla está no ranking de Ana
  Quando Ana bloqueia Carla pelo perfil de amigo, o bloqueio termina (pumpAndSettle) e ela volta
  Então Carla não aparece, o cache não tem a entrada de Carla e o log tem 0 gets para isso

Esquema do Cenário: Bloquear a partir de outros lugares ajusta o contador
  Dado que Ana tem 2 amigos confirmados
  Quando bloqueia <pessoa> a partir de <origem>
  Então o contador fica <efeito>
  Exemplos:
    | pessoa               | origem                                   | efeito                         |
    | a amiga Carla        | busca, com a lista carregada e Carla nela | 1, sem leitura                 |
    | Zeca (não amigo)     | pedido recebido, lista carregada e completa | 2, sem leitura               |
    | Carla                | busca, com a lista não carregada          | recontagem (1 agregada)        |

Cenário: Amigo que desligou "Estatísticas" sai na próxima leitura
  Dado que Carla estava no ranking de Ana e desligou "Estatísticas"
  Quando Ana toca "Atualizar" fora do cooldown
  Então Carla não aparece e o rodapé conta Carla entre os que não compartilham

Cenário: Ex-amigo dentro do TTL (risco aceito, D8)
  Dado que Ana viu Carla no ranking há 2 min e Carla desfez a amizade há 1 min em outro aparelho
  Quando Ana reabre o ranking sem tocar "Atualizar"
  Então os números exibidos de Carla são os da entrada do cache (o mesmo objeto) e o log tem 0 gets
  E ao tocar "Atualizar" (fora do cooldown) Carla sai do ranking

Cenário: Amigo exclui a conta
  Dado que a exclusão da conta de Carla está em curso (par existe, documento já apagado)
  Quando Ana abre o ranking
  Então o get de Carla volta not-found e Carla conta no rodapé
  Quando a exclusão termina (par apagado) e Ana toca "Atualizar" fora do cooldown
  Então o get é negado, Carla some sem contar no rodapé e há 1 recontagem

Cenário: Trocar de conta limpa o ranking
  Dado que Carla viu o ranking
  Quando Carla sai e Davi entra na mesma aba
  Então FriendProfileCache, FriendsController, FriendsCountController e RankingController não têm estado de Carla
  E a pista de Carla não é lida e nada do ranking de Carla é exibido
  E uma carga de Carla ainda em voo na troca não grava nada no cache de Davi

Cenário: Excluir a minha conta apaga a pista
  Quando Ana exclui a conta
  Então friendsHint:{Ana} é apagada junto com socialHint e sharedHint

# ================= Ordenação, empates e períodos =================
Esquema do Cenário: Empates (D4) - resumo; oráculo completo em docs/91 O1
  Dado os valores <valores> em Episódios assistidos / Este mês
  Então a ordem e as posições exibidas são <posições>
  Exemplos:
    | valores                                   | posições |
    | Ana 10, Bia 10, Caio 8                     | Ana 1º, Bia 1º, Caio 3º (Ana e Bia "empatado") |
    | Zé 5 (Você), Ana 5                         | Ana 1º, Zé 1º "Você" (ordem: Ana, Zé) |
    | Ana 0, Bia 0                               | Ana 1º, Bia 1º + "Ninguém pontuou neste período ainda." |
    | Ana 3, Bia —, Caio 1                       | Ana 1º, Caio 2º, Bia sem posição no fim |
    | "Álvaro" 4, "Ana" 4, "alice" 4             | alice, Álvaro, Ana, todos 1º |
    | "ana"(u2) 4, "Ana"(u1) 4, "ANA"(u3) 4      | Ana(u1), ana(u2), ANA(u3), todos 1º |
    | 10, 8, 8, 8, 3                             | 1º, 2º, 2º, 2º, 5º |

Cenário: Horas assistidas ordena por minutos
  Dado Ana com 600 min e Bia com 659 min em Total
  Então Bia é 1º com "10 h 59 min" e Ana 2º com "10 h 00 min"

Cenário: Amigo com o mesmo apelido que eu
  Dado que eu sou "Ana" (u1) e tenho uma amiga "Ana" (u2) com o mesmo valor
  Então as duas linhas aparecem em ordem de uid e só a minha tem o rótulo "Você"

Cenário: Mês do dono que já passou conta 0
  Dado que o snapshot de Carla tem month.key = "2026-09" com 40 episódios e year.key = "2026" com 90
  Então em Este mês Carla tem "0 episódios" e em Este ano "90 episódios"

Cenário: Dezembro lido em janeiro
  Dado o instante 2027-01-05T15:00Z e Carla com tz = -180, month.key "2026-12", year.key "2026"
  Então em Este mês e Este ano Carla tem 0 e em Total o valor gravado

Cenário: Cada participante no próprio fuso
  Dado o instante 2026-11-01T02:30Z
  E Ana com tz = -180 e month.key "2026-10", Carla com tz = 0 e month.key "2026-11"
  Então em Este mês Ana tem o valor de outubro e Carla o de novembro

Cenário: Virada de mês com a tela aberta
  Dado o ranking aberto em 2026-11-01T02:59:59Z com Carla (tz -180, month.key "2026-10", 7 episódios) em Este mês
  Quando o relógio avança 1 s
  Então Carla passa a "0 episódios" sem nenhuma leitura

Cenário: Trocar filtro não lê nada
  Dado o ranking carregado
  Quando Ana troca de Episódios para Filmes e de Este ano para Total
  Então o log não tem nenhuma leitura nova, a ordem é recalculada e a URL é atualizada

Cenário: Nota de marcações sem data (RF-R9)
  Dado que Carla participa com undatedEpisodes = 300 e datedFrom em 2026-10-02
  Quando Ana escolhe Este mês
  Então aparece "Marcações anteriores a esta versão contam só no total."
  E em Total a nota não aparece
  Mas se o único com undated > 0 é um amigo que não participa ou falhou, a nota não aparece

# ================= Leitor estrito (D12) - resumo; oráculo em docs/91 O2/O3 =================
Esquema do Cenário: Valores descartados viram "sem informação"
  Dado que o snapshot de Carla tem watchedEpisodes em total = <valor>
  Então em Episódios / Total Carla aparece <resultado>
  Exemplos:
    | valor         | resultado |
    | 12            | com 12, posicionada |
    | 12.0 (double) | com 12, posicionada |
    | -0.0          | com 0, posicionada |
    | 1000000       | com "1.000.000 episódios" (no teto) |
    | 12.5          | "—", sem posição, no fim |
    | Infinity      | "—" |
    | NaN           | "—" |
    | 1e300         | "—" |
    | -1            | "—" |
    | 1000001       | "—" (acima do teto) |
    | "12"          | "—" |
    | true          | "—" |
    | null / ausente | "—" |

Cenário: Período maior que o total
  Dado que Carla tem watchedMovies month = 50, year = 50, total = 10 (chaves do período atual)
  Então Filmes assistidos de Carla é "—" em Total, Este ano e Este mês
  E as outras métricas de Carla não mudam

Cenário: Teste no navegador
  Dado os arquivos ranking_reading_test, ranking_table_test, ranking_period_test e ranking_texts_test
  Quando rodam com flutter test e com flutter test --platform chrome
  Então os mesmos resultados valem nas duas plataformas
  E os valores vêm de literais Dart, de jsonDecode, de double.parse/double.infinity e, no Chrome, de jsify().dartify()

# ================= Desatualizado (D11) - oráculo em docs/91 O6 =================
Esquema do Cenário: Marcador de desatualizado
  Dado agora = 2026-10-15T15:00Z e o updatedAt de Carla = <updatedAt>
  Então a linha de Carla <marcador>
  Exemplos:
    | updatedAt               | marcador |
    | 2026-10-08T15:00:00Z    | não tem marcador (7 d) |
    | 2026-10-07T15:00:01Z    | não tem marcador (7 d 23:59:59) |
    | 2026-10-07T15:00:00Z    | mostra "Atualizado há 8 dias" |
    | ausente                 | mostra "Atualização desconhecida" |
  E a minha linha nunca tem marcador

# ================= Estados (fases e leituras em docs/91 O9 e O11) =================
Cenário: Offline não mostra ninguém
  Dado que Ana viu o ranking há 1 min e o aparelho fica offline
  Quando ela reabre o ranking
  Então vê só "Sem conexão. Conecte-se para ver o ranking."
  E nenhuma linha (nem a dela), nenhum filtro, faixa, resumo ou rodapé
  Quando a conexão volta
  Então o ranking aparece com 0 gets (cache fresco)

Cenário: Erro total
  Dado 5 amigos e todas as leituras respondem unavailable com o aparelho online
  Então vê "Não foi possível carregar o ranking." e "Tentar novamente", sem linhas

Cenário: Erro da lista de amigos
  Dado que a lista de amigos não está em memória e a leitura dela falha com unavailable
  Então vê "Não foi possível carregar o ranking." e o log tem 0 gets de shared_profiles

Cenário: Disjuntor
  Dado 50 amigos e as 10 primeiras respostas são unavailable
  Então vê "Não foi possível carregar o ranking." e o log tem exatamente 10 gets iniciados

Cenário: Falha parcial (D13)
  Dado 5 amigos que compartilham, 2 deles com timeout de 8 s (relógio falso no timeout do fake)
  Então, quando a carga termina, vê 3 amigos (e eu) ordenados e "Não foi possível carregar 2 amigos. As posições podem mudar."
  Quando toca "Tentar novamente" (sem cooldown)
  Então o log tem exatamente 2 gets, dos 2 que falharam

Cenário: Cota
  Dado 20 amigos e as respostas chegam na ordem: 1ª ok, 2ª ok, 3ª resource-exhausted
  E, pela janela, 12 leituras foram iniciadas (10 + 2) e 9 estão em voo
  Então vê "Muitas operações hoje. Tente de novo amanhã." e "Tentar novamente"
  E nenhuma linha (nem a minha), nenhum resumo, nenhuma leitura nova
  E as 9 respostas em voo não entram no cache (só as 2 ok anteriores ficam)

Cenário: Sessão expirada no meio da carga
  Dado que a 4ª resposta é unauthenticated
  Então segue o fluxo existente de sessão expirada, nada parcial, e as respostas seguintes não entram no cache

Cenário: Sair da tela no meio da carga
  Dado uma carga com 6 leituras em voo
  Quando Ana sai do ranking
  Então as respostas que chegam depois não gravam estado nem cache e nada lança
  Quando ela reabre
  Então só os amigos que não estavam no cache antes de sair são lidos

Cenário: Duas cargas simultâneas
  Dado a carga a frio em curso
  Quando "Atualizar" é acionado (ou a tela pede de novo)
  Então há uma carga só (o log não duplica gets)

Cenário: Mesmo amigo aberto em paralelo no perfil e no ranking
  Dado que o ranking ainda lê Carla
  Quando Ana abre o perfil de Carla
  Então o log tem no máximo 2 gets de Carla e o estado final das duas telas é coerente

Cenário: Ninguém compartilha
  Dado que Ana não compartilha e nenhum dos 3 amigos compartilha
  Então vê "Nenhum amigo compartilha estatísticas ainda." e a faixa RF-E10
  E o rodapé "3 amigos não compartilham estatísticas."

Cenário: Só eu
  Dado que Ana compartilha e nenhum amigo compartilha
  Então vê a linha "Você" em 1º, "Sua posição: 1º de 1" e a mensagem RF-E9

Cenário: Snapshot com schema mais novo
  Dado que o documento de Carla tem v = 2, calc = 2 e campos extras
  Então os campos extras são ignorados e Carla não recebe marcador de desatualizado

# ================= Cota, janela e cooldown (oráculos docs/91 O10 e O11) =================
Cenário: Abrir a frio com 20 amigos
  Dado que Ana tem 20 amigos, a lista está em memória e o cache de perfis está vazio
  Quando ela abre o ranking
  Então o log tem 20 gets de shared_profiles com Source.server e nenhuma consulta em shared_profiles
  E o pico de leituras simultâneas medido pelo fake é 10
  E, com a 1ª resposta ok, a 11ª leitura começa quando a 1ª termina, sem esperar as outras 9

Cenário: Reabrir dentro do TTL
  Dado que Ana abriu o ranking (lista e snapshots lidos no mesmo instante) há 4 min 59 s
  Quando reabre
  Então 0 leituras
  Quando reabre aos 5 min
  Então 1 consulta da lista e 20 gets

Cenário: Ranking e perfil de amigo compartilham o cache
  Dado que Ana abriu o ranking há 1 min
  Quando abre o perfil de Carla pelo ranking
  Então 0 gets e 0 leitura do par, e o cabeçalho vem do extra

Esquema do Cenário: Atualizar com cooldown de 60 s (N1)
  Dado que o ranking foi carregado do servidor em t0
  Quando Ana toca "Atualizar" em <instante>
  Então <resultado>
  Exemplos:
    | instante | resultado |
    | t0+10 s  | 0 leituras e "A lista já está atualizada (atualizada há instantes)." |
    | t0+59 s  | 0 leituras e o mesmo SnackBar |
    | t0+60 s  | 1 consulta da lista e 20 gets |

Cenário: Mais amigos que o limite (D5 = 50)
  Dado que Ana tem 80 amigos confirmados pela contagem e a lista em memória tem 51 itens (50 + 1 aceito agora)
  Então o ranking lê só os 50 primeiros de FriendsController.state.items
  E mostra "O ranking compara você com 50 dos seus 80 amigos."
  Mas sem a contagem confirmada mostra "O ranking compara você com 50 dos seus amigos."

# ================= Navegação, layout, acessibilidade =================
Cenário: Ativar uma linha abre o perfil
  Quando Ana toca (ou foca e aperta Enter ou Espaço) a linha de Carla
  Então vai para /friends/u/<uid de Carla> com o cabeçalho do extra e 0 gets dentro do TTL
  Quando ativa a linha "Você"
  Então vai para /profile

Cenário: Larguras, fonte e tema
  Dado 320, 375, 768, 769, 1024 e 1440 px, fonte 1×, 2× e 3×, claro e escuro
  Quando abro o ranking em cada estado com apelidos de 40 caracteres
  Então tester.takeException() é nulo e não há rolagem horizontal
  E o ícone da MobileTopBar some exatamente na escala calculada por topBarFits (±0,01)
  E em 768 px vale o layout mobile e em 769 px o desktop
  E com fonte 3× em 320 px o ícone some da barra e "Ver ranking" (Amigos) e "Ranking" (Perfil) continuam

Cenário: Teclado e leitor de tela (T3)
  Quando navego com Tab em cada estado da T3
  Então o foco passa exatamente pelas paradas da T3, na ordem
  E cada linha tem o rótulo Semantics literal da T1
  Quando troco o filtro com a fase content
  Então o resumo da T1 é anunciado
```

### Casos de borda
- **Amigo me bloqueia durante a leitura**: o `get` dele volta `permission-denied` ⇒ RF-E7.
- **Amigo exclui a conta no meio**: `not-found` ⇒ "não participa" até a exclusão terminar; depois, `denied` (cenário acima).
- **Eu desativo as amizades com o ranking aberto**: estado descartado, entrada some, redirect (cenário acima).
- **Desligo meu "Estatísticas" e volto ao ranking**: minha linha sai, faixa D9, sem leitura (cenário acima).
- **Meu snapshot desatualizado** (motor esperando W = 5 s): minha linha pode ficar alguns segundos atrás do Perfil ao vivo; é o que os amigos veem (aceito).
- **Virada de mês com a tela aberta**: um `Timer` para a próxima virada entre os fusos dos participantes força o recálculo, sem leitura (docs/91 §7.3).
- **Horário de verão**: vale o `tz` gravado pelo dono (borda de 1 h, aceita na F2).
- **Apelido igual entre dois amigos ou igual ao meu**: desempate final por uid (O1).
- **Apelido vazio/só espaços no par**: o repositório já entrega "Usuário" (`SocialNickname.clean` + fallback em `social_repository.dart:555–560`), então ordenação e Semantics nunca recebem texto vazio.
- **Amigo com `stats` mas sem `month`/`year`**: mês/ano desconhecidos, Total válido.
- **"Ver mais" carregado ou amigo recém-aceito**: o conjunto considerado são os 50 primeiros de `state.items` no momento da carga (RF-R12); uma recarga posterior pode trocar quem entra.
- **Relógio do aparelho errado**: atrasado é corrigido pelo `max(updatedAt)`; adiantado pode dar 0 indevido em "este mês" (aceito, N4; O5).

### Cota (estimativa; não medida em produção)
Os números por cenário, separados em fake / regra / cobrança, estão na tabela **O11** do docs/91 (oráculo dos testes de controller). Resumo:
| Ação | Leituras do app | Regra | Escritas |
|---|---|---|---|
| Sinal "≥ 1 amigo" (agregada) | 1 por sessão (+1 por carga com negação; +1 se a 1ª falhou ou foi descartada) | 0 | 0 |
| Lista de amigos fria | min(N, 50) documentos, +1 só se N > 50 (`limit + 1`); 1 mínimo se N = 0 | 0 | 0 |
| Snapshot de cada amigo a frio (existe ou não) | 1 `get` (`Source.server`) | 1 (`isFriend`) | 0 |
| Snapshot negado (ex-amigo) | 0 documento; cobrança da negação **não verificada** (assumo ≤ 1) | ≤ 1 | 0 |
| Minha linha / trocar filtro / reabrir no TTL / offline / perfil aberto pelo ranking no TTL | 0 | 0 | 0 |
| "Atualizar" (fora do cooldown de 60 s) | lista (se fora dos 15 s dela) + min(N, 50) | min(N, 50) | 0 |

**Abrir a frio** (cache vazio):
| N amigos | Lista fria + snapshots | Lista em memória | % de 50 mil/dia por abertura |
|---|---|---|---|
| 1 | 3 | 2 | 0,006% |
| 5 | 15 | 10 | 0,03% |
| 10 | 30 | 20 | 0,06% |
| 20 | 60 | 40 | 0,12% |
| 50 | 150 | 100 | 0,30% |
| 100 / 300 (limite 50) | 151 | 100 | 0,30% |

Hipótese diária (a mesma da F2: 100 usuários sociais ativos/dia, 3 sessões, 2 aberturas frias/dia, 10 amigos em média): 100 × 2 × 30 = 6 000 + sinal 300 ⇒ **≈ 6 300 leituras/dia (12,6%)**. Somado às Fases 1–2 (≈ 10,3 mil), total ≈ **16,6 mil/dia (≈ 33%)**. Uso pesado acidental: com o cooldown de 60 s, uma pessoa com 50 amigos tocando "Atualizar" sem parar faz no máximo ≈ 6 mil leituras/hora. Bytes: ≈ 3–8 KB por documento típico (até ≈ 30 KB com 50 recomendados): 50 amigos ≈ 0,15–1,5 MB por abertura fria, aceitável no web.

**Consultas por lista de ids:** a documentação do Firestore (consultada em 2026-10-18) permite até 30 cláusulas em `in`, mas com regra por documento o emulador só aceitou **10** ids por consulta `documentId in` (docs/50 §7), e um ex-amigo no lote nega o lote inteiro. Como `list` em `shared_profiles` é negado e o custo cobrado é igual ao de 10 `get`, a decisão é `get` por id com janela de 10 (D16, ADR-007).

### Privacidade
- Participa quem é **amigo mútuo** (par existente; invariante "amigo ⇒ não bloqueado") **e** tem `stats` no documento (só existe com consentimento vigente, garantido pelas regras).
- Desfazer amizade/bloquear (de qualquer lado) **nega a leitura na hora** pelas regras. Do meu lado, a linha some sem leitura (cache e lista limpos no mesmo ponto da F2: `FriendsController.remove`/`afterBlock`). Do outro lado, some na próxima leitura do servidor; no intervalo (≤ TTL de 5 min, sem "Atualizar") eu posso rever **o que já tinha visto** — risco aceito D15 da F2, estendido ao ranking (D8).
- Offline nada de amigos é exibido, nem da memória (D10 da F2). Nada é guardado em disco além da pista booleana `friendsHint` (cache só de memória; `Source.server`).
- Quem não compartilha é contado, nunca nomeado (D10). O ranking não revela "quem me bloqueou": negado some em silêncio e não entra na contagem.
- Consentimento: o diálogo de "Estatísticas" já cita "comparações entre amigos" (D13 da F2). A política muda de tempo verbal (RF-V6), com data nova, junto ou antes do app. Parecer jurídico **não verificado**.

---

## Decisões — Aprovado pelo Manager em 2026-10-24

D1–D16 aprovadas na recomendação, com os refinamentos do Arquiteto (docs/91 §17.2), que já estão refletidos nos requisitos acima. Ajuste do Orquestrador na D3. N1–N5 (docs/91 §18) também aprovadas.

| # | Decisão | Aprovado | Consequência |
|---|---|---|---|
| **D1** | Lista final de estatísticas | **(a)** as 5 métricas validadas por `rankOk`: Filmes assistidos, Séries assistidas, Séries concluídas, Episódios assistidos, Horas assistidas | Toda métrica funciona nos 3 períodos; nenhuma mudança de schema/regra |
| **D2** | Períodos suportados | **(a)** Total, Este ano, Este mês (fuso do dono) | Custo zero; "mês passado" continua fora de escopo |
| D3 | Filtro padrão ao abrir | **Episódios assistidos · Este ano** (ajuste do Orquestrador; a recomendação era Este mês); entrar em `/ranking` sem query abre o **último filtro usado na sessão** (T2) | Evita o "Ninguém pontuou neste período ainda." dos primeiros dias do mês (ressalva do Arquiteto) |
| **D4** | Critério de desempate | **(a)** competição (1º, 1º, 3º), ordem no empate por `collationKey` e uid, "Você" sem prioridade e pelo apelido exibido, "empatado" em todo o grupo | Oráculo O1 |
| **D5** | Limite prático de amigos | **(b) 50** = os 50 primeiros de `FriendsController.state.items` na carga, com aviso | Pior abertura fria ≈ 151 leituras (0,3%); "os 50 mais recentes" não agora (A8) |
| **D6** | Onde a entrada entra | **(a)** menu do topo da Início (desktop, depois de Amigos), ícone na `MobileTopBar` à esquerda de Amigos (primeiro a sair), "Ver ranking" em Amigos e "Ranking" no Perfil; Perfil selecionado na barra inferior em `/ranking` | Nenhuma barra perde destino |
| D7 | Sinal "≥ 1 amigo" | **(a)** contador: agregada 1×/sessão + pista local por uid + ajustes locais + descarte da resposta em voo + recontagem em revogação | Oráculo O7/O8 |
| D8 | Ex-amigo × cache | **(a)** cache de memória de 5 min compartilhado com o perfil de amigo | Ex-amigo revê o que já viu por ≤ 5 min |
| D9 | Minha linha quando não compartilho | **(a)** não apareço + faixa e botão para o Perfil; desde 2026-10-24 "não compartilho" corresponde ao interruptor único "Aparecer na busca" (docs/95) | Reciprocidade; fonte única |
| D10 | Amigos que não compartilham | **(a)** contagem anônima no rodapé (`not-found` + sem `stats` + `stats` não mapa) | Sem pressão por nome |
| D11 | Snapshot desatualizado | **(a)** marcador neutro com `inDays > 7` sobre o relógio do ranking; `updatedAt` ausente e `calc` < 1 também; nunca na minha linha | Oráculo O6 |
| D12 | Valores implausíveis | **(a)** leitor estrito (inteiro, finito, ≤ teto, coerência; chave ilegível/futura = "—") | Oráculos O2–O4 |
| D13 | Falha parcial | **(a)** quem carregou + aviso + "Tentar novamente" só dos que faltam; disjuntor; cota/offline/sessão tudo ou nada | Oráculo O9 |
| D14 | Exibição de horas | **(a)** "1.234 h 05 min", ordena por minutos | T1 |
| D15 | Filtro no endereço | **(a)** `?estatistica=&periodo=`, sem entrada no histórico, pilha preservada | T2 |
| D16 | Regras e forma de leitura | **(a)** nenhuma mudança de regra; `get` por id com janela de 10 | ADR-007 (Aceita) |
| N1 | Cooldown do "Atualizar" | **60 s** (a lista mantém 15 s) | O10 |
| N2/N3 | Hotfix A2 e passo Chrome da CI | **publicados** em `main` 9389bc5 (docs/92); o ranking reutiliza `readSafeInt` | Fatia H não existe mais |
| N4 | Relógio | **`ServerClock` + `max(updatedAt)` só no ranking**; perfil de amigo inalterado | O5 |
| N5 | Texto do meu valor desconhecido | "Sua posição: sem informação" | T1 |

❓ de texto fechados como recomendado pelo PA/Arquiteto (decisão do Orquestrador): RF-V3, RF-R9 (passa a reutilizar o texto genérico da F2), RF-E13, "Atualização desconhecida", RF-R12 sem N e N5 — todos na T1.

## Perguntas ao Arquiteto
A1–A11 respondidas no docs/91 §17.1. Nenhuma pergunta em aberto.

## Fatiamento (atualizado em 2026-10-24; a Fatia H, hotfix A2, já está em produção)
S. **Fatia S — Um interruptor só** (decisão do Manager de 2026-10-24): primeira fatia da Fase 3, especificada no [docs/95](./95-simplificacao-compartilhamento.md) (S0–S4). Vem antes das fatias visíveis do ranking; a Fatia 0 abaixo não conflita.
0. **Fatia 0 — Testes de regra (sem mudar regras)**: `firestore_rules_test/ranking.test.mjs` com a matriz do docs/91 §14.1 (inclui a agregada `count` de `friendships` permitida ao membro e negada com o uid de outra pessoa, e conta excluída com o par presente: `get` permitido, documento inexistente); mutantes RK* em `mutations.mjs`, cada um morto por um teste que **não** é o de sha; gate de sha256 num arquivo **separado** `rules_sha.test.mjs`, que não entra nas suítes dos mutantes, mais o passo de conferência do sha na CI (SRE). Nada de app.
1. **Fatia 1 — Domínio puro** (`lib/ranking/`): leitor estrito (reusa `readCount`; chave de período estrita; coerência; marcador), `RankingTable.rank` com o relógio do ranking, `RankingTexts`; testes parametrizados pelas tabelas O1–O6 e T1, na VM e com `--platform chrome` (acrescentados ao passo Chrome existente da CI).
2. **Fatia 2 — Dados e sinal**: `FriendsCountController` + pista + ganchos (`FriendsController.add` **antes** do retorno antecipado, `remove`, `onFirstPage`, `afterBlock`, `_revoked`), `rankingAccessProvider`; `RankingController` (conjunto considerado, janela de 10 com disjuntor, cache compartilhado, fases, cooldown 60 s, minha linha); fakes com contadores, pico de simultaneidade, timeout injetável e falhas por ordem de chegada. Oráculos O7–O11.
3. **Fatia 3 — Rota, navegação e tela**: `/ranking` + redirect + saída quando empilhado; 4 entradas; barra inferior; filtros na URL (T2); tela, estados, foco (T3), matriz de layout; política (RF-V6) e README.
4. **Fechamento**: review e QA integrados, smoke com contas Google (docs/93 §5), cota no console na 1ª semana, checklist de release no modelo do docs/89. Ordem de publicação: regras = só conferir o sha → política → app.

## Definition of Done (desta especificação)
- [x] B1–B11 e os ajustes menores do docs/93 incorporados no docs/90 e no docs/91, conferidos pelo QA (reconferência de testabilidade).
- [x] Todos os critérios de aceite verificáveis por teste (unit, widget, emulador), com os oráculos O1–O11 e T1–T3 copiáveis 1:1.
- [x] Nenhum ❓ bloqueante em aberto.
- [x] docs/90, docs/91 e ADR-007 coerentes entre si (decisões aprovadas em 2026-10-24).

**Reconferência QA (2026-10-24)** sobre `1738dd2`: B1–B11 OK. Pendências corrigidas antes da Fatia 2, nesta revisão:
- 🔴 Contagens da janela deslizante: fórmula exata `iniciados = min(N, 10 + respostas desde a 1ª ok/denied, inclusive)` no docs/91 §10.3 e RNF4. Ordem de chegada fixada nos oráculos e números corrigidos: O9 linhas 5 (12 iniciados, 9 em voo), 9 e 10 (13 iniciados); O11 linha 13 (12); Gherkin "Cota" (9 em voo).
- 🟡1 `freshAt` conta todas as respostas `ok` dos considerados (com ou sem `stats`); linhas 12–13 novas na O10 ("ninguém compartilha" tem cooldown).
- 🟡2 O7 linha 25: contagem em voo continua em voo e é descartada (`dirty`), como na linha 24.
- 🟡3 docs/91 §9: `Router.neglect` descrito como mecanismo novo (não usado em `lib/`), coberto pelo spike da Fatia 3 e pelo smoke.
- 🟡4 RF-R7: origem do "Usuário" corrigida. O apelido do **amigo** vem de `SocialRepository._friendOf` (`SocialNickname.clean` + "Usuário" se vazio, `social_repository.dart:555–560`). O `SocialNickname.normalize(...) ?? 'Usuário'` (`social_lists_providers.dart:618`) é o do `afterBlock`, para a lista Bloqueados; as duas referências ficaram registradas.
