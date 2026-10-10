# 81 - Especificação: Perfil social (Fase 2 de 5: meu perfil, perfil de amigo, estatísticas e atividades compartilhadas)

> Autor: Product Analyst · Base: `main` em `9c57327` (Fase 1 Amizades em produção) · Branch: `feat/social-profile`
> Design: [docs/82](./82-design-perfil-social.md) · Decisão: [ADR-006](./adr/adr-006-snapshot-perfil-social.md) (**Aceita**, Manager, 2026-10-10) · Testabilidade: [docs/83](./83-testabilidade-perfil-social.md).
> **Status: decisões D1–D17 aprovadas pelo Manager em 2026-10-10** ("aprovo tudo"). Etapa 2 revisada em 2026-10-10 para ficar coerente com docs/82, ADR-006 e docs/83 (B1–B8). A Etapa 1 (análise) foi mantida como registro do que se sabia antes do design; onde ela diverge, valem a Etapa 2, o docs/82 e o ADR-006.
> **Este documento só especifica.** Nenhum código foi alterado por ele.
> Conjunto social: F1 amizades (feita) → **F2 perfil** → F3 ranking → F4 avaliações → F5 comentários.
> Legenda: **RF** requisito funcional, **RNF** requisito não funcional, **D** decisão do Manager (todas aprovadas), **A** pergunta ao Arquiteto (respondidas no docs/82 §16). Não há ❓ em aberto.

---

## Etapa 1 - Análise do código atual

### 1.1 Como as peças funcionam hoje (lido em `main` 9c57327)

**Perfil (`lib/screens/profile_screen.dart`).** Rota `/profile` (no shell, protegida pelo `redirect` de `lib/router.dart`). Mostra avatar (`UserAvatar`, foto do Google em tempo de execução), apelido (`displayLabelProvider`; edição por `showNicknameDialog`, desabilitada enquanto uma operação social roda), e-mail, **"Membro desde"** (vem de `AppUser.createdAt`, metadado do Firebase Auth, **não está no banco**), cartão "Concluir exclusão" (quando `users/{uid}.deleting`), `ProfileStatsCard`, `SocialSection` (Fase 1), `PrivacySummary`, `TmdbAttribution`, `ExportDataSection`, Sair e Excluir conta.

**Estatísticas (`lib/models/profile_stats.dart`, `lib/widgets/profile_stats_card.dart`, `lib/services/watch_time.dart`, `profileStatsProvider` em `lib/providers/account_providers.dart`).** São **derivadas em tempo real** da lista de documentos de favoritos (`favoriteDocsProvider`, listener já assinado) e do **cache local de catálogo** (Hive: temporadas, duração de filmes e episódios). Nada é guardado. Itens exibidos:
| Rótulo | Definição atual |
|---|---|
| Favoritos | nº de documentos em `users/{uid}/favorites` |
| Filmes favoritos / Séries favoritas | por `mediaType` |
| Filmes assistidos | filmes com `watchedMovie == true` |
| Episódios assistidos | soma do tamanho do mapa `eps` das séries |
| Séries concluídas | todos os episódios **já exibidos** marcados (catálogo local completo) ou, sem catálogo, `eps` ≥ soma de `seasonSummaries.episodeCount` |
| Recomendações | documentos com `recommended == true` |
| Tempo assistido | soma das durações (TMDB) de filmes assistidos e episódios assistidos; episódio sem duração própria usa a média da série (**estimado**); sem duração nenhuma fica **fora da soma** (**unknown**); o cartão avisa "Estimado…"/"…não entraram na soma"/"Calculando…" |

Consequências importantes para esta fase:
1. **"Séries concluídas" e "Tempo assistido" mudam sem nenhuma escrita do usuário**: um episódio novo que vai ao ar "desconclui" a série; a duração de um título chega depois (reconciliador de catálogo, `reconcileRuntimes`). Um snapshot gravado só "a cada escrita" fica desatualizado nesses casos.
2. As durações e a lista de episódios exibidos **só existem no aparelho** (cache TMDB). Num aparelho novo, até o catálogo baixar, os números são parciais (o cartão mostra "Calculando…").

**Favoritos e progresso (`lib/data/firestore_favorites_data_source.dart`, `lib/repositories/favorites_repository.dart`, `lib/services/favorite_mapper.dart`, ADR-003/004).** Um documento por título em `users/{uid}/favorites/{id-tipo}`: `id, mediaType, title, posterPath, overview, addedAt, lastWatchedAt, watchedMovie, seasonSummaries, eps, updatedAt, recommended`. Escritas por intenção, cada uma **um único `update`/`set` não aguardado** (`_sink.fire`), que funciona offline (fila do SDK): `add` (set), `remove` (delete), `setWatchedMovie` (`watchedMovie` + `lastWatchedAt` serverTimestamp), `setEpisodes` (`eps.{s_e}: true | delete` + `lastWatchedAt`), `setSeasonSummaries`, `setRecommended` (sem carimbo de atividade). Marcações em massa (temporada, série inteira, Desfazer: `applySeriesBulk`/`undoSeriesBulk`) são **um `update` atômico** com vários caminhos de `eps`. Regras: `validFavorite` com `hasOnly` (qualquer campo novo exige publicar regras antes) e "`addedAt` só diminui".

Lacunas de dados que pesam nesta fase:
- **Não existe data por episódio**: `eps` é `"{s}_{e}": true`. `lastWatchedAt` é **por título** (última marcação/desmarcação de qualquer episódio). Portanto **"episódios assistidos este mês/ano" não é derivável dos dados existentes**.
- Para **filmes**, `lastWatchedAt` com `watchedMovie == true` é a data da marcação atual (o último toggle foi o que marcou); documentos anteriores ao campo têm `lastWatchedAt` nulo.
- **Não existe registro de eventos** ("o que eu fiz e quando"): favoritar só deixa `addedAt`; concluir série não deixa data nenhuma.

**Minhas recomendações (docs/40, ADR-004).** Campo opcional `recommended` no próprio favorito; aba `/recommendations`. **Privadas**; política (`web/privacidade.html`) e `PrivacySummary` prometem: "Pediremos seu consentimento antes de qualquer compartilhamento". ADR-004 item 10 já fixou: flag de compartilhamento **distinto** de `recommended`, coleção separada, nunca abrir `favorites`.

**Exportar meus dados (docs/39, `lib/export/data_exporter.dart`, `export_serializer.dart`, `social_export.dart`, `lib/data/firestore_export_data_source.dart`).** Schema 2: favoritos brutos, `users/{uid}`, seção `social` (inclusive resíduos sem ponteiro). **Coleções novas não entram sozinhas.**

**Exclusão de conta (`lib/account/account_deleter.dart`).** Reautentica → `ensureOnline` → `markDeleting` → `SocialRepository.wipeForAccountDeletion` (fecha a porta: ponteiro/cartão/convite, depois varre pares, pedidos e bloqueios) → favoritos em lotes → perfil → usuário. Idempotente e retomável. **Não conhece documentos novos.**

**Desativar amizades (`SocialRepository.deactivate`/`sweepAll`).** Varre, fecha a porta, varre de novo; resíduo possível se a última varredura falhar ("Concluir limpeza"). Comentário em `firestore.rules`: nesse resíduo `isFriend` continua verdadeiro; alternativa `isFriend(a,b) && exists(socialPath(a))` (+1 chamada).

**Privacidade.** `web/privacidade.html` e `lib/widgets/privacy_summary.dart` afirmam hoje: "Seus amigos veem **somente o seu cartão**: apelido e foto… Ninguém vê seus favoritos, recomendações, progresso nem e-mail, e isso vale também para os amigos". **Esta frase é um compromisso com os usuários atuais** e pesa nos padrões (D2).

### 1.2 O que da Fase 1 é reutilizado
| Peça | Onde | Uso na Fase 2 |
|---|---|---|
| `isFriend(a,b)` (1 `exists`) e invariante "amigo ⇒ não bloqueado" | `firestore.rules` | **única** condição de leitura do conteúdo compartilhado (docs/50 §7, docs/51 §3) |
| `isBlocked`/`isBlockedEither` | `firestore.rules` | não necessário na leitura (invariante); bloquear desfaz a amizade no mesmo batch |
| Lista de amigos (`friends()`, `Friend{uid,name,photoUrl,since}`, cache 5 min, sem listener) | `lib/repositories/social_repository.dart`, `lib/screens/friends_screen.dart` (`_FriendTile`) | ponto de entrada do perfil de amigo; **cabeçalho do perfil (apelido, foto, "amigos desde") vem do instantâneo do par, 0 leitura extra** |
| Remover amizade / Bloquear + diálogos | `SocialRepository.removeFriend`, `blockUser`; `lib/widgets/block_dialogs.dart` (`confirmBlock`); diálogo de remoção em `_FriendTile` | ações no perfil de amigo, mesmos textos ("A pessoa não será avisada") |
| Rotas protegidas `/friends*`, `redirect` | `lib/router.dart` | nova rota do perfil de amigo sob a mesma proteção |
| `SocialGate`/estado "amizades ativas" | `lib/widgets/social_gate.dart`, `social_providers.dart` | interruptores de compartilhamento só aparecem com amizades ativas |
| Padrões de mensagem única, "Aguarde a operação anterior terminar.", estados de lista (esqueleto, erro, offline) | `friends_screen.dart` (`_Skeleton`, `_ListError`, `_OfflineStrip`) | estados do perfil de amigo |
| Suíte de regras: `social.test.mjs`, `social_compat.test.mjs`, `rules_budget.test.mjs`, `dart_payloads.test.mjs` + golden, `mutations.mjs` | `firestore_rules_test/` | Fatia 0 da Fase 2 segue o mesmo padrão |
| Exclusão/exportação/desativação com passo social | `AccountDeleter`, `runExport`, `deactivate` | ganham os documentos novos |

