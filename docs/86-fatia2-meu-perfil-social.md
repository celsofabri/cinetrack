# 86 - Perfil social (Fase 2), Fatia 2: Meu perfil "O que seus amigos veem" (Estatísticas e Atividades)

> Autor: Dev (Backend + Frontend) · Data: 2026-10-11 · Branch: `feat/social-profile` (base 286a65b)
> Entradas: [docs/81](./81-especificacao-perfil-social.md) (RF-P, RF-S, RF-A, textos literais, estados de UI), [docs/82](./82-design-perfil-social.md) §6, §7.1, §9, §10, §15 item 2, [docs/83](./83-testabilidade-perfil-social.md) (B4, B5, §4 mutações), [docs/84](./84-fatia0-regras-perfil-social.md), [docs/85](./85-fatia1-fundacao-perfil-social.md) (decisões Q1/Q2), [ADR-006](./adr/adr-006-snapshot-perfil-social.md).
> **`firestore.rules` não foi alterado** (sha256 `6135322e…e612`, o publicado). Nenhuma mudança de regra foi necessária. Nada publicado: sem push, sem deploy.

## HANDOFF
De: Dev (Backend + Frontend) → Para: Code Reviewer e QA, depois Orquestrador
Demanda: Fase 2 (perfil social), Fatia 2: Meu perfil "O que seus amigos veem" (Estatísticas e Atividades)
Fluxo: feature | Etapa: Fatia 2
Prioridade: P1 (o primeiro dado compartilhado com amigos; a Fatia 3 lê o que esta grava)

### O que foi feito
**Dados (escrita do compartilhado)**
- `SharedProfileDataSource` ganhou `toggle(plan)` (transação: lê o próprio documento, `plan` monta a escrita a partir do que foi lido, aplica na mesma transação; nunca vai para a fila) e `writeSections(write)` (o `update` do motor, aguardado só pelo próprio motor; erros nunca vão para o banner dos favoritos).
  - `FirestoreSharedProfileDataSource.toggle`: timeout de 10 s = `uncertain`; `unavailable`/`deadline-exceeded`/`cancelled` **depois** de a escrita ter sido montada e aplicada = `uncertain`; **antes** (a leitura da transação falhou) = `offline` (nada foi enviado); `permission-denied` = `denied`; `resource-exhausted` = cota. Seams `txRunner`/`updater` para testar o mapeamento sem Firebase.
  - Fake `InMemorySharedProfileDataSource`: aplica set/update (caminhos com ponto, `deleteField`, `serverTimestamp` = relógio do fake)/delete como o servidor e um subconjunto das regras do docs/84 (update sem documento = `not-found`; seção sem consentimento = negado; mudar consentimento sem `social` = negado); falhas injetáveis por operação (`toggle`, `write`, `readOwn`), entrega posterior de toggle/escrita incertos, portões (`toggleGate`, `writeGate`, `readGate`), log `toggle`/`writeShared`, payloads aceitos.
- `SharedProfileRepository` + `SharedProfileFailure` (docs/82 §9): `readOwn` (servidor), `turnOn(section, content, now)` (seção já ligada = transação vazia), `turnOff(section)` (já desligada = transação vazia; última seção = apaga o documento), `recalc`, `pulse`. Executa só os payloads puros da Fatia 1 (`SharedProfilePayloads`, golden e replay nas regras já existentes: **nenhum payload novo**).
- `SharedProfileDoc` (leitura defensiva do documento: seção malformada = ausente; campo/tipo desconhecido ignorado) e `SharedSectionParsers` (stats/recs).

