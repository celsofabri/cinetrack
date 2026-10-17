# 87 - Perfil social (Fase 2), Fatia 3: Perfil de amigo

> Autor: Dev (Backend + Frontend) · Data: 2026-10-17 · Branch: `feat/social-profile` (base 4aeb4bd)
> Entradas: [docs/81](./81-especificacao-perfil-social.md) (RF-F1–F9, textos, estados de UI, cenários "Perfil de amigo"), [docs/82](./82-design-perfil-social.md) §7.2 (tabela resposta → estado, B6/B7), §9, §10, §11, §15 item 3, [docs/83](./83-testabilidade-perfil-social.md) (B6, B7, cenários e mutações), [docs/84](./84-fatia0-regras-perfil-social.md), [docs/85](./85-fatia1-fundacao-perfil-social.md), [docs/86](./86-fatia2-meu-perfil-social.md), [ADR-006](./adr/adr-006-snapshot-perfil-social.md).
> **`firestore.rules` não foi alterado** (sha256 `6135322e…e612`, o publicado). Nenhuma mudança de regra foi necessária: `get friendships/{par}` já é permitido a quem está no par e `get shared_profiles/{uid}` a amigos mútuos. Golden e payloads inalterados. Nada publicado: sem push, sem deploy.

## HANDOFF
De: Dev (Backend + Frontend) → Para: Code Reviewer e QA, depois Orquestrador
Demanda: Fase 2 (perfil social), Fatia 3: Perfil de amigo
Fluxo: feature | Etapa: Fatia 3
Prioridade: P1 (primeira tela em que alguém vê o que um amigo compartilha)

### O que foi feito
**Rota e entrada**
- `GoRoute('/friends/u/:uid')`, irmã de `/friends/add` dentro do `ShellRoute` (protegida pelo `redirect` existente de `/friends/*`; sem login = `/`). Hash sob `/cinetrack/` funciona ao recarregar.
- `redirect` da rota: **próprio uid → `/profile`**, sem leitura.
- uid validado antes de qualquer leitura (`isValidFriendUid`: o `validUid` das regras, `^[^_/]{1,128}$`, e nunca `.`/`..`). Malformado (`a_b`, 129 caracteres, `%2F..%2F`, `a%2Fb`) = "Este perfil não está disponível." + "Voltar para Amigos", **0 leituras**.
- Lista de Amigos: nome/foto do cartão viram um botão ("Abrir o perfil de Fulano" no leitor; toque ou Enter) que faz `context.push('/friends/u/<uid>', extra: Friend)`. Remover/Bloquear continuam no cartão. O diálogo de remoção virou `confirmRemoveFriend` (mesmo texto da Fase 1), usado pela lista e pelo perfil.

**Dados**
- `SocialDataSource.readFriendship(otherUid)` (Firestore: 1 `get` **do servidor** de `friendships/{par ordenado}`; fake com log `friendship:<uid>`) e `SocialRepository.friendship(otherUid)` → `Friend?` (mesmo parser da lista, extraído em `_friendOf`; par que não é entre os dois = `null`).
- `FirestoreSharedProfileDataSource.readFriend`: continua `Source.server` (resposta do cache do aparelho = `unavailable`, nunca exibida) e ganhou o **timeout de 8 s** (`friendTimeout`).
- `SharedProfileRepository.readFriend(uid)` → `FriendSharedView?` (`null` = documento não existe), falhas como `SharedProfileFailure`.
- **Leitura defensiva (RF-F9)**: `lib/shared_profile/shared_stats_reading.dart` (`SharedStatsReading`, `PeriodReading`, `FriendSharedView`). Número ausente, negativo ou de tipo errado = `null` = **"—"** (nunca 0; leitor de tela: "Rótulo: sem informação"); campos desconhecidos ignorados; seção presente = campo presente no documento; atividade malformada/de tipo desconhecido ignorada (parser da Fatia 1); `tz` fora de −840..840 = UTC. O parser estrito do dono (`SharedProfileDoc`, usado pelo motor) **não mudou**.

