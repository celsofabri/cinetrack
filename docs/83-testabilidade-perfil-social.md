# Testabilidade da especificação: Perfil social (Fase 2)

> QA Engineer (shift-left) · 10/10/2026 · Entrada: [docs/81](./81-especificacao-perfil-social.md). Somente leitura; nenhum teste rodado. Registrado pelo Orquestrador a partir do parecer do QA.

## Veredito: testável após ajustes

8 ajustes bloqueantes (B1–B8) e ~20 ajustes menores. O DoD do docs/81 ("[x] Critérios de aceite verificáveis por teste", linha 578) deve voltar a "[ ]" até os ajustes entrarem. Ordem recomendada: fechar B1–B8, A1, A5 e A10 no docs/82/ADR-006 antes da Fatia 0. A tabela de tetos e a tabela de transições de atividades são os oráculos dos testes.

## 1. Bloqueantes

| # | Critério | Problema | Reescrita sugerida |
|---|---|---|---|
| B1 | RF-S2, "Fuso/virada de mês", "Snapshot de um mês que já passou" | O leitor não sabe o fuso do dono; perto da virada amigos veem valores diferentes (a F3 compara amigos). `EpisodeCache.hasAired` (lib/models/episode_cache.dart:38) usa `DateTime.now()` sem relógio injetável. | Snapshot guarda `periodMonth: "AAAA-MM"` e `periodYear: "AAAA"` no fuso local do dono no cálculo. Leitor mostra "este mês" = valor gravado se `periodMonth` = mês atual no fuso do leitor, senão 0 (ano igual); divergência ≤ 1 dia aceita, ou guardar offset do dono (Arquiteto decide). Função pura `periodKey(DateTime local)`. Relógio injetável (`sharedProfileClockProvider`) no cálculo, atividades e `hasAired`. Cenários com datas absolutas (ex.: "hoje é 15/10/2026 12:00 America/Sao_Paulo"). |
| B2 | RF-S3, "Marcações antigas contam só no total" | Data de corte depende da A5; "nos primeiros tempos" não é verificável. | Definir a data de corte (ex.: primeira gravação com data de marcação no aparelho, ou data em que ligou "Estatísticas"). Nota aparece em "este mês" se o corte cai no mês atual, em "este ano" se no ano atual. Filmes: `watchedMovie` com `lastWatchedAt` = 02/10/2026 conta em outubro; sem `lastWatchedAt`, só no Total. |
| B3 | RF-S1 | Sem definição de "concluída/assistida/tempo no período": teste sem oráculo. | Conclusão = maior data de marcação entre os episódios exibidos, se todos marcados; se o episódio que concluiu não tem data, só Total. Série assistida no período = ≥ 1 marcação com data no período. Tempo no período = soma das durações dos itens com data no período (regra estimado/sem duração do `WatchTimeCalculator`). Data órfã só conta se `eps` tem a chave. Remarcar substitui a data. |
| B4 | "Marcar episódio atualiza…", "Série deixa de estar concluída", "Maratona", ❓-2 | "Em poucos segundos", "grava uma vez só", "seguidos" não são observáveis. | Janela de coalescência W numérica (no ADR-006). "Após W s da última marcação (relógio falso), exatamente 1 escrita"; "N marcações dentro de W = 1 escrita"; "recálculo sem mudança = 0 escritas"; "seguidos" = enquanto a atividade da série for a mais recente, sem limite de tempo (explícito). |
| B5 | RF-P4, RF-P6, "Ligar ou desligar sem conexão" | Conexão cai entre a checagem online e a confirmação: a escrita fica na fila e publica depois, mas a pessoa viu "falhou" (publicação sem consentimento percebido). A Fase 1 já tem `SocialFailureKind.uncertain`. | Cenário "Conexão cai durante o ligar": interruptor mostra "Ainda não confirmado…"; ao voltar a conexão o app confere o servidor; se publicou, fica ligado com aviso (ou apaga automaticamente — decidir). Desligar com timeout: mesmo tratamento. |
| B6 | RF-F6 x "Amizade desfeita com a tela aberta", D10, estado "indisponível" | Reabrir dentro de 5 min serve cache ao ex-amigo; cenário diz "na próxima atualização", tabela diz "na hora"; offline com cache de memória indefinido. | "Atualizar"/"Tentar novamente" ignoram TTL. Reabrir no TTL mostra cache (risco aceito ≤ 5 min, escrito). Offline nunca mostra conteúdo, nem de memória. "Indisponível" apaga o cache do uid e tira o amigo da lista em cache na hora. Sair/trocar de conta limpa todo o cache de perfis (como `account_isolation_test`). |
| B7 | RF-F2, RF-F5, A1, A8 | O teste precisa saber como cada caso aparece na leitura (depende da A1): documento inexistente com leitura permitida → "não compartilha"; `permission-denied` → "indisponível". Exclusão interrompida após apagar conteúdo e antes de varrer pares: sem A8, Carla vê "ainda não compartilha nada". | Tabela "resposta do servidor → estado da tela" (`not-found`, `permission-denied`, `unavailable`, `resource-exhausted`, `fromCache`, `timeout`) e decisão explícita sobre o caso da exclusão interrompida. |
| B8 | RF-A3, RF-A4, "Marcar a série inteira", "Desmarcar remove" | Indefinido: desmarcar 1 de 4 agrupados (contador 3 ou remove?); "até T2E4" fora de ordem (último marcado ou maior episódio?); Desfazer de `completed_series` que substituiu `watched_episodes`; massa quando a mais recente já é da mesma série. | Tabela de transições (estado da lista + evento → nova lista), testada 1:1 por teste unitário parametrizado. |

