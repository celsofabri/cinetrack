# 95 - Simplificação do compartilhamento: um interruptor só (Fase 3, Fatia S)

> Autores: Product Analyst + Arquiteto (adendo) · Data: 2026-10-24 · Branch: `feat/social-ranking` (base `main` 9389bc5)
> Entrada: decisão do Manager de 2026-10-24, depois do smoke da Fase 2 ("funcional, mas… uma vez que um usuário ativa seu nome na busca, ele já deveria permitir todas as suas infos, e não ter que ativar mais nada"). Contexto: [docs/81](./81-especificacao-perfil-social.md)/[docs/82](./82-design-perfil-social.md) (perfil social, consentimento por seção, D2/D13), [docs/84](./84-fatia0-regras-perfil-social.md) (orçamento de expressões), [docs/86](./86-fatia2-meu-perfil-social.md) (interruptores, "incerto", B5), [docs/90](./90-especificacao-ranking.md)/[docs/91](./91-design-ranking.md) (ranking, D9).
> **Este documento só especifica.** Nenhum código ou regra foi alterado. Afirmações sobre o código foram conferidas em `feat/social-ranking`; números de orçamento de regras vêm do `rules_budget.test.mjs` atual e **não** foram remedidos para a escrita nova (é a primeira tarefa da fatia, S0).
> Legenda: **RF-S1…** requisito desta fatia (prefixo `RF-SC` para não colidir com o RF-S da F2), **E** estado, ❓ pergunta ao Manager.

## 1. Decisão do Manager (2026-10-24)
1. **Um interruptor só**: "Aparecer na busca".
   - **Ligado** = a pessoa aparece na busca **e** compartilha com amigos mútuos Estatísticas + Atividades recentes + Recomendados, com **um** diálogo de consentimento.
   - **Desligado** = não aparece na busca e não compartilha nada. O documento `shared_profiles/{uid}` é apagado, como hoje quando se desliga a última seção.
   - Os três interruptores por seção saem da interface.
2. **Quem já está com "Aparecer na busca" ligado** recebe, na próxima abertura, um aviso de uma vez explicando que os amigos passam a ver estatísticas, atividades e recomendados, com "OK" e "Desligar". **Nada** novo é compartilhado antes do OK (LGPD: a política atual promete consentimento).
3. Quem está com a busca desligada e tem amigos (por convite) não compartilha nada.
4. Entra como a **primeira fatia da Fase 3 (Fatia S)**, na `feat/social-ranking`. A D9 do ranking ("eu não compartilho") passa a corresponder a esse interruptor.

## 2. Situação atual (código em `feat/social-ranking`)
- "Aparecer na busca" = `discoverable` no cartão `handles/{handle}`. Escrito por `SocialController.setDiscoverable` com `SocialPayloads.updateCard` (transação; `social_payloads.dart:180`). O formulário de ativação tem o mesmo interruptor, com padrão `kDiscoverableByDefault = true` (`social_models.dart:191`).
- Compartilhamento = `shared_profiles/{uid}` com o mapa `sharing` (`stats`/`activity`/`recs`). Ele é escrito pelo `SharingController.turnOn/turnOff`, uma seção por vez, com um diálogo por seção (`kSharingDialogs`, `sharing_section.dart:13`).
  - Desligar a última seção apaga o documento.
  - O controller já trata: estado "incerto" (B5), uma ação por vez, leitura de sessão, releitura na reconexão, pista local `sharedHint`, recusa do motor ⇒ releitura.
- Regras: o `create` aceita 1 a 3 seções numa escrita só (`validShared`, `sharedSectionsOk`), exige `exists(social/{uid})` (amizades ativas). `actSince == request.time` quando entra `activity`. Itens de atividade precisam ter `at >= actSince`.
- Orçamento (`rules_budget.test.mjs`, docs/84): o pior documento **legal** (create com 3 seções, 10 atividades, 50 recomendados) ocupa ≈ 65%, com teste travado em ≤ 70%; a pior escrita **do app** hoje (mudança de consentimento + 3 seções mudando) ocupa ≈ 64%, com teste travado em ≤ 65%.

## 3. Escopo
- Inclui:
  - interruptor único;
  - diálogo de consentimento único (com a prévia "Como seus amigos veem");
  - confirmação ao desligar;
  - aviso de uma vez para quem já está com a busca ligada (e para o caso legado do ❓1);
  - estado "falta confirmar" no Perfil;
  - formulário de ativação;
  - remoção dos interruptores por seção;
  - política e `PrivacySummary`;
  - textos da D9 do ranking;
  - testes de regra sem mudar regras (orçamento da escrita nova);
  - testes e mutações.
