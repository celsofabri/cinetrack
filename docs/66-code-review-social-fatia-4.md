# 66 - Code review: Amizades, fatia 4 (bloquear, aba Bloqueados, desbloquear)

> Revisor: Code Reviewer (gate). Escopo: working tree NÃO commitado sobre `e8c84eb` (branch `feat/social-friends`). Somente leitura; mutações extras só em cópias no scratchpad; `git status` idêntico antes e depois (25 entradas). Base: ADR-005, docs/49, 50, 51, 62, 64, 65.

## Veredito: **REPROVADO** (1 🟡; nenhum 🔴). O Manager exige APROVADO limpo, então a correção abaixo é pequena e obrigatória; o resto está sólido.

## Números rodados por mim
| Verificação | Resultado |
|---|---|
| `flutter analyze` | 0 problemas |
| `flutter test` | **1336** passaram, 0 falhas |
| `flutter build web --release` | ok |
| `firestore_rules_test` `npm test` (emulador) | **325/325** (0 falhas) |
| `npm run test:mutations` | **37/37 mortas**, 0 sobreviventes (M27 a M33 e F1 a F4 incluídas) |
| `git diff` de `firestore.rules`, `firestore.indexes.json` | vazio; testes de regras existentes: só inserções (o único `-` em `dart_payloads.test.mjs` é o import e o `FIXTURE_PATH`, para a harness de mutação) |
| Chrome / aparência real | **Não verificado** (o app exige login Google; só `flutter test` e build) |

## (1) Contrato Dart x regras: ok
- `blockUser` (`social_payloads.dart`): `set users/{eu}/blocks/{outro}` com `blockedName?`, `blockedPhoto?`, `createdAt` = servidor + 3 deletes. Confere campo a campo com `firestore.rules:216-229` (`hasOnly(['blockedName','blockedPhoto','createdAt'])`, `createdAt == request.time`, nome por `validName`, foto por `validPhoto`, `validUid`, `!= uid`, 3 `existsAfter`). Nulos são omitidos (não enviados como `null`). Modo `batch`, sem `reads`.
- Deletes "no escuro": `friend_requests` (regra linha ~163) e `friendships` (~203) aceitam `resource == null` quando o id contém o meu uid. O replay (`dart_payloads.test.mjs`, 3 payloads x 6 estados = 18 testes) prova aceitação nos 6 estados (nada, só amizade, só recebido, só enviado, os dois, tudo) e que depois não resta amizade nem pedido. Prova também que sem o batch correto é NEGADO (cada delete faltando quando o doc existe; `set` sozinho com relações existentes) e que nada é criado numa negativa. O `.mjs` lê o fixture, que o golden Dart (`social_payloads_golden_test.dart`) trava contra o código Dart: nada copiado à mão.
- Mutações extras minhas (cópias do fixture reexecutadas contra as regras reais, `FIXTURE_PATH`): X1 sem delete do par: 15 testes falham; X2 sem delete do pedido enviado: 14; X3 campos do bloqueio renomeados (`blockedName`->`nome`, `createdAt`->`created`): 35; X4 modo `batch`->`transaction`: 2 (assert do modo); X5 `createdAt` do cliente: 34. Todas mortas.
- Orçamento: 3 `existsAfter` por bloqueio (limite 10/op, 20/batch); o replay mede 1, 3, 6 e 7 bloqueios num batch. App bloqueia 1 por batch. Folga confirmada.

