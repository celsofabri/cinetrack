# 90 - Especificação: Ranking entre amigos (Fase 3 de 5)

> Autor: Product Analyst · Base: `main` em `827cec5` (Fases 1 e 2 em produção; `firestore.rules` publicado = sha `6135322e…e612`) · Branch: `feat/social-ranking`
> Entradas: prompt do Manager da Fase 3; [docs/81](./81-especificacao-perfil-social.md) (D1–D17 aprovadas), [docs/82](./82-design-perfil-social.md) (§4.4 schema, §5.1 períodos, §7.2 perfil de amigo, §11/§11.1 cota), [ADR-006](./adr/adr-006-snapshot-perfil-social.md), [docs/84](./84-fatia0-regras-perfil-social.md) (`rankOk` aceita `double`), [docs/87](./87-fatia3-perfil-de-amigo.md) (cache/TTL do perfil de amigo), [docs/50 §7](./50-design-amizades.md) (limites de chamadas em consultas).
> **Status: etapa 1 (análise) + parte de especificação da etapa 2, para revisão do Manager.** As decisões D1–D16 (§ Decisões) estão **pendentes**; nada será implementado antes da aprovação. O design (docs/91) é do Arquiteto, com as perguntas A1–A11.
> **Este documento só especifica.** Nenhum código ou regra foi alterado por ele.
> Conjunto social: F1 amizades (feita) → F2 perfil (feita) → **F3 ranking** → F4 avaliações → F5 comentários.
> Legenda: **RF** requisito funcional, **RNF** requisito não funcional, **D** decisão do Manager, **A** pergunta ao Arquiteto, ❓ dúvida em aberto.

---

## Etapa 1 - Análise

### 1.1 O que o snapshot da Fase 2 oferece ao ranking (lido em `main` 827cec5)

Fonte única: `shared_profiles/{uid}.stats` (docs/82 §4.1/§4.4), que só existe enquanto o dono mantém **"Estatísticas"** ligado (regra: `stats` ⇔ `sharing.stats`). Pela D13 (aprovada) esse mesmo interruptor governa o ranking, e o texto literal do consentimento já diz "…no seu perfil **e nas comparações entre amigos**". Quem já ligou "Estatísticas" consentiu com o ranking; **não é preciso consentimento novo**.

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

**Períodos (já suportados, sem mudança de schema).** `stats.month.key` ("AAAA-MM") e `stats.year.key` ("AAAA") são calculados **no fuso do dono**. O leitor calcula "agora no fuso do dono" (`agoraUtc + tz`): "este mês" = `stats.month` se a chave é o mês atual do dono, senão **0**; idem para o ano (docs/82 §5.1; `PeriodReading.current` já faz isso em `lib/shared_profile/shared_stats_reading.dart`). Todos os leitores veem o mesmo número de um amigo, que é o que o ranking precisa. **Conclusão: Total, Este mês e Este ano são suportados pelo snapshot atual; nenhuma mudança mínima é necessária.**

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
| L5 | **Leitor atual `readCount` usa `v is int`**: no Flutter **web** um número JS inteiro "é" `int`, e `double.infinity is int` **pode** ser verdadeiro no dart2js (confiança média, **não verificado**) | `Infinity` poderia passar como contagem, inclusive no perfil de amigo da Fase 2 | leitor do ranking checa `isFinite` e teto explicitamente; teste em `--platform chrome` (A2). Achado também vale para a F2 (exibição) |
| L6 | **Números falsos plausíveis** (D12 da F2, risco aceito) | no ranking o incentivo a falsificar é maior (ficar em 1º) | sem servidor não há remédio completo; teto + coerência no leitor, remover/bloquear (D12 desta fase) |
| L7 | **Snapshot desatualizado** só é detectável por `updatedAt` (pulso de 24 h só com o app aberto) | "desatualizado" = o dono não abre o app há dias; os números podem estar certos | marcador neutro "Atualizado há N dias" acima de um limiar (D11) |
| L8 | **Marcações antigas sem data** contam só no Total (D5 da F2) | "este mês/ano" favorece quem começou depois da versão nova; Total favorece o histórico | aceitar; nota quando há marcações sem data (RF-R9) |
| L9 | **Fuso diferente entre amigos**: na virada do mês, um amigo já está em "novembro" e outro ainda em "outubro" | por algumas horas os "este mês" não cobrem o mesmo intervalo | aceitar e documentar (cada um no próprio mês, regra B1 da F2) |
| L10 | **A barra inferior (mobile) já tem 5 destinos** (Início, Explorar, Recomendo, Favoritos, Perfil), o máximo recomendado pelo Material 3; a barra superior mobile já esconde o ícone Amigos quando não cabe | não há lugar "natural" para uma 6ª aba | D6 |
| L11 | **Lista de amigos sem ordem definida no servidor** (`members array-contains`, sem `orderBy`): a 1ª página de 50 sai na ordem do id do par | um limite de N amigos escolhe um subconjunto arbitrário (estável, mas sem critério visível) | D5 |
| L12 | **Política diz que os números "servirão para comparações entre amigos"** (futuro) | texto fica desatualizado quando o ranking for ao ar | trocar para o presente ("são usados no ranking entre amigos"), sem mudar o que é compartilhado (RF-V6) |

### 1.3 Riscos
| # | Risco | Impacto | Mitigação proposta |
|---|---|---|---|
| R1 | **Cota de leituras** cresce linearmente com N amigos (2 cobradas por amigo a frio + lista) | estouro do Spark afeta todos | limite prático (D5), cache de memória compartilhado com o perfil de amigo (TTL 5 min), filtros sem leitura, "Atualizar" com cooldown de 15 s |
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
- **Zero vazamento**: suíte de regras prova que não amigo, ex-amigo, bloqueado (2 sentidos), anônimo e conta não Google não leem `shared_profiles/{uid}` e que `list` (inclusive `documentId in`) continua negado; teste de widget prova que amigo sem `stats` não aparece em nenhuma linha.
- **Zero escrita**: abrir, filtrar e atualizar o ranking não gravam nada (log de operações do fake sem escrita).
- **Cota**: abrir a frio com N amigos (N ≤ limite) = **2N** leituras cobradas + a lista de amigos se não estiver em memória; trocar filtro = **0**; reabrir no TTL = **0** (contadores dos fakes).
- **Remoção imediata**: depois de eu remover/bloquear um amigo, a próxima renderização do ranking não tem a linha dele, sem leitura.