- Não inclui:
  - mudança de schema ou de regras (se o S0 provar que não cabe, volta ao Arquiteto antes de qualquer app);
  - compartilhamento parcial escolhido pelo usuário;
  - mudança em "Mostrar minha foto", convite, pedidos, bloqueios, exportação, exclusão de conta ou desativação de amizades (todos continuam como estão);
  - mudança no motor de recálculo (`SharedProfileSync`), que já trabalha só com as seções presentes no documento.

## 4. Estados (derivados; nenhum campo novo persistido)
Entradas: `D` = `discoverable` do cartão (estado do `SocialController`); `S` = seções do documento confirmado nesta sessão (`SharingState.doc?.sharing`): `∅`, parcial ou as 3.
| Estado | D | S | O que o Perfil mostra | Aviso |
|---|---|---|---|---|
| **E0 Desligado** | não | ∅ | interruptor desligado | — |
| **E1 Ligado** | sim | as 3 | interruptor ligado | — |
| **E2 Ligado, falta confirmar** | sim | ∅ ou parcial | interruptor ligado + "Falta você confirmar o que seus amigos veem." + botão "Revisar" | aviso **A** (1× por sessão) |
| **E3 Legado: busca desligada com seções** | não | parcial ou as 3 | interruptor desligado + "Você ainda compartilha: <seções>." + botões (❓1) | aviso **B** (❓1) |
| **Ep Pendente** | — | estado não confirmado (sessão sem leitura, offline) | interruptor pela pista, desabilitado | nenhum aviso |
| **Ei Incerto** | — | operação com resultado desconhecido | "Ainda não confirmado…" (texto existente), interruptor desabilitado | nenhum |
- O consentimento novo fica registrado pelo próprio documento: **as 3 seções presentes** = consentiu no modelo novo. Não há flag "aviso visto" no servidor. A condição do aviso some quando a pessoa escolhe (OK ⇒ E1; Desligar ⇒ E0), em qualquer aparelho.
- "Visto nesta sessão" é só memória (por uid), para não reabrir o aviso na mesma sessão depois de fechado sem escolha.
- Sem amizades ativas: nada disso existe (como hoje; só o cartão não existe).

## 5. Requisitos funcionais
- **RF-SC1 Interruptor único.** Em Perfil → Amizades, "Aparecer na busca" é o único controle de compartilhamento.
  - A seção "O que seus amigos veem" perde os três interruptores e continua com: a prévia "Como seus amigos veem", "Atualizado há", "Atividades recentes" e o texto de estado (T, §7).
  - Leitores de tela anunciam o interruptor como "Aparecer na busca e compartilhar com amigos".
- **RF-SC2 Ligar (E0 → E1).** Tocar no interruptor abre o diálogo de consentimento (T-C) com a prévia das 3 seções.
  - Enquanto a prévia não está pronta (`sharedPreviewProvider` nulo), o botão "Ligar" fica desabilitado com "Calculando…", como hoje.
  - "Ligar" executa **uma** transação: cartão `discoverable = true` + `shared_profiles` com as 3 seções (`actSince = request.time`, `activity = []`, `stats` e `recs` da prévia).
  - "Cancelar", Esc ou tocar fora ⇒ nada é escrito.
- **RF-SC3 Desligar (E1/E2/E3 → E0).** Tocar no interruptor ligado abre a confirmação (T-D). "Desligar" executa **uma** transação: cartão `discoverable = false` + `delete` de `shared_profiles/{uid}`. Amizades, pedidos, convite e dados da pessoa não mudam.
- **RF-SC4 Aviso A (E2).** Na primeira vez na sessão em que o estado confirmado é E2, online, com o shell visível, abre o aviso A (T-A) com a prévia.
  - Se a pessoa já compartilha alguma seção, o aviso diz quais.
  - "OK" executa uma transação que **acrescenta as seções que faltam** sem tocar nas que existem: `stats`, `recs` e, se ainda não existir, `activity` com `actSince` novo. Uma `activity` que já existe mantém `actSince` e itens.
  - "Desligar" ⇒ RF-SC3, **sem** a confirmação T-D (o aviso já explica).
  - Fechar sem escolher (Esc, voltar) ⇒ nada muda; o Perfil mostra E2 com "Revisar", e o aviso volta na próxima sessão.
  - **Nenhuma escrita** acontece antes do OK.
