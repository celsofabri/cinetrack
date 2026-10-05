# 60 - Code review: amizades, fatia 2 (busca, enviar/cancelar pedido, "Pedidos enviados")

> Revisor: Code Reviewer (gate) · 2026-10-06 · Escopo: working tree NÃO commitado sobre `feat/social-friends` (8c5d9dd, 091c664) + [docs/59](./59-social-fatia-2-implementacao.md). Somente leitura; mutações só em cópia (scratchpad). `git status` idêntico antes e depois.

## Veredito: **REPROVADO** (1 🟡 que o critério "APROVADO limpo" do Manager não admite + 1 🟡 de texto; nenhum 🔴)

A fatia é sólida: contrato Dart x regras travado, privacidade da busca correta, sem perda de dados. Falta corrigir um estado velho em memória (🟡-1) e alinhar o texto publicado com a decisão D4 (🟡-2). Ambos são pequenos.

## Números reais (reexecutados por mim)
| Item | Resultado |
|---|---|
| `flutter analyze` | 0 issues |
| `flutter test` | **1088 passam** (confere) |
| `flutter build web --release` | OK; `main.dart.js` 3.843.228 bytes (confere) |
| `npm test` (emulador, JDK 24) | **256/256** |
| `npm run test:mutations` | **22/22 mortas** (são mutações das regras; as da fatia 2 abaixo são minhas) |
| `firestore.rules`, `firestore.indexes.json`, testes de regras existentes | **sem diff** (só `dart_payloads.test.mjs` estendido e fixture com adições) |
| Testes antigos | nenhum alterado; só `test/social_payloads_golden_test.dart` (+30, só adições) e `test/support/fake_social_cloud.dart` (+120, 1 linha de comentário trocada) |
| `lib/data/firestore_favorites_data_source.dart` | **não está no diff** (nem no working tree). Última mudança nele é de commits antigos (89dd74c). A declaração de que foi tocado não procede nesta fatia; nada a justificar. |
| Chrome / navegador | **não verifiquei** (nada conectado/usado; as telas só existem logado com Google) |

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes

### 🟡-1 Lista "Pedidos enviados" em memória sobrevive a Desativar -> Ativar (pedidos "fantasma" e envio travado por até 5 min)
- `lib/providers/social_providers.dart:~320` (`SentRequestsController`; só reinicia quando muda o uid, `build()` linha ~300) e `deactivate()` / `finishCleanup()` (linhas ~190-215) que nunca invalidam `sentRequestsControllerProvider` (grep: nenhuma referência fora das telas).
- Cenário (reproduzido por mim em teste descartável na cópia): carregar a lista, enviar pedido a @bruno, Perfil -> Desativar amizades (o servidor apaga o pedido), Ativar de novo na mesma sessão, abrir `/friends` dentro do TTL de 5 min: a lista mostra 1 pedido que **não existe mais** no servidor ("GHOST items after reactivation: 1"). Pior: em `/friends/add`, buscar @bruno cai em `_Send.alreadySent` pela lista em memória (`add_friend_screen.dart:~108`), **sem botão de enviar**, até cancelar o fantasma ou o TTL vencer. Nada se perde, mas o usuário é levado a acreditar em um pedido que não existe (viola "ninguém precisa fazer nada / estado honesto").
- Correção: em `SocialController.deactivate()` (sucesso e `cleanupPendingCode`) e `finishCleanup()` chamar `ref.invalidate(sentRequestsControllerProvider)` (ou `build()` observar `socialControllerProvider.select((s) => s.profile?.handle)`/fase); teste: o cenário acima termina com lista vazia e 1 leitura nova.

### 🟡-2 Política e README descrevem o pedido cruzado de forma oposta à decisão D4
- `web/privacidade.html` (item "Pedidos de amizade": "Se ela já tiver pedido a sua amizade, o app apenas avisa; só viram amigos quando as duas pessoas aceitarem") e README (mesma ideia: "o app só avisa"). A decisão do Manager (D4, docs/49/50) é que o pedido cruzado **vira amizade**. A fatia 3 vai mudar o comportamento, mas a política publicada continuaria afirmando o contrário (texto jurídico/LGPD falso depois da fase).
- Correção: ou reescrever agora de forma neutra e verdadeira nos dois estados ("se a pessoa também tiver pedido a sua amizade, vocês podem virar amigos sem novo pedido"; sem prometer quando), ou registrar como critério de aceite explícito da fatia 3 ("atualizar privacidade.html e README do cruzado"). Prefiro a primeira, porque a política só é publicada junto da fase inteira e o texto neutro vale nos dois estados.