### Escopo
- Inclui:
  - Rota **`/ranking`** (no shell), entrada na navegação **só com ≥ 1 amigo mútuo** (D6, D7), proteção no `redirect`.
  - Ranking de **eu + amigos mútuos com "Estatísticas" ligado**, filtro por **estatística** (D1) e **período** Total / Este ano / Este mês (D2), filtro padrão (D3).
  - Destaque da minha posição, critério de empate (D4), avatar/apelido levam ao perfil do amigo (`/friends/u/:uid`) e minha linha ao `/profile`.
  - Indicador de snapshot desatualizado (D11), aviso quando eu não compartilho (D9), contagem de quem não participa (D10).
  - Estados: carregando, erro, offline, cota, sessão expirada, falha parcial, todos os amigos sem compartilhamento, só eu, sem amigos (rota).
  - Leitor estrito para o ranking (D12), limite prático de amigos (D5) com aviso, leitura em lotes.
  - Testes de regra novos (sem mudar regras), testes de unidade e de widget com fakes, README e trecho da política.
- Não inclui:
  - Mudança de schema do snapshot, novas métricas gravadas, "mês passado"/histórico de períodos (fora de escopo desde a F2).
  - Ranking por **recomendações** (outro consentimento) ou por **favoritos** em períodos (não existe no snapshot).
  - Ranking global, de amigos de amigos ou de não amigos; ligas, medalhas, notificações ("Fulano passou você"), histórico de posições.
  - Validação "verdadeira" dos números (impossível sem servidor; D12 da F2 continua aceito).
  - Ligar "Estatísticas" de dentro do ranking (o consentimento continua no Perfil; o ranking só leva até lá, D9).
  - Android/iOS (app em produção é web; nada aqui deve impedir as outras plataformas).

### Requisitos funcionais

**RF-V: Visibilidade da entrada e rota**
- RF-V1. A entrada **Ranking** aparece na navegação somente quando: há sessão Google, as amizades estão **ativas** (`socialActiveProvider`) **e** o usuário tem **≥ 1 amigo mútuo** (par em `friendships`). Não depende de alguém compartilhar estatísticas.
- RF-V2. O sinal "≥ 1 amigo" (D7): pista local por uid (mostrada enquanto confirma), confirmada por **1 leitura do servidor por sessão** (contagem agregada) e ajustada **sem leitura** pelas ações deste aparelho: aceitar pedido / pedido cruzado vira amizade ⇒ ≥ 1; remover/bloquear o último amigo ⇒ 0. Qualquer leitura da lista de amigos ou do ranking que constate 0 amigos (primeira página vazia e sem mais) também atualiza o sinal.
- RF-V3. Quando o sinal passa a 0 **com o app aberto**, a entrada **some na hora** (sem recarregar) em todas as larguras; se a tela Ranking está aberta, ela é substituída pelo destino do redirect (RF-V4) com a mensagem "Você não tem mais amigos no CineTrack." ❓ (texto a validar).
- RF-V4. `/ranking` é protegida no `redirect`: sem sessão ⇒ `/`; sessão sabida, amizades inativas **ou** sinal confirmado = 0 ⇒ `/friends` (onde se ativam amizades ou se adicionam amigos). Enquanto a sessão ou o sinal ainda carregam, **não redireciona** e a tela mostra o esqueleto (mesmo padrão de `/profile`). Recarregar a página em `/#/ranking` funciona.
- RF-V5. Remoção feita pelo **outro lado** (outro aparelho): a entrada some quando o app **descobre** (próxima confirmação de sessão, reconexão, leitura da lista de amigos ou do ranking com resultado 0). Não há listener (decisão da Fase 1; ver D7 (b) se o Manager quiser tempo real).
- RF-V6. A política (`web/privacidade.html`, data nova) passa a dizer, no presente, que os números de "Estatísticas" "aparecem no **Ranking** dos seus amigos mútuos"; nada novo é compartilhado. O `PrivacySummary` ganha a mesma frase se citar a seção.

**RF-R: Ranking**
- RF-R1. Participantes: **eu** (só se eu compartilho "Estatísticas", D9) + cada amigo mútuo cuja leitura do servidor retorne documento **com** `stats` (mapa). Amigo com documento sem `stats`, sem documento (`not-found`) ou com `stats` que não é mapa **não aparece** e entra na contagem "não participam" (D10).
- RF-R2. **Métricas** (D1, recomendação): Filmes assistidos (`watchedMovies`), Séries assistidas (`watchedSeries`), Séries concluídas (`completedSeries`), Episódios assistidos (`watchedEpisodes`), Horas assistidas (`minutes`). Rótulos iguais aos do Perfil.
- RF-R3. **Períodos** (D2): Total, Este ano, Este mês. "Este mês/ano" de cada participante segue o fuso **dele** (`PeriodReading.current` com `periodKey(agoraUtc, tz)`): chave antiga ⇒ **0**; chave ausente/ilegível ⇒ desconhecido.
- RF-R4. **Ordenação**: valor decrescente. **Empates** (D4, recomendação): mesma posição para valores iguais com numeração de competição ("1º, 1º, 3º"); dentro do empate, ordem por apelido (mesma `collationKey` da lista de Amigos) e depois uid; "Você" não tem prioridade. Horas: ordena por **minutos** (o empate é no minuto, não na hora exibida).
- RF-R5. **Valor desconhecido** (campo ausente, ilegível ou descartado pelo leitor estrito, RF-L): a pessoa aparece **depois** de todos os que têm valor, **sem posição** ("—"), em ordem de apelido. Não conta como 0.
- RF-R6. **Zero** é valor: participantes com 0 são ordenados normalmente (todos com 0 empatam).
- RF-R7. **Linha**: posição ("1º"), avatar (foto do par, `Friend.photoUrl`; a minha, a do Google), apelido (do par; o meu, `displayLabelProvider`), valor formatado (pt-BR, separador de milhar: "1.234 episódios"; horas conforme D14), e marcador de desatualizado (D11). Minha linha tem destaque visual **e** textual ("Você") e o resumo "Sua posição: 3º de 8" no topo (ou "Você não está no ranking", D9).
- RF-R8. Tocar (ou Enter) no avatar/apelido de um amigo abre `/friends/u/<uid>` com o `Friend` como `extra` (cabeçalho sem leitura) e, se a entrada do cache de memória está fresca, o perfil abre **sem leitura**. Minha linha abre `/profile`.
- RF-R9. Nota de datas: se o período é Este mês/ano e **algum** participante tem `undatedMovies + undatedEpisodes > 0`, aparece uma nota única sob os filtros: "Marcações feitas antes da versão com datas contam só no total." ❓ (texto a validar).
- RF-R10. **Filtros sem leitura**: trocar métrica ou período reordena os dados já em memória (0 leituras). O filtro fica no endereço (D15): `/ranking?estatistica=<m>&periodo=<p>`; valor inválido ⇒ padrão (D3), sem erro.
- RF-R11. **"Atualizar"**: relê do servidor a lista de amigos (se fora do cooldown de 15 s) e os snapshots, ignorando o TTL; durante a leitura mantém o ranking anterior visível com indicador de progresso; cooldown de 15 s como nas listas da Fase 1 (dentro dele: "A lista já está atualizada.").
- RF-R12. **Limite prático** (D5, recomendação 50): se tenho mais amigos que o limite, o ranking usa os primeiros `limite` da lista de amigos e mostra "O ranking compara você com 50 dos seus N amigos." (N vindo da contagem, quando conhecida).