## 2. Ajustes nos demais critérios

| Critério | Problema | Reescrita |
|---|---|---|
| Usuário atual vê tudo desligado | "Mesmos números de antes" sem oráculo | `ProfileStats` igual ao golden da `main` para a mesma fixture de 54 favoritos |
| Usuário sem amizades ativas | "Perfil igual" e "nenhuma leitura" vagos | Mesma lista e ordem de seções; log de operações do fake idêntico ao baseline. "Amizades ativas" = recurso ligado, não "≥ 1 amigo" (R13 mistura) |
| Ligar "Estatísticas" | Texto do diálogo não fixado; D13 muda o texto | Texto pt-BR exato (comparação literal). Payload sem Recomendações se Recomendados desligado. Faixas de "Atualizado agora/há X min/h/dias" |
| Métrica "Meu perfil sem nenhuma leitura nova" | Contradiz a cota (prévia lê 1) | 0 leituras novas sem interruptor; 1 (prévia) com algum ligado |
| Desligar apaga na hora | Depende da A1 | Documento/seção não existe no emulador após a operação; leitura do amigo = "não compartilha" |
| Duas ações seguidas | RF-P7 travaria interruptores durante o recálculo automático | Recálculo em segundo plano não desabilita os interruptores (fila); caso de tocar 2× no mesmo |
| Marcar episódio atualiza | Texto contradiz RF-A3 se já há atividade da série | Pré-condição "a mais recente não é da Série X"; textos fixos para 1 e N episódios |
| Falha nunca desfaz a marcação | O que o dono vê? Risco de laço (cota, R10) | Falha silenciosa; nova tentativa só no próximo gatilho; 10 falhas = no máximo 10 tentativas ligadas a gatilhos |
| Desmarcar em mês anterior | Falta ano/virada de ano | Datas absolutas; marcado 12/2026, desmarcado 01/2027: mês/ano atuais não mudam |
| Snapshot de mês passado | Falta virada de ano; "só grava se mudou" ignora troca de chave | Dezembro→janeiro (ano = 0); mudança de `periodMonth` conta como mudança |
| Aparelho novo não publica zeros | "Enquanto" fora do Gherkin; catálogo baixando indefinido | "Dado `fromCache=true`, quando o recálculo dispara, então 0 escritas"; decidir se espera o sync de catálogo antes da primeira gravação da sessão (RF-S5 aceita minutos parciais e regride o snapshot, R3) |
| App antigo marcando | Não automatizável com app antigo | Favoritos mudam no servidor por outro cliente (escrita direta no fake/emulador); ao abrir, recalcula e grava 1 vez |
| Números impossíveis | Tetos, formatos e margem de data não fixados | Tabela no ADR-006: campo, tipo, mín/máx, formato de chave, tamanho de listas, margem `date ≤ request.time + X`; cada linha vira teste de emulador e mutação |
| O que conta como atividade | 5 casos num cenário | Esquema do Cenário com exemplos |
| Tipo desconhecido | Falta documento malformado/campo ausente | Item com campo faltando ou tipo errado é ignorado; os demais aparecem |
| Recomendados só com opt-in | Faltam 50/51, ordem, onde aparece o número | Ordem = `FavoriteItem.byRecentActivity` (reescreve a lista a cada marcação); 50 sem "e mais", 51 com "e mais 1"; número na seção Recomendados |
| Abrir perfil pela lista | "Imediatamente" e "2 leituras cobradas" não mensuráveis | Cabeçalho visível com leitura pendente (Completer); 1 get no contador do fake e regra ≤ 1 chamada (rules_budget); cobrança real no smoke; TTL 4:59 sem leitura, 5:00 com leitura |
| Não amigo pelo endereço | Falta uid malformado | uid inválido/longo/especial: mesma mensagem, nenhuma leitura |
| Exclusão / desativação | Faltam pendentes | Escrita coalescida pendente quando `markDeleting` acontece → 0 escritas; desativação interrompida → conteúdo já apagado, "Concluir limpeza" termina |
| Exportar | "Conforme A10" | Fechar A10 antes da Fatia 1; data por marcação aparece nos favoritos exportados |
| Larguras e fonte | "Texto cortado" não detectável | Sem exceção de overflow; reticências e texto completo no Semantics; fonte 1x, 2x e 3x |
| Teclado e leitor | "Ordem lógica" vaga | Ordem exata dos focos; rótulos Semantics testáveis; leitor real no smoke |

## 3. Cenários que faltam