### 1.3 Riscos principais
| # | Risco | Impacto | Mitigação proposta |
|---|---|---|---|
| R1 | **Números falsos no snapshot**: o próprio dono grava o que quiser pelo SDK; regras não conseguem somar favoritos | ranking (F3) manipulável; perfil "mentiroso" | regras limitam tipo, faixa, chaves, tamanho de listas, `updatedAt == request.time`; produto: vale só entre amigos, amigo pode remover/bloquear; risco aceito formalmente no ADR-006 (D12) |
| R2 | **Snapshot desatualizado**: escrita offline ainda na fila; outro aparelho; série "desconcluída" por episódio novo; duração que chega depois; app antigo (sem a Fase 2) marcando episódios | amigo vê números velhos | recálculo completo ao abrir o app e ao terminar o sync de catálogo (só grava se mudou); "Atualizado há…" visível ao amigo e ao dono (D7) |
| R3 | **Snapshot calculado de dados incompletos** (aparelho novo, cache vazio, catálogo baixando) sobrescreve um snapshot bom com zeros | regressão visível a amigos e no ranking | RNF: só recalcular com lista de favoritos confirmada pelo servidor; tempo assistido com `unknown > 0` grava também o `unknown` (A6) |
| R4 | **Acoplar a escrita do favorito à do snapshot no mesmo batch**: se as regras recusarem o snapshot (bug, regras não publicadas, campo fora da faixa), o SDK **desfaz a marcação do favorito** (o batch inteiro é revertido no cache local) | **perda da ação do usuário** (viola "nenhum usuário perde dados") | D4: nunca no mesmo batch do favorito; snapshot em escrita própria, coalescida |
| R5 | **Períodos sem data nos dados antigos** (sem data por episódio; filmes antigos sem `lastWatchedAt`) | "este mês/ano" impreciso ou impossível para o histórico | D5: guardar a data da marcação daqui para a frente; histórico sem data conta só no Total; nunca inventar data |
| R6 | **Atividade não tem fonte hoje** (sem log de eventos) | as "últimas 3" precisam ser gravadas | registrar só com consentimento e só daqui para a frente (D1, D6) |
| R7 | **Quebra de promessa de privacidade**: política diz que amigos não veem progresso nem recomendações | LGPD (transparência/consentimento) | todos os interruptores **desligados** por padrão, consentimento por seção, política atualizada antes do app (D2) |
| R8 | **Revogação**: desligar compartilhamento offline fica na fila e o amigo continua vendo até sincronizar | expectativa de "imediato" frustrada | desligar exige conexão confirmada (D10); desfazer amizade/bloquear já revoga pelas regras |
| R9 | **Resíduo `isFriend` sem `social/{uid}`** (desativação/exclusão interrompida) | ex-amigo ainda leria o conteúdo compartilhado | apagar o conteúdo compartilhado **antes** das varreduras; avaliar `&& exists(socialPath(dono))` (A8) |
| R10 | **Cota Spark do projeto** (50 mil leituras, 20 mil escritas/dia): cada marcação de um usuário que compartilha vira +1 escrita; F3 lê o snapshot de N amigos | estouro de cota afeta todos | escrita coalescida; perfil de amigo ≤ 2 leituras cobradas com TTL; ranking reaproveita o mesmo documento (§ cota) |
| R11 | **Contenção de escrita** (≈1 escrita/s sustentada por documento) ao marcar episódios em sequência rápida | escritas lentas/recusadas | coalescer (A4) |
| R12 | **Rollout**: app novo antes das regras | se mal desenhado, quebra favoritos | ligar interruptor falha com "ainda não disponível"; quem não liga nada não grava nada novo; regras nunca voltam |
| R13 | **Usuários sem amizades ativas** | não têm amigos para ver nada | interruptores só aparecem com amizades ativas; Meu perfil continua idêntico para eles |
| R14 | **Dados de terceiros no aparelho**: o cache persistente do Firestore guarda o perfil do amigo lido | ex-amigo continua no disco do outro | não servir o conteúdo do amigo a partir do cache quando o servidor nega; offline não mostra conteúdo antigo (D10) |

> Resolução final de cada risco: docs/82 §14 e ADR-006. Mudanças em relação às mitigações acima: R1 as regras validam menos do que listado (tetos e coerência ficam no app, D12/D16); R6 as atividades são **derivadas dos dados** (`epsAt`, `addedAt`, `lastWatchedAt`), não registradas; R9 resolvido apagando o documento antes e depois de fechar `social` (sem `exists(social)`, A8); R14 o leitor usa `Source.server` e cache só de memória (D10, D15).

### 1.4 Impacto
| Área | Hoje | Preciso |
|---|---|---|
| Regras | `isFriend` sem consumidor | documento(s) de perfil compartilhado lidos por `isOwner || isFriend`; escrita só do dono com schema; possivelmente campo de data de marcação aditivo em `validFavorite` (D5) |
| Meu perfil | estatísticas ao vivo, seção Amizades | + seção "O que seus amigos veem" (3 interruptores, prévia, "Atualizado há"), + "Atividades recentes" (quando compartilhadas) |
| Perfil de amigo | não existe | nova rota a partir da lista de amigos, ações remover/bloquear |
| Favoritos/progresso | escrita única por ação | + `epsAt` no mesmo `update` do episódio (D5); atualização do compartilhado em escrita própria, coalescida, só para quem compartilha (D4) |
| Exclusão / desativação / exportação | cobrem social da Fase 1 | + `shared_profiles/{uid}` (exportação: schema 3, aditivo, decidido no docs/82 §8) |
| Privacidade | "amigos veem só o cartão" | texto novo, data nova, por seção |

---

## Etapa 2 - Especificação

> **Revisada em 2026-10-10** para ficar coerente com o design [docs/82](./82-design-perfil-social.md), o [ADR-006](./adr/adr-006-snapshot-perfil-social.md) (Aceita) e a testabilidade [docs/83](./83-testabilidade-perfil-social.md) (ajustes B1–B8 e cenários que faltavam). **Decisões D1–D17 aprovadas pelo Manager em 2026-10-10** ("aprovo tudo"). Onde este documento e o docs/82 descreverem o mesmo comportamento, os dois dizem a mesma coisa; os **oráculos de teste** são a tabela de tetos (docs/82 §4.4), a tabela de definições (docs/82 §5.2), a tabela de transições de atividades (docs/82 §5.3) e a tabela "resposta do servidor → estado da tela" (docs/82 §7.2), reproduzidas aqui onde o critério de aceite depende delas.

## Perfil social: meu perfil, perfil de amigo e o que eu compartilho

**Problema:** depois da Fase 1, amigos só veem apelido e foto um do outro. Quem tem amigos no CineTrack não consegue ver o que o amigo tem assistido, quanto assiste nem o que ele recomenda, que é o motivo de ter amigos no app. Ao mesmo tempo, os usuários atuais foram informados de que **nada disso é compartilhado**, e as recomendações têm promessa explícita de consentimento.
**Resultado esperado:** cada pessoa escolhe, por seção e a qualquer momento, o que os amigos veem (estatísticas, atividades recentes, recomendados); amigos abrem esse perfil a partir da lista de amigos com pouquíssimas leituras; ninguém além de amigos mútuos vê nada; e a base de dados para o ranking (F3) com filtros por período fica pronta.
**Métricas de sucesso** (sem telemetria no app; verificáveis por teste e uso real):
- **Zero vazamento**: suíte de regras prova que não amigo, ex-amigo, bloqueado (nos dois sentidos), anônimo e conta não Google não leem `shared_profiles/{uid}`; `list` negado a todos (100% dos casos negativos passam).
- **Zero perda**: favoritos, progresso, recomendações, apelido e dados sociais de qualquer conta idênticos antes/depois; **nenhuma falha de escrita do perfil compartilhado desfaz uma marcação** (teste com fake que recusa a escrita do compartilhado: o favorito permanece); `epsAt` só é enviado depois de constatadas as regras novas.
- Abrir o perfil de um amigo pela lista: **1 `get`** + **1 chamada de regra** (`isFriend`) a frio = 2 leituras cobradas; **0** dentro do TTL de 5 min; aberto por endereço sem lista em cache: +1 (`get` do par).
- Desligar uma seção: o documento/seção **não existe mais no servidor** ao fim da operação; a próxima leitura do amigo mostra "não compartilha".
- Leituras/escritas novas por perfil de uso:
  | Perfil de uso | Leituras novas | Escritas novas |
  |---|---|---|
  | Sem amizades ativas | **1 por aparelho, uma única vez** (sonda de regras, D17) | **0** (a data de marcação vai no mesmo `update` do episódio) |
  | Amizades ativas, nada ligado | 1 por sessão (estado do dono, que também serve de sonda) | 0 |
  | Compartilha algo | 1 por sessão | ≤ 1 por janela de 5 s de atividade (máx. 30 s), 0 se nada mudou, pulso ≤ 1/dia |

### Escopo
- Inclui:
  - **Meu perfil** (evolução de `/profile`): tudo o que existe hoje continua igual (estatísticas **ao vivo**, `profileStatsProvider` inalterado); com amizades ativas, nova seção **"O que seus amigos veem"** com três interruptores (Estatísticas, Atividades recentes, Recomendados), todos **desligados por padrão** (D2), consentimento por seção com prévia, "Atualizado há…" e bloco **"Atividades recentes"** (últimas 3, quando "Atividades" estiver ligado).
  - **Perfil de amigo** (rota `/friends/u/:uid`, aberta tocando no amigo da lista de `/friends`): cabeçalho (apelido, foto, "Amigos desde"; "No CineTrack desde" se ele compartilha estatísticas, D8), estatísticas, últimas 3 atividades e recomendados (cada um só se compartilhado), ações **Remover amizade** e **Bloquear** (Fase 1), e todos os estados (§ Estados de UI).
  - **Documento compartilhado** `shared_profiles/{uid}` (ADR-006): só existe com ≥ 1 seção ligada; seção desligada = campo ausente no servidor.
  - **Data de cada marcação de episódio** (`epsAt`) no próprio favorito, privada, gravada pela versão nova para todos os usuários (D5, D6), base dos recortes "este mês/este ano" e das atividades.
  - **Atividades derivadas dos dados** (D1), modelo extensível com `rated` reservado à F4.
  - Cobertura em **Exclusão de conta**, **Desativar amizades** e **Exportar meus dados** (schema 3); `web/privacidade.html` e `PrivacySummary` atualizados.
  - Regras finais + testes no emulador (Fatia 0), ADR-006 (Aceita), README.
- Não inclui:
  - Ranking (F3), avaliações (F4), comentários (F5); só os requisitos de forward-compat.
  - Ver a **lista de favoritos** ou o **progresso por título** de um amigo.
  - Perfil para não amigos, perfil "público", link de perfil compartilhável fora do app.
  - Notificações, feed de atividades de todos os amigos, curtir/comentar atividade.
  - Mudar como as estatísticas do **Meu perfil** são calculadas.
  - **"Mês passado"/histórico de períodos** (fora de escopo, decisão do Manager; derivável no futuro a partir de `epsAt`, sem migração).
  - Alarme de "desatualizado" (decisão do Manager: nunca; só o texto neutro "Atualizado há X").
  - Confirmação ao desligar um interruptor (decisão do Manager: sem confirmação).
  - Validação nas regras dos tetos numéricos, da coerência entre números e do conteúdo de cada item de lista (D12, D16: ficam no app).
  - Backfill de datas para marcações antigas de episódios (não existe a data).
  - Android/iOS (o app em produção é web; nada aqui deve impedir as outras plataformas).

### Requisitos funcionais

**RF-P: Privacidade e interruptores (Meu perfil)**
- RF-P1. A seção "O que seus amigos veem" só aparece com **amizades ativas** (recurso da Fase 1 ligado, `social/{uid}` existe; não é "ter ≥ 1 amigo"). Sem amizades ativas, Meu perfil tem a mesma lista e ordem de seções de hoje.
- RF-P2. Três interruptores independentes, todos **desligados** por padrão para usuários atuais e novos (D2):
  - **Estatísticas** (`stats`): números do Perfil **exceto "Recomendações"**, recortes "este mês" e "este ano", tempo assistido e "No CineTrack desde".
  - **Atividades recentes** (`activity`): até 10 atividades derivadas (3 exibidas), só posteriores ao momento em que foi ligado (`actSince`).
  - **Recomendados** (`recs`): até 50 títulos com "Recomendo" e o número **"Recomendações"** (`recs.count`, RF-P3).