**Cache e controller** (`lib/providers/friend_profile_providers.dart`)
- `FriendProfileCache`: **só memória**, uma instância por conta **e** por período de amizades (`friendProfileCacheProvider` observa `currentUidProvider` e `socialPeriodProvider`): trocar de conta, sair, desativar/reativar amizades = cache vazio. Guarda por amigo o cartão + o que ele compartilha + a hora da leitura; também os cartões entregues pela lista.
- `friendProfileTtlProvider` = 5 min (D15): `fresh` vale enquanto `agora − leitura < 5 min` (4:59 serve; 5:00 lê).
- `FriendProfileController` (`autoDispose.family` por uid), relógio = `sharedProfileClockProvider`:
  1. uid inválido → indisponível, nada lido.
  2. **Offline (`syncStatus.offline`) → "Sem conexão. Conecte-se para ver o perfil de Fulano." e nada mais**, nem o cache de memória (D10); 0 leituras. Ao voltar a conexão, carrega sozinho (do cache se ainda fresco).
  3. Dentro do TTL → do cache, 0 leituras.
  4. Cabeçalho: cartão entregue pela lista → lista em memória → **`get` do par** (só por endereço sem lista). Par inexistente/negado = indisponível, e o perfil **não** é lido.
  5. `get shared_profiles/{uid}` (Source.server). Uma carga por vez (pedidos simultâneos se juntam).
- "Atualizar"/"Tentar novamente" ignoram o TTL (1 leitura por toque).

**Tabela resposta → estado (docs/82 §7.2), implementada 1:1**
| Resposta | Tela | Efeito |
|---|---|---|
| documento existe | conteúdo; seção ausente = "Fulano não compartilha estatísticas com amigos." / "… atividades com amigos." | grava no cache |
| `not-found` | "Fulano ainda não compartilha nada além do cartão." | grava no cache |
| `permission-denied` (ou par inexistente) | "Este perfil não está disponível." + "Voltar para Amigos" (sem cabeçalho nem ações) | apaga o cache do uid **e** tira o amigo da lista em memória na hora |
| aparelho offline | cabeçalho + "Sem conexão. Conecte-se para ver o perfil de Fulano." | nenhum conteúdo, nem o de memória |
| `unavailable` / timeout 8 s / desconhecido, online | "Não foi possível carregar o perfil." + "Tentar novamente" | nenhum conteúdo |
| `resource-exhausted` | "Muitas operações hoje. Tente de novo amanhã." + "Tentar novamente" | — |
| `unauthenticated` | mensagem de sessão expirada existente + "Entrar" (mesmo `signInWithFeedback` do banner) | — |
| uid inválido | indisponível | nenhuma leitura |
| próprio uid | `/profile` | nenhuma leitura |
| amizades próprias desativadas | o `SocialGate` de `/friends` | nenhuma leitura |
| exclusão interrompida (par existe, documento não) | "não compartilha nada além do cartão"; depois que o par some, indisponível | — |

**Tela** (`lib/screens/friend_profile_screen.dart`)
- Ordem: "Voltar" (foco inicial; volta com `pop`, ou vai a `/friends` num link direto) → cabeçalho (foto, apelido como título, "Amigos desde DD/MM/AAAA" e, **só com Estatísticas**, "No CineTrack desde DD/MM/AAAA" no fuso do dono, D8) → "Atualizado há X" (neutro) + "Atualizar" → Estatísticas (`SharedStatsView`, o mesmo componente da prévia do dono, agora sobre a leitura tolerante; "No CineTrack desde" sai do bloco e vai para o cabeçalho) com "este mês/este ano" no fuso do dono e a nota de datas → Atividades recentes (3 das até 10, `SharedActivityTile` da Fatia 2: frase do RF-A8 + data relativa, toque abre `/movie/:id`/`/tv/:id`, título longo com reticências e frase inteira no leitor, título sem pôster mostra o ícone do tipo; vazia = "Fulano ainda não tem atividades recentes.") → "Remover amizade" / "Bloquear".
- Remover/Bloquear: diálogos e métodos da Fase 1 (`FriendsController.remove/block`, o mesmo `runFor`/`afterBlock`); "Removendo..."/"Bloqueando..." com os dois botões travados; offline = desabilitados + "Sem conexão. Remover amigos exige internet."; erro = mensagem da Fase 1 e continua no perfil; sucesso = SnackBar da Fase 1 ("Amizade removida." / "Pessoa bloqueada. Ela não foi avisada.") e `go('/friends')`. **Toda tentativa (exceto "ocupado") apaga o cache desse amigo**.
- Teclado: Tab = Voltar → Atualizar → cada atividade → Remover amizade → Bloquear (teste); Esc volta para a lista (Esc em diálogo fecha o diálogo). Leitor: estatísticas "Rótulo: valor", "Atualizar o perfil de Fulano", "Remover amizade com Fulano", "Bloquear Fulano", "Voltar para Amigos", regiões vivas nas mensagens de estado.
- Layout: coluna de no máximo 640 px; 320/375/768/1024/1440 × 1×/2×/3× × claro/escuro sem exceção (teste com título de 300 caracteres, rolando até o fim); estados indisponível/offline a 320 px 1× e 3×.
- Recomendados: **fora desta fatia** (Fatia 4): a tela não mostra nada de `recs`, nem a frase "não compartilha recomendados".

