# 63 - Code review: amizades, fatia 3 (receber/aceitar/recusar, lista, remover, indicador, pedido cruzado)

> Revisor: Code Reviewer (gate). Escopo: fatias 0 a 2 commitadas (8c5d9dd, 091c664, dc5f100) + working tree da fatia 3 (23 arquivos modificados, 5 novos). Contrato: ADR-005, docs/49 (D4, D5, D7, D8), docs/50, docs/51, docs/55, 59, 61, 62. Nada foi alterado no worktree (`git status` com as mesmas 28 entradas antes e depois, exceto este arquivo). Mutações extras e o teste de diagnóstico foram feitos em cópia em `/private/tmp`.

## Veredito: REPROVADO (mudanças pequenas, nenhum 🔴)

Não há falha de segurança, perda de dados nem quebra de contrato Dart x regras. Há **2 🟡** (um é comportamento que a documentação promete e o código não faz; o outro é o teto de 300 que o próprio dev perguntou se deve ser conferido). Pelo critério do Manager ("APROVADO limpo, nenhum 🔴 nem 🟡"), a fatia volta para ajuste e a re-revisão é curta (2 correções localizadas + testes). O resto do código é de boa qualidade.

## Números reais (rodados por mim)

| Item | Resultado |
|---|---|
| `flutter analyze` | 0 problemas |
| `flutter test` | 1220 passam, 0 falham |
| `flutter build web --release` | OK, `main.dart.js` = 3.884.879 bytes (igual ao declarado) |
| `npm test` (emulador, JDK 24) | 283/283 |
| `npm run test:mutations` | 26/26 mortas, nenhuma sobreviveu |
| `git diff -- firestore.rules firestore.indexes.json` e testes de regras existentes | vazio (só `dart_payloads.test.mjs` estendido, fixture e `mutations.mjs` com adições) |

## 🟡 Importantes (resolver nesta fatia)

### 🟡-1. O indicador NUNCA é atualizado depois da primeira leitura da sessão (o "TTL de 10 min" não existe na prática)

- Onde: `lib/providers/social_lists_providers.dart:447-456` (`receivedBadgeProvider`) e `:405-421` (`ensureFresh`).
- O que acontece: `receivedBadgeProvider` é um `Provider` do Riverpod 2.6 (sem `autoDispose`): só reexecuta quando uma dependência observada muda (`socialActiveProvider` e o `count`). `ensureFresh()` só é chamado dentro dele, então é chamado 1 vez por sessão (mais quando o `count` muda). Redesenhar a barra, trocar de tela ou esperar 10 minutos não dispara nova leitura. O docs/62 (tabela de cota) e o README prometem "1 `count()` a cada 10 min se uma tela com o ícone for redesenhada".
- Cenário: usuário deixa o app aberto (PWA) por horas; chegam 3 pedidos; o ícone continua sem número até ele abrir a aba Pedidos, aceitar/recusar algo ou recarregar a página. O indicador, que é a única descoberta de pedido novo (sem push, sem listener, por decisão), fica mudo.
- Prova (cópia em `/private/tmp`): contêiner com `receivedCountTtlProvider = Duration.zero`, ouvindo `receivedBadgeProvider`; leio o badge (1 leitura de `count`), semeio um segundo pedido no servidor e releio o provider 5 vezes com `settle()` entre elas: `countReceived` continua em 2 leituras no log (a do arranque), o badge segue mostrando 1 com 2 no servidor. O teste existente (`social_friends_test.dart:601`) passa porque só prova "leu uma vez" e "depois de expirar, leu de novo quando o `count` mudou", não que um redesenho após o TTL relê.
- Correção sugerida (barata, sem listener): fazer cada ponto que mostra o badge chamar `ref.read(receivedCountControllerProvider.notifier).ensureFresh()` no `build` (via `Future.microtask`, como já se faz), mantendo o `if (dentro do TTL) return;` que já existe, ou expor um `ref.watch` de um provider que o faça. Acrescentar teste: TTL expirado + novo `read` do badge de um widget redesenhado => +1 leitura de `countReceived`; dentro do TTL => 0. Se preferirem não fazer isso nesta fatia, então corrigir docs/62 e README para dizer "1 leitura por sessão; o número é atualizado ao abrir Pedidos" (mas aí a descoberta de pedidos novos fica pior que o desenho do docs/50 §9).