- **RF-SC5 Formulário de ativação.** O interruptor "Aparecer na busca" do formulário mantém o padrão `kDiscoverableByDefault`, mas o rótulo e o texto mudam (T-F).
  - Com ele ligado, "Ativar" abre primeiro o diálogo T-C: consentimento explícito, nunca uma caixa pré-marcada.
    - "Ligar" ⇒ a transação de ativação cria o cartão com `discoverable = false` e, em seguida, roda a transação de RF-SC2.
    - "Agora não" ⇒ ativa com a busca desligada (E0).
  - Se a 2ª transação falhar, a pessoa fica em E0 (consistente) com o SnackBar T-F2.
  - Motivo da ordem: a regra de `shared_profiles` exige `exists(social/{uid})`, que numa mesma transação enxerga o estado **anterior**, então criar o documento junto com a ativação seria negado.
- **RF-SC6 Offline / não confirmado / incerto.** Reaproveita a máquina da Fatia 2 (`blockReason`, `uncertain`, `_settling`, `_afterSettle`, releitura na reconexão, nova tentativa única em 30 s).
  - Sem confirmação ou offline: interruptor e botões do aviso desabilitados; tentar ⇒ mensagem offline existente.
  - Resultado incerto: interruptor desabilitado com "Ainda não confirmado…" até uma leitura **posterior** ao fim da transação. Essa leitura decide E0/E1/E2 e dá o aviso correspondente: ligou ⇒ T-S1; não ligou ⇒ "Não foi possível ligar. Tente de novo."; desligou ⇒ T-S2; não desligou ⇒ `kSharingOffFailed`.
  - Uma operação por vez (vale para o interruptor, o aviso e o formulário).
- **RF-SC7 Dois aparelhos.** As transações são idempotentes e leem o documento dentro da transação:
  - "Ligar" ou "OK" com as 3 seções já presentes não regrava o compartilhamento (só o cartão, se preciso);
  - "Desligar" com o documento já apagado só grava o cartão.
  - O aparelho desatualizado se corrige na releitura de reconexão ou de sessão (RF-P10 da F2).
  - Um recálculo do motor recusado (`not-found`/`permission-denied`, porque o outro aparelho desligou) ⇒ `reloadAfterRefusal` (já existe).
  - Um aviso A aberto num aparelho depois de o outro ter escolhido: o botão executa a transação idempotente e o estado final é o do servidor.
- **RF-SC8 Quem não compartilha.** E0 com amigos (por convite) não compartilha nada; o perfil de amigo da F2 mostra "<Nome> ainda não compartilha nada além do cartão." (texto existente).
- **RF-SC9 Ranking (D9).** "Eu participo" continua sendo `doc.stats != null` (o que os amigos veem). A faixa RF-E10 do docs/90 ganha duas variantes (T-R): busca desligada (E0/E3 sem stats) ⇒ botão leva a `/profile`; E2 ⇒ botão "Revisar" abre o aviso A.
- **RF-SC10 Política e resumo.** `web/privacidade.html` (data nova) e `kPrivacySharingSentence` (T-P) descrevem o modelo novo. **Publicação da política antes ou junto do app.**

## 6. Migração dos documentos existentes
Nada é migrado por script nem apagado sem ação da pessoa. A decisão é tomada na próxima sessão, no aparelho:
| Situação hoje (Fase 2) | Estado | O que acontece |
|---|---|---|
| busca ligada, nada compartilhado | E2 (S = ∅) | aviso A; OK cria o documento com as 3 seções |
| busca ligada, 1 ou 2 seções (ex.: só Estatísticas) | E2 (parcial) | aviso A com "Hoje você já compartilha: Estatísticas."; OK acrescenta as que faltam (as existentes intactas); Desligar apaga tudo (o texto diz) |
| busca ligada, as 3 seções | E1 | nada (já consentiu com tudo, uma a uma) |
| busca desligada, nada compartilhado | E0 | nada |
| busca desligada, alguma seção ligada | E3 | ❓1 (recomendação: aviso B; manter o que a pessoa já compartilha até ela escolher) |
| sem amizades ativas | — | nada |
- Quem já tinha ligado alguma seção consentiu com **aquela** seção, não com as outras. Por isso o aviso A aparece mesmo nesse caso, antes de acrescentar qualquer coisa (recomendação do coordenador, acolhida).
- Até a escolha, o motor continua recalculando só as seções presentes no documento (comportamento atual): o que a pessoa já compartilhava segue atualizado e nada novo é escrito.