- RF-P3. O número "Recomendações" **mora em `recs.count`** e só existe com "Recomendados" ligado; nunca está em `stats`.
- RF-P4. **Ligar** abre o diálogo de consentimento da seção (textos literais abaixo), com prévia calculada a partir dos dados atuais. "Cancelar"/Esc não grava nada. "Compartilhar" executa **uma transação** (lê o próprio documento; grava `sharing.X = true` + a seção recalculada + `updatedAt` do servidor; para Atividades, `actSince` = hora do servidor). Se a prévia ainda não pode ser calculada com dados confiáveis (RF-S5), o botão mostra "Calculando…" e fica desabilitado.
- RF-P5. **Desligar não pede confirmação** (decisão do Manager). Uma transação apaga `sharing.X` e a seção (e `actSince` junto, para Atividades); se era a última seção, **apaga o documento**. Ao concluir: mensagem curta "Seus amigos não veem mais suas [estatísticas | atividades recentes | recomendados]."
- RF-P6. Ligar e desligar **exigem servidor** (transação, nada vai para a fila). Offline: o interruptor não muda e aparece "Sem conexão. Tente de novo quando estiver online."
- RF-P7. **Resultado incerto** (timeout de 10 s depois de enviar, `deadline-exceeded` ou `unavailable` no commit): o interruptor mostra **"Ainda não confirmado…"** (desabilitado, com progresso); o app relê o documento do servidor assim que houver conexão (imediatamente e a cada volta de conectividade) e mostra o **estado real**: ligar confirmado depois = ligado, com "Compartilhamento ligado." (houve consentimento no diálogo); desligar que não aconteceu = ligado, com "Não foi possível desligar. Tente de novo." (padrão `SocialFailureKind.uncertain` da Fase 1).
- RF-P8. Toque num interruptor com outra operação de interruptor em andamento: "Aguarde a operação anterior terminar." O **recálculo automático não desabilita os interruptores** (um toque durante uma gravação do motor espera a escrita local e segue).
- RF-P9. Erros ao ligar/desligar: `permission-denied` com `social` ausente ⇒ estado de amizades desativadas; `permission-denied` com `social` presente (regras antigas) ⇒ "O perfil compartilhado ainda não está disponível."; `resource-exhausted` ⇒ mensagem de cota existente; em todos, o interruptor volta ao estado do servidor.
- RF-P10. Ao abrir o Perfil com amizades ativas, o estado dos interruptores vem de uma **pista local** (por uid), confirmada por **1 leitura do servidor** por sessão. Sem pista: esqueleto. Estado não confirmado e offline: interruptores desabilitados com "Sem conexão. Tente de novo quando estiver online.". Dois aparelhos: ligar no aparelho A aparece no B na próxima confirmação de sessão (ou reconexão).
- RF-P11. O dono vê **"Atualizado há X"** (faixas: "agora" < 1 min; "há N min" < 60 min; "há N h" < 24 h; "há N dias") e a prévia **"Como seus amigos veem"**, alimentada pelo documento gravado (mesmos componentes do perfil de amigo).
- RF-P12. Desativar amizades (Fase 1) **apaga o documento compartilhado** e os interruptores voltam a desligado; reativar começa com tudo desligado (D11).

**Textos literais dos diálogos** (os testes de widget comparam o texto exato):
| Seção | Título | Corpo | Botões |
|---|---|---|---|
| Estatísticas | "Compartilhar estatísticas com amigos?" | "Seus amigos mútuos vão ver seus números (favoritos, filmes e episódios assistidos, séries assistidas e concluídas e tempo assistido), os totais deste mês e deste ano e desde quando você está no CineTrack, no seu perfil e nas comparações entre amigos. Você pode desligar quando quiser: desligar apaga na hora." | "Cancelar" · "Compartilhar" |
| Atividades | "Compartilhar atividades recentes com amigos?" | "Seus amigos mútuos vão ver suas 3 atividades mais recentes: títulos que você favoritou, filmes e episódios que marcou como assistidos e séries que concluiu. Só entra o que você fizer a partir de agora. Recomendações nunca aparecem como atividade. Você pode desligar quando quiser: desligar apaga na hora." | "Cancelar" · "Compartilhar" |
| Recomendados | "Compartilhar seus recomendados com amigos?" | "Seus amigos mútuos vão ver os títulos que você marcou com Recomendo (até 50, na ordem da sua aba) e quantos são. Para você, nada muda nas suas recomendações. Você pode desligar quando quiser: desligar apaga na hora." | "Cancelar" · "Compartilhar" |
| Seção, tudo desligado | — | "Seus amigos veem só seu cartão (apelido e foto)." | — |

**RF-D: Data de cada marcação (`epsAt`, D5)**
- RF-D1. Marcar um episódio grava, **no mesmo `update`** da marcação, a data dessa marcação no próprio favorito (`epsAt.{s}_{e}`); desmarcar apaga a data. Não é uma escrita extra.
- RF-D2. A data é a **hora do aparelho corrigida pelo desvio do servidor** (estimado quando um `lastWatchedAt` carimbado por este aparelho volta confirmado; sem estimativa, desvio 0); **um único instante por escrita** (marcar uma temporada ou a série inteira dá a mesma data a todos os episódios). Data futura é limitada a "agora corrigido" antes de gravar.
- RF-D3. **Desfazer** de marcação em massa restaura também as datas anteriores (desmarcar tudo + Desfazer não "rejuvenesce" o histórico); Desfazer de uma marcação nova apaga as datas.
- RF-D4. Data **órfã** (deixada por app antigo que desmarcou o episódio) não conta e é apagada na próxima escrita da versão nova naquele favorito (até 500 por escrita).
- RF-D5. O app **só envia `epsAt` depois de constatar as regras novas** (sonda de 1 leitura, lembrada no aparelho; com amizades ativas, a leitura de sessão do RF-P10 serve de sonda). Sem constatação (regras antigas, offline sem resposta), a marcação vai **sem data** e conta só no Total. **A marcação nunca é recusada por causa da data**: se `epsAt` passaria de 5000 entradas, a marcação vai sem data.
- RF-D6. Filmes não ganham campo: `lastWatchedAt` com `watchedMovie == true` é a data da marcação atual; nulo = sem data.

**RF-S: Snapshot de estatísticas (`stats`)**
- RF-S1. Conteúdo, para **Total**, **Ano** (`year.key` "AAAA") e **Mês** (`month.key` "AAAA-MM"):
  | Métrica | Total | Mês/Ano | Uso |
  |---|---|---|---|
  | Favoritos, Filmes favoritos, Séries favoritas | sim | não | perfil |
  | Filmes assistidos | sim | sim | perfil + F3 |
  | Episódios assistidos | sim | sim | perfil + F3 |
  | Séries assistidas | sim | sim | F3 |
  | Séries concluídas | sim | sim | perfil + F3 |
  | Minutos assistidos + nº estimado + nº sem duração | sim | sim | perfil + F3 ("horas assistidas") |
  | `undatedMovies`, `undatedEpisodes` (marcações sem data) | sim | — | nota de corte |
  | `datedFrom` (primeira data existente) | sim | — | nota de corte |
  | `memberSince` ("No CineTrack desde", metadado do Firebase Auth) | sim | — | cabeçalho (D8) |
  Fora de `stats`, no documento: `updatedAt` (hora do servidor), `tz` (deslocamento UTC do dono em minutos, −840..840), `calc` (versão da fórmula), `v` (versão do schema = 1). **"Recomendações" não está aqui** (RF-P3).
- RF-S2. **Definições** (oráculo; docs/82 §5.2). `D(s,k)` = `epsAt[k]` **só se `k` está em `eps`**; "datado no período P" = chave do período de `D` no fuso do dono = P.
  | Métrica | Total | Período P |
  |---|---|---|
  | Filmes assistidos | `watchedMovie` | `watchedMovie` e `lastWatchedAt` em P |
  | Episódios assistidos | nº de chaves em `eps` | nº de `k` com `D(s,k)` em P |
  | Séries assistidas | séries com ≥ 1 episódio em `eps` | séries com ≥ 1 `D(s,k)` em P |
  | Séries concluídas | regra atual do Perfil (catálogo local, episódios já exibidos) | concluída **agora** e `conclusão(s)` em P, com `conclusão(s)` = maior `D(s,k)` dos episódios marcados; concluída sem nenhuma data: só Total |
  | Minutos / estimado / sem duração | `WatchTimeCalculator` (inalterado) | mesma fórmula, só filmes/episódios datados em P |
  Remarcar substitui a data. Série "desconcluída" por episódio novo sai de concluídas (Total e períodos) no próximo recálculo; reconcluída conta na data da nova marcação.
- RF-S3. **Períodos no fuso do dono** (B1): `month.key`/`year.key` são calculados no fuso do aparelho do dono no momento do cálculo e `tz` é gravado. O leitor calcula "agora no fuso do dono" (`agoraUtc + tz`) e mostra "este mês" = `stats.month` se `month.key` é esse mês, senão **0**; "este ano" idem. Todos os leitores, em qualquer fuso, veem o mesmo número. Mudança de `month.key`/`year.key` conta como mudança (grava). Horário de verão: vale o deslocamento do cálculo (borda de 1 h aceita).
- RF-S4. **Nota de corte** (B2): aparece se `undatedMovies + undatedEpisodes > 0`, com o texto "Marcações feitas antes de DD/MM/AAAA contam só no total." (`datedFrom`), ou, sem `datedFrom`, "Marcações anteriores a esta versão contam só no total."; mostrada sob "este mês" se `datedFrom` (sem ele, `updatedAt`) cai no mês atual do dono, sob "este ano" se cai no ano atual.
- RF-S5. **Quando grava** (D4, D7; docs/82 §6): gatilhos = toda mudança da lista de favoritos observada pelo listener (escritas do app, massa, Desfazer, `addAndRecommend`, `favoriteThen`, replay pós-login, outro aparelho, aba antiga), fim do sync de catálogo/durações, virada de mês/ano do dono, início de sessão, ligar seção. **Escrita própria, nunca no mesmo batch nem na mesma escrita do favorito.** Coalescência: **W = 5 s** sem nova mudança, no máximo **30 s** desde a primeira mudança pendente; ao ocultar a página tenta gravar o que estiver pronto. N mudanças dentro de W = **1** escrita.
- RF-S6. **Só grava com dados confiáveis**: favoritos já confirmados pelo servidor nesta sessão (`fromCache == false` visto), sem escritas pendentes, sync de catálogo ocioso (ou 60 s de espera), ≥ 1 seção ligada (estado lido do servidor nesta sessão), `deleting != true`, nenhuma exclusão/desativação em andamento, mesmo uid do início.
- RF-S7. **Só grava se mudou** (comparação do conteúdo sem `updatedAt`): igual = 0 escritas. **Não regride**: se as contagens são iguais e só minutos/estimado/sem duração ficariam menos completos, não grava. **Pulso de 24 h**: conteúdo igual e `updatedAt` com mais de 24 h ⇒ grava só `updatedAt` (no máximo 1/dia, com o app aberto).
- RF-S8. **Falha do compartilhado é silenciosa** (sem banner; não usa o banner de sincronização dos favoritos) e **nunca desfaz** a marcação. `permission-denied`/`not-found` ⇒ relê o próprio documento do servidor e atualiza o estado. No máximo **1 tentativa por gatilho** (10 falhas = no máximo 10 tentativas, todas ligadas a gatilhos; nunca laço).
- RF-S9. Antes de gravar, o app **limita** cada valor às faixas da tabela de tetos (docs/82 §4.4; ex.: `favorites` ≤ 100 000, `watchedEpisodes` ≤ 1 000 000, `minutes` ≤ 52 560 000, `movies + series == favorites`, mês ≤ ano ≤ total, datas ≤ agora + 24 h); a ação do usuário nunca é recusada por isso. **As regras não impõem esses tetos nem a coerência** (D12): impõem forma, ≥ 0 nas 5 métricas do ranking, formatos de chave, hora do servidor, `tz` em faixa, listas ≤ 10/50, `at >= actSince`, seção ⇔ consentimento.
- RF-S10. As estatísticas do **Meu perfil** continuam calculadas ao vivo; só a prévia lê o documento gravado. Com os dados confirmados, a prévia mostra os **mesmos números** do Perfil ao vivo.