### 🟡-2. O teto de 300 amigos não é conferido no pedido cruzado (e é alcançável pela interface normal)

- Onde: `lib/data/firestore_social_data_source.dart` (ramo `on _CrossedRequest`, ~linhas 174-195) e `lib/repositories/social_repository.dart:178-198` (`sendRequest` só confere o teto de 50 enviados).
- Cenário (sem cliente modificado): usuária com 300 amigos busca por `@fulano`, que já tinha pedido a amizade dela, e toca "Enviar pedido". O app vira a amizade (301). Na tela de pedidos o mesmo gesto ("Aceitar") é barrado com "limite de 300 amigos". Duas portas do mesmo limite com comportamentos diferentes; o README e a política (`web/privacidade.html`) dizem "você pode ter até 300 amigos".
- Dano máximo: o próprio usuário passa de 300 uma amizade por vez (ninguém consegue impor isso a outra pessoa; o limite do outro lado também não é conferido no aceite, por D5 ser só de cliente). Sem perda de dados, sem risco de segurança. Mas o fan-out de D8 (<= 300 escritas em lotes) deixa de ter teto, e a regra anunciada ao usuário fica incoerente.
- Custo de corrigir: 1 `count()` **só no ramo cruzado** (raro), sem custo para o envio normal. No ramo `_CrossedRequest`, antes do `acceptRequest`: `if (await _count(SocialPayloads.friendsCountQuery(uid)) >= kMaxFriends) throw const SocialFailure(SocialFailureKind.friendsLimit);` (a mensagem "Remova alguém para aceitar outro pedido" serve) e ajustar o texto de `friendsLimit` para não dizer "aceitar" apenas, e um teste no fake (300 amigos + inverso => nada é criado, o pedido dele continua). Atualizar a linha da tabela de cota (cruzado = 4 leituras).
- Nota: se o Manager preferir manter como está, a alternativa honesta é registrar como tarefa e trocar README/política para "limite sugerido de 300"; eu não recomendo, a correção é de ~6 linhas.

## Contrato Dart x regras (verificado campo a campo)

- **Aceitar**: `SocialPayloads.acceptRequest` gera 1 `batch` com `set friendships/{menor}_{maior}` (`members` ordenado, `createdAt` = sentinela de servidor, `aName`/`bName`, fotos só quando existem) + `delete friend_requests/{outro}_{eu}` + `delete friend_requests/{eu}_{outro}`. Confronto com `validFriendshipCreate` (`firestore.rules:170-195`): `keys().hasOnly/hasAll` batem; `members[0] < members[1]` (ordenação por unidade UTF-16 do Dart = comparação das regras para uids alfanuméricos); `key == members[0]_members[1]`; `createdAt == request.time`; a "metade do outro" vem de `request.rawFromName/rawFromPhoto` (sem limpeza), exatamente o que a regra compara com `get(requestPath(other, me))`; ausência de foto = chave omitida (a regra usa `d.get(..., null) == req.get('fromPhoto', null)`); `!existsAfter` dos dois pedidos é satisfeito pelos dois `delete` (apagar o que não existe é aceito porque o id contém meu uid). Leituras de regra no `set`: 1 `get` + 2 `exists(social)` + 2 `isBlocked` + 2 `existsAfter` = 7, abaixo do limite de 10 por operação e de 20 por batch.
- **Recusar** = 1 `delete {de}_{eu}` (regra de delete do destinatário); **remover** = 1 `delete` do par (qualquer membro). Idempotentes (delete de inexistente com id contendo meu uid é aceito).
- **Cruzado**: a transação lê os dois pedidos (regra de `get` por id contendo meu uid) e, achando o inverso, NÃO cria nada: roda o MESMO payload `acceptRequest` usando `fromName/fromPhoto` do pedido dele (`social_data_source` constrói o `AcceptDraft` a partir do documento lido), minha metade do cartão da busca. Ordem, tipos e modo (batch) idênticos ao do aceite.
- **Consultas**: `received` (`to == uid`, `orderBy createdAt desc`, índice já existente), `receivedCount` (agregação, limite 50), `friends` (`members array-contains uid`, índice automático de campo único, sem `orderBy`), `friendsCount` (limite 300). Todas no golden, no fixture e reexecutadas no `.mjs` (inclusive `startAfter` e os negados para outro usuário/anônimo).
- **O `.mjs` reexecuta exatamente isso** contra as regras reais: os testes derivam caminhos e operações do fixture (não reescrevem à mão), e `dart_payloads.test.mjs` tem teste que exige `['set','delete','delete']` e os dois caminhos de pedido no batch.
- **4 mutações extras, em cópia** (golden): (A) renomear `aName` para `nameA` no `acceptRequest`; (B) a foto do outro lado passa a ser a minha; (C) remover o delete do pedido inverso; (D) trocar `batch` por `transaction`. As 4 quebram `social_payloads_golden_test`. Para provar que o replay não depende só do golden, regenerei o fixture com a mutação (B) (`UPDATE_GOLDEN=1`) e rodei `npm test` na cópia: **2 falhas** (`acceptRequest_with_photos: creates the pair...` e `field limits`), 281/283. Mutação própria de `_rememberHint` (voltar a ler o uid depois do `await`, sem guarda de geração): o teste `socialHint race (docs/61 a)` falha, como o dev declarou.
- Versão do mutante do dev: as 4 novas (M23 a M26) estão em `mutations.mjs` e todas morrem (26/26).