**RF-L: Leitor estrito para o ranking (D12)**
- RF-L1. Um valor de métrica só é usado se: numérico, **finito**, **inteiro** (`v == v.truncate()`), ≥ 0 e ≤ teto da tabela do docs/82 §4.4 (`watchedEpisodes` ≤ 1 000 000; `minutes` ≤ 52 560 000; filmes/séries ≤ 100 000). Senão o valor é **desconhecido** (RF-R5) naquela métrica/período.
- RF-L2. Coerência por métrica: se `month > year` ou `year > total` (para a mesma métrica, quando as chaves são do período atual), os três valores dessa métrica daquele participante ficam desconhecidos.
- RF-L3. `updatedAt` ausente/ilegível ⇒ trata como desatualizado (D11). `tz` fora de −840..840 ⇒ 0 (como hoje). `calc` < mínimo exigido (hoje 1) ⇒ desatualizado.
- RF-L4. O leitor estrito é **só do ranking**; o perfil de amigo da Fase 2 continua com o leitor tolerante (exceto a correção de `Infinity`, se o Arquiteto confirmar L5, A2).

**RF-E: Estados**
- RF-E1. **Carregando a frio**: esqueleto de linhas; filtros visíveis e habilitados; a minha linha (se eu compartilho) já pode aparecer.
- RF-E2. **Erro** (`unavailable`/timeout 8 s em **todas** as leituras, ou falha da lista de amigos) online: "Não foi possível carregar o ranking." + "Tentar novamente".
- RF-E3. **Offline** (D10 da F2): "Sem conexão. Conecte-se para ver o ranking." **Nenhum** dado de amigo, nem do cache de memória. Minha linha também não aparece (a tela não vira "só eu"). Ao reconectar, carrega (do cache se fresco).
- RF-E4. **Cota** (`resource-exhausted` em qualquer leitura): mensagem de cota existente + "Tentar novamente"; nada parcial.
- RF-E5. **Sessão expirada** (`unauthenticated`): fluxo existente.
- RF-E6. **Falha parcial** (D13, recomendação): alguns amigos carregaram, outros falharam com `unavailable`/timeout ⇒ mostra o ranking com quem carregou e o aviso "Não foi possível carregar N amigos. As posições podem mudar." + "Tentar novamente" (relê só os que falharam).
- RF-E7. **Amigo negado** (`permission-denied`: me removeu, me bloqueou, excluiu a conta): sai do ranking em silêncio, sai da lista de amigos em memória e do cache de perfil **na hora** (mesmo `_revoked` do perfil de amigo); não conta como "não participa" nem como falha. Se era o último amigo, RF-V3.
- RF-E8. **Todos os amigos com compartilhamento desligado** e eu também: "Nenhum amigo compartilha estatísticas ainda." + aviso D9.
- RF-E9. **Só eu** (eu compartilho, nenhum amigo compartilha): minha linha em 1º + "Nenhum amigo compartilha estatísticas ainda. Quando compartilharem, eles aparecem aqui."
- RF-E10. **Eu não compartilho** (D9): faixa fixa no topo: "Você não aparece no ranking dos seus amigos porque suas estatísticas não estão compartilhadas." + botão "Compartilhar estatísticas" que leva a `/profile` (seção "O que seus amigos veem"). Se meu estado de compartilhamento ainda não foi confirmado pelo servidor nesta sessão, a faixa espera a confirmação (não pisca).
- RF-E11. **Não participam** (D10): rodapé "N amigos não compartilham estatísticas." (sem nomes; 1 = "1 amigo não compartilha estatísticas.").
- RF-E12. **Desatualizado** (D11): na linha, texto neutro "Atualizado há N dias" quando `agora − updatedAt > 7 dias` (ou RF-L3); a pessoa continua no ranking com os números que tem.
- RF-E13. **Período sem movimento**: todos os participantes com 0 na métrica/período ⇒ lista normal (todos "1º") + "Ninguém pontuou neste período ainda." ❓ (texto a validar).

### Requisitos não funcionais
- RNF1 **Privacidade por construção**: só `shared_profiles/{uid}` de amigos mútuos, por `get` permitido pela regra atual (`isOwner || isGoogle && isFriend`, 1 chamada); `list` continua negado; nenhum dado de favoritos de terceiros; o ranking não grava nada.
- RNF2 **Spark**: sem Cloud Functions; sem regra nova (D16); sem índice novo.
- RNF3 **Nunca perder dados**: nenhuma escrita nesta fase; nenhuma mudança em favoritos, progresso, snapshot ou dados sociais. Abrir o ranking não altera o motor do snapshot.
- RNF4 **Cota**: ver § Cota. Leituras de amigos em **lotes de até 10 `get` em paralelo** (alinhado ao limite medido de 10 chamadas por consulta e para não abrir dezenas de requisições simultâneas; A4), timeout de 8 s por leitura (como o perfil de amigo).
- RNF5 **Revogação**: remover/bloquear por mim ⇒ fora do ranking na próxima renderização, sem leitura; pelo outro ⇒ negado pela regra na próxima leitura do servidor (D8).
- RNF6 **Isolamento de conta**: sair/trocar de conta ou desativar/reativar amizades descarta todo o estado do ranking e o cache (mesmo `socialPeriodProvider`/`currentUidProvider`).
- RNF7 **Acessibilidade e layout**: 320/375/768/1024/1440 px × fonte 1×/2×/3× × claro/escuro, sem overflow nem rolagem horizontal; apelidos longos com reticências e texto completo no `Semantics`; cada linha anunciada como "3º lugar, Ana, 120 episódios assistidos" (empate: "3º lugar, empatado, …"; minha: "Você, 3º lugar, …"; desconhecido: "Ana, sem informação"); filtros operáveis por Tab/Shift+Tab, setas, Enter/Espaço; ordem de foco: Período → Estatística → "Atualizar" → faixa D9 (botão) → linhas → rodapé.
- RNF8 **Mensagens sem vazamento**: o motivo de um amigo não aparecer nunca é exposto por nome; `permission-denied` nunca mostrado cru.
- RNF9 **Relógio injetável**: o mesmo `sharedProfileClockProvider` para "este mês/ano", desatualizado e TTL.
- RNF10 **Textos em português**, comparados literalmente nos testes de widget.