## 🟢 Sugestões
1. **Ícone Amigos = +1 leitura por sessão Google, mesmo para quem nunca ativou** (`MobileTopBar`/`HomeScreen` observam `socialActiveProvider`, que dispara `SocialController.build` -> `load()` server-first). Aceitável para a cota Spark e documentado (1 inativo / 2 ativo), e é só leitura (nenhuma escrita, nada visível). Alternativa mais barata sem mudar o desenho: decidir a visibilidade do ícone com **cache primeiro** (`Source.cache`/`LocalStore` "inativo" por uid) e confirmar no servidor só ao abrir Perfil ou `/friends`; ganho: 0 leituras de rede para quem nunca ativou. Fica como melhoria; não bloqueia.
2. `lookupHandle` (`firestore_social_data_source.dart`) lê `handles/{h}` por `_handle()` fora de `social_payloads.dart` (idem os `get` já existentes de cartão da fatia 1). A frase "todas as leituras passam por social_payloads" vale para escritas, transações, `count()` e a query de enviados; o `get` de handle é um path trivial coberto só pelo `.mjs` (que o executa). Considere `SocialPayloads.handlePath` já existente no `lookupHandle` (path único no golden).
3. Amigo existente achado na busca: "Enviar pedido" resulta na mensagem genérica "Não foi possível enviar o pedido". Correto para a regra (indistinguível de bloqueio), mas é um beco sem explicação; na fatia 3, com a lista de amigos em mãos, pode virar "Vocês já são amigos" sem vazar nada (é estado do próprio usuário).
4. Limite de 50 só no app: `count()` + transação não são atômicos; 2 abas simultâneas podem passar de 50 em 1-2 pedidos. Aceito pelo D5 (só app); registrar.
5. Menu desktop: o item Amigos só existe no Início (Explorar/Favoritos/Recomendações só têm a lupa, como já era). Documentado; considere replicar quando houver o cabeçalho comum.
6. A política cita que a busca responde igual quando a pessoa "bloqueou você". Não revela nada de um caso concreto (a mensagem é a mesma), é honesto e mantém negação plausível; apenas confirme que o Manager aceita citar a categoria em texto público.

## Análise por tópico

### (1) Privacidade / vazamento por diferença de resposta: OK
- `SocialRepository.search` (`social_repository.dart:~128`): inexistente, oculto, bloqueado (nos dois sentidos), o próprio, uid próprio sob outro handle, reservado e `permission-denied` retornam o mesmo `SearchNotFound` -> mesma frase `kSearchNotFoundMessage` na UI. Só falha de transporte vira erro visível (e é igual para todos os handles). Teste `social_requests_test` "missing, hidden, blocked either way, yourself, reserved: the SAME answer" e o de UI idêntico (`friends_screens_test:265`) comparam o texto/árvore.
- Timing/leituras: próprio e reservado não leem; os demais fazem 1 `get`. Oráculo possível: só "este handle é o seu / reservado", ambos já públicos ou do próprio usuário. Inexistente x oculto x bloqueado fazem exatamente 1 `get` (mesma latência de ordem de grandeza, a diferença é de regra no servidor, não observável de forma útil). Aceitável. Offline: o botão é desabilitado igual para qualquer handle (não distingue).
- Envio: toda negação das regras vira `notSent` (mensagem única, sem motivo); `alreadySent`, `limitReached` e `incomingRequest` falam só do estado do próprio usuário (o pedido do outro para mim eu já poderia ler/receber). O cartão mostra só apelido, @handle e foto (`_FoundCard`). Sem PII em logs (`debugPrint` só com `e.code`).

### (2) Contrato Dart x regras: OK
- Todas as novas escritas/transação/consultas saem de `SocialPayloads` (`sendRequest` com `reads`, `cancelRequest`, `sentQuery`, `sentCountQuery`, `requestPath`); `_execute` escolhe transação/batch por `write.mode`. Golden cobre 2 cenários de envio (sem/com fotos, com `reads`), cancelar, as 2 consultas (`orderBy`, `aggregate`). O `.mjs` lê o MESMO fixture, executa `reads` dentro da transação, depois o envio; `count` via `getCountFromServer`, enviados com `orderBy` + `startAfter`.
- Mutações minhas (cópia no scratchpad, golden): (M1) renomear `toName`->`toNick`; (M2) mudar tipo de `to` (string -> int); (M3) path `{from}_{to}` -> `{from}-{to}`; (M4) `cancelRequest` batch -> transaction. **As quatro quebraram o golden** (fixture divergente) e o `.mjs` consome esse fixture. O dev já mostrou M1 quebrando 5 testes do replay.
- Conferido contra `firestore.rules` (friend_requests): campos exigidos/permitidos (`from,to,fromName,toName,createdAt` + fotos opcionais ausentes quando nulas), `createdAt` = `request.time` (marcador `serverTimestamp`), id `{de}_{para}`, `validName`/`validPhoto` iguais aos validadores Dart, `isGoogle`, `social` de ambos, bloqueio nos dois sentidos, já amigos, duplicado (create sobre existente), `get` do inverso e do próprio permitido (id contém o uid). Nenhum envio legítimo é negado; os negados caem em `notSent`. 20 emoji (40 unidades) passam; 41 falha: igual ao Dart.
- Não verificado (declarado pelo dev e confirmo): nada contra Firebase real (`count()`, `startAfterDocument`, exceção do `check` propagando de `runTransaction`, faturamento).