## 7. Textos literais
**T-I Interruptor** (Perfil → Amizades):
- Título: "Aparecer na busca"
- Subtítulo: "Ligado: quem digitar seu identificador exato encontra você, e seus amigos mútuos veem suas estatísticas, atividades recentes e recomendados. Desligado: só quem você aceitar ou convidar vira seu amigo, e seus amigos veem só seu cartão (apelido e foto)."
- Semantics: "Aparecer na busca e compartilhar com amigos"
- E2: "Falta você confirmar o que seus amigos veem." + botão "Revisar"
- E3: "Você ainda compartilha: Estatísticas." (lista na ordem Estatísticas, Atividades recentes, Recomendados, separada por vírgula e "e") — botões no ❓1

**T-C Diálogo de consentimento** (ligar, formulário de ativação):
- Título: "Aparecer na busca e compartilhar com amigos?"
- Corpo: "Quem digitar seu identificador exato vai encontrar seu cartão (apelido e foto). E seus amigos mútuos vão ver, no seu perfil e no Ranking:"
- Itens:
  - "Estatísticas: seus números (favoritos, filmes e episódios assistidos, séries assistidas e concluídas e tempo assistido), os totais deste mês e deste ano e desde quando você está no CineTrack."
  - "Atividades recentes: até 10 das suas atividades mais recentes (títulos que você favoritou, filmes e episódios que marcou como assistidos e séries que concluiu), só a partir de agora."
  - "Recomendados: os títulos que você marcou com Recomendo (até 50, na ordem da sua aba) e quantos são."
- Fecho: "Recomendações nunca aparecem como atividade e seu e-mail nunca é mostrado. Você pode desligar quando quiser: desligar tira você da busca e apaga na hora o que seus amigos viam."
- Prévia: "Como seus amigos veem" (a mesma da F2, com as 3 seções)
- Botões: "Cancelar" (no formulário: "Agora não") / "Ligar" (desabilitado com "Calculando…" enquanto a prévia não está pronta)

**T-D Confirmação ao desligar**:
- Título: "Desligar "Aparecer na busca"?"
- Corpo: "Você sai da busca e seus amigos passam a ver só seu cartão (apelido e foto). O que eles viam (estatísticas, atividades recentes e recomendados) é apagado agora; se você ligar de novo, as atividades recomeçam do zero. Seus amigos continuam seus amigos e seus dados no CineTrack não mudam."
- Botões: "Cancelar" / "Desligar"

**T-S SnackBars**:
- T-S1 (ligou): "Pronto: você aparece na busca e seus amigos veem suas estatísticas, atividades e recomendados."
- T-S2 (desligou): "Você não aparece mais na busca e seus amigos veem só seu cartão."
- T-S3 (não ligou): "Não foi possível ligar. Tente de novo."
- Não desligou: `kSharingOffFailed` = "Não foi possível desligar. Tente de novo." (existente)
- Offline, ocupado e regras indisponíveis: os textos existentes de `SharedProfileFailure`

**T-A Aviso de uma vez** (E2):
- Título: "Novidade: seus amigos veem mais de você"
- Corpo: "Agora "Aparecer na busca" também mostra aos seus amigos mútuos, no seu perfil e no Ranking, suas estatísticas, suas atividades recentes (só a partir de agora) e seus recomendados. Nada disso é compartilhado antes de você tocar em OK."
- Se já compartilha algo, acrescentar: "Hoje você já compartilha: Estatísticas."
- Fecho: "Se preferir, desligue: você sai da busca e seus amigos veem só seu cartão." Se já compartilha algo: "…só seu cartão, e o que você já compartilha é apagado."
- Prévia: "Como seus amigos veem"
- Botões: "Desligar" / "OK" (OK desabilitado com "Calculando…" enquanto a prévia não está pronta)

**T-B Aviso legado** (E3; só se o ❓1 seguir a recomendação):
- Título: "Mudou a forma de compartilhar com amigos"
- Corpo: "Agora o que seus amigos veem fica ligado junto com "Aparecer na busca". Hoje você não aparece na busca, mas compartilha: Estatísticas. Escolha como prefere continuar."
- Botões: "Parar de compartilhar" (⇒ RF-SC3) / "Aparecer na busca e compartilhar tudo" (⇒ T-C)