### Cota (docs/82 §11, conferida por contadores nos testes)
| Ação | Leituras do app (contadas no fake) | Leitura de regra (`isFriend`) | Cobradas |
|---|---|---|---|
| Abrir pela lista, a frio | 1 (`readFriend`) | 1 | **2** |
| Abrir por endereço, sem lista em memória | 2 (par + `readFriend`) | 1 | 3 |
| Reabrir no TTL (pela lista ou por endereço) | 0 | 0 | 0 |
| Offline | 0 | 0 | 0 |
| "Atualizar" / "Tentar novamente" | 1 | 1 | 2 |
| uid inválido / próprio uid / amizades desativadas | 0 | 0 | 0 |
| Não amigo por endereço | 1 (par: não existe) | 0 | 1 |
Nenhuma escrita nova. Os "2 a frio" do pedido são o `get` + a leitura da regra (docs/82 §11); por endereço o par soma +1 (previsto na mesma tabela).

### Números
| Comando | Resultado |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` (2 rodadas, fuso da máquina) | **1908/1908** nas duas (antes: 1804; +104) |
| `TZ=UTC flutter test` | **1908/1908** |
| `flutter build web --base-href /cinetrack/` | ✓ Built build/web |
| `npm test` (regras) | **não rodado**: `firestore.rules`, fixtures e payloads (golden) inalterados |
| `python3 tool/dart_mutations.py` (lista completa, cópia em /tmp do HEAD final) | **143/143 KILLED** (111 anteriores + 32 novas `V1–V32`), "All Dart mutations were killed." |

### Decisões tomadas (e por quem)
- Dev (sujeitas a review):
  1. **Remover/Bloquear apagam o cache do amigo em qualquer desfecho** (sucesso, erro, incerto), exceto "ocupado": um desfecho incerto pode ter removido a amizade; o custo é 1 leitura na próxima abertura.
  2. `permission-denied` e "par inexistente" mostram só a mensagem neutra e "Voltar para Amigos": sem cabeçalho e sem ações (nada a remover/bloquear de quem não é amigo; e o texto é o mesmo para todos os casos, RNF8).
  3. Offline: o cabeçalho continua (vem da lista, não é conteúdo compartilhado); "Atualizar" e as ações ficam desabilitados; "Tentar novamente" aparece; ao reconectar a tela carrega sozinha (do cache se fresco, senão 1 leitura).
  4. "Atualizar" durante a leitura mostra o esqueleto (o conteúdo anterior some até a resposta), para que uma recusa nunca deixe conteúdo antigo na tela.
  5. Seção presente = **campo** presente no documento (as regras amarram seção ⇔ consentimento); documento só com `recs` (impossível nesta versão) mostra as duas frases "não compartilha …".
  6. Número desconhecido: "—" na tela e "Rótulo: sem informação" no leitor de tela (um "—" lido em voz alta não diz nada). `Tempo assistido: —` idem.
  7. Período cuja chave está ausente = "—" em todas as métricas daquele recorte; chave antiga = zeros (regra B1 da Fatia 2).
  8. Textos sem literal no docs/81: "Fulano ainda não tem atividades recentes." (atividades ligadas e vazias), "Sem conexão. Conecte-se para ver este perfil." (offline sem cabeçalho conhecido), título "Perfil de amigo" na barra do desktop.
  9. O cartão do amigo na lista ficou um botão de linha inteira (nome + foto + chevron), com os botões Remover/Bloquear numa linha abaixo, recuada.

### Desvios do docs/82 (com justificativa)
- §9 "cache de memória com TTL" está num `FriendProfileCache` próprio (provider por conta/período), não dentro do `SharedProfileRepository` (que continua sem estado): a troca de conta/período limpa o cache pelo mesmo mecanismo das listas da Fase 1 (`socialPeriodProvider`), sem o repositório precisar saber disso.
- §7.2 "`permission-denied` remove o amigo da lista em cache" vale também para **par inexistente** (abrir por endereço quem deixou de ser amigo).

### Mutações Dart novas (`V1–V32`, docs/83 §4 desta fatia)
V1 offline serve o cache de memória; V2 `permission-denied` mantém o cache; V3 … mantém o amigo na lista; V4 fronteira do TTL (5:00 ainda servido); V5 TTL nunca expira; V6 "Atualizar" respeita o TTL; V7 leitura do amigo do cache do aparelho (`Source.server` trocado); V8 timeout de 30 s em vez de 8 s; V9 cache mantido na troca de conta/período; V10 … num novo período de amizades; V11 Remover pelo perfil mantém o cache; V12 Bloquear idem; V13 rota aceita uid malformado; V14 uid com `_`; V15 uid > 128; V16 próprio uid sem redirecionar; V17 cartão entregue pela lista ignorado (lê o par); V18 `not-found` não vai para o cache; V19 erro online mostrado como offline; V20 `permission-denied` como erro com "Tentar novamente"; V21 mostra as 10 atividades; V22 número ausente vira 0 (grade); V23 … (leitor); V24 a rota ignora o cartão entregue (`extra`); V25 reconexão não recarrega; V26 cargas simultâneas não se juntam; V27 Esc não volta; V28 sem foco inicial em "Voltar"; V29 Remover habilitado offline; V30 "Atualizar" habilitado offline; V31 `tz` fora da faixa aceito; V32 "No CineTrack desde" sem Estatísticas (D8).
Primeira rodada (só V1–V32 + Q9/Q10/Q18): 34 de 35 mortas; sobreviveu a primeira versão de `V24` ("o cartão da lista não passa o `extra`"), **equivalente**: o cartão tocado está sempre na lista em memória, a segunda fonte do cabeçalho. A `V24` foi reapontada para a rota (`extra` ignorado) com um teste novo (push com `extra` sem lista carregada = 0 leituras do par; `extra` de outro uid nunca é usado) e morre.
`Q9`, `Q10`, `Q18` (Fatia 2, prévia do dono) foram reapontadas para a grade nova (`r.total.watchedEpisodes`, `r.total.completedSeries`, `r.series`; mesma intenção).

### Suposições (não verificadas)
- SDK web: `GetOptions(source: Source.server)` offline falha (não cai no cache) e `isFromCache` é falso numa resposta do servidor (mesma suposição da Fatia 1; o `_get` recusa resposta do cache).
- go_router 14: `push` não muda a barra de endereço (`optionURLReflectsImperativeAPIs` desligado), como `/friends/add` hoje; recarregar depois de abrir pela lista volta a `/friends`. Abrir/recarregar o endereço `/friends/u/<uid>` funciona (teste).
- Emulador = produção nas regras (risco 10 do docs/82): nenhuma regra nova; o smoke com 2 contas (docs/83 §5) confere `isFriend` e a cobrança real.

### Riscos / atenção
- **Risco aceito D15**: um ex-amigo que reabre o perfil em até 5 min, sem "Atualizar", revê o que já viu (teste "ex-friend reopening within the TTL"). A cópia do SDK no cache persistente do leitor nunca é exibida.
- Primeira tela que mostra dados de terceiros: publicar junto com a política da Fatia 2 (já descreve o que amigos veem) — nada novo é guardado ou compartilhado nesta fatia.
- Smoke (Manager, 2 contas): abrir pela lista e por endereço, reabrir no TTL (0 leituras no console), offline real, remover/bloquear pelo perfil, leitor de tela real.

### Artefatos
- Código novo: `lib/providers/friend_profile_providers.dart`, `lib/screens/friend_profile_screen.dart`, `lib/shared_profile/shared_stats_reading.dart`.
- Alterados: `lib/router.dart`, `lib/screens/friends_screen.dart`, `lib/widgets/{block_dialogs,shared_profile_widgets,profile_stats_card}.dart`, `lib/shared_profile/shared_profile_texts.dart`, `lib/data/{social_data_source,firestore_social_data_source,firestore_shared_profile_data_source}.dart`, `lib/repositories/{social_repository,shared_profile_repository}.dart`.
- Testes: `test/friend_profile_test.dart` (app inteiro sobre os fakes), `test/friend_profile_unit_test.dart`; fakes: `readFriendship`/`pairGate` no `FakeSocialCloud`, `friendsLink`/`friendGate` no `FakeSharedProfileCloud` (amizade do fake social = `isFriend`), `FriendsApp.shared/friendReads/pairReads` no harness; `tool/dart_mutations.py` (`V1–V32`, Q9/Q10/Q18 reapontadas).

### Critério de aceite deste handoff
- Code Review e QA aprovados; `flutter analyze` limpo; `flutter test` e a suíte Dart de mutações verdes no ambiente do revisor. Depois, merge e publicação do app (sem regras novas).