## (2) Segurança e privacidade: ok, com a ressalva da fatia
- Busca: `handles/{h}` `get` nega igual para oculto e bloqueado (`isBlockedEither`, `permission-denied`); `SocialRepository.search` converte `denied` em `SearchNotFound`, a mesma mensagem do handle inexistente; mesma 1 leitura. A diferença no nível de rede (inexistente x negado) é o limite aceito do docs/50 §4 e já documentado.
- Enviar pedido/aceitar: `validRequest` e `validFriendshipCreate` exigem `!isBlockedEither`; a UI mostra as mensagens genéricas já existentes (`notAccepted`, "não foi possível enviar").
- Dado do bloqueio: `allow read: if isOwner(uid)` (M27 morta: o bloqueado não lê); nome/foto só do dono. Exportação: já existia (`social.blocks`, uid e apelido, sem foto), teste novo com bloqueio real; não expõe a terceiros.
- Bloquear a si mesmo (regra e app), duas vezes (update negado, tratado como `notBlocked`), quem me bloqueou, sem social e não Google: cobertos no replay; nenhum vira oráculo (o bloqueio nunca falha por causa do estado do outro).
- Races: bloquear x aceitar (a regra do aceite lê o pedido, que o batch apaga; se o aceite vence, o batch apaga a amizade na sequência); bloquear x remover (delete de inexistente é aceito). Invariante "bloqueio => sem amizade nem pedido" mantida.
- O que o bloqueado percebe (amizade e pedido somem) é inevitável e está documentado (docs/65, política, README).
- Desbloquear: 1 delete, não restaura e não deixa rastro; "depois de desbloquear dá para pedir de novo" testado.

## (3) Estados e caches: ok
`afterBlock` tira a pessoa de Amigos, Recebidos e Enviados sem leitura, corrige o indicador (`adjust(-1)`, ou `invalidate()` quando a lista de recebidos não está carregada) e põe a pessoa no topo de Bloqueados. A guarda de geração em `block`/`blockSender`/`blockPerson` impede vazamento entre contas: a mutação `if (false)` nas guardas (4 ocorrências, feita por mim em cópia) derruba `social_block_test.dart` "an in-flight block of A touches nothing of B". Desativar/reativar/logout zeram a lista (`socialPeriodProvider`, `currentUidProvider`).

## (4) Costura do data source: ok
`executor`/`countReader` nulos em produção => mesmo código de antes (`_execute` default idêntico; `reads` ganhou o tipo `SocialSnapshot` com `exists`/`data`, equivalente a `snap.exists`/`snap.data()`). `FirebaseFirestore.instance` lazy: mesma instância. Nada de código de teste na build (só dois typedefs e dois parâmetros opcionais com `@visibleForTesting`). Mutação minha `if (await _count(...) >= kMaxFriends)` -> `if (false)`: derruba 1 teste (o dos 300 amigos), como o dev declarou.

## (5) UI e acessibilidade: ok (verificação só por teste/leitura)
Diálogo de bloquear: efeitos listados, `autofocus` em Cancelar, Esc fecha, texto rolável (fonte 3x). Aba Bloqueados com carregando (esqueleto), vazio explicativo, erro com "Tentar de novo", faixa offline. Desbloquear com confirmação e SnackBar honesto. Abas com setas, cima/baixo, Home/End, Tab só na aba selecionada, alvos de 48 px, empilha quando não cabe. Rótulos semânticos começam pelo texto visível.

## (6) Política, README, resumo: ok
`web/privacidade.html`, `privacy_summary.dart` e README dizem corretamente: efeitos, sem aviso, desbloquear não restaura, o que é guardado e que só o dono lê, exportação inclui bloqueios (uid e apelido, sem foto), apelido órfão se a pessoa apagar a conta. "Última atualização" não foi tocada (com o Orquestrador). `deactivate`/`wipeForAccountDeletion`/`deleteAccount` varrem bloqueios (testes com bloqueios reais).

## (7) Regressões e cota
Os 1228 anteriores seguem verdes. Os 2 testes ajustados (`friends_slice3_screens_test.dart` de 2 para 3 abas; `friends_screens_test.dart` não afirma mais a ausência de "Bloqueados") são legítimos: o comportamento antigo mudou por requisito. Diff sem churn de formatação nos arquivos de produção. Tabela de cota do docs/65 confere com o código (0 leituras para bloquear; +1 `count()` só quando a lista de recebidos não está carregada).

---

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes

### 🟡-1 Resposta tardia do bloqueio (e do envio) grava estado numa OUTRA pessoa na busca
- **Onde:** `lib/screens/add_friend_screen.dart:176-203` (`_block`); o mesmo padrão pré-existente em `_sendRequest` (linhas 147-171).
- **Cenário (reproduzido por mim num teste em cópia, `scratchpad/rc/test`):** a pessoa busca `@bruno`, toca "Bloquear", confirma (o servidor demora; o campo de texto NÃO fica desabilitado), digita e busca `@caio` e o cartão do Caio aparece com "Enviar pedido". Quando o bloqueio do Bruno termina, `_block` faz `setState(_send = _Send.blocked)` sem conferir se o cartão ainda é o do Bruno. Resultado medido: o cartão do **Caio** passa a dizer "Pessoa bloqueada. Ela não foi avisada e não encontra mais você na busca." e perde o botão "Enviar pedido" (0 botões), embora o Caio NÃO tenha sido bloqueado. Nenhum dado errado é gravado, mas é feedback falso (viola "feedback honesto") e esconde a ação até nova busca. Em falha o mesmo vazamento restaura `_send`/`_sendFailure` do cartão errado.
- **Correção (pequena):** depois do `await`, guardar pela identidade do cartão (e/ou `_generation`): `if (!mounted || _card?.uid != card.uid) return;` (ou capturar `final generation = _generation;` e comparar), mantendo o `SnackBar` (que é verdadeiro sobre o Bruno). Aplicar o mesmo em `_sendRequest`. Adicionar teste: bloqueio em voo (`writeGate`), outra busca, liberar o gate; esperar o cartão novo intacto e "Enviar pedido" presente. Alternativa mais simples: desabilitar o campo e o botão "Buscar" enquanto `_send` é `sending`/`blocking`.

## 🟢 Sugestões (não bloqueiam)
1. `lib/providers/social_lists_providers.dart:261-300` + `afterBlock` (581): num resultado `uncertain`, `runFor` já faz `await reload()` e `afterBlock` relê a mesma lista de novo (até 2 x 21 leituras; raro). Excluir a lista própria em `afterBlock` ou só recarregar no `notBlocked`.
2. `blockSender`/`block` (363/…): se `runFor` devolver `null` por a chave já estar `busy` (não acontece pela UI, que desabilita os botões), `afterBlock` trataria como sucesso e mostraria "Pessoa bloqueada" sem ter bloqueado. Defesa: devolver um sinal distinto ou checar `busy` antes.
3. `ReceivedRequestsController.dropBlocked` (390): ao bloquear um AMIGO com a lista de recebidos não carregada, `invalidate()` gera 1 `count()` desnecessário (amigo não tem pedido pendente, pelo invariante). Só invalidar quando a origem é pedido recebido ou busca. Pessoa com pedido além da 1a página: o indicador fica com 1 a mais até o TTL de 10 min (cosmético).
4. `afterBlock` -> `BlockedUser(name: name ...)` usa o nome cru do cartão, enquanto a lista relida usa o normalizado/"Usuário": pode haver diferença visual até o próximo reload (cosmético).
5. `_refreshWithFeedback` (`friends_screen.dart:511`): tocar várias vezes em "Atualizar" no cooldown enfileira vários SnackBars; usar `hideCurrentSnackBar()` antes.
6. `web/privacidade.html:41`: falta vírgula/"e" entre "(...e a data)" e "os bloqueios que você fizer".
7. Desativar as amizades apaga os bloqueios (por desenho, docs/49): vale uma linha no diálogo de desativar dizendo que quem você bloqueou poderá encontrá-lo de novo se reativar. Hoje a política só diz que os bloqueios são apagados.

## ❓ Perguntas
Nenhuma.

## Segurança: ok
Nenhum vazamento de bloqueio identificado (busca, envio, aceite, leitura do registro, exportação). Sem segredos (`.env` não lido). Único ponto aberto é o 🟡-1 (UI), sem efeito em dados.

## O que o Dev precisa fazer para APROVAR
Corrigir o 🟡-1 (guarda após o `await` em `_block`, idem `_sendRequest`) com o teste de corrida. As 🟢 ficam a critério (recomendo 1, 2 e 5 por serem de uma linha). Não precisa de novo review completo: re-review focado em `add_friend_screen.dart` e no teste novo.