### Estados de UI
| Estado | O que aparece |
|---|---|
| sem sessão / amizades inativas / 0 amigos | rota redireciona (RF-V4); entrada ausente |
| sinal de amigos carregando | entrada pela pista local; em `/ranking`, esqueleto, sem redirect |
| carregando a frio | filtros + esqueleto de linhas (+ minha linha se conhecida) |
| conteúdo | "Sua posição: Xº de N", linhas ordenadas, rodapé "não compartilham" |
| eu não compartilho | faixa RF-E10 + linhas dos amigos que compartilham |
| só eu | minha linha em 1º + RF-E9 |
| ninguém compartilha | RF-E8 + faixa RF-E10 |
| falha parcial | linhas carregadas + aviso RF-E6 |
| erro total | RF-E2 |
| offline | RF-E3, nenhum número |
| cota | RF-E4 |
| sessão expirada | fluxo existente |
| atualizando | ranking anterior visível + progresso no botão "Atualizar" |
| desatualizado | "Atualizado há N dias" na linha (RF-E12) |
| valor desconhecido | linha no fim, "—", sem posição |
| marcações sem data (mês/ano) | nota RF-R9 |
| mais amigos que o limite | aviso RF-R12 |
| último amigo removido com a tela aberta | RF-V3 |

### Critérios de aceite
Convenções: relógio falso (`sharedProfileClockProvider`); hoje = 15/10/2026 12:00 em America/Sao_Paulo (`tz = −180`) salvo indicação; "log" = log de operações dos fakes; métrica padrão = Episódios assistidos, período padrão = Este mês (D3) salvo indicação.