**RF-A: Atividades (derivadas dos dados, D1)**
- RF-A1. Tipos emitidos: `favorited`, `watched_movie`, `watched_episodes`, `completed_series`. Reservado à F4: `rated`. O leitor **ignora** item de tipo desconhecido, malformado ou com campo obrigatório ausente, e mostra os demais.
- RF-A2. Cada item: `type`, `id` (TMDB), `mediaType`, `title`, `poster` (opcional), `at`; para episódios `count`, `season`, `episode` ("até" = **maior** temporada/episódio do grupo).
- RF-A3. **Não há registro de eventos**: as atividades são **recalculadas a partir dos dados** a cada snapshot — eventos `favoritou` (`addedAt`), `assistiu filme` (`lastWatchedAt` com `watchedMovie`) e `assistiu episódio` (`D(s,k)`), só os com `at >= actSince`. Por isso desmarcar, Desfazer e remover dos favoritos **refletem-se sozinhos**: desmarcar 1 de N episódios agrupados **reduz o contador** (e o "até", se era o maior); desmarcar o único episódio do grupo **remove** o item; remover o título dos favoritos remove todos os itens dele.
- RF-A4. Agrupamento: episódios da mesma série se fundem enquanto **nenhum outro título** aparece entre eles (sem limite de tempo); grupos da mesma série se fundem de novo se o título que os separava some; massa = 1 grupo (mesmo instante); grupo cuja data é a de conclusão de uma série concluída agora vira `completed_series`; `favoritou` seguido de `assistiu` do mesmo título em **≤ 10 min** vira só o `assistiu`.
- RF-A5. **Recomendar não é atividade.** Marcações sem data (app antigo) não geram atividade.
- RF-A6. Guarda os **10** mais recentes (mais novo primeiro), exibe 3. Desligar e religar "Atividades" recomeça a lista (novo `actSince`).
- RF-A7. Tocar numa atividade abre `/movie/:id` ou `/tv/:id`.
- RF-A8. Textos: `favorited` "Favoritou X"; `watched_movie` "Assistiu X"; `watched_episodes` com 1 episódio "Assistiu TaEb de X", com N > 1 "Assistiu N episódios de X, até TaEb"; `completed_series` "Concluiu X"; seguidos da data relativa ("há 2 h").

**RF-R: Recomendados (`recs`)**
- RF-R1. Com "Recomendados" ligado, amigos veem até **50** títulos (`id, mediaType, title, poster`) na ordem da aba Minhas recomendações (`FavoriteItem.byRecentActivity`) e o número **"Recomendações"** (`recs.count`, exibido na seção Recomendados). 50 títulos: sem "e mais"; 51: "e mais 1". Tocar abre o detalhe.
- RF-R2. Marcar/desmarcar "Recomendo" ou remover o título de Favoritos atualiza `recs` pelo mesmo motor (RF-S5–S8). Os itens são validados pelo app, não pelas regras (D16).
- RF-R3. Desligar apaga `recs`; o campo `recommended` dos favoritos **não muda**.

**RF-F: Perfil de amigo**
- RF-F1. Na lista Amigos, tocar (ou Enter) no nome/foto do amigo abre `/friends/u/<uid>`; Remover/Bloquear continuam no cartão.
- RF-F2. Rota protegida pelo `redirect` existente de `/friends/*`; funciona ao recarregar (hash sob `/cinetrack/`). Sem dados do amigo vindos da lista (recarregar/endereço digitado): procura na lista em cache; senão `get friendships/{par}` (1 leitura; negado ou inexistente = "indisponível").
- RF-F3. Cabeçalho (apelido, foto, "Amigos desde") vem do instantâneo do par (0 leitura) e aparece **antes** de a leitura do conteúdo terminar.
- RF-F4. Leitura de `shared_profiles/{uid}` sempre **do servidor** (`Source.server`), nunca do cache persistente; resultado guardado só **em memória**, por (leitor, amigo), **TTL 5 min** (D15). "Atualizar"/"Tentar novamente" ignoram o TTL. Sair ou trocar de conta descarta todo o cache.
- RF-F5. **Resposta do servidor → estado** (oráculo B7):
  | Resposta | Estado | Efeito |
  |---|---|---|
  | documento existe | conteúdo; seção ausente = "Fulano não compartilha [estatísticas \| atividades \| recomendados] com amigos." | grava no cache de memória |
  | `not-found` (leitura permitida) | "Fulano ainda não compartilha nada além do cartão." | grava no cache de memória |
  | `permission-denied` | "Este perfil não está disponível." + "Voltar para Amigos" | apaga o cache desse uid e tira o amigo da lista em cache **na hora** |
  | aparelho offline | "Sem conexão. Conecte-se para ver o perfil de Fulano." | **nenhum conteúdo**, nem o de memória (D10) |
  | `unavailable` / timeout (8 s) online | "Não foi possível carregar o perfil." + "Tentar novamente" | nenhum conteúdo exibido |
  | `resource-exhausted` | mensagem de cota existente + "Tentar novamente" | — |
  | `unauthenticated` | fluxo de sessão expirada existente | — |
  | uid inválido (falha `validUid` local), longo ou com caracteres especiais | "Este perfil não está disponível." | **nenhuma leitura** |
  | próprio uid | vai para `/profile` | nenhuma leitura |
  | amizades próprias desativadas | estado de `/friends` sem amizades ativas (Fase 1) | nenhuma leitura |
- RF-F6. **Exclusão interrompida do dono** (documento compartilhado já apagado, par ainda existe): o amigo vê "Fulano ainda não compartilha nada além do cartão." (coerente com o cartão em Amigos); quando a exclusão termina, passa a "indisponível". Nada é exposto (sem `exists(social)` na regra, A8).
- RF-F7. **Risco aceito (D15)**: um ex-amigo que reabre o perfil em até 5 min depois da revogação, sem "Atualizar", revê o que já tinha visto (nada novo); a cópia no cache persistente do SDK do leitor nunca é exibida.
- RF-F8. Ações Remover amizade e Bloquear: diálogos e métodos da Fase 1; sucesso ⇒ `/friends` com a mensagem da Fase 1 e lista/indicador reconstruídos; offline ⇒ botões desabilitados com o motivo; erro ⇒ mensagem da Fase 1; ação em andamento ⇒ "Removendo..."/"Bloqueando...".
- RF-F9. Campo ausente no documento do amigo (schema mais antigo/novo) aparece "—", nunca 0; campos e tipos desconhecidos são ignorados.

### Requisitos não funcionais
- RNF1 **Privacidade por construção**: `users/{uid}/favorites` nunca é lido por terceiros (inclusive `epsAt`); conteúdo para amigos só em `shared_profiles/{uid}`; leitura = `isOwner(uid) || isFriend(uid, leitor)` (1 chamada); `list` negado; seção desligada = ausente do servidor; o motor nunca escreve `sharing`, então um aparelho atrasado não republica seção desligada (negado pelas regras).
- RNF2 **Spark**: sem Cloud Functions; ≤ 1 chamada `exists`/`get` por operação; pior escrita ≤ 65% do limite de **1000 expressões** por requisição (medido ≈ 62%); teste de folga em `rules_budget`.
- RNF3 **Nunca perder dados**: nenhuma escrita desta fase compartilha batch/escrita com favorito/progresso (exceto `epsAt`, que é parte da própria marcação e só vai com regras constatadas); falha do compartilhado é silenciosa e não desfaz nada; validador Dart = contrato da tabela de tetos + golden `shared_profile_payloads.json` reproduzido contra as regras; valores fora da faixa são limitados, nunca recusados.
- RNF4 **Compatibilidade**: documentos antigos sem `epsAt`/sem `shared_profiles` funcionam; app antigo × regras novas: suíte atual inteira passa (376/376 no spike); app novo × regras antigas (fixture `firestore.rules.v3` = regras atuais da `main`): interruptores falham com "O perfil compartilhado ainda não está disponível.", marcações seguem **sem data**, nada se perde. Regras **antes** do app e nunca revertidas.
- RNF5 **Cota**: ver § Cota.
- RNF6 **Revogação imediata**: desfazer amizade/bloquear negam a próxima leitura pela regra, sem reescrever o documento do dono; desligar apaga no servidor por transação.
- RNF7 **Acessibilidade e layout**: 320/375/768/1024/1440 px × fonte 1×/2×/3× × claro/escuro, sem exceção de overflow nem rolagem horizontal; títulos longos com reticências e texto completo no `Semantics`; interruptores com `Semantics(toggled)`; teclado (Tab/Shift+Tab, Enter/Espaço, Esc fecha diálogos); ordem de foco fixada nos critérios.
- RNF8 **Mensagens sem vazamento**: "indisponível" único para não amigo, ex-amigo, bloqueio (2 sentidos), conta excluída, uid inválido; `permission-denied` nunca mostrado cru.
- RNF9 **LGPD**: consentimento específico por seção, informado (prévia e texto literal), revogável a qualquer momento; nada anterior ao consentimento de atividades é publicado; a data de marcação (dado privado novo para todos) e o compartilhamento entram na política (com data) **antes** do app de cada fatia; exportação e exclusão cobrem tudo. Parecer jurídico **não verificado**.
- RNF10 **Relógio injetável** único (`sharedProfileClockProvider`) no cálculo, nas atividades e em `EpisodeCache.hasAiredAt`, para testes com datas absolutas.

### Estados de UI
| Tela | Estado | O que aparece |
|---|---|---|
| Meu perfil | sem amizades ativas | como hoje; sem a seção |
| Meu perfil | estado carregando | interruptores pela pista local, desabilitados com progresso; sem pista: esqueleto |
| Meu perfil | estado não confirmado e offline | interruptores desabilitados + "Sem conexão. Tente de novo quando estiver online." |
| Meu perfil | tudo desligado (padrão) | 3 interruptores desligados + "Seus amigos veem só seu cartão (apelido e foto)." |
| Meu perfil | prévia ainda calculando | botão de compartilhar do diálogo mostra "Calculando…" |
| Meu perfil | ligando/desligando | interruptor desabilitado com progresso |
| Meu perfil | incerto | "Ainda não confirmado…"; reconcilia ao reconectar (RF-P7) |
| Meu perfil | offline ao tocar | interruptor não muda + "Sem conexão. Tente de novo quando estiver online." |
| Meu perfil | regras antigas | "O perfil compartilhado ainda não está disponível." |
| Meu perfil | cota | mensagem de cota existente |
| Meu perfil | ligado | "Atualizado há X", "Como seus amigos veem" |
| Meu perfil | atividades ligadas, sem atividade | "Suas próximas atividades aparecem aqui." |
| Meu perfil | falha silenciosa do recálculo | sem banner; "Atualizado há X" continua honesto |
| Meu perfil / perfil de amigo | `month.key` antigo | "este mês" 0 + "Atualizado há N dias" (texto neutro, sem alarme) |
| Meu perfil / perfil de amigo | marcações sem data | nota de corte (RF-S4) |
| Perfil de amigo | carregando | cabeçalho do par + esqueleto das seções |
| Perfil de amigo | conteúdo / não compartilha / indisponível / offline / erro / cota / sessão expirada / uid inválido / próprio uid / amizades desativadas | tabela RF-F5 |
| Perfil de amigo | sem login | redirect para `/` (como `/friends`) |
| Perfil de amigo | ação em andamento / offline | "Removendo..."/"Bloqueando..." / botões desabilitados com motivo |

### Critérios de aceite
Convenções: datas absolutas no fuso `America/Sao_Paulo` (UTC−3, `tz = −180`) salvo indicação; "relógio falso" = `sharedProfileClockProvider` + `fake_async`; "log de operações" = log do fake de Firestore; W = 5 s.