## Segurança (aceitar, cruzado, corridas)

- Aceitar pedido alheio, inexistente, o PRÓPRIO pedido (remetente "confirmando"), duas vezes, com bloqueio nos dois sentidos, com o outro lado sem `social` (desativou), sem eu ter `social`, conta não Google: **todos negados** pelo emulador (testes do replay, mutação M26 prova que a regra depende do pedido do outro).
- **Cruzado não abre brecha**: o único modo de o cliente criar o par sem clicar "Aceitar" é existir o pedido `{outro}_{eu}`, que só o outro cria (`d.from == request.auth.uid`). Forjar "pedido B->A" é impossível (regra de `create` do pedido exige `from == me`); sem ele, o `get(requestPath(other, me))` do `set` do par falha. E a "metade do outro" é comparada com o que ELE gravou, M25 prova.
- Um lado criar a amizade sozinho: negado (M1, replay "neither side can create a friendship alone").
- Remover amizade que não é minha: negado (M24); par que não contém meu uid, mesmo inexistente: negado.
- Corridas: aceitar nos dois aparelhos => o segundo batch é negado (o pedido já foi consumido) e a UI mostra a mensagem genérica de "não foi possível aceitar" e remove o item localmente; recusar x aceitar => idem; remover x aceitar => o par some e o pedido nunca volta (o pedido só pode ser recriado depois); cruzado simultâneo com os dois pedidos pendentes => um aceite apaga os dois (testado no replay); retry depois de resposta incerta no cruzado: reenviar é negado (`!isFriend`), mensagem genérica, nada duplica.
- Teto de 300: ver 🟡-2. Dano máximo: o próprio usuário ultrapassa o limite; nada alheio.

## Privacidade / vazamento

- A lista de amigos mostra apenas o que o par guarda para o outro lado (apelido, foto sanitizada, data). Nada de favoritos/uid exibido.
- Recusar e remover não avisam; o único efeito observável para o outro é o desaparecimento (da lista de enviados no caso de recusa, o pedido some como uma aceitação ou cancelamento; da lista de amigos no caso de remoção, só na próxima leitura). O texto "Se a pessoa recusar, o pedido some daqui sem aviso" é honesto e não separa recusa de outras causas.
- Mensagem genérica única: aceite negado por qualquer motivo (pedido sumiu, bloqueio, social desligado do outro) => "Não foi possível aceitar o pedido. Ele pode ter sido cancelado. Atualizamos a lista."; cruzado negado => "não foi possível enviar". Nenhum texto menciona bloqueio ou ocultação.
- Bloqueio (fatia 4) ainda não existe; o desenho já prevê o caso: o batch de bloqueio apaga par e pedidos (regras), e a lista local reage por TTL/recarga; remover/recusar/aceitar são idempotentes ou genéricos. Nada na fatia 3 precisa mudar para acomodar a fatia 4.
- Badge/contagem: é a contagem do próprio usuário (`to == uid`); não revela nada a terceiros.

## Cota