```gherkin
# ================= Visibilidade da entrada e rota =================
Cenário: Sem amigos, sem entrada
  Dado que Bruno tem amizades ativas e 0 amigos confirmados pelo servidor
  Então nem o menu do topo (1024 px) nem a barra superior (375 px) mostram "Ranking"
  Quando ele abre /#/ranking
  Então é levado para /friends

Cenário: Primeiro amigo faz a entrada aparecer sem recarregar
  Dado que Bruno tem 0 amigos e está na Início
  Quando ele aceita um pedido de amizade em /friends
  Então a entrada "Ranking" aparece sem nova leitura e sem recarregar

Cenário: Remover o último amigo faz a entrada sumir na hora
  Dado que Ana tem 1 amigo e está com /ranking aberto
  Quando ela remove esse amigo em /friends (ou bloqueia pelo perfil)
  Então a entrada "Ranking" some sem recarregar
  E abrir /#/ranking leva a /friends

Cenário: Remoção feita pelo outro lado
  Dado que Carla é a única amiga de Ana e remove Ana em outro aparelho
  Quando Ana toca "Atualizar" no ranking
  Então a leitura de shared_profiles/{Carla} recebe permission-denied
  E Carla sai do ranking, da lista de amigos em memória e do cache de perfil
  E a entrada "Ranking" some e Ana vai para /friends

Cenário: Pista local enquanto confirma
  Dado que a pista local de Ana diz "tem amigos" e a contagem ainda não respondeu
  Então a entrada aparece
  E /ranking não redireciona e mostra o esqueleto
  Mas se a contagem responde 0
  Então a entrada some e /ranking vai para /friends

Cenário: Sinal de amigos custa 1 leitura por sessão
  Dado que Ana tem amizades ativas
  Quando a sessão começa
  Então o log tem exatamente 1 consulta de contagem de friendships
  E navegar entre telas não faz outra

Cenário: Rota protegida sem sessão e com amizades desativadas
  Quando ninguém está conectado e alguém abre /#/ranking
  Então é levado para /
  Quando Davi está conectado com amizades desativadas e abre /#/ranking
  Então é levado para /friends

Cenário: Recarregar mantém o filtro
  Dado que Ana está em /ranking?estatistica=horas&periodo=ano
  Quando recarrega a página
  Então vê "Horas assistidas" e "Este ano" selecionados

Esquema do Cenário: Filtro inválido no endereço
  Quando Ana abre /ranking?<query>
  Então vê Episódios assistidos e Este mês selecionados, sem erro
  Exemplos:
    | query |
    | estatistica=xyz |
    | periodo=semana |
    | estatistica=&periodo= |

# ================= Participantes e privacidade =================
Cenário: Só amigos com "Estatísticas" ligado participam
  Dado que Ana compartilha estatísticas
  E Carla compartilha estatísticas, Davi compartilha só atividades e Eva não tem documento
  Quando Ana abre o ranking
  Então as linhas são Ana e Carla
  E o rodapé diz "2 amigos não compartilham estatísticas."
  E nenhuma linha, rótulo ou Semantics contém "Davi" ou "Eva"

Cenário: Eu não compartilho
  Dado que Ana não compartilha estatísticas (estado confirmado pelo servidor) e Carla compartilha
  Quando Ana abre o ranking
  Então vê "Você não aparece no ranking dos seus amigos porque suas estatísticas não estão compartilhadas."
  E o botão "Compartilhar estatísticas" leva a /profile
  E a única linha é Carla e o resumo é "Você não está no ranking"

Cenário: Minha linha sai do meu próprio documento, sem leitura extra
  Dado que Ana compartilha estatísticas e o estado do dono já foi lido nesta sessão
  Quando ela abre o ranking
  Então o log não tem leitura de shared_profiles/{Ana}
  E os números da linha "Você" são os do documento que os amigos veem

Cenário: Bloquear um amigo pelo perfil o tira do ranking na hora
  Dado que Carla está no ranking de Ana
  Quando Ana bloqueia Carla pelo perfil de amigo e volta ao ranking
  Então Carla não aparece e nenhuma leitura foi feita para isso

Cenário: Amigo que desligou "Estatísticas" sai na próxima leitura
  Dado que Carla estava no ranking de Ana e desligou "Estatísticas"
  Quando Ana toca "Atualizar"
  Então Carla não aparece e o rodapé conta Carla entre os que não compartilham

Cenário: Ex-amigo dentro do TTL (risco aceito, D8)
  Dado que Ana viu Carla no ranking há 2 min e Carla desfez a amizade há 1 min em outro aparelho
  Quando Ana reabre o ranking sem tocar "Atualizar"
  Então pode ver os mesmos números de Carla de 2 min atrás e nada mais novo
  E ao tocar "Atualizar" Carla sai do ranking

Cenário: Trocar de conta limpa o ranking
  Dado que Carla viu o ranking
  Quando Carla sai e Davi entra na mesma aba
  Então nada do ranking de Carla é exibido a Davi e o cache está vazio

# ================= Ordenação, empates e períodos =================
Esquema do Cenário: Empates (D4)
  Dado os valores <valores> em Episódios assistidos / Este mês
  Então as posições exibidas são <posições>
  Exemplos:
    | valores                                   | posições                 |
    | Ana 10, Bia 10, Caio 8                     | Ana 1º, Bia 1º, Caio 3º   |
    | Zé 5, Ana 5 (Zé é "Você")                  | Ana 1º, Você 1º (ordem: Ana, Zé) |
    | Ana 0, Bia 0                               | Ana 1º, Bia 1º + "Ninguém pontuou neste período ainda." |
    | Ana 3, Bia — (desconhecido), Caio 1        | Ana 1º, Caio 2º, Bia sem posição no fim |
    | "Álvaro" 4, "Ana" 4, "alice" 4             | ordem alice, Álvaro, Ana (collationKey), todos 1º |

Cenário: Horas assistidas ordena por minutos
  Dado Ana com 600 min e Bia com 659 min em Total
  Então Bia é 1º e Ana 2º, mesmo que as duas mostrem "10 h" na parte inteira
  E os valores exibidos seguem D14

Cenário: Mês do dono que já passou conta 0
  Dado que o snapshot de Carla tem month.key = "2026-09" com 40 episódios e year.key = "2026"
  Então em Este mês Carla tem 0
  E em Este ano Carla tem o valor de "2026"

Cenário: Dezembro lido em janeiro
  Dado que hoje é 05/01/2027 no fuso de Carla e o snapshot dela tem year.key = "2026"
  Então em Este mês e Este ano Carla tem 0 e em Total o valor gravado

Cenário: Cada participante no próprio fuso
  Dado o instante 01/11/2026 02:30 UTC
  E Ana com tz = -180 e month.key "2026-10", Carla com tz = 0 e month.key "2026-11"
  Então em Este mês Ana tem o valor de outubro e Carla o de novembro

Cenário: Trocar filtro não lê nada
  Dado o ranking carregado
  Quando Ana troca de Episódios para Filmes e de Este mês para Total
  Então o log não tem nenhuma leitura nova e a ordem é recalculada

Cenário: Nota de marcações sem data
  Dado que Carla tem undatedEpisodes = 300
  Quando Ana escolhe Este mês
  Então aparece a nota de RF-R9
  E em Total a nota não aparece

# ================= Leitor estrito (D12) =================
Esquema do Cenário: Valores descartados viram "sem informação"
  Dado que o snapshot de Carla tem watchedEpisodes em total = <valor>
  Então em Episódios / Total Carla aparece <resultado>
  Exemplos:
    | valor        | resultado |
    | 12           | com 12, posicionada |
    | 12.5         | "—", sem posição, no fim |
    | 12.0 (double)| com 12, posicionada (valor inteiro) |
    | Infinity     | "—", sem posição |
    | NaN          | "—", sem posição |
    | 1000001      | "—", sem posição (acima do teto) |
    | "12"         | "—", sem posição |
    | ausente      | "—", sem posição |

Cenário: Período maior que o total
  Dado que Carla tem watchedMovies month = 50, year = 50, total = 10 (chaves do período atual)
  Então Filmes assistidos de Carla é "—" em Total, Este ano e Este mês
  E as outras métricas de Carla não mudam

Cenário: Teste no navegador
  Dado a suíte do leitor estrito executada com flutter test --platform chrome
  Então os mesmos exemplos acima passam (números JS no dart2js)

# ================= Desatualizado (D11) =================
Esquema do Cenário: Marcador de desatualizado
  Dado que updatedAt de Carla foi há <tempo>
  Então a linha de Carla <marcador>
  Exemplos:
    | tempo   | marcador |
    | 6 dias  | não tem marcador |
    | 7 dias  | não tem marcador |
    | 8 dias  | mostra "Atualizado há 8 dias" |
    | ausente | mostra "Atualização desconhecida" ❓ |

# ================= Estados =================
Cenário: Offline não mostra ninguém
  Dado que Ana viu o ranking há 1 min e o aparelho fica offline
  Quando ela reabre o ranking
  Então vê "Sem conexão. Conecte-se para ver o ranking."
  E nenhuma linha, nem a dela

Cenário: Erro total
  Dado que todas as leituras respondem unavailable com o aparelho online
  Então vê "Não foi possível carregar o ranking." e "Tentar novamente"

Cenário: Falha parcial (D13)
  Dado 5 amigos que compartilham, 2 deles com timeout de 8 s
  Então vê 3 amigos (e eu) ordenados e "Não foi possível carregar 2 amigos. As posições podem mudar."
  Quando toca "Tentar novamente"
  Então o log tem exatamente 2 leituras, dos 2 que falharam

Cenário: Cota
  Dado que uma leitura responde resource-exhausted
  Então vê a mensagem de cota existente e "Tentar novamente" e nenhuma linha

Cenário: Ninguém compartilha
  Dado que Ana não compartilha e nenhum dos 3 amigos compartilha
  Então vê "Nenhum amigo compartilha estatísticas ainda." e a faixa de RF-E10
  E o rodapé "3 amigos não compartilham estatísticas."

Cenário: Só eu
  Dado que Ana compartilha e nenhum amigo compartilha
  Então vê a linha "Você" em 1º e a mensagem de RF-E9

# ================= Cota e lotes =================
Cenário: Abrir a frio com 20 amigos
  Dado que Ana tem 20 amigos, a lista de amigos já está em memória e o cache de perfis está vazio
  Quando ela abre o ranking
  Então o log tem 20 gets de shared_profiles com Source.server, em lotes de no máximo 10 simultâneos
  E nenhuma consulta list em shared_profiles

Cenário: Reabrir dentro do TTL
  Dado que Ana abriu o ranking há 4 min 59 s
  Quando reabre
  Então 0 leituras
  Quando reabre aos 5 min
  Então 20 leituras

Cenário: Ranking e perfil de amigo compartilham o cache
  Dado que Ana abriu o ranking há 1 min
  Quando abre o perfil de Carla pelo ranking
  Então 0 leituras

Cenário: Atualizar com cooldown
  Dado que o ranking foi lido há 10 s
  Quando Ana toca "Atualizar"
  Então nenhuma leitura e aparece "A lista já está atualizada."

Cenário: Mais amigos que o limite (D5 = 50)
  Dado que Ana tem 80 amigos
  Então o ranking lê no máximo 50 snapshots
  E mostra "O ranking compara você com 50 dos seus 80 amigos."

# ================= Navegação, layout, acessibilidade =================
Cenário: Tocar num amigo abre o perfil
  Quando Ana toca no apelido de Carla
  Então vai para /friends/u/<uid de Carla> com o cabeçalho já preenchido
  Quando toca na linha "Você"
  Então vai para /profile

Cenário: Larguras, fonte e tema
  Dado 320, 375, 768, 1024 e 1440 px, fonte 1×, 2× e 3×, claro e escuro
  Quando abro o ranking em cada estado e com apelidos de 40 caracteres
  Então não há overflow nem rolagem horizontal
  E a entrada "Ranking" aparece segundo a regra de encaixe de D6 ou pela entrada alternativa

Cenário: Teclado e leitor de tela
  Quando navego com Tab no ranking
  Então o foco passa por Período → Estatística → "Atualizar" → "Compartilhar estatísticas" (se houver) → cada linha
  E cada linha é anunciada como "<n>º lugar, <apelido>, <valor> <métrica>", com "empatado" nos empates e "Você" na minha
```