```gherkin
# ================= Meu perfil: padrões, consentimento, interruptores =================
Cenário: Usuário atual com amizades ativas vê tudo desligado após atualizar o app
  Dado que Ana ativou as amizades na Fase 1 e tem a fixture de 54 favoritos
  Quando ela abre o Perfil na versão nova
  Então vê "O que seus amigos veem" com Estatísticas, Atividades recentes e Recomendados desligados
  E vê "Seus amigos veem só seu cartão (apelido e foto)."
  E o log de operações tem exatamente 1 leitura nova (estado do dono) e 0 escritas novas
  E o ProfileStats exibido é igual ao golden da main para a mesma fixture

Cenário: Usuário sem amizades ativas
  Dado que Bruno nunca ativou as amizades e a sonda de regras já foi feita neste aparelho
  Quando ele abre o Perfil
  Então a lista e a ordem das seções são as mesmas da main
  E o log de operações é idêntico ao baseline da main

Cenário: Sonda de regras uma única vez por aparelho
  Dado que Bruno não tem amizades ativas e este aparelho nunca fez a sonda
  Quando a sessão começa
  Então há 1 leitura de shared_profiles/{uid} no servidor
  E nas sessões seguintes neste aparelho não há nenhuma leitura de sonda

Cenário: Ligar "Estatísticas" com consentimento
  Dado que Ana está online, com amizades ativas, dados confirmados pelo servidor e "Estatísticas" desligado
  Quando ela liga "Estatísticas"
  Então vê o diálogo "Compartilhar estatísticas com amigos?" com o corpo literal da tabela de textos
  E a prévia mostra os mesmos números do Perfil ao vivo, sem "Recomendações"
  Quando ela toca "Compartilhar"
  Então uma transação grava sharing.stats = true e a seção stats, sem recs
  E o interruptor fica ligado e aparece "Atualizado agora"

Cenário: Prévia ainda não disponível
  Dado que os favoritos de Ana ainda não foram confirmados pelo servidor nesta sessão
  Quando ela liga "Estatísticas"
  Então o botão do diálogo mostra "Calculando…" e está desabilitado

Cenário: Cancelar o consentimento não grava nada
  Dado o diálogo de "Recomendados" aberto
  Quando Ana toca "Cancelar" ou pressiona Esc
  Então o interruptor continua desligado e o log não tem escrita

Cenário: Desligar sem confirmação apaga do servidor
  Dado que Ana compartilha só "Atividades recentes"
  Quando ela desliga "Atividades recentes" online
  Então nenhum diálogo de confirmação aparece
  E ao fim da operação o documento shared_profiles/{Ana} não existe no servidor
  E aparece "Seus amigos não veem mais suas atividades recentes."
  E nenhum favorito ou progresso de Ana muda

Cenário: Desligar uma de duas seções
  Dado que Ana compartilha "Estatísticas" e "Atividades recentes"
  Quando ela desliga "Estatísticas"
  Então o documento continua existindo sem stats e sem sharing.stats
  E activity e actSince não mudam

Cenário: Ligar ou desligar sem conexão
  Dado que Ana está offline
  Quando ela toca em qualquer interruptor
  Então o interruptor não muda de posição
  E vê "Sem conexão. Tente de novo quando estiver online."
  E nada fica na fila de escrita

Cenário: Conexão cai durante o ligar (resultado incerto)
  Dado que Ana confirmou "Compartilhar" em "Estatísticas"
  E a transação foi enviada mas não houve resposta em 10 s
  Então o interruptor mostra "Ainda não confirmado…" desabilitado
  Quando a conexão volta e a leitura do servidor mostra sharing.stats = true
  Então o interruptor fica ligado com "Compartilhamento ligado."
  Mas se a leitura mostra que nada foi gravado
  Então o interruptor fica desligado

Cenário: Conexão cai durante o desligar
  Dado que Ana desligou "Recomendados" e a transação não teve resposta em 10 s
  Então o interruptor mostra "Ainda não confirmado…"
  Quando a leitura do servidor mostra que recs ainda existe
  Então o interruptor fica ligado com "Não foi possível desligar. Tente de novo."

Cenário: App novo com regras antigas
  Dado as regras da fixture firestore.rules.v3 (atuais da main)
  Quando Ana liga "Estatísticas"
  Então vê "O perfil compartilhado ainda não está disponível." e o interruptor volta a desligado
  E marcar episódios continua funcionando, sem epsAt no payload
  E nenhuma marcação é desfeita

Cenário: Cota ao ligar
  Dado que a transação de ligar falha com resource-exhausted
  Então Ana vê a mensagem de cota existente e o interruptor volta ao estado do servidor

Cenário: Amizades desativadas em outro aparelho ao ligar
  Dado que social/{Ana} foi apagado em outro aparelho
  Quando Ana liga "Estatísticas" e a transação recebe permission-denied
  Então o app relê o estado e mostra a seção de amizades desativadas

Cenário: Duas operações de interruptor seguidas
  Dado que "Estatísticas" está sendo ligado
  Quando Ana toca em "Recomendados" ou toca de novo em "Estatísticas"
  Então vê "Aguarde a operação anterior terminar."

Cenário: Recálculo automático não trava os interruptores
  Dado que o motor está gravando um recálculo
  Quando Ana toca em "Atividades recentes"
  Então o diálogo de consentimento abre normalmente

Cenário: Estado dos interruptores ao abrir e entre aparelhos
  Dado que Ana ligou "Estatísticas" no aparelho A
  Quando ela abre o Perfil no aparelho B, com uma pista local antiga (tudo desligado)
  Então B mostra a pista desabilitada com progresso
  E depois da leitura do servidor mostra "Estatísticas" ligado
  Mas se B está offline e o estado não foi confirmado nesta sessão
  Então os interruptores ficam desabilitados com "Sem conexão. Tente de novo quando estiver online."

Esquema do Cenário: "Atualizado há"
  Dado que updatedAt foi há <tempo>
  Então o texto é "<texto>"
  Exemplos:
    | tempo     | texto              |
    | 30 s      | Atualizado agora   |
    | 59 min    | Atualizado há 59 min |
    | 60 min    | Atualizado há 1 h  |
    | 23 h 59   | Atualizado há 23 h |
    | 24 h      | Atualizado há 1 dia |
    | 40 dias   | Atualizado há 40 dias |

# ================= Data de cada marcação (epsAt) =================
Cenário: Marcar episódio grava a data na mesma escrita
  Dado regras novas constatadas e o desvio do servidor estimado em +2 min
  Quando o relógio do aparelho marca 15/10/2026 20:00 e Ana marca T1E3 de "Série X"
  Então o log tem 1 update no favorito com eps.1_3 = true e epsAt.1_3 = 15/10/2026 20:02
  E nenhuma outra escrita no mesmo batch

Cenário: Marcação em massa usa um único instante
  Quando Ana marca a temporada 2 inteira de "Série X" (10 episódios)
  Então os 10 epsAt têm o mesmo valor

Cenário: Relógio adiantado
  Dado que o relógio do aparelho está 3 dias adiantado e o desvio ainda não foi estimado
  Quando Ana marca um episódio
  Então a marcação é gravada
  E o snapshot limita qualquer data a no máximo agora + 24 h antes de gravar

Cenário: Desfazer restaura as datas
  Dado que T1E1..T1E5 de "Série X" têm datas de setembro
  Quando Ana desmarca a série inteira e toca "Desfazer"
  Então eps e epsAt voltam exatamente aos valores de setembro

Cenário: Data órfã de app antigo
  Dado que uma aba antiga desmarcou T1E1 deixando epsAt.1_1
  Então T1E1 não conta em nenhum período
  E a próxima escrita da versão nova nesse favorito apaga epsAt.1_1

Cenário: Sem regras novas constatadas
  Dado que a sonda recebeu permission-denied
  Quando Ana marca um episódio
  Então o update tem só eps e lastWatchedAt, sem epsAt
  E o episódio conta só no Total

# ================= Snapshot: escrita separada, coalescência, condições =================
Cenário: Snapshot nunca no mesmo batch do favorito (D4)
  Dado que Ana compartilha estatísticas
  Quando ela marca um filme como assistido
  Então o log tem primeiro o update do favorito, isolado
  E depois de 5 s sem nova mudança exatamente 1 update em shared_profiles/{Ana}, separado

Cenário: Recusa do compartilhado não desfaz a marcação
  Dado que o fake recusa toda escrita em shared_profiles/{Ana} com permission-denied
  Quando Ana marca um filme como assistido
  Então o filme continua marcado no fake do servidor e na tela
  E não aparece banner de erro
  E o app relê shared_profiles/{Ana} uma vez e não tenta gravar de novo até o próximo gatilho

Cenário: Falhas repetidas não viram laço
  Dado que toda escrita do compartilhado falha com resource-exhausted
  Quando ocorrem 10 gatilhos
  Então houve no máximo 10 tentativas de escrita, cada uma ligada a um gatilho

Esquema do Cenário: Coalescência (relógio falso)
  Dado que Ana compartilha estatísticas e a atividade mais recente não é de "Série X"
  Quando ela faz <ações>
  Então o número de escritas em shared_profiles é <escritas> após <espera>
  Exemplos:
    | ações                                         | espera                  | escritas |
    | 1 marcação                                    | 4,9 s                   | 0        |
    | 1 marcação                                    | 5 s                     | 1        |
    | 4 marcações com 2 s entre elas                | 5 s após a última       | 1        |
    | marcações a cada 4 s por 40 s                 | 30 s após a primeira    | 1        |
    | marcar e desmarcar o mesmo episódio em 2 s    | 5 s                     | 0        |

Cenário: Ocultar a página grava o que estiver pronto
  Dado uma mudança pendente há 2 s e as condições de gravação atendidas
  Quando a página fica oculta
  Então 1 escrita é enviada

Cenário: Aparelho novo não publica zeros
  Dado que Ana compartilha estatísticas e o listener só entregou dados com fromCache = true
  Quando o recálculo dispara
  Então há 0 escritas em shared_profiles

Cenário: Escritas pendentes ou catálogo baixando
  Dado hasPendingWrites = true ou o sync de catálogo em andamento há menos de 60 s
  Quando o recálculo dispara
  Então há 0 escritas
  E quando as condições passam a valer, há 1 escrita

Cenário: Recálculo sem mudança
  Dado que o conteúdo calculado é igual ao do servidor e updatedAt tem 3 h
  Quando Ana abre o app
  Então há 0 escritas

Cenário: Pulso de 24 h
  Dado que o conteúdo calculado é igual ao do servidor e updatedAt tem 25 h
  Quando Ana abre o app
  Então há 1 escrita contendo só updatedAt (mais tz e calc)

Cenário: Não regredir o tempo assistido
  Dado que o servidor tem minutes = 20000 e unknown = 0, gravados pelo aparelho A
  E o aparelho B, com catálogo incompleto, calcula as mesmas contagens com minutes = 18000 e unknown = 4
  Então B não grava

Cenário: Série deixa de estar concluída sem ação do dono
  Dado que "Série X" estava concluída e um episódio novo foi ao ar (relógio falso após a data de exibição)
  Quando o sync de catálogo termina
  Então o recálculo reduz "Séries concluídas" em Total, ano e mês, em 1 escrita

Cenário: Outro cliente muda os favoritos (equivale a app antigo)
  Dado que um cliente direto grava eps no favorito de Ana sem epsAt
  Quando a versão nova recebe a mudança pelo listener
  Então recalcula e grava 1 vez, com o episódio contado só no Total

Cenário: Dois aparelhos marcando ao mesmo tempo
  Dado dois repositórios de Ana sobre o mesmo fake
  Quando cada um marca um episódio diferente no mesmo segundo
  Então os dois favoritos ficam marcados
  E depois da sincronização o conteúdo de shared_profiles reflete os dois episódios (vence a última escrita, o outro aparelho acha "igual" e não grava)

Cenário: Sessão trocada com escrita pendente
  Dado uma escrita coalescida pendente de Ana
  Quando a sessão expira ou outra conta entra na mesma aba
  Então nenhuma escrita é feita sob qualquer uid

# ================= Períodos (B1–B3) =================
Cenário: Episódio marcado no mês conta em mês, ano e total
  Dado que hoje é 15/10/2026 12:00 e Ana compartilha estatísticas
  Quando ela marca T1E3 de "Série X"
  Então month.key = "2026-10", year.key = "2026", tz = -180
  E watchedEpisodes sobe 1 em total, year e month

Cenário: Virada de mês no fuso do dono
  Dado que Ana marca um episódio em 31/10/2026 23:59 (America/Sao_Paulo)
  Então ele conta em "2026-10"
  E um episódio marcado em 01/11/2026 00:00 conta em "2026-11"

Cenário: Todos os leitores veem o mesmo "este mês"
  Dado o snapshot de Ana com month.key = "2026-10" e tz = -180, e o instante 01/11/2026 02:30 UTC
  Quando Carla (UTC+0) e Davi (UTC−3) abrem o perfil de Ana
  Então os dois veem "este mês" = valor de "2026-10" (no fuso de Ana ainda é 31/10 23:30)

Cenário: Desmarcar episódio marcado em mês anterior
  Dado que Ana marcou T1E1 em 20/09/2026 e hoje é 15/10/2026
  Quando ela desmarca T1E1
  Então o total cai 1, "este ano" cai 1 e "este mês" não muda

Cenário: Desmarcar na virada de ano
  Dado que Ana marcou T1E1 em 20/12/2026 e hoje é 10/01/2027
  Quando ela desmarca T1E1
  Então o total cai 1 e "este mês" e "este ano" (2027) não mudam

Cenário: Snapshot de um mês que já passou
  Dado que o último snapshot de Ana tem month.key = "2026-09" e hoje é 15/10/2026 no fuso dela
  Quando Carla abre o perfil de Ana
  Então "este mês" mostra 0, "este ano" e o total mostram os valores gravados
  E aparece "Atualizado há N dias" sem nenhum alerta

Cenário: Snapshot de dezembro lido em janeiro
  Dado month.key = "2026-12" e year.key = "2026" e hoje é 05/01/2027 no fuso do dono
  Então "este mês" e "este ano" mostram 0

Cenário: Virada de mês grava mesmo sem mudança de contagem
  Dado que Ana está com o app aberto às 23:59:50 de 31/10/2026
  Quando o relógio passa para 01/11/2026 00:00
  Então o motor grava 1 vez com month.key = "2026-11"

Cenário: Marcações antigas contam só no total, com nota
  Dado que Ana tem 300 episódios marcados sem data, nenhum com data, e liga "Estatísticas" em 15/10/2026
  Então Total de episódios = 300, "este mês" = 0, "este ano" = 0, undatedEpisodes = 300
  E aparece "Marcações anteriores a esta versão contam só no total." sob "este mês" e sob "este ano"

Cenário: Nota com data de corte
  Dado que a primeira data existente (datedFrom) é 11/10/2026 e há marcações sem data
  Então aparece "Marcações feitas antes de 11/10/2026 contam só no total."

Esquema do Cenário: Definições por período (hoje = 15/10/2026)
  Dado <situação>
  Então em outubro/2026 <resultado>
  Exemplos:
    | situação | resultado |
    | filme assistido com lastWatchedAt 02/10/2026 | conta em filmes assistidos do mês e do ano |
    | filme assistido sem lastWatchedAt | só no Total, undatedMovies +1 |
    | série com T1E1 marcado em 03/10 | séries assistidas do mês +1 |
    | série concluída cujo último episódio marcado tem data 10/10 | séries concluídas do mês +1 |
    | série concluída sem nenhuma data | só no Total |
    | episódio de 45 min com data 05/10 | minutos do mês +45 |
    | episódio sem duração com data 05/10 | unknown do mês +1, minutos inalterados |
    | T1E2 desmarcado e remarcado em 12/10 (antes, 20/09) | conta em outubro, não em setembro |

# ================= Limites e regras (D12, D16) =================
Esquema do Cenário: Regras recusam forma inválida
  Quando o dono tenta gravar <payload>
  Então o servidor nega
  Exemplos:
    | payload |
    | watchedEpisodes negativo em total, year ou month |
    | campo desconhecido no documento ou em stats |
    | updatedAt diferente de request.time |
    | tz = 900 |
    | month.key "2026-13" ou com prefixo diferente de year.key |
    | 11 atividades |
    | atividade com at anterior a actSince |
    | 51 recomendados ou recs.count menor que o número de itens |
    | stats presente sem sharing.stats (ou o inverso) |
    | mudar sharing sem social/{uid} |
    | criar o documento com conta não Google |

Cenário: Regras não impõem tetos nem coerência (risco aceito D12)
  Dado um cliente modificado do dono
  Quando ele grava watchedEpisodes = 999999999 ou month maior que total, com forma válida
  Então o servidor aceita
  E o validador Dart do app oficial nunca produz esse payload (limita a 1000000 e a month ≤ year ≤ total)

Cenário: Validador limita antes de gravar
  Dado um cálculo que produziria um valor acima do teto da tabela de tetos
  Então o payload gravado tem o valor limitado ao teto
  E a ação do usuário que disparou o cálculo não é afetada

Cenário: Aparelho atrasado não republica seção desligada
  Dado que Ana desligou "Atividades" no aparelho A
  Quando o aparelho B envia um recálculo com activity
  Então o servidor nega e B relê o documento e passa a mostrar "Atividades" desligado

Cenário: Amigo não escreve no documento do dono
  Quando Carla tenta criar, alterar ou apagar shared_profiles/{Ana}
  Então o servidor nega

Esquema do Cenário: validFavorite com epsAt
  Quando o dono grava um favorito com <epsAt>
  Então o servidor <resultado>
  Exemplos:
    | epsAt              | resultado |
    | ausente (payload antigo) | aceita |
    | mapa com 5000 entradas   | aceita |
    | mapa com 5001 entradas   | nega   |
    | string                   | nega   |

# ================= Atividades (D1, B8) =================
Esquema do Cenário: O que conta como atividade
  Dado que Ana compartilha atividades desde actSince
  Quando ela <ação>
  Então a lista <efeito>
  Exemplos:
    | ação | efeito |
    | favorita "Filme Y" | ganha "Favoritou Filme Y" |
    | marca "Filme Y" assistido 2 h depois de favoritar | ganha "Assistiu Filme Y" acima de "Favoritou Filme Y" |
    | favorita "Filme Z" e marca assistido em 8 min | ganha só "Assistiu Filme Z" |
    | marca T1E3 de "Série X" | ganha "Assistiu T1E3 de Série X" |
    | conclui "Série X" | ganha "Concluiu Série X" |
    | marca ou desmarca "Recomendo" | não muda |

Esquema do Cenário: Tabela de transições (oráculo docs/82 §5.3, teste parametrizado 1:1)
  Dado a lista <antes>
  Quando <ação>
  Então a lista é <depois>
  Exemplos:
    | # | antes | ação | depois |
    | 1 | [] | marca T1E1..T1E4 de X, um por vez | [ep(X,4,T1E4)] |
    | 2 | [ep(X,4,T1E4)] | desmarca T1E2 | [ep(X,3,T1E4)] |
    | 3 | [ep(X,4,T1E4)] | desmarca T1E4 | [ep(X,3,T1E3)] |
    | 4 | [ep(X,1,T1E1), mov(Y)] | desmarca T1E1 | [mov(Y)] |
    | 5 | [ep(X,2,T2E2)] | marca T1E5 | [ep(X,3,T2E2)] |
    | 6 | [mov(Y), ep(X,2,T1E2)] | marca T1E3 de X | [ep(X,1,T1E3), mov(Y), ep(X,2,T1E2)] |
    | 7 | [ep(X,1,T1E3), mov(Y), ep(X,2,T1E2)] | desmarca Y | [ep(X,3,T1E3)] |
    | 8 | [mov(Y)] | marca X inteira (conclui) | [done(X,n), mov(Y)] |
    | 9 | [ep(X,2,T1E2)] | marca o resto de X em massa (conclui) | [done(X,2+m)] |
    | 10 | [done(X,n), mov(Y)] | Desfazer da massa do #8 | [mov(Y)] |
    | 11 | [done(X,n)] | episódio novo de X vai ao ar; recálculo | [ep(X,n,…)] |
    | 12 | [] | favorita Z e marca assistido em ≤ 10 min | [mov(Z)] |
    | 13 | [] | favorita Z; 2 h depois marca assistido | [mov(Z), fav(Z)] |
    | 14 | [ep(X,3,…), fav(Z)] | remove X dos favoritos | [fav(Z)] |
    | 15 | qualquer | marca/desmarca "Recomendo" | inalterado |
    | 16 | qualquer | marcação feita no app antigo (sem data) | inalterado |
    | 17 | lista com itens | desliga e religa "Atividades" | [] |
    | 18 | [mov(Y), ep(X,1,T1E1)] | desmarca e remarca T1E1 | [ep(X,1,T1E1), mov(Y)] |
    | 19 | 10 itens | nova atividade; depois desfaz | 10 itens (o mais antigo sai); o antigo volta |
    | 20 | item de tipo desconhecido ou malformado no documento | leitor desta fase | item ignorado, demais exibidos |

Cenário: Marcar episódio atualiza o que os amigos veem
  Dado que Ana compartilha estatísticas e atividades e a atividade mais recente não é de "Série X"
  Quando ela marca T1E3 de "Série X" e passam 5 s
  Então o documento tem watchedEpisodes +1 (total, ano e mês) e a primeira atividade "Assistiu T1E3 de Série X"

Cenário: Nada anterior ao consentimento é publicado
  Dado que Ana assistiu 3 filmes ontem e liga "Atividades recentes" hoje
  Então a lista publicada está vazia e Meu perfil mostra "Suas próximas atividades aparecem aqui."

Cenário: Atividades desligadas
  Dado que "Atividades recentes" está desligado
  Quando Ana marca episódios
  Então o documento compartilhado não tem activity
  E as datas de marcação continuam sendo gravadas nos favoritos dela (privadas)

# ================= Recomendados =================
Cenário: Recomendados só com opt-in
  Dado que Ana tem 12 títulos recomendados e "Recomendados" desligado
  Quando Carla abre o perfil de Ana
  Então não vê a lista nem o número "Recomendações"
  Quando Ana liga "Recomendados" e confirma
  Então o documento tem recs.count = 12 e 12 itens na ordem da aba
  E Carla, ao tocar "Atualizar", vê os 12 títulos e "Recomendações: 12" na seção Recomendados

Esquema do Cenário: Limite de 50
  Dado que Ana tem <n> recomendados
  Então Carla vê <itens> títulos e <rodapé>
  Exemplos:
    | n  | itens | rodapé |
    | 50 | 50 | nenhum "e mais" |
    | 51 | 50 | "e mais 1" |

Cenário: Desligar recomendados não mexe nas recomendações
  Quando Ana desliga "Recomendados"
  Então recs não existe no servidor
  E "Minhas recomendações" de Ana continua com os mesmos títulos e o campo recommended não muda

# ================= Perfil de amigo =================
Cenário: Abrir o perfil de um amigo pela lista
  Dado que Ana e Carla são amigas e Ana compartilha estatísticas
  Quando Carla toca no cartão de Ana em Amigos (leitura retida por um Completer)
  Então apelido, foto e "Amigos desde" já estão visíveis com a leitura pendente
  E o contador do fake registra 1 get de shared_profiles/{Ana} com Source.server
  E a regra de leitura usa no máximo 1 chamada (rules_budget)

Cenário: Cache de memória com TTL (D15)
  Dado que Carla abriu o perfil de Ana
  Quando ela reabre após 4 min 59 s
  Então nenhuma leitura é feita
  Quando ela reabre após 5 min
  Então 1 leitura é feita
  E "Atualizar" faz 1 leitura a qualquer momento

Cenário: Abrir por endereço sem lista em cache
  Dado que Carla recarrega a página em /friends/u/<uid de Ana> sem lista em cache
  Então o app lê friendships/{par} (1 leitura) para o cabeçalho e depois shared_profiles/{Ana}

Esquema do Cenário: Resposta do servidor → estado (oráculo B7)
  Dado que a leitura de shared_profiles/{Ana} responde <resposta>
  Então Carla vê <estado>
  E <efeito>
  Exemplos:
    | resposta | estado | efeito |
    | documento com stats e activity, sem recs | estatísticas, atividades e "Ana não compartilha recomendados com amigos." | conteúdo vai para o cache de memória |
    | not-found | "Ana ainda não compartilha nada além do cartão." | vai para o cache de memória |
    | permission-denied | "Este perfil não está disponível." e "Voltar para Amigos" | cache do uid apagado e Ana sai da lista em cache na hora |
    | unavailable com o aparelho online | "Não foi possível carregar o perfil." e "Tentar novamente" | nenhum conteúdo exibido |
    | timeout de 8 s | "Não foi possível carregar o perfil." e "Tentar novamente" | nenhum conteúdo exibido |
    | resource-exhausted | mensagem de cota existente e "Tentar novamente" | nenhum conteúdo exibido |
    | unauthenticated | fluxo de sessão expirada | — |

Cenário: Offline não mostra nada, nem da memória (D10)
  Dado que Carla abriu o perfil de Ana há 1 min (conteúdo no cache de memória)
  E o aparelho fica offline
  Quando ela reabre o perfil de Ana
  Então vê o cabeçalho e "Sem conexão. Conecte-se para ver o perfil de Ana."
  E nenhum número, atividade ou recomendado aparece

Cenário: Não amigo pelo endereço
  Dado que Davi não é amigo de Ana
  Quando ele abre /friends/u/<uid de Ana>
  Então vê "Este perfil não está disponível."
  E as regras negam a leitura

Esquema do Cenário: uid inválido
  Quando alguém abre /friends/u/<uid>
  Então vê "Este perfil não está disponível." e nenhuma leitura é feita
  Exemplos:
    | uid |
    | a_b |
    | (129 caracteres) |
    | %2F..%2F |

Cenário: Bloqueio nos dois sentidos
  Dado que Ana bloqueou Carla (ou Carla bloqueou Ana)
  Quando qualquer uma tenta ler o perfil da outra
  Então vê "Este perfil não está disponível." e as regras negam nos dois sentidos

Cenário: Amizade desfeita com a tela aberta
  Dado que Carla está com o perfil de Ana aberto
  Quando Ana remove a amizade em outro aparelho
  E Carla toca "Atualizar"
  Então vê "Este perfil não está disponível."
  E Ana sai da lista de amigos em cache de Carla na hora
  E nenhum dado de Ana foi reescrito

Cenário: Ex-amigo reabrindo dentro do TTL (risco aceito D15)
  Dado que Carla viu o perfil de Ana há 2 min e a amizade foi desfeita há 1 min
  Quando Carla reabre o perfil sem tocar "Atualizar"
  Então vê o mesmo conteúdo de 2 min atrás e nada mais novo
  E ao tocar "Atualizar" vê "Este perfil não está disponível."

Cenário: Trocar de conta limpa o cache de perfis
  Dado que Carla viu o perfil de Ana
  Quando Carla sai e Davi entra na mesma aba
  Então nenhum perfil em cache de Carla é exibido a Davi

Cenário: Amigo que excluiu a conta
  Dado que Ana excluiu a conta e Carla tem a lista de amigos em cache
  Quando Carla toca no cartão de Ana
  Então vê "Este perfil não está disponível." e o cartão sai da lista em cache

Cenário: Exclusão interrompida do dono
  Dado que a exclusão de Ana parou depois de apagar shared_profiles e antes de varrer os pares
  Quando Carla abre o perfil de Ana
  Então vê "Ana ainda não compartilha nada além do cartão."
  E quando a exclusão termina, vê "Este perfil não está disponível."

Cenário: Amizades próprias desativadas
  Dado que Carla desativou as amizades
  Quando ela abre /friends/u/<uid de Ana>
  Então vê o estado de /friends sem amizades ativas e nenhuma leitura é feita

Cenário: Sem login
  Quando ninguém está conectado e alguém abre /friends/u/<uid>
  Então é levado para o Início

Cenário: Próprio uid
  Quando Ana abre /friends/u/<uid de Ana>
  Então é levada para /profile sem leitura

Cenário: Remover amizade pelo perfil
  Quando Carla toca "Remover amizade" no perfil de Ana e confirma ("A pessoa não será avisada")
  Então volta para /friends com a mensagem da Fase 1 e Ana não aparece mais

Cenário: Bloquear pelo perfil
  Quando Carla toca "Bloquear" no perfil de Ana e confirma
  Então o batch da Fase 1 grava o bloqueio e desfaz a amizade
  E Carla volta para /friends e Ana aparece em Bloqueados

Cenário: Remover ou bloquear offline ou com erro
  Dado que Carla está offline
  Então "Remover amizade" e "Bloquear" estão desabilitados com o motivo da Fase 1
  E com erro do servidor aparece a mensagem da Fase 1 e Carla continua no perfil

Cenário: Schema mais novo ou mais antigo
  Dado um documento de Ana sem o campo watchedSeries e com um campo "rankPoints" desconhecido
  Então "Séries assistidas" aparece "—" e o campo desconhecido é ignorado

Cenário: Título sem pôster ou longo
  Dado uma atividade de título removido do TMDB sem pôster e outra com título de 300 caracteres
  Então a primeira mostra o ícone padrão e a segunda aparece com reticências e o texto completo no Semantics

# ================= Exclusão, desativação, exportação, política =================
Cenário: Exclusão de conta apaga o compartilhado antes e depois das varreduras
  Dado que Ana compartilha as três seções
  Quando ela exclui a conta
  Então o log segue: reauth, ensureOnline, markDeleting, delete shared_profiles/{Ana}, varreduras sociais, delete shared_profiles/{Ana}, favoritos, perfil, usuário
  E retomada após falha em qualquer passo termina sem resíduo

Cenário: Escrita coalescida pendente ao excluir
  Dado uma escrita do motor pendente (dentro de W)
  Quando markDeleting acontece
  Então 0 escritas em shared_profiles depois de markDeleting

Cenário: Desativar amizades apaga e desliga
  Quando Ana desativa as amizades
  Então o log segue: delete shared_profiles, varredura, fechar social, delete shared_profiles, varredura
  E os três interruptores ficam desligados; ao reativar, tudo começa desligado

Cenário: Desativação interrompida
  Dado que a desativação falhou na última varredura ("Concluir limpeza")
  Então shared_profiles/{Ana} já não existe
  E "Concluir limpeza" chama a exclusão do compartilhado de novo e termina

Cenário: Exportar meus dados (schema 3)
  Dado que Ana compartilha estatísticas e atividades e tem episódios com data
  Quando ela exporta
  Então o arquivo tem schemaVersion 3, "sharedProfile": {"id": uid, "data": documento bruto} com data.sharing
  E os favoritos exportados contêm epsAt
  E para quem nunca ligou nada o arquivo é o de hoje com "sharedProfile": null e schemaVersion 3

Cenário: Política e resumo de privacidade
  Quando a Fatia 1 é publicada
  Então PrivacySummary e web/privacidade.html (com data nova) dizem que a data de cada marcação de episódio é guardada só para o dono
  E na Fatia 2/4 dizem que por padrão amigos veem só o cartão e que cada seção é escolhida e desligada a qualquer momento
  E o teste de widget compara o texto literal do PrivacySummary

# ================= Layout e acessibilidade =================
Cenário: Larguras, fonte e tema
  Dado 320, 375, 768, 1024 e 1440 px, fonte 1×, 2× e 3×, tema claro e escuro
  Quando abro Meu perfil (seção ligada e desligada) e o perfil de amigo (com conteúdo e em cada estado)
  Então não há exceção de overflow nem rolagem horizontal
  E a grade de estatísticas segue o padrão do Perfil (2 colunas, linhas de altura igual)

Cenário: Ordem de foco e leitor de tela em Meu perfil
  Quando navego com Tab pela seção "O que seus amigos veem"
  Então o foco passa por: "Estatísticas" → "Atividades recentes" → "Recomendados" → "Como seus amigos veem" → cada atividade recente
  E Espaço/Enter alternam o interruptor focado e Esc fecha o diálogo
  E o leitor anuncia "Compartilhar estatísticas com amigos, desligado"

Cenário: Ordem de foco e leitor de tela no perfil de amigo
  Quando navego com Tab no perfil de amigo
  Então o foco passa por: Voltar → "Atualizar" → cada atividade → cada recomendado → "Remover amizade" → "Bloquear"
  E cada estatística tem o rótulo "<rótulo>: <valor>" (ex.: "Filmes assistidos: 12") e cada atividade a frase completa
```