- Interruptores ao abrir: carregando; offline/estado do cache; coerência entre 2 aparelhos após ligar num deles.
- Dois aparelhos marcando ao mesmo tempo: vence a última escrita; o recálculo ao abrir corrige (2 repositórios sobre o mesmo fake).
- Erros só presentes na tabela de estados: cota no perfil de amigo; cota ao ligar; amizades próprias desativadas abrindo `/friends/u/<uid>`; sessão expirada/troca de conta com escrita pendente (nada gravado sob outro uid).
- Remover/Bloquear pelo perfil: offline ou com erro (desabilitado ou mensagem, como na Fase 1).
- Relógio adiantado: data futura limitada no cliente e negada pela regra além da margem.
- Título sem pôster ou removido do TMDB; título com 300 caracteres.
- Amigo com schema mais novo/antigo: campo ausente aparece "—", nunca 0.
- Regras: amigo não escreve no documento do dono; `list` negado; anônimo e não-Google negados; dono com `deleting == true` (se a A9 levar à regra); resíduo `isFriend` sem `social` (A8).
- `validFavorite` com a data nova: com e sem o campo; tipo errado; tamanho com 5000 episódios (A2); payload antigo aceito.
- Política: texto e data novos em `PrivacySummary`, teste de widget literal.

## 4. Estratégia de testes

**Unitário puro (maioria, tabelas de exemplos de B1–B4, B8):** `periodKey`; `SharedStatsCalculator` (Total/mês/ano, concluídas, séries assistidas, minutos/estimado/sem duração, datas órfãs); redutor de atividades (tabela de transições); limitador de faixas; validador Dart = regras; parser tolerante; coalescedor com `fake_async`; cache com TTL e limpeza na troca de conta.

**Repositório/controllers com fakes, por log de operações:** "nunca no mesmo batch do favorito"; "0 escritas/leituras para quem não liga"; ordem da exclusão (conteúdo antes das varreduras); B5 (incerta).

**Widget:** Meu perfil (seção, diálogos, estados, prévia); perfil de amigo (todos os estados da tabela B7); matriz 320/375/768/1024/1440 × 1x/2x/3x × claro/escuro; teclado e Semantics.

**Emulador (Fatia 0):** `shared_profile.test.mjs` com matriz de leitura (dono, amigo, estranho, ex-amigo, bloqueado nos 2 sentidos, anônimo, não-Google) e schema linha a linha da tabela de tetos; revogação imediata; `social_compat` ampliado com fixture `firestore.rules.v3` = regras atuais da `main` (app novo × v3 nega sem efeito colateral; payloads antigos × regras novas); `rules_budget` (leitura ≤ 1 chamada); golden `shared_profile_payloads.json` gerado pelo Dart e reproduzido contra as regras.

**Fakes novos/ampliados:** `InMemorySharedProfileDataSource`/`FakeSharedProfileCloud` (log de operações, contador de leituras, falhas injetáveis `permission-denied`/`unavailable`/`resource-exhausted`/timeout com entrega posterior/`fromCache`, modo "regras antigas"); `FakeCloud` de favoritos com data de marcação e escrita "de outro cliente"; relógio injetável único (inclusive `hasAired`); fake de conectividade; `FriendsHarness` com a rota do perfil de amigo.

**Mutações (todas devem morrer):**
- Regras: leitura sem `isFriend`; `||` abrindo permissão; `hasOnly` removido; limite de lista 10/50 removido; `updatedAt == request.time` removido; amigo pode apagar/escrever; `validFavorite` aceita data não-timestamp.
- Payload: campo extra; número negativo; 11 atividades.
- Dart (validador, por D12/D16 os tetos e a margem de data ficam no app): teto removido; margem de data removida; itens de lista fora do schema aceitos.
- Dart: snapshot no mesmo batch do favorito; grava com `fromCache`; "Recomendações" sem opt-in; atividade registrada com interruptor desligado; desligar só esconde; cache servido após `permission-denied`/offline; passo da exclusão depois das varreduras; exportação omite; tipo desconhecido lança; coalescência desligada; período em UTC; "só grava se mudou" removido; "incerta" tratada como falha.

> Nota do Orquestrador (2026-10-10, pós-gate): o B1 foi resolvido pelo design aprovado com o **fuso do dono** (campo `tz` no snapshot), não do leitor; o docs/81 segue o design. Os testes de período usam o `tz` do dono como oráculo.

## 5. Smoke manual (Manager, 2 contas Google)

Riscos herdados da Fase 1: SDK real nunca rodou contra o emulador; cobrança real de leituras não verificada. Cobrir: ordem do rollout (política e regras antes do app); leitura `Source.server` e offline real (D10, sem cache persistente); leituras cobradas no console (≤ 2 a frio, 0 no TTL); gravação ao ocultar/fechar a aba; conexão cai durante o ligar (B5); dois aparelhos; virada de mês (opcional, mudando o fuso do sistema); leitor de tela real (VoiceOver/NVDA) e navegador real nas larguras; exportação antes/depois com números do Perfil iguais; exclusão da conta B e a visão de A.