**Estado do dono e interruptores** (`SharingController`, `lib/providers/sharing_providers.dart`)
- Só existe com **amizades ativas** (`socialActiveProvider`); sem elas a seção não aparece e **nada é lido** (RF-P1).
- **1 leitura do servidor por sessão** do próprio documento. Ela é também a **sonda de regras** (decisão Q1 do docs/85): `ready` alimenta a **mesma** instância de `SharedRulesGate` (`feed`, novo), `permission-denied` = `oldRules`. O `sharedRulesGateProvider` deixou de sondar sozinho: espera o estado das amizades; com amizades ativas (confirmadas ou pela pista local) quem decide é a leitura de sessão; sem elas (ou conta não Google, ou falha ao carregar), a sonda dedicada de sempre. Quem já viu as regras no aparelho continua sem ler nada.
- Pista local por uid (`sharedHint:<uid>` no Hive, só nomes de seção): interruptores aparecem na hora, desabilitados com progresso, até a leitura confirmar; sem pista, esqueleto. Não confirmado e offline: desabilitados + "Sem conexão. Tente de novo quando estiver online.". Volta da conexão (fromCache true→false) relê se ainda não confirmou.
- **Ligar**: diálogo de consentimento com os **textos literais** do docs/81 e prévia (mesmo builder e mesmas entradas do motor; Estatísticas mostra a grade com os números do Perfil ao vivo, sem "Recomendações"); botão "Calculando…" desabilitado enquanto os dados não são confiáveis (mesmas condições do motor). "Compartilhar" = 1 transação; em seguida 1 leitura do servidor para ter `actSince`/`updatedAt` reais (se falhar, visão local do que foi gravado).
- **Desligar**: sem confirmação; transação que apaga consentimento + seção (+ `actSince`); a última apaga o documento; mensagem "Seus amigos não veem mais suas estatísticas." / "…suas atividades recentes.".
- **Incerto (B5)**: "Ainda não confirmado…" no interruptor (desabilitado, com progresso), relê o servidor na hora e a cada volta da conexão, sem fila; resultado real: ligar confirmado = ligado + "Compartilhamento ligado."; ligar que não aconteceu = desligado; desligar que não aconteceu = ligado + "Não foi possível desligar. Tente de novo."; desligar que aconteceu = mensagem normal. Enquanto incerto, outro toque = "Aguarde a operação anterior terminar.".
- Erros: offline (pré-checagem `syncStatus.offline` e leitura da transação) = interruptor não muda + "Sem conexão…"; `permission-denied` = relê o estado das amizades (desativadas noutro aparelho: a seção some) e mostra "O perfil compartilhado ainda não está disponível."; cota = mensagem de cota existente; uma operação por vez ("Aguarde a operação anterior terminar."). O motor **não** trava os interruptores.

**Motor `SharedProfileSync`** (Notifier iniciado pelo `AppShell`, recriado por uid)
- Gatilhos: listener de `favoriteDocsProvider` (nunca o repositório: nenhuma linha de `FavoritesRepository` mudou), confirmação do estado/seção ligada, fim do sync de catálogo/durações, virada de mês do dono e pulso (um timer de "acordar" até o que vier primeiro), ocultar/pausar a página (grava o que estiver pronto).
- Coalescência W = 5 s (debounce de borda final), máximo 30 s desde a primeira mudança pendente.
- Só grava com: favoritos confirmados pelo servidor na sessão, `fromCache == false` agora, sem escritas pendentes, catálogo ocioso (ou 60 s de espera), estado do compartilhado confirmado com ≥ 1 seção, `deleting != true`, exclusão de conta não rodando, nenhuma operação de amizades rodando (a desativação apaga o documento), mesmo uid. Condição que volta a valer = a janela normal e 1 escrita.
- `SharedSyncPolicy.decide` (puro): "só grava se mudou" (seção a seção, contra o último estado conhecido do servidor: lido na sessão ou o último gravado), "não regredir" (mesmas contagens, só tempo menos completo: não grava estatísticas), pulso de 24 h (só `updatedAt`). Mudança de `month.key`/`year.key` conta como mudança.
- Escrita: `update` próprio (`SharedProfilePayloads.recalc`/`pulse`), nunca `sharing`/`actSince`, nunca junto do favorito. A visão do dono é atualizada na hora (otimista). Falha: `permission-denied`/`not-found` = relê o documento (consentimento mudou noutro aparelho/regras); outras = volta à visão anterior, silêncio; no máximo 1 tentativa por gatilho, nunca laço, nunca banner.
- Exclusão (`deleting`/conta sendo excluída) e troca/saída de conta descartam o pendente (0 escritas).