### Casos de borda
- **Fuso/horário de verão**: vale o deslocamento do dono no cálculo (`tz`); borda de 1 h aceita.
- **Relógio do aparelho errado** antes da primeira estimativa de desvio: a data de uma marcação pode cair no mês vizinho (risco residual, docs/82 §14 #5); datas limitadas a agora + 24 h.
- **Dois aparelhos com catálogos diferentes**: "não regredir" evita piorar minutos; oscilação pequena aceita.
- **Aba antiga** remarcando um episódio com data órfã: volta a contar na data antiga (raro, documentado).
- **Rollback do app** com conteúdo publicado: a versão antiga não sabe desligar; o dono usa a versão nova, a exclusão ou a desativação (checklist de release).
- **Escrita do motor já na fila do SDK** quando o documento é apagado: negada (`update` em inexistente).
- **300 amigos** abrindo o mesmo perfil: cada leitor paga as próprias leituras.
- **Série com 5000 episódios**: `epsAt` ≈ +100 KB, abaixo de 1 MiB; isenção de índice opcional para `epsAt`.
- **Limite de 500 transformações por escrita** (documentado, não verificado em produção): por isso `epsAt` usa um instante do cliente, não `serverTimestamp` por episódio.

### Forward-compat
- **F3 Ranking**: filtros (filmes assistidos, séries assistidas, séries concluídas, episódios, minutos) × (Total, este mês, este ano) saem de `stats` no mesmo documento, sem migração; quem não compartilha estatísticas não entra no ranking (D13, texto do consentimento já cita "comparações entre amigos"). Leitura de N amigos: N `get` (2N leituras a frio) ou `documentId in [≤ 10]`; `list` continua negado até a F3 decidir. Recomendação ao F3: desatualizado se `agora − updatedAt > 7 dias` ou `calc` menor que o exigido. "Mês passado" fora de escopo; derivável de `epsAt` no futuro.
- **F4 Avaliações**: tipo `rated` derivado das avaliações do dono, com regras que aceitam `v` novo; o leitor desta fase ignora tipos desconhecidos.
- **F5 Comentários**: não depende deste documento.

---

## Decisões do Manager (aprovadas em 2026-10-10)

| # | Decisão | Opções | Escolha | Consequência | Status |
|---|---|---|---|---|---|
| D1 | O que conta como atividade | (a) 4 eventos sem agrupar; (b) 4 eventos agrupados e removidos ao desfazer; (c) incluir "recomendou" | **(b), derivado dos dados**: favoritou, assistiu filme, assistiu N episódios (agrupados enquanto nenhum outro título entra no meio), concluiu série; massa = 1; favoritar+assistir em ≤ 10 min = só assistir; **desmarcar 1 de N reduz o contador, desmarcar o único remove**; grupos se refundem quando o título do meio some; recomendar não é atividade; `rated` reservado à F4; guarda 10, mostra 3 | Lista sempre coerente com os dados, sem apagar nada à mão | **Aprovado pelo Manager em 2026-10-10** |
| D2 | Padrões de privacidade | (a) tudo desligado; (b) ligado para novos; (c) tudo ligado exceto recomendados | **(a)** opt-in por seção (promessa atual da política; LGPD art. 8º §4 e §5, art. 6º III, art. 46 §2º) | Perfis começam vazios; parecer jurídico não verificado | **Aprovado pelo Manager em 2026-10-10** |
| D3 | O que o snapshot guarda | (a) só o Perfil; (b) Perfil + mês/ano + séries assistidas + minutos/estimado/sem duração + "desde" + atualizado em | **(b)** + `undatedMovies/Episodes`, `datedFrom`, `tz`, `calc`; **"Recomendações" em `recs.count`**, fora de `stats` | F3 sem migração | **Aprovado pelo Manager em 2026-10-10** |
| D4 | Quando atualizar | (a) mesmo batch do favorito (texto do prompt); (b) escrita própria coalescida + recálculo | **(b)**: gatilho = cada mudança da lista (listener), W = 5 s (máx. 30 s), ao ocultar a página, recálculo ao abrir/sync/virada de mês, só se mudou, pulso de 24 h; **nunca no batch do favorito** | Amigo vê com segundos de atraso; nenhuma marcação pode ser desfeita pelo snapshot | **Aprovado pelo Manager em 2026-10-10** |
| D5 | Períodos e dados antigos | (a) contadores por período; (b) data por marcação daqui pra frente; (c) só desde que ligou | **(b)** `epsAt` no favorito, mesma escrita, hora do aparelho corrigida pelo desvio do servidor, só depois de constatadas as regras novas; histórico sem data só no Total, com nota | Campo privado novo para todos; regras antes do app e nunca voltam | **Aprovado pelo Manager em 2026-10-10** |
| D6 | Sem snapshot / registro de atividades | (a) só com interruptor; (b) gravar para todos | **(a)**: documento só com ≥ 1 seção; atividades publicadas só a partir de `actSince`; a data de marcação (D5) é guardada para todos, privada | 0 escritas extras para quem não liga | **Aprovado pelo Manager em 2026-10-10** |
| D7 | Recalcular e corrigir | (a) só a cada escrita; (b) + recálculo; (c) + botão | **(b)** + pulso de 24 h + "não regredir", sem botão; "Atualizado há X" sempre neutro (nunca alarme de desatualizado) | ≤ 1 escrita/dia extra | **Aprovado pelo Manager em 2026-10-10** |
| D8 | "Membro desde" | (a) sempre; (b) com Estatísticas; (c) não | **(b)** (`stats.memberSince`); cabeçalho sempre com apelido, foto e "Amigos desde" | Data da conta copiada só com opt-in | **Aprovado pelo Manager em 2026-10-10** |
| D9 | Recomendados | 20 / 50 / todos | **50**, ordem da aba, "e mais N"; número só com opt-in (`recs.count`) | Itens validados pelo app (D16) | **Aprovado pelo Manager em 2026-10-10** |
| D10 | Offline no perfil de amigo | (a) cache; (b) só cabeçalho | **(b)**, sem usar nem o cache de memória; interruptores exigem servidor (transação) | Sem consulta offline | **Aprovado pelo Manager em 2026-10-10** |
| D11 | Desativar/excluir | (a) só regras; (b) apagar | **(b)**, apagando antes **e depois** de fechar `social`; sem `exists(social)` na regra de leitura | Sem resíduo; sem chamada extra | **Aprovado pelo Manager em 2026-10-10** |
| D12 | Números falsos | (a) aceitar com limites; (b) validar no leitor | **(a)**, risco assinado no ADR-006: regras só checam forma, ≥ 0 nas métricas do ranking, formatos, hora do servidor, `tz`, listas ≤ 10/50, `at >= actSince`, seção ⇔ consentimento; **tetos e coerência no app** | Cliente modificado do dono pode mostrar números plausíveis falsos aos amigos dele | **Aprovado pelo Manager em 2026-10-10** |
| D13 | Estatísticas = ranking (F3) | (a) mesmo interruptor; (b) separado | **(a)**, texto do consentimento cita "comparações entre amigos" | Um consentimento só | **Aprovado pelo Manager em 2026-10-10** |
| D14 | Endereço do perfil | uid / handle / sem endereço | **`/friends/u/<uid>`** | Recarregar funciona; uid no histórico do navegador | **Aprovado pelo Manager em 2026-10-10** |
| D15 | Cache de perfil de amigo × revogação | (a) TTL 5 min em memória; (b) TTL 0 | **(a)**, "Atualizar" ignora TTL, offline sem conteúdo, `permission-denied` limpa, troca de conta limpa | Ex-amigo que reabre em ≤ 5 min revê o que já viu; cópia no cache persistente do SDK nunca exibida | **Aprovado pelo Manager em 2026-10-10** |
| D16 | Validação dos itens de lista | (a) regras validam forma; itens no app (limite de 1000 expressões, medido); (b) reduzir a ~10 recomendados | **(a)** | Cliente modificado do dono pode publicar texto arbitrário em títulos e inflar o documento até 1 MiB para os amigos dele; remédio: remover/bloquear | **Aprovado pelo Manager em 2026-10-10** |
| D17 | Leituras novas fora do perfil de amigo | (a) 1 leitura por sessão com amizades ativas + 1 sonda única por aparelho; (b) sem sonda | **(a)** | +≈ 300 leituras/dia na hipótese; protege as marcações se o app sair antes das regras | **Aprovado pelo Manager em 2026-10-10** |

Pontos menores também aprovados: **sem confirmação ao desligar** (ex-❓-1); **W = 5 s** (ex-❓-2); **nunca alarme de "desatualizado"** (ex-❓-3); **"mês passado" fora de escopo** (ex-❓-4). Não há ❓ em aberto.

## Respostas do Arquiteto às perguntas A1–A14
Respondidas em [docs/82 §16](./82-design-perfil-social.md) e incorporadas acima: A1 um documento `shared_profiles/{uid}` com `sharing`; A2 `epsAt` paralelo a `eps`; A3 recálculo completo, coalescido, só com dados do servidor; A4 gatilho no listener; A5 hora do aparelho corrigida + `tz` do dono; A6 minutos/estimado/sem duração com "não regredir"; A7 regras enxutas (tabela de tetos R × D); A8 sem `exists(social)`; A9 apagar antes e depois; A10 schema 3; A11 cache só de memória; A12 `/friends/u/:uid`; A13 sem índice composto (isenção opcional de `epsAt`); A14 cota abaixo.

## Cota (docs/82 §11; estimativa, não medida em produção)
| Ação | Leituras | Regra | Escritas | Deletes |
|---|---|---|---|---|
| Abrir perfil de amigo pela lista, a frio | 1 | 1 | 0 | 0 |
| Idem por endereço sem lista em cache | 2 | 1 | 0 | 0 |
| Reabrir no TTL / offline | 0 | 0 | 0 | 0 |
| Início de sessão com amizades ativas | 1 | 0 | 0 | 0 |
| Sonda sem amizades ativas | 1 por aparelho, uma vez | 0 | 0 | 0 |
| Ligar seção | 1 | 1 | 1 | 0 |
| Desligar seção | 1 | 1 | 1 (ou 0) | 0 (ou 1) |
| Marcação de quem compartilha | 0 | 0 | ≤ 1 por janela de 5 s | 0 |
| Marcação de quem não compartilha | 0 | 0 | 0 | 0 |
| Recálculo / pulso | 0 | 0 | 0–1 (pulso ≤ 1/dia) | 0 |
| Exportar | +1 | 0 | 0 | 0 |
| Excluir conta / desativar | 0 | 0 | 0 | 2 |
Hipótese (100 usuários sociais ativos/dia, 30% compartilham, 20 marcações/dia, 5 perfis abertos/dia, 3 sessões/dia): **≈ 1 300 leituras/dia (2,6%)** e **≈ 270 escritas/dia (1,4%)**; somado à Fase 1, ≈ 21% das leituras. F3: 2N leituras por abertura a frio.

## Rollout (docs/82 §12)
1. Manager exporta a própria conta e anota os números do Perfil.
2. **Regras da Fase 2** publicadas pela CLI **antes** do app; aditivas; **nunca voltar** (regras anteriores negariam marcações com `epsAt`).
3. Índices: isenção opcional de `epsAt`.
4. Política atualizada junto ou antes do app de cada fatia que muda o que é guardado ou compartilhado.
5. Merge/deploy do app por fatia. App antes das regras: sonda vê `permission-denied` ⇒ marcações sem data, interruptores "ainda não disponível", nada se perde.
Rollback: sempre do app; documento compartilhado e `epsAt` ficam e são ignorados pelo app antigo.

## Fatiamento (alinhado ao docs/82 §15)
0. **Fatia 0 — Regras + índices + testes** (gate: publicação pela CLI): regras de `shared_profiles` e `epsAt` em `validFavorite`; isenção de índice de `epsAt`; `shared_profile.test.mjs` (matriz de leitura, linhas R da tabela de tetos, aparelho atrasado, `validFavorite`); fixture `firestore.rules.v3`; `rules_budget` (1 chamada + folga de expressões); mutações do docs/83 §4 que se aplicam às regras; ADR-006 aceito. Nada de app.
1. **Fatia 1 — Fundação de dados (nada visível a amigos)**: `epsAt` (sonda, `ServerClock`, órfãs, Desfazer com datas), `FavoriteDoc.watchedAt` + mapper; `hasAiredAt` + relógio injetável; `SharedProfileBuilder`/`ActivityDeriver`/`periodKey`/validador + payloads + golden; `SharedProfileDataSource` (interface, Firestore, fake, inerte) com `deleteOwn`; `AccountDeleter`/`deactivate`/`finishCleanup`; exportação schema 3; política e `PrivacySummary` (data de marcação). Exclusão/exportação antes do primeiro dado compartilhado.
2. **Fatia 2 — Meu perfil "O que seus amigos veem" (Estatísticas e Atividades)**: estado do dono, interruptores por transação (consentimento, prévia, incerto, mensagens), motor `SharedProfileSync`, "Atualizado há", "Atividades recentes", nota de datas; política (compartilhamento).
3. **Fatia 3 — Perfil de amigo**: rota `/friends/u/:uid`, entrada pela lista, cabeçalho do par, leitura `Source.server` com TTL de memória, tabela RF-F5, Remover/Bloquear, layout/teclado/leitor.
4. **Fatia 4 — Recomendados**: interruptor e consentimento próprios, `recs` no builder/motor, lista 50 + "e mais N", número "Recomendações"; política (trecho de recomendações).
5. **Fechamento**: review e QA integrados, smoke com 2 contas (docs/83 §5), cota no console, README, checklist de release (modelo docs/80).

## Definition of Done (desta especificação)
- [ ] Todos os critérios de aceite verificáveis por teste (unit, widget, emulador de regras), conferido pelo QA após esta revisão.
- [ ] Nenhuma ❓ bloqueante em aberto (D1–D17 aprovadas em 2026-10-10; confirmar na revisão do QA).
- [ ] QA revisou os critérios revisados (B1–B8 e cenários que faltavam) e concordou que são testáveis.
- [ ] docs/82 e ADR-006 coerentes com esta especificação (conferência cruzada pelo Arquiteto).