### (3) Pedido cruzado: ramo intermediário aceitável, com ressalva de texto (🟡-2)
- É seguro: lê os dois documentos, **não escreve nada** (`check` lança `incomingRequest` antes de `_applyTx`), não perde nada, texto honesto ("Os pedidos recebidos chegam em breve"). A fase só é publicada inteira, então não há beco sem saída para o usuário final; ele existe só entre fatias.
- Contradiz D4 só provisoriamente. A fatia 3 tem tudo para fechar: as regras (docs/51) permitem criar `friendships/{menor}_{maior}` quando existe o pedido do outro e o mesmo batch/transação apaga os dois pedidos (`!existsAfter` dos dois), com o nome do outro lado vindo do `fromName` do pedido inverso. Basta o ramo `incomingRequest` ler o documento (já é lido) e executar o payload "aceitar" (batch: create friendship + delete inverso). Não precisa de mudança de regras/índices.
- Critério de aceite da fatia 3 sugerido: teste "enviar com inverso existente vira amizade e não sobra pedido" + atualizar texto (🟡-2).

### (4) Cota / leituras
Ver 🟢-1 (+1/+2 leituras por sessão; aceitável, com alternativa barata). Lista de enviados: paginação por cursor com 1 documento de olhada adiante, sem listener, TTL 5 min em memória, lista vinda do aparelho não conta como fresca (teste). Abrir `/friends/add` lê 0 (rota irmã, confirmado). Cada busca 1, cada envio 3 (`count` + 2 `get`). Limite de 50: 🟢-4. Fora o 🟡-1, o cache não invalida em Desativar.

### (5) UI / UX / acessibilidade: OK pelos testes de widget (não vi em navegador/leitor de tela)
- `/friends`: esqueleto de 3 linhas, vazio explicativo, erro com "Tentar de novo", faixa offline, cancelar com confirmação (foco em "Manter pedido"), "Cancelando...", "Ver mais". `/friends/add`: foco inicial, validação em tempo real, Enter busca, cartão, estados já enviado/inverso/limite/recusa, altura mínima fixa (teste de layout shift). Rótulos semânticos começam pelo texto visível ("Cancelar pedido para X", "Enviar pedido para @h"). Alvos 48 px. Testes 320-1440 px, fonte 1x/2x/3x, claro/escuro, barra mobile a 320 px e menu desktop 769-1024 px sem overflow (`friends_navigation_test`).
- Redirect: `/profile`, `/friends`, `/friends/*` deslogado -> `/`; sessão carregando não redireciona; sem social: convite "Ir para o Perfil". Perfil permanece selecionado em `/friends` e `/friends/add`. Deep link cai no `SocialGate`.

### (6) Exportação / exclusão / textos
`requestsSent` já estava no schema 2 (slice 1); o teste novo prova que o leitor lê exatamente o documento gravado (uid + apelido do destinatário, sem foto). `AccountDeleter` varre pedidos enviados e recebidos; teste envia pelo app, exclui e confirma zero resíduo e que pedidos de terceiros ficam. `socialCleanup:{uid}` é limpo ao concluir a exclusão (corrige o 🟢 do docs/58). Política/README/diálogos coerentes entre si, exceto o cruzado (🟡-2). Sem PII em logs.

### (7) Regressões
analyze 0, 1088 testes passam, build ok. Nenhum teste antigo modificado (só adições em golden e no fake). Ativação/desativação (fatia 1) passam; o refactor `_executePlanned` preserva a ordem (transação lê -> aplica; batch depois), com teste que trava 2 `runTransaction(`, 1 `.batch()` e nenhum `.set/.update(_handle(...))` fora dos payloads. Única regressão funcional encontrada: 🟡-1.

### (8) Testes que passam por motivo errado / lacunas
- Mutações mentais: o teste "SAME answer" compara textos reais e o estado; o de "opening reads NOTHING" usa `readLog` do fake (falharia se a rota virasse filha); o de TTL usa contagem de `sent:page`. Bons.
- Lacuna única relevante: nenhum teste cobre Desativar -> Ativar com a lista carregada (origem do 🟡-1).
- Limitação conhecida: o executor `FirestoreSocialDataSource` só roda em fakes (o replay valida payloads/regras, não o SDK).

## Resumo
REPROVADO por 2 🟡 pequenos: (1) invalidar `sentRequestsControllerProvider` ao desativar/concluir limpeza (+ teste); (2) alinhar política/README com D4 (pedido cruzado vira amizade) ou registrar como aceite da fatia 3. Depois disso, nada mais bloqueia: contrato, privacidade, cota e a11y estão corretos. Reenviar para novo gate após a correção.