**UI** (`lib/widgets/sharing_section.dart`, `lib/widgets/shared_profile_widgets.dart`, `lib/shared_profile/shared_profile_texts.dart`)
- Seção "O que seus amigos veem" no Perfil, depois de Amizades, **só com amizades ativas** (sem elas, mesma lista e ordem de hoje). Interruptores **Estatísticas** e **Atividades recentes** (Recomendados é da Fatia 4). Tudo desligado (D2): cartão discreto "Seus amigos veem só seu cartão (apelido e foto).".
- "Atualizado agora/há N min/há N h/há N dias", sempre neutro (nunca alarme). "Como seus amigos veem" (botão expansível, com estado `expanded` no leitor) abre a prévia lida do documento gravado: No total, Este mês, Este ano (no fuso do dono: mês que já passou = 0), tempo assistido, "No CineTrack desde", e a nota "Marcações feitas antes de DD/MM/AAAA contam só no total." / "Marcações anteriores a esta versão contam só no total." sob o mês/ano em que cai o corte (só o histórico sem data fica no Total).
- "Atividades recentes": 3 das até 10 guardadas, frase do RF-A8 + data relativa, toque abre `/movie/:id` ou `/tv/:id`; vazia = "Suas próximas atividades aparecem aqui.".
- Acessibilidade: interruptor anunciado "Compartilhar estatísticas com amigos" com estado ligado/desligado; ordem de Tab Estatísticas → Atividades recentes → Como seus amigos veem → cada atividade (teste); Esc fecha o diálogo; títulos longos com reticências e frase inteira no `Semantics`; diálogo inteiro rolável (320 px a 3×).

**Política (compartilhamento)**: `PrivacySummary` com a frase nova (teste literal: "Por padrão, quem vira seu amigo vê só o seu cartão (apelido e foto). Em "O que seus amigos veem", no perfil, você escolhe, por seção, …; para isso guardamos uma cópia só do que você ligou, e desligar apaga na hora."); `web/privacidade.html` (data 11/10/2026): linha nova na tabela, item "O que seus amigos veem" em Amizades, "Para que usamos" e "Como excluir". Lista vazia de Amigos: "Por padrão, quem é seu amigo vê só o seu cartão (apelido e foto).".