**T-F Formulário de ativação**:
- Interruptor: "Aparecer na busca"
- Subtítulo: "Quem digitar seu identificador exato vê seu apelido e foto, e seus amigos mútuos veem suas estatísticas, atividades recentes e recomendados. Você confirma no próximo passo."
- T-F2 (2ª transação falhou): "Amizades ativadas, mas não foi possível ligar "Aparecer na busca". Tente de novo no Perfil."

**T-V Seção "O que seus amigos veem"** (sem interruptores):
- E0: "Seus amigos veem só seu cartão (apelido e foto)." (existente `kSharingAllOff`)
- E1: "Seus amigos mútuos veem suas estatísticas, atividades recentes e recomendados."
- E2: o texto de E2 da T-I

**T-Convite** (`invite_section.dart:145`): "Funciona mesmo com "Aparecer na busca" desligado (aí seus amigos veem só seu cartão). Você pode revogar quando quiser."

**T-R Ranking (docs/90 T1, RF-E10)**:
- Busca desligada: faixa "Você não aparece no ranking dos seus amigos porque "Aparecer na busca" está desligado." / botão "Ir para o Perfil"
- E2: faixa "Você não aparece no ranking dos seus amigos porque ainda não confirmou o que eles veem." / botão "Revisar"

**T-P Política e resumo**:
- `kPrivacySharingSentence`: "Por padrão, quem vira seu amigo vê só o seu cartão (apelido e foto). Se você ligar "Aparecer na busca", no perfil, e confirmar, além de aparecer na busca exata pelo identificador você mostra aos seus amigos mútuos suas estatísticas (números totais, deste mês e deste ano, tempo assistido e desde quando está no CineTrack), suas atividades recentes (títulos que favoritou, assistiu ou concluiu, só a partir de quando ligar) e seus recomendados (até 50 títulos que marcou com Recomendo, na ordem da sua aba, e quantos são), inclusive no Ranking entre amigos; para isso guardamos uma cópia disso, e desligar apaga na hora."
- `web/privacidade.html`:
  - linha da tabela "Só se você ligar em 'O que seus amigos veem'" → "**Só se você ligar "Aparecer na busca" e confirmar:** uma cópia das suas estatísticas (…), atividades recentes (…, só a partir de quando você confirmou) e recomendados (…), o seu fuso horário e a hora da última atualização | Banco de dados na nuvem | Mostrar aos seus amigos mútuos, no seu perfil e no Ranking; desligar apaga";
  - item "O que seus amigos veem (opcional, tudo desligado por padrão)" reescrito: um interruptor, consentimento único com prévia, quem já usava a busca recebe um aviso e nada novo é compartilhado antes do OK, desligar tira da busca e apaga a cópia;
  - frase das finalidades (linha ≈175): "…e, **apenas se você ligar "Aparecer na busca" e confirmar**, mostrar aos seus amigos as estatísticas, atividades recentes e recomendados";
  - data nova.