- Tabela do docs/62 conferida contra o código: abrir `/friends` = N leituras da aba na tela (nenhum listener, nenhuma leitura da outra aba); reabrir/trocar de aba dentro do TTL = 0; aceitar = 1 `count()` de amigos + 7 de regra (<= 10 por operação, <= 20 no batch); recusar e remover = 0 leituras; cruzado = 3 leituras + 7 de regra (com o 🟡-2 passa a 4). O número do indicador: ver 🟡-1 (hoje o custo é ainda menor que o declarado porque nunca é renovado).
- Paginação: `friends` pagina por id de documento (índice composto proibido) e o cliente ordena por nome o que já carregou: com <= 50 amigos a lista fica correta; com mais, cada "Ver mais" reordena tudo (ver 🟢-1). Com 300 amigos: 6 páginas, 301 leituras na pior abertura, sem estourar nada.
- Caches reconstruídos nos eventos certos (ativar/desativar, trocar de conta, logout) via `socialPeriodProvider` e `currentUidProvider`; trocar o handle não derruba mais as listas (🟢-c do docs/61); testes cobrem, inclusive sem vazamento entre contas.

## UI / acessibilidade

- Abas `Amigos | Pedidos`: papel `tab`/`tabBar`, selecionada marcada, setas esquerda/direita (e cima/baixo, invertidas em RTL), Home/End movem foco E seleção, foco rotativo (só a aba selecionada entra no Tab), anel de foco, alvo >= 48 px, empilha com fonte grande. Cartões de pedido/amigo com rótulos "Aceitar pedido de X", "Remover amizade com X"; "Salvando..." com os dois botões desabilitados; confirmação de remover com "A pessoa não será avisada" e foco inicial em "Cancelar"; estados carregando/vazio/erro/offline cobertos.
- Badge: "Amigos, N pedidos recebidos" (singular tratado, "50+" no teto), número fora da semântica para não ser lido duas vezes.
- `friendsIconFits`: conferi a fórmula (largura - 32 - 48 - 32 - 48 >= 32 + 8 + 56 x fator): esconde o ícone em 320 e 360 px com fonte 3x (160 < 208 e 200 < 208), mantém em 320 px/2x (160 >= 152, folga de 8 px, coberta pelo teste de matriz sem overflow), 390 px/3x (230 >= 208) etc. Nos casos escondidos o usuário ainda chega a `/friends` por "Perfil -> Gerenciar amigos" (com Badge) e há um ponto no destino Perfil quando há pedidos. Sem pedidos e ícone escondido, a única entrada é o Perfil: aceitável e coerente com docs/50 §13.
- Chrome: **não verificado** (a validação visual real exige login Google e não é possível sem a conta do usuário); a aparência do `Badge`/ponto nos temas reais, foco com Tab/setas em navegador e leitor de tela reais seguem não verificados, como o dev declarou.

## Exportação, exclusão, política, README

- Exportação: o leitor (`social_export.dart`) já lia `members/aName/bName` do documento que `acceptRequest` grava; há teste que parte do documento real do aceite (uid + apelido + `since`, sem foto). Arquivo antigo (schema 1/2 sem amigos) continua legível (nenhum arquivo de exportação foi alterado).
- `deactivate` e `AccountDeleter` com amizade real: o replay prova que a varredura apaga os pares e os pedidos e que o outro lado deixa de ver o usuário; os testes de app criam as amizades pelo próprio app. Sem fantasmas.
- Política/README/`PrivacySummary` descrevem corretamente o que o amigo vê (só o cartão e a data), que recusar e remover não avisam e que o pedido cruzado vira amizade. Pequeno exagero: a política diz que o app guarda no aparelho "o número de pedidos recebidos mostrado no ícone" e as listas; o número e as listas ficam só em memória (e, quando offline, no cache do Firestore). É conservador (diz guardar mais do que guarda), não gera risco; pode ficar ou ser ajustado.
- **"Última atualização" da política**: está `06/10/2026` e a data do sistema é 05/10/2026. A política mudou de forma relevante nesta fatia (amizades, aceitar, recusar, remover, cópia local). Exijo que a data seja a **da publicação** (o dia do commit final), atualizada pelo Manager no commit; não é bloqueio de código, mas fica como condição de entrega.

## Os 3 🟢 do docs/61