### Casos de borda
- **Amigo me bloqueia durante a leitura**: o `get` dele volta `permission-denied` ⇒ RF-E7.
- **Amigo exclui a conta no meio** (exclusão interrompida, par ainda existe, documento já apagado): `not-found` ⇒ "não participa" até a exclusão terminar (coerente com o perfil de amigo, RF-F6 da F2).
- **Eu desativo as amizades com o ranking aberto**: `socialPeriodProvider` muda ⇒ estado descartado, entrada some, redirect.
- **Desligo meu "Estatísticas" e volto ao ranking**: minha linha sai (estado do dono atualizado pela transação) e a faixa D9 aparece, sem leitura.
- **Meu snapshot desatualizado** (motor esperando W = 5 s): minha linha pode ficar alguns segundos atrás do Perfil ao vivo; é o que os amigos veem (aceito).
- **Virada de mês com a tela aberta**: os períodos são recalculados na próxima renderização/abertura com o relógio injetável (não precisa de leitura).
- **Horário de verão**: vale o `tz` gravado pelo dono (borda de 1 h, aceita na F2).
- **Apelido igual entre dois amigos**: desempate final por uid (estável).
- **Amigo com `stats` mas sem `month`/`year`** (schema antigo/novo): mês/ano desconhecidos, Total válido.
- **Lista de amigos com mais páginas e o limite**: só a 1ª página (50) é usada; "Ver mais" da lista de Amigos não muda o ranking ❓ (confirmar com D5).
- **Relógio do aparelho do leitor errado**: "este mês" do amigo usa `agoraUtc` do leitor; com relógio errado em dias, o leitor pode ver 0 indevido. ❓ Arquiteto: usar `ServerClock` (já existe) em vez do relógio local (A7).

### Cota (estimativa; não medida em produção)
"Regra" = leitura feita pelas regras (cobrada). Base: docs/82 §11.1.
| Ação | Leituras do app | Regra | Escritas |
|---|---|---|---|
| Sinal "≥ 1 amigo" (contagem agregada) | 1 por sessão (1 por até 1000 entradas de índice) | 0 | 0 |
| Lista de amigos, se não está em memória | até 50 por página (+1 de folga do `limit+1`) | 0 | 0 |
| Snapshot de cada amigo a frio | 1 `get` (`Source.server`; documento inexistente também é cobrado) | 1 (`isFriend`) | 0 |
| Minha linha | 0 (estado do dono já lido na sessão, A1) | 0 | 0 |
| Trocar filtro | 0 | 0 | 0 |
| Reabrir no TTL (5 min) / offline | 0 | 0 | 0 |
| "Atualizar" (fora do cooldown) | lista + N | N | 0 |

**Abrir a frio com N amigos** (lista e snapshots fora da memória): ≈ **3N + ⌈N/50⌉** cobradas; com a lista já em memória (vindo de Amigos): **2N**.
| N | Lista fria + snapshots | Só snapshots | % de 50 mil/dia por abertura |
|---|---|---|---|
| 5 | 16 | 10 | 0,03% |
| 10 | 31 | 20 | 0,06% |
| 20 | 61 | 40 | 0,12% |
| 50 | 151 | 100 | 0,30% |
| 100 | 302 | 200 | 0,60% |
| 300 | 906 | 600 | 1,81% |

Hipótese diária (a mesma da F2: 100 usuários sociais ativos/dia) + 2 aberturas frias/dia, 10 amigos em média: 100 × 2 × 31 ≈ **6 200 leituras/dia (12,4%)** + sinal 100 × 3 sessões = 300. Somado às Fases 1–2 (≈ 10,3 mil), total ≈ **16,8 mil/dia (≈ 34%)**. Um único usuário com 300 amigos e 3 aberturas frias/dia: ≈ 2 700 (5,4%) — razão do limite D5. Bytes: ≈ 3–8 KB por documento típico (até ≈ 30 KB com 50 recomendados): 50 amigos ≈ 0,4–1,5 MB por abertura fria, aceitável no web.

**Consultas por lista de ids:** a documentação do Firestore (consultada em 2026-10-18, *Perform simple and compound queries*) diz: "Use the `in` operator to combine up to **30** equality (==) clauses on the same field". Mas com regra que chama `isFriend(resource.id, …)` por documento, o emulador só aceitou **10** ids por consulta `documentId in` (20 negado; docs/50 §7), e a regra de projeto das fases anteriores é **lotes ≤ 10**. Como `list` em `shared_profiles` é negado e o custo cobrado de uma consulta de 10 ids (10 documentos + 10 leituras de regra) é igual ao de 10 `get`, a recomendação é **`get` por id em lotes de 10 em paralelo** (D16). Com consulta, um único ex-amigo no lote negaria o lote inteiro (docs/50 §7), o que exigiria repetir por `get` de qualquer forma.