## 8. Critérios de aceite
Convenções: fakes com log de operações (escritas por caminho e campos); relógio falso; amizades ativas; sessão confirmada e online salvo indicação.
```gherkin
Cenário: Ligar com um consentimento só
  Dado que Ana está em E0
  Quando ela liga "Aparecer na busca"
  Então vê o diálogo T-C com a prévia das 3 seções e o log não tem escrita
  Quando toca "Ligar"
  Então o log tem 1 transação com handles/{handle}.discoverable = true e shared_profiles/{Ana} com sharing {stats, activity, recs}, activity [] e actSince = hora do servidor
  E aparece T-S1 e o Perfil mostra E1

Cenário: Cancelar não escreve nada
  Quando Ana abre T-C e toca "Cancelar" (ou Esc, ou fora)
  Então o log não tem escrita e o interruptor continua desligado

Cenário: Prévia ainda calculando
  Dado que os dados de Ana ainda não estão confiáveis (sincronizando)
  Então "Ligar" fica desabilitado com "Calculando…"

Cenário: Desligar apaga e tira da busca
  Dado que Ana está em E1
  Quando desliga e confirma em T-D
  Então o log tem 1 transação com discoverable = false e delete de shared_profiles/{Ana}
  E aparece T-S2 e um amigo que abre o perfil de Ana vê "Ana ainda não compartilha nada além do cartão."
  E os favoritos, amigos, pedidos e convite de Ana não mudam

Cenário: Não há mais interruptores por seção
  Então "O que seus amigos veem" não tem interruptores e nenhum Semantics "Compartilhar estatísticas com amigos"

Esquema do Cenário: Aviso para quem já estava na busca
  Dado que Bia tem a busca ligada e compartilha <seções> (Fase 2)
  Quando abre o app com a sessão confirmada e online
  Então vê o aviso A <variante> e o log não tem escrita
  Quando toca "OK"
  Então a transação acrescenta só <acrescenta> e as seções existentes ficam como estavam
  Exemplos:
    | seções         | variante                                 | acrescenta                        |
    | nada           | sem "Hoje você já compartilha"           | stats, activity (actSince novo), recs |
    | Estatísticas   | com "Hoje você já compartilha: Estatísticas." | activity (actSince novo), recs |
    | Atividades     | com "…: Atividades recentes."            | stats, recs (actSince e itens mantidos) |

Cenário: Desligar pelo aviso
  Dado que Bia vê o aviso A e compartilha Estatísticas
  Quando toca "Desligar"
  Então sem outra confirmação o log tem discoverable = false e delete de shared_profiles/{Bia}

Cenário: Fechar o aviso sem escolher
  Quando Bia fecha o aviso A com Esc
  Então nada é escrito, o Perfil mostra "Falta você confirmar o que seus amigos veem." e "Revisar"
  E o aviso não reaparece nesta sessão
  Quando a aba é recarregada (nova sessão)
  Então o aviso reaparece

Cenário: Aviso nunca aparece sem estado confirmado
  Dado que a leitura de sessão de Bia ainda não respondeu ou o aparelho está offline
  Então o aviso A não aparece
  Quando a leitura confirma E2 online
  Então o aviso aparece

Cenário: Quem já compartilha tudo não vê aviso
  Dado que Caio tem a busca ligada e as 3 seções
  Então nenhum aviso aparece

Cenário: Busca desligada com amigos não compartilha
  Dado que Davi tem amigos por convite, a busca desligada e nenhuma seção
  Então nenhum aviso aparece e nada é escrito

Cenário: Ativar amizades com a busca ligada pede consentimento
  Quando Eva preenche o formulário de ativação com "Aparecer na busca" ligado e toca "Ativar"
  Então vê T-C antes de qualquer escrita
  Quando toca "Ligar"
  Então o log tem a transação de ativação com discoverable = false e depois a transação de RF-SC2
  Quando, em vez disso, toca "Agora não"
  Então ativa com discoverable = false e sem shared_profiles

Cenário: Falha da 2ª transação na ativação
  Dado que a transação de RF-SC2 falha com unavailable depois da ativação
  Então Eva fica em E0 e vê T-F2

Cenário: Offline
  Dado o aparelho offline
  Então o interruptor e os botões do aviso estão desabilitados e tocar mostra a mensagem offline existente

Cenário: Resultado incerto
  Dado que a transação de ligar termina como incerta
  Então o interruptor mostra "Ainda não confirmado…" e fica desabilitado
  Quando uma leitura feita depois do fim da transação mostra as 3 seções e discoverable = true
  Então aparece T-S1 e o estado é E1

Cenário: Dois aparelhos
  Dado Ana em E1 no aparelho X e no Y
  Quando desliga no X e o Y, ainda desatualizado, tenta recalcular
  Então o recálculo do Y é recusado e o Y relê e mostra E0
  Quando o Y, desatualizado em E2, toca "OK" depois de o X já ter escolhido OK
  Então a transação não regrava as seções e o estado final é E1

Cenário: Ranking com a busca desligada
  Dado que Ana está em E0
  Quando abre o ranking
  Então vê "Você não aparece no ranking dos seus amigos porque "Aparecer na busca" está desligado." e "Ir para o Perfil"

Cenário: Ranking com confirmação pendente
  Dado que Bia está em E2 sem Estatísticas
  Quando abre o ranking
  Então vê a faixa de E2 e "Revisar" abre o aviso A
```