- (a) `_rememberHint(uid, geração, ativo)` com o uid capturado antes do `await` e guarda de geração: fechado; o teste "socialHint race" cobre e o mutante (reler o uid depois do `await`) o derruba (conferi em cópia).
- (b) hint gravado ao confirmar ativar/desativar: fechado, teste cobre o caso offline.
- (c) trocar handle derrubava a lista: fechado (`socialPeriodProvider`; teste "lista sobrevive à troca", 1 só leitura).

## Testes antigos ajustados e churn

- Os ajustes listados no docs/62 são legítimos: nenhum foi afrouxado (o teste do ramo provisório do cruzado passou a exigir a amizade e nenhum pedido restante; as listas de enviados moveram-se para a aba Pedidos; a matriz da barra superior passou a esperar o ícone escondido em 320/360 px com fonte 3x, que é o fallback pedido; `reads` do harness exclui a agregação do indicador e a conta em `countReads`). Nenhuma regressão nos 1095 anteriores (1220 passam).
- `git diff --stat` (2255 inserções, 254 remoções) x `git diff -w --stat` (2213, 212): ~42 linhas de reformatação nos arquivos tocados (`friends_screen.dart`, `firestore_social_data_source.dart`, `friends_navigation_test.dart`, `social_requests_test.dart`, `fake_social_cloud.dart`), concentradas em código que a fatia reescreve. Resta um pedaço alheio reformatado em `lib/widgets/app_shell.dart` (assinatura de `detailAppBar` colapsada em 1 linha, fora do escopo): 🟢-5.

## 🟢 Sugestões

1. **Lista de amigos reordena a cada "Ver mais"** (`social_lists_providers.dart:346-350`, `social_repository.dart` `friends()`): com mais de 50 amigos a primeira página é ordenada por nome só dentro dos 50 que vieram por id de documento; ao tocar em "Ver mais" a lista se reembaralha. Sem perda, mas confunde. Sugestão: quando `hasMore`, mostrar uma linha "Mostrando N amigos; toque em Ver mais para ver o resto." e/ou deixar o cabeçalho da lista dizer que a ordem é alfabética dentro do que foi carregado. Além disso a ordenação `toLowerCase().compareTo` põe "Álvaro" depois de "Zé" (acentos); usar uma chave sem acento (ou `compareTo` sobre NFD sem marcas) é melhor para pt-BR.
2. **Aba Amigos não tem "Atualizar"** (a aba Pedidos tem). Depois que o outro lado remove a amizade, a lista fica como estava até 5 min e, na busca, a pessoa continua aparecendo como "Vocês já são amigos." (`add_friend_screen.dart:111`) sem botão de enviar, sem como forçar uma releitura. Sugestão: botão "Atualizar" simétrico na aba Amigos (e, se já estiver em "Vocês já são amigos.", oferecer "Atualizar lista").
3. Tocar no ícone com Badge enquanto já está em `/friends?tab=pedidos` mas vendo a aba Amigos não faz nada (`initialTab` não mudou, `didUpdateWidget` não dispara). Raro.
4. No aceite duplicado em dois aparelhos o segundo mostra "Ele pode ter sido cancelado" mesmo tendo sido aceito no primeiro; a lista de amigos desse aparelho não relê (TTL). Aceitável por ser a mensagem genérica; opcional: após `notAccepted`, invalidar o TTL da lista de amigos.
5. Churn de formatação em `lib/widgets/app_shell.dart` (`detailAppBar`), arquivo tocado só por causa do Badge. Desfazer essa linha.
6. Entrega do Manager: data de "Última atualização" da política (condição acima) e, no commit final, confirmar que a política e o README refletem a correção do 🟡-1 (se a decisão for "uma leitura por sessão").

## Resumo para o Manager

REPROVADO por 2 🟡 pequenos, sem nenhum 🔴. Segurança, contrato Dart x regras, cruzado, privacidade, exportação/exclusão e acessibilidade estão sólidos. Pendências: (1) o indicador não renova depois da primeira leitura da sessão (a promessa de TTL de 10 min não se cumpre; reproduzido em teste de diagnóstico); (2) o pedido cruzado não confere o teto de 300 (corrigir com um `count()` só nesse ramo). Re-revisão rápida após os dois ajustes + testes. Política: usar a data do dia do commit final.