### Privacidade
- Participa quem é **amigo mútuo** (par existente; invariante "amigo ⇒ não bloqueado") **e** tem `stats` no documento (só existe com consentimento vigente, garantido pelas regras).
- Desfazer amizade/bloquear (de qualquer lado) **nega a leitura na hora** pelas regras. Do meu lado, a linha some sem leitura (cache e lista limpos no mesmo ponto da F2: `FriendsController.remove`/`afterBlock`). Do outro lado, some na próxima leitura do servidor; no intervalo (≤ TTL de 5 min, sem "Atualizar") eu posso rever **o que já tinha visto** — mesmo risco aceito D15 da F2, estendido ao ranking (D8).
- Offline nada de amigos é exibido, nem da memória (D10 da F2). Nada é guardado em disco (cache só de memória; `Source.server`).
- Quem não compartilha é contado, nunca nomeado (D10). O ranking não revela "quem me bloqueou": negado some em silêncio e não entra na contagem.
- Consentimento: o diálogo de "Estatísticas" já cita "comparações entre amigos" (D13 da F2). A política muda de tempo verbal (RF-V6), com data nova, junto ou antes do app. Parecer jurídico **não verificado**.

---

## Decisões a validar com o Manager

As cinco pedidas no prompt são D1, D2, D4, D5 e D6. As demais apareceram na análise e mudam comportamento visível ou custo.

| # | Decisão | Opções | Recomendação | Consequência |
|---|---|---|---|---|
| **D1** | **Lista final de estatísticas** | (a) as 5 métricas que as regras já validam (`rankOk`): Filmes assistidos, Séries assistidas, Séries concluídas, Episódios assistidos, Horas assistidas; (b) (a) + Favoritos (só no Total; período desabilitado para ele); (c) (b) + Recomendações (exige o consentimento de Recomendados, contraria D13) | **(a)** | Toda métrica funciona nos 3 períodos; nenhuma mudança de schema/regra; "favoritar" não é "assistir" |
| **D2** | **Períodos suportados** | (a) Total, Este ano, Este mês (já no snapshot, fuso do dono); (b) (a) + Mês passado/Ano passado (mudança de schema + regras + `calc` 2) | **(a)** | Custo zero; "mês passado" continua fora de escopo (decisão da F2) |
| D3 | Filtro padrão ao abrir | (a) Episódios assistidos · Este mês; (b) Horas assistidas · Total; (c) Filmes · Este ano | **(a)**, e o último filtro escolhido fica no endereço/memória da sessão (D15) | "Este mês" é a disputa mais "justa" (todos começam do zero; marcações antigas sem data não pesam) e a que mais muda |
| **D4** | **Critério de desempate** | (a) mesma posição, numeração de competição (1º, 1º, 3º), ordem dentro do empate por apelido e uid; (b) mesma posição densa (1º, 1º, 2º); (c) desempate por métrica secundária (ex.: minutos, depois episódios) e só então apelido; (d) "Você" primeiro dentro do empate | **(a)** | Previsível e honesto (ninguém "ganha" um empate); valor desconhecido fica sem posição no fim; horas empatam no minuto |
| **D5** | **Limite prático de amigos** | (a) 30; (b) **50** = 1 página da lista de amigos (0 leitura extra se a lista está em memória); (c) 100 (2 páginas); (d) 300 = todos (`kMaxFriends`) | **(b) 50**, com aviso "O ranking compara você com 50 dos seus N amigos." | Pior abertura fria ≈ 151 leituras (0,3%); acima de 50 o subconjunto é o da 1ª página (ordem do id do par, estável mas sem critério visível). Escolher "os 50 mais recentes" exigiria `orderBy(createdAt)` + índice composto (A8) |
| **D6** | **Onde a entrada entra na navegação** | (a) **Desktop** (> 768 px): item "Ranking" no menu do topo da Início, depois de "Amigos" (ícone `leaderboard`; rótulo some abaixo da nova largura mínima). **Mobile** (≤ 768 px): ícone `leaderboard` na barra superior, ao lado de Amigos, com a mesma regra de encaixe (é o primeiro a sair quando não cabe) + **entrada alternativa sempre presente** no topo da tela Amigos ("Ver ranking") e no Perfil (seção Amizades); (b) 6º destino na barra inferior (passa do máximo de 5 do Material 3; ≈ 53 px por item em 320 px, rótulos cortados a 2×/3×); (c) aba "Ranking" dentro de Amigos (Amigos · Pedidos · Bloqueados · Ranking), sem mudar barras; (d) só desktop no menu, mobile só via Amigos | **(a)** | Nenhuma barra perde destino; a entrada aparece/some com o sinal D7 nos dois layouts; em 320 px com fonte 2×/3× o ícone some e o ranking continua a 1 toque de Amigos/Perfil. Em `/ranking` no mobile, o destino selecionado da barra inferior é **Perfil** (como Amigos, que "mora" no Perfil) |
| D7 | Sinal "≥ 1 amigo" para mostrar a entrada | (a) contagem agregada 1×/sessão + pista local por uid + ajustes locais nas ações + reconciliação por qualquer leitura; (b) listener `friendships` `limit(1)` (tempo real também para remoção feita pelo outro; +1 leitura por mudança; quebra o padrão "sem listener" da F1); (c) ler a lista inteira ao iniciar | **(a)** | +1 leitura por sessão; remoção feita pelo outro só some quando o app descobre (RF-V5) |
| D8 | Ex-amigo × cache (extensão da D15) | (a) ranking usa o mesmo cache de memória de 5 min do perfil de amigo; remoção/bloqueio por mim limpam na hora; pelo outro, até a próxima leitura; (b) TTL 0 no ranking (2N a cada abertura) | **(a)** | Ex-amigo que reabre em ≤ 5 min revê o que já viu (nada novo); custo bem menor |
| D9 | Minha linha quando eu não compartilho | (a) não apareço + faixa explicando e botão para o Perfil; (b) apareço marcado "só você vê", calculado ao vivo (prévia) | **(a)** | Reciprocidade (não comparo sem ser comparado) e uma fonte só (o documento); (b) usaria um número que os amigos não veem |
| D10 | Amigos que não compartilham | (a) só contagem anônima no rodapé; (b) lista de nomes "não participam"; (c) nada | **(a)** | Sem pressão por nome; a informação por pessoa já existe no perfil de amigo |
| D11 | Snapshot desatualizado | (a) marcador neutro "Atualizado há N dias" quando > 7 dias (limite do ADR-006), pessoa continua no ranking; (b) > 7 dias sai do ranking; (c) limiar de 2 ou 14 dias; (d) sem marcador | **(a)** com 7 dias | Coerente com D7 da F2 (texto neutro, sem alarme); "desatualizado" quase sempre = não abre o app há dias |
| D12 | Valores implausíveis (D12 da F2 aplicada ao ranking) | (a) leitor estrito: descarta não inteiro, não finito, acima do teto e período > total ⇒ "—", sem posição; (b) limitar ao teto (clamp) e ranquear; (c) só descartar não inteiro/não finito | **(a)** | Cliente modificado não chega ao 1º lugar com 999 999 999; números plausíveis falsos continuam possíveis (risco já aceito) |
| D13 | Falha parcial | (a) mostrar quem carregou + aviso com contagem + "Tentar novamente" só dos que faltam; (b) tudo ou nada (erro se 1 falha) | **(a)**; cota/offline/sessão continuam tudo ou nada | Ranking útil com rede instável; aviso evita posição enganosa sem explicação |
| D14 | Exibição de "Horas assistidas" | (a) horas e minutos sem converter em dias ("1.234 h 05 min"), ordena por minutos; (b) o formato do Perfil (`WatchTimeFormatter`: anos, meses, dias…); (c) só horas inteiras | **(a)** | Comparável linha a linha; o formato do Perfil mistura unidades e dificulta comparar |
| D15 | Filtro no endereço | (a) `/ranking?estatistica=<filmes\|series\|concluidas\|episodios\|horas>&periodo=<total\|ano\|mes>`; (b) só em memória | **(a)** | Recarregar/voltar mantém o filtro; valor inválido cai no padrão |
| D16 | Regras e forma de leitura | (a) **nenhuma mudança de regra**: `get` por id em lotes de 10 paralelos; `list` continua negado; testes de regra novos; (b) abrir `list` com `documentId in [≤ 10]` (regra nova, publicada antes do app) | **(a)** | Custo cobrado igual; sem publicação de regras nesta fase (sha `6135322e…` mantido); um ex-amigo não derruba um lote |