## 9. Dados, regras e cota (Arquiteto)
**Escritas novas** (nenhuma mudança de schema):
| Operação | Transação | Leituras na transação | Regras (chamadas) |
|---|---|---|---|
| Ligar (E0/E3 → E1) | `update handles/{h}` (`discoverable`, `updatedAt`) + `set shared_profiles/{uid}` (create ou acréscimo de seções) | 2 (cartão para o `update`; documento para create × update e idempotência) | cartão: `getAfter(social)` (1); shared: `exists(social)` (1) |
| OK do aviso (E2 → E1) | `update shared_profiles/{uid}` acrescentando seções (ou create se ∅); o cartão já está `true` | 1 | 1 |
| Desligar | `update handles/{h}` + `delete shared_profiles/{uid}` | 1–2 | cartão 1; delete 0 |
| Ativar com a busca ligada | ativação atual (`discoverable = false`) e depois "Ligar" | as da ativação + as de "Ligar" | as atuais + as de "Ligar" |
- **`actSince`**: no primeiro consentimento do modelo novo (ou ao religar depois de desligar), `actSince = request.time` e `activity = []`. Só entra atividade posterior ao consentimento, como exige `validActivities`. Uma `activity` já existente (consentida na F2) mantém `actSince` e itens.
- **`epsAt`** (datas por episódio em `favorites`): não muda.
- **Exportação / exclusão / desativação**: inalteradas. Exportar já inclui o cartão (com `discoverable`) e as seções; excluir a conta e desativar amizades já apagam `shared_profiles` e o cartão.
- **Regras: nenhuma mudança esperada.** `validShared` aceita as 3 seções num `create`; `sharedSectionsOk` valida só o que muda.
  - Orçamento: a escrita nova mais pesada do app é o create com 3 seções e `activity = []`, mais leve que o "pior documento legal" (10 atividades), que ocupa ≈ 65%. Hoje o teste trava esse caso em ≤ 70%, e a pior escrita do app em ≤ 65%.
  - **Não verificado**: se o limite de 1000 expressões de uma transação com dois documentos (cartão + shared) é contado por documento ou pela requisição inteira. A documentação não deixa claro.
  - **S0** acrescenta ao `rules_budget.test.mjs` três casos com a folga `HEAD_APP` (≤ 65%): (a) a transação cartão + create com 3 seções, `activity []` e 50 recomendados; (b) a transação cartão + delete; (c) o acréscimo de 2 seções sobre um documento com 1.
  - Se (a) não couber, o plano B não muda regras: duas escritas em sequência, primeiro o `shared_profiles` (o consentimento) e depois o cartão, com conserto no estado incerto (uma operação composta, uma tentativa de completar o cartão na reconexão). Volta ao Orquestrador antes do app.
  - `rules_sha.test.mjs` continua exigindo o sha atual.
- **Cota**: ligar ≈ 2 leituras + 2 escritas; OK ≈ 1 + 1; desligar ≈ 1–2 + 2. O aviso não lê nada (usa a leitura de sessão do dono e o estado do `SocialController`, já existentes). O motor passa a recalcular 3 seções para quem consentir (até 1 escrita por janela de 5 s, como hoje). Na hipótese de 100 usuários sociais/dia, a mudança é desprezível (< 0,5% da cota).

**Componentes** (nomes sugeridos):
- `SharingController.setSearchSharing(bool on, {SharedProfileContent? content})` e `confirmNotice(content)`, com a máquina de incerteza atual estendida a "operação composta" (`uncertain` passa a aceitar a chave `all`);
- `SharedProfileRepository.searchAndShare(handle, content | null)`, uma transação Firestore com os dois documentos;
- `sharingModeProvider` (E0–E3, Ep, Ei);
- `noticeShownThisSession` (memória por uid);
- `SocialController.setDiscoverable` deixa de ser chamado pela UI (fica para a ativação, com `false`).

## 10. Interação com o ranking (docs/90, docs/91)
- D9 e RF-E10: "eu não compartilho" = `meSharing == false` = documento confirmado sem `stats`, o que no modelo novo significa E0 ou E2 sem Estatísticas (ou E3 sem Estatísticas). Faixa e botão por variante (T-R).
- Minha linha (docs/91 §10.6): inalterada (`doc.stats`). Ligar ou dar OK ⇒ o `doc` otimista entra e a linha aparece sem leitura.
- docs/90 e docs/91 foram atualizados com referência a este documento (T1, RF-E10, D9, §10.6, fatiamento).

## 11. Testes e mutações
**Testes**:
- `sharing_mode_test`: tabela §4 (E0–E3, Ep, Ei) e condição do aviso, 1:1.
- `sharing_search_controller_test`, com fakes e log:
  - operações exatas de ligar, OK (as 3 variantes da migração), desligar e ativar;
  - `actSince` novo × mantido;
  - idempotência (dois aparelhos);
  - offline, `denied`, `quota`, incerto (com `settled`), geração (troca de conta);
  - 0 escritas antes de "Ligar"/"OK".