### Números
| Comando | Resultado |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` (2 rodadas, fuso da máquina) | **1773/1773** nas duas (antes: 1657; +116) |
| `TZ=UTC flutter test` | **1773/1773** |
| `flutter build web --base-href /cinetrack/` | ✓ Built build/web |
| `npm test` (regras) | **não rodado**: `firestore.rules`, fixtures e payloads (golden) inalterados (última rodada: 518/0/0, docs/85) |
| `python3 tool/dart_mutations.py` (lista completa, cópia em /tmp) | NUM_MUT |

Mutações Dart novas (docs/83 §4 desta fatia), `S1–S23`: coalescência desligada; snapshot no mesmo turno/escrita do favorito; grava com `fromCache`; atividade publicada com interruptor desligado; desligar só esconde; "só grava se mudou" removido; incerta tratada como falha; "não regredir" removido; pulso nunca enviado; virada de mês não acorda o motor; sem o máximo de 30 s; `unavailable` antes de enviar lido como incerto; timeout lido como offline; sonda dedicada mesmo com amizades (Q1); leitura de sessão não alimenta o portão; motor ignora `deleting`; pré-checagem offline do interruptor removida; dois interruptores ao mesmo tempo; sem reconciliação ao reconectar; pista local ignorada; "Compartilhar" habilitado antes dos dados confiáveis; motor não espera operação de amizades; escrita retida nunca retomada.
Não aplicáveis aqui: "cache servido após `permission-denied`/offline" (perfil de amigo, Fatia 3); "Recomendações sem opt-in" já existe (Fatia 1, G).

### Decisões tomadas (e por quem)
- Dev (sujeitas a review):
  1. "Cartão de convite discreto" (pedido da demanda, sem texto no docs/81/82) = o cartão do estado "tudo desligado" com o texto literal "Seus amigos veem só seu cartão (apelido e foto)." (sem botão extra: os interruptores logo acima são o convite).
  2. Depois de ligar, **1 leitura do servidor** para ter `actSince`/`updatedAt` do servidor (o motor precisa do `actSince` real: com uma estimativa local anterior ao do servidor a próxima atividade seria negada pela regra `at >= actSince`). Custo: +1 leitura por ligar (ação rara). Desligar não relê.
  3. Toggle `offline` × `uncertain`: decidido por "a escrita já foi aplicada na transação?" (antes = nada enviado = offline; depois = incerto). Timeout é sempre incerto.
  4. O motor pausa enquanto uma operação de amizades roda (a desativação apaga o documento) e retoma quando ela termina.
  5. Prévia "Como seus amigos veem" só existe com Estatísticas ligado (com só Atividades, a lista de atividades abaixo já é o que os amigos veem); recolhida por padrão.
  6. Os recortes Este mês/Este ano mostram também "Séries assistidas" (está no documento, RF-S1).
  7. `sharedRulesGateProvider`: não sonda mais por conta própria; decide pela fase das amizades (ver acima). Testes da Fatia 1 que dependiam da sonda automática continuam passando (conta sem amizades = sonda dedicada).

### Desvios do docs/82 (com justificativa)
- §11 "Ligar seção = 1 leitura": aqui são 2 (transação + releitura), decisão 2.
- §6 "Dois aparelhos: o segundo costuma achar 'igual' e não grava": sem listener no documento compartilhado (cota), cada aparelho compara com o **seu** último estado conhecido; dois aparelhos que mudam na mesma janela podem gravar **o mesmo conteúdo** uma vez cada (≤ 1 escrita extra, nunca divergente; teste "two devices"). Ler o documento antes de cada escrita custaria 1 leitura por escrita.
- §10 "Atualizado há X" não tem relógio próprio: o texto é recalculado a cada reconstrução da tela (abrir o Perfil, ligar/desligar, gravação do motor). Um timer por minuto foi evitado (timer pendente em testes e na aba em segundo plano).
- RF-P8 também bloqueia outro toque enquanto um interruptor está **incerto** (mesma mensagem "Aguarde…").

### Suposições (não verificadas)
- SDK web: `runTransaction` que estoura o timeout local ainda pode ser confirmado depois (por isso "incerto"); `unavailable` antes do commit não grava nada.
- `WidgetsBindingObserver` recebe `hidden`/`paused` ao trocar de aba/fechar no navegador (Flutter web documenta; não medido aqui). Sem isso, a escrita sai no fim da janela de 5 s se a página continuar viva.
- Emulador = produção nas regras (risco 10 do docs/82). Os payloads executados são os do golden já reproduzido contra as regras publicadas.

### Riscos / atenção
- **Primeiro dado compartilhado com amigos**: publicar a política (`web/privacidade.html`) junto com o app desta fatia (docs/82 §12 passo 4). Ninguém compartilha nada sem ligar (D2); quem não liga não tem nenhuma escrita nova.
- Ainda não há tela de amigo (Fatia 3): o que é gravado agora só é lido pelo próprio dono (prévia) até a Fatia 3 sair. Releases separadas são seguras (o documento já tem o formato final).
- Quem tem amizades ativas passa a ler 1 documento por sessão (já previsto em D17); a sonda dedicada some para essas contas.
- Rollback do app: o documento fica e a versão anterior não sabe desligar (docs/82 §12): o dono reinstala a nova ou desativa as amizades/exclui a conta nesta versão (checklist de release).
- Avisos (SnackBar) que chegam com o Perfil fechado (reconciliação de um incerto) não são mostrados depois; o estado do interruptor é sempre o real.

### Artefatos
- Código: `lib/providers/sharing_providers.dart`, `lib/repositories/shared_profile_repository.dart`, `lib/shared_profile/{shared_profile_doc,shared_sync_policy,shared_profile_texts}.dart`, `lib/widgets/{sharing_section,shared_profile_widgets}.dart`; alterados: `lib/data/{shared_profile_data_source,firestore_shared_profile_data_source,shared_rules_gate}.dart`, `lib/providers/{shared_profile_providers,social_providers}.dart`, `lib/services/local_store.dart`, `lib/shared_profile/shared_profile_models.dart`, `lib/screens/{profile_screen,friends_screen}.dart`, `lib/widgets/{app_shell,privacy_summary}.dart`, `web/privacidade.html`.
- Testes: `test/{shared_profile_sync,sharing_controller,sharing_section,shared_profile_texts_policy}_test.dart`, `test/support/sharing_rig.dart`, fake ampliado `test/support/fake_shared_profile_cloud.dart`; ajuste de altura da superfície em `test/export_data_section_test.dart` (o resumo de privacidade cresceu); `tool/dart_mutations.py` (`S1–S23`).

### Critério de aceite deste handoff
- Code Review e QA aprovados; `flutter analyze` limpo; `flutter test` e a suíte Dart de mutações verdes no ambiente do revisor. Depois, merge e publicação do app **junto com a política**.