## Perguntas ao Arquiteto (para o design docs/91)
- **A1** Minha linha: `SharingState.doc` reflete as escritas do motor (`SharedProfileSync`) na mesma sessão, ou só a leitura de sessão/transações? Se não, de onde vem o "meu documento atual" sem leitura extra?
- **A2** `readCount` (`v is int && v >= 0`) no dart2js: `double.infinity`, `NaN`, `1e300` passam? Confirmar com `flutter test --platform chrome`. Se `Infinity` passa, corrigir também o leitor da F2 (exibição)?
- **A3** Sinal "≥ 1 amigo": contagem agregada (`friendsCountQuery`, `limit 300`) é cobrada como 1 leitura no Spark? Onde vive a pista local (Hive, como `socialHint`) e como reconciliar com `FriendsController`, `afterBlock`, aceite e pedido cruzado sem condição de corrida?
- **A4** Leitura dos N snapshots: reaproveitar `FriendProfileCache` (a entrada guarda `Friend` + `FriendSharedView`) ou um cache próprio com as mesmas regras de limpeza? Concorrência (lotes de 10), timeout por leitura (8 s) e cancelamento por geração (troca de conta no meio).
- **A5** Regra de encaixe do ícone Ranking em `MobileTopBar` (ordem de saída: Ranking antes de Amigos) e nova largura mínima de rótulos no menu do topo (`kTopMenuLabelsMinWidth` + Amigos + Ranking).
- **A6** `redirect` de `/ranking` com sinal assíncrono: incluir o sinal no `refreshListenable` do router; comportamento durante "carregando".
- **A7** "Agora" do leitor para períodos e desatualizado: `ServerClock` (corrigido pelo desvio do servidor) em vez do relógio local?
- **A8** Se o Manager preferir D5 com "os 50 mais recentes": custo do índice composto `members array-contains` + `createdAt desc` e impacto na lista de Amigos (hoje ordenada por nome no cliente).
- **A9** Estrutura de `RankingEntry`/ordenação como função pura (testável 1:1 com a tabela de empates) e onde o leitor estrito mora (`lib/shared_profile/`).
- **A10** Testes de regra: novo `ranking.test.mjs` (matriz de N amigos, `list`/`documentId in` negados, `stats` ausente quando desligado) e mutações associadas; confirmar que nada em `firestore.rules` muda (sha igual).
- **A11** Selecionado da barra inferior em `/ranking` = Perfil (D6): confirmar com o padrão de `/friends`.

## Fatiamento sugerido
0. **Fatia 0 — Testes de regra (sem mudar regras)**: `firestore_rules_test/ranking.test.mjs` — amigo lê `get` de N amigos; não amigo, ex-amigo, bloqueado (2 sentidos), anônimo e não Google negados; `list` e `documentId in [..]` negados; documento com "Estatísticas" desligado não tem `stats` (forma garantida pela regra); `rankOk` aceita `double` (documenta a necessidade do leitor estrito); gate: `shasum` de `firestore.rules` = `6135322e…e612`. Nada de app. (Se D16 = (b): regra nova + publicação pela CLI antes de qualquer app.)
1. **Fatia 1 — Domínio puro**: leitor estrito (RF-L), `RankingEntry`, ordenação e empates (D4), períodos por fuso do dono, desconhecidos, formatação (D14), textos; testes de unidade parametrizados pelas tabelas desta especificação (inclui `--platform chrome` para o leitor).
2. **Fatia 2 — Dados e sinal**: sinal "≥ 1 amigo" (D7: contagem, pista, ajustes, reconciliação); `RankingController` (lista ≤ 50, `get` em lotes, cache compartilhado D8, mapeamento de falhas → estados, `permission-denied` → `_revoked`, falha parcial D13, "Atualizar" com cooldown); contadores de cota nos fakes.
3. **Fatia 3 — Rota, navegação e tela**: `/ranking` + `redirect` (RF-V4), entradas desktop/mobile + alternativas (D6), tela com filtros no endereço (D15), destaque da minha posição, faixa D9, rodapé D10, marcador D11, todos os estados, navegação para o perfil; testes de widget (aba aparece/some, redirect, filtros, estados, 320–1440 px, fonte 3×, teclado, Semantics); política e README.
4. **Fechamento**: review e QA integrados, smoke com 3 contas (uma não compartilha, uma desatualizada), cota no console, checklist de release (modelo docs/89). Ordem de publicação: (sem regras) → política → app.

## Definition of Done (desta especificação)
- [ ] Todos os critérios de aceite verificáveis por teste (unit, widget, emulador), conferido pelo QA.
- [ ] D1–D16 decididas pelo Manager; ❓ de texto (RF-V3, RF-R9, RF-E13, desatualizado sem `updatedAt`) resolvidas.
- [ ] A1–A11 respondidas no docs/91 (design) e coerentes com esta especificação.