- `sharing_search_widget_test`:
  - textos literais T-I, T-C, T-D, T-S, T-A, T-F, T-V e T-Convite;
  - nenhum interruptor por seção;
  - aviso 1× por sessão e "Revisar";
  - foco e Semantics do interruptor;
  - layout 320–1440 px × 1×/2×/3×.
- `privacy_summary`/política: teste literal (padrão `shared_profile_texts_policy_test`) e data em `web/privacidade.html`.
- Ranking: as variantes da faixa (T-R) entram na T1 do docs/90 e no `ranking_screen_test`.
- Regras (emulador, sem mudança): transação cartão + create de 3 seções aceita; cartão + delete aceita; acréscimo de seções aceito; `actSince` antigo com `activity` nova negado (já coberto, reexecutar); casos de orçamento do §9; sha.

**Mutações** (todas devem morrer):
- aviso com as 3 seções presentes;
- aviso sem estado confirmado ou offline;
- aviso duas vezes na sessão;
- fechar o aviso tratado como OK;
- fechar tratado como Desligar;
- escrita antes do OK ou do "Ligar";
- OK sem acrescentar todas as que faltam;
- OK que regrava `actSince`/atividades existentes;
- ligar sem `activity` ou sem `actSince = request.time`;
- desligar sem apagar o documento;
- desligar sem tirar da busca;
- desligar sem confirmação T-D;
- confirmação T-D exigida no "Desligar" do aviso;
- ativação com a busca ligada sem T-C;
- ativação criando o cartão com `discoverable = true`;
- interruptores por seção ainda visíveis;
- faixa do ranking com a variante trocada;
- transação não idempotente (regrava seções já presentes);
- incerto resolvido por leitura anterior ao fim da transação.
- Regras: os mutantes RK* e os da F2 continuam valendo.

## 12. Fatiamento da Fatia S (antes das fatias visíveis do ranking; a Fatia 0 de regras do ranking, já em curso, não conflita)
- **S0 — Orçamento** (backend, emulador, sem mudar regras): casos do §9 no `rules_budget.test.mjs` + testes de aceitação das transações. Decide transação única × plano B.
- **S1 — Dados e controller**: repositório (transações), `sharingModeProvider`, `setSearchSharing`, `confirmNotice`, incerteza da operação composta; testes de controller.
- **S2 — Interface**: interruptor único, T-C, T-D, aviso A (e B conforme o ❓1), "Revisar", formulário de ativação, seção sem interruptores, convite; testes de widget.
- **S3 — Política e textos**: `web/privacidade.html` (data nova), `PrivacySummary`, variantes da faixa do ranking (docs/90 T1).
- **S4 — Fechamento**: code review, QA e smoke com contas reais:
  - uma conta com a busca ligada e nada compartilhado;
  - uma com a busca ligada e só Estatísticas;
  - uma com a busca desligada e amigos por convite;
  - dois aparelhos.
  Ordem de publicação: regras (só conferir o sha) → **política** → app.

## 13. Pergunta ao Manager
- **❓1 (bloqueia só a parte de migração do S2):** o que fazer com quem está com a **busca desligada** mas ligou alguma seção na Fase 2 (E3)? É o caso de quem fez amigos por convite. A decisão diz "OFF = nada compartilhado" e "busca desligada com amigos não compartilha nada", mas apagar sem ação contraria "nunca apagar o que a pessoa compartilhou sem ação dela".
  - **Recomendação:** aviso B uma vez por sessão, até a escolha entre "Parar de compartilhar" e "Aparecer na busca e compartilhar tudo" (este passa pelo T-C). Até lá, mantém o que a pessoa já compartilha, e o Perfil mostra "Você ainda compartilha: …".
  - **Alternativa:** apagar automaticamente na próxima sessão, com um aviso informativo.
  - S0, S1, S3 e o restante do S2 não dependem da resposta.

## 14. Definition of Done (desta especificação)
- [ ] ❓1 decidida pelo Manager.
- [ ] QA revisou a testabilidade (estados, textos, transações, migração).
- [ ] S0 confirmou o orçamento (transação única) ou o Orquestrador aprovou o plano B.
- [ ] docs/90 e docs/91 coerentes com este documento.

## Decisão do Manager sobre o ❓1 (2026-10-24)

Aprovada a recomendação: aviso B uma vez por sessão com "Parar de compartilhar" ou "Aparecer na busca e compartilhar tudo"; até a escolha, mantém o que a pessoa já compartilha. Nada é apagado sem ação dela.
