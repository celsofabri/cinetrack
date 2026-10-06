# 65 - Amizades, fatia 4: bloquear, aba Bloqueados e desbloquear

> Autor: Dev FE/BE · Base: [docs/49](./49-especificacao-amizades.md) (fatiamento 4), [docs/50](./50-design-amizades.md) §8, §9, §12, §13, [docs/51](./51-regras-sociais-fatia-0.md), [docs/62](./62-social-fatia-3-implementacao.md), [docs/64](./64-conferencia-final-social-fatia-3.md). **`firestore.rules`, `firestore.indexes.json` e os testes de regras existentes não foram alterados** (`git diff` vazio nos três). Só `dart_payloads.test.mjs` foi ESTENDIDO (+42 testes), o fixture ganhou entradas (só inserções) e `mutations.mjs` ganhou 11 mutações. Convite por link, refresh de foto/apelido nos pares e "desativar social" além do que já existia (fatia 5) não foram tocados. Nada foi commitado.

## Fechamento das 3 pendências 🟢 do docs/64

### (a) Teste do ramo cruzado REAL (teto de 300)
- **Costura testável** em `FirestoreSocialDataSource`: dois parâmetros opcionais `executor` (`SocialExecutor`: roda um `SocialWrite` do jeito que o `mode` manda; recebe o `check` das leituras da transação com `SocialSnapshot = ({exists, data})`, sem tipos do Firestore) e `countReader` (`SocialCountReader`: roda o `count()` de um `SocialQuerySpec`). O `FirebaseFirestore` passou a ser obtido de forma preguiçosa (`firestore ?? FirebaseFirestore.instance`), então com as duas costuras injetadas a classe nunca toca o Firebase. Sem as costuras o comportamento é o de antes (o executor padrão é o mesmo código que existia).
- **Teste** `test/firestore_social_data_source_test.dart` roda a classe REAL: (1) 300 amigos + pedido dele: `friendsLimit`, **nada** criado, o pedido dele continua, só a transação de leitura passou (não aplicada); (2) 299: vira o 300º, **um** batch com exatamente o payload de `acceptRequest`, os dois pedidos somem; (3) o `count()` só é lido no ramo cruzado (pedido normal com 300 amigos não paga leitura); (4) pedido meu já existente: `alreadySent`, sem `count()`; (5) pedido dele sem nome: negado, nada gravado. Também trava `blockUser` (UM batch, sem leitura, payload exato) e `unblockUser`.
- **Prova por mutação** (feita à mão, em cópia do arquivo restaurado depois): trocar `if (await _count(...) >= kMaxFriends)` por `if (false)` quebra o teste "300 friends: nothing is created..." (1 falha, 6 passam). O `git diff` do arquivo voltou ao esperado.

### (b) "Atualizar" sem aviso no cooldown de 15 s
- `PagedListController.refresh()` agora devolve `Future<bool>`: `false` quando ignorou o toque por causa do cooldown. As três abas (Amigos, Pedidos recebidos, Bloqueados) mostram o `SnackBar` **"A lista já está atualizada (atualizada há instantes)."** (`kListJustRefreshedMessage`); SnackBar é região viva, então o leitor de tela anuncia. Fora do cooldown lê de novo e não mostra nada.
- Testes (`friends_slice4_screens_test.dart`, grupo "Atualizar never looks broken"): dentro do cooldown não lê e diz; passados 16 s lê e a mensagem não aparece; o mesmo nas abas Pedidos e Bloqueados; a mensagem está na árvore de semântica. Mutação (remover o `showSnackBar`) derruba 3 testes.

### (c) docs/62
A linha do "Mensagem genérica de aceite" agora diz que o pedido cruzado confere o mesmo teto (1 `count()` extra só nesse ramo) e remete a este documento e ao docs/64; deixou de contradizer a linha das correções.

## Dados (toda escrita/consulta por `SocialPayloads`, golden e replay)
- **`blockUser(uid, BlockDraft)`**: UM batch com `set users/{eu}/blocks/{outro}` (`blockedName?`, `blockedPhoto?`, `createdAt` = servidor) + `delete friendships/{par}` + `delete friend_requests/{eu}_{outro}` + `delete friend_requests/{outro}_{eu}`. **Os três deletes vão sempre**, existam ou não: as regras aceitam apagar o que não existe quando o id contém o meu uid, e `existsAfter` na criação do bloqueio exige que nenhum dos três exista no fim. Assim **bloquear custa 0 leituras** e cobre sem ramificação os 6 estados (nada, só amizade, só recebido, só enviado, os dois pedidos, tudo). Nome e foto são instantâneos opcionais do cartão que o usuário já viu (amigo, pedido recebido ou resultado da busca); nome que não passa na validação das regras (`SocialNickname.normalize`) e foto fora do host do Google são **omitidos**, nunca enviados (a lista mostra "Usuário").
- **`unblockUser`** (1 delete do bloqueio), **`blocksQuery`** (`users/{eu}/blocks`, `orderBy createdAt desc`, índice automático de campo único) e `readBlockedPage` (paginada com `startAfterDocument`, como as outras listas; sem listener).
- `FirestoreSocialDataSource` ganhou `blockUser`, `unblockUser`, `readBlockedPage`; o executor segue escolhendo transação/batch só por `write.mode` (continuam 2 `runTransaction(` e 1 `.batch()`; teste trava).
- Repositório: `blockUser` (negação das regras vira o genérico `SocialFailureKind.notBlocked`: "Não foi possível bloquear agora. Atualizamos as listas; confira e tente de novo."; bloquear a si mesmo nem chega ao servidor), `unblockUser`, `blockedUsers` (nome limpo, "Usuário" sem nome, foto sanitizada).
- **Bloquear duas vezes**: o segundo `set` num documento existente é um *update*, que as regras negam. O app trata como `notBlocked` e **relê** as listas já carregadas (a pessoa já estará em Bloqueados).

### Confirmado nas regras e provado no emulador (replay do fixture)
`dart_payloads.test.mjs` (283 -> **325** testes) executa os payloads do fixture (`blockUser`, `blockUser_with_photo`, `blockUser_bare`, `unblockUser`, `requestQueries.blocked`):
- Os 3 payloads x os 6 estados: aceitos; depois não há amizade nem pedido em nenhum sentido (18 testes); o outro lado da amizade também pode bloquear.
- **Sem o batch correto é NEGADO**: cada delete faltando quando o documento existe (par, enviado, recebido) e o `set` sozinho com relações existentes; nada é criado. Um `set` sozinho **é aceito** quando nada existe (comportamento correto das regras, documentado).
- Bloquear a si mesmo (negado), duas vezes (negado, o primeiro intacto), usuário **sem social** e sessão **não-Google** (aceitos: o bloqueio é só meu e as regras não exigem Google/social nele; o app só oferece a ação a quem tem social), terceiro/anônimo criando sob o meu uid (negado), limites de campo (campo extra, nome vazio/41/zero-width, foto fora do Google, relógio do cliente, sem `createdAt`; 20 emoji passa), uid com `_`.
- Desbloquear: o dono apaga e **nada volta**; inexistente e repetido são aceitos; apagar o bloqueio **de outra pessoa** (existente ou não) e o bloqueado apagar o bloqueio contra ele são negados; depois de desbloquear dá para pedir de novo.
- Lista: só os MEUS bloqueios, mais recente primeiro, `startAfter`; o bloqueado, terceiros e anônimo **não** rodam a consulta nem leem o documento; as listas de amizade/recebidos/enviados dos dois ficam vazias.
- Efeito nas outras operações: o bloqueado enviar pedido ao bloqueador (negado, nada criado) e o bloqueador ao bloqueado (negado); aceitar o pedido de quem bloqueei (o pedido foi apagado; negado mesmo se recriado); pedido cruzado entre bloqueados (negado); **busca**: o cartão de quem me bloqueou dá `permission-denied` **igual** ao cartão oculto e só o handle inexistente difere (o app mostra a mesma mensagem nos três); desbloquear reabre a busca nos dois sentidos; a varredura de desativar/excluir apaga bloqueios reais.
- **Orçamento de chamadas das regras**: bloquear usa 3 `existsAfter` (limite 10 por operação, 20 por batch). Registrado no emulador: 1, 3, 6 e 7 pessoas em um único batch passam (`block N in one batch (emulator)`); o app bloqueia **uma por batch**.

### Mutações (`npm run test:mutations`: 37 mortas, 0 sobreviventes)
As 26 anteriores + **7 nas regras** (M27 o bloqueado lê o bloqueio, M28/M29 bloquear sem exigir apagar o pedido recebido/enviado, M30 terceiro desbloqueia, M31 auto-bloqueio, M32 bloquear duas vezes, M33 nome sem validação) + **4 nos payloads** (F1 bloquear sem apagar a amizade, F2 sem apagar o pedido enviado, F3 sem apagar o pedido recebido, F4 bloqueio gravado no uid do outro): as F usam uma cópia quebrada do fixture (`FIXTURE_PATH`) repetida contra as regras reais.

## Camada de aplicação
- `BlockedController` (lista paginada, TTL de 5 min, geração, `busy`/`blocking`), `FriendsController.block`, `ReceivedRequestsController.blockSender`, `BlockedController.blockPerson` (resultado da busca) e `afterBlock(...)`: no sucesso a pessoa sai de Amigos, Recebidos e Enviados (sem leitura), o **indicador** cai em 1 se o pedido estava na lista (ou fica **invalidado** quando a lista de recebidos nunca foi carregada: a próxima tela que mostra o contador faz 1 `count()`, em vez de adivinhar) e a pessoa entra no topo de Bloqueados. Se a falha deixa o resultado incerto (`notBlocked`, `uncertain`), as listas **já carregadas** são lidas de novo. A ação só termina na confirmação do servidor ("Bloqueando..." antes; a pessoa não some antes).
- **Sem vazamento entre contas**: tudo observa `currentUidProvider` e `socialPeriodProvider` (como as outras listas); `block`/`blockSender`/`blockPerson` capturam a geração e **não tocam em nada** se a conta/período mudou durante a operação (teste: Ana bloqueia, sai, Bruno entra e abre os dele; a resposta tardia de Ana não aparece em Bruno; mutação que remove a guarda derruba o teste). Desativar/reativar zera a lista de bloqueados.

## UI
- `/friends`: **Amigos | Pedidos | Bloqueados** (`?tab=bloqueados`; `context.replace` ao trocar; deep link com a tela aberta). Setas esquerda/direita (e cima/baixo), **Home/End** movem foco e seleção, cíclico; só a aba selecionada entra no Tab; ≥ 48 px; empilha em largura total quando os três rótulos não cabem lado a lado (fonte grande em tela estreita). O número do indicador continua só em "Pedidos".
- **Bloquear**: botão no cartão do amigo (ao lado de "Remover amizade", `Wrap`), no cartão do pedido recebido (ao lado de Aceitar/Recusar) e no cartão do resultado da busca. Diálogo (`block_dialogs.dart`): "Bloquear X?" com a lista do que acontece (desfaz a amizade; cancela os pedidos pendentes nos dois sentidos; **a pessoa não é avisada**; ela não encontra mais você na busca nem envia pedidos) e "você pode desbloquear depois, mas a amizade não volta"; foco inicial em "Cancelar", Esc fecha. "Bloqueando..." com os outros botões do cartão travados; SnackBar "Pessoa bloqueada. Ela não foi avisada." ou a falha genérica. Offline: desabilitado (escrita social exige servidor). Na busca, o cartão vira "Pessoa bloqueada. Ela não foi avisada e não encontra mais você na busca." + "Ver bloqueados"; buscar de novo dá "Não encontramos ninguém com esse apelido".
- **Aba Bloqueados**: "Pessoas bloqueadas" + "Atualizar"; esqueleto de 3 linhas (nunca "vazio" falso), erro com "Tentar de novo", faixa offline (lista do aparelho; Desbloquear desabilitado), "Ver mais" a cada 20, vazio que explica ("Você não bloqueou ninguém... Só você vê esta lista"), cartão com foto/iniciais, apelido guardado, "Bloqueado em dd/mm/aaaa" e **Desbloquear** (confirmação leve: "A amizade e os pedidos de antes não voltam. Ela não será avisada."; "Desbloqueando..."; SnackBar "Pessoa desbloqueada. A amizade não foi restaurada.").
- Rótulos semânticos começam pelo texto visível ("Bloquear Bruno", "Bloqueando Bruno", "Desbloquear Bruno"). Sem login `/friends*` redireciona para `/`; sem social ativado o `SocialGate` convida a ativar no Perfil e a aba nem aparece.

## Privacidade: o que o bloqueado percebe
| O que a pessoa bloqueada vê/faz | Resultado | Distinguível de outra causa? |
|---|---|---|
| Lista de amigos | A amizade some (na próxima leitura; em memória até 5 min ou "Atualizar") | **Inevitável**; igual a "removeu a amizade" |
| Pedido que ela enviou | Some de "Enviados" | Igual a recusa/cancelamento (recusa já é silenciosa) |
| Pedido que ela recebeu de você | Some de "Recebidos" | Igual a cancelamento |
| Aceitar um pedido antigo (tela velha) | "Não foi possível aceitar... pode ter sido cancelado" | Igual a pedido cancelado |
| Buscar seu identificador | "Não encontramos ninguém com esse apelido" | Igual a inexistente/oculto |
| Enviar pedido | "Não foi possível enviar o pedido..." | Igual a oculto, sem social, já amigos |
| Ler o seu bloqueio | `permission-denied` | Só você lê `users/{você}/blocks` |
| Notificação | Nenhuma | - |
Limite técnico (aceito, docs/50 §4): quem inspeciona a rede distingue "handle inexistente" de "existe e foi negado" (revela que o identificador está ocupado, o que a checagem de disponibilidade já revela); **bloqueado e oculto dão o mesmo `permission-denied`** (provado no replay).
**Dado guardado**: `users/{você}/blocks/{uid}` com apelido e foto como estavam no cartão que você viu + data, **legível só por você**. A pessoa bloqueada **não fica com nenhum dado seu exposto** por causa do bloqueio. Se ela apagar a conta, o apelido que você guardou segue só no seu registro até você desbloquear ou desativar/excluir (o mesmo órfão inofensivo do docs/49); documentado na política.
- `web/privacidade.html`: tabela de dados, tópico "Bloquear e desbloquear" (efeitos, sem aviso, desbloquear não restaura, quem vê o registro) e texto do resumo do app (`privacy_summary.dart`). **A data "Última atualização" e o comentário `<!-- ATUALIZAR ... -->` ficaram como estavam** (o Orquestrador a atualiza na publicação). README atualizado (fatia 4, testes).
- **Exportação**: a seção `social.blocks` (uid e apelido; sem foto) já existia; o schema **não mudou** (`kExportSchemaVersion` = 2). Teste novo lê um bloqueio escrito pelo payload real do app e um documento antigo (só `createdAt`, ou só nome): ambos legíveis.
- **Desativar e excluir conta** já varriam bloqueios: testes novos com bloqueios criados pelo repositório (`deactivate`, `wipeForAccountDeletion`, `AccountController.deleteAccount`); o bloqueio que OUTRA pessoa fez contra mim continua dele.

## Cota por tela (docs/50 §9; valores com ≈ são estimativa, **não medidos em produção**)
| Tela / ação | Leituras | Regra | Escritas | Deletes |
|---|---|---|---|---|
| Abrir Bloqueados, a frio (B bloqueios) | máx(1, min(B, 21)) (página de 20 + 1 de olhar adiante) | 0 | 0 | 0 |
| Reabrir dentro do TTL de 5 min / voltar de outra aba | 0 (memória) | 0 | 0 | 0 |
| "Atualizar" (fora do cooldown de 15 s) / dentro | min(B, 21) / **0** | 0 | 0 | 0 |
| "Ver mais" | até 21 | 0 | 0 | 0 |
| **Bloquear** (amigo, pedido ou busca) | **0** | ≈ **3** (`existsAfter`; limite 10/op e 20/batch: **folga**) | 1 | até 3 (os que não existem podem ser cobrados mesmo assim: não medido) |
| Depois de bloquear, lista de recebidos não carregada | +1 `count()` na próxima exibição do indicador | 0 | 0 | 0 |
| Bloquear que falha de forma incerta | + releitura só das listas já carregadas (raro) | 0 | 0 | 0 |
| **Desbloquear** | 0 | 0 | 0 | 1 |
| Abrir Amigos / Pedidos | inalterado (a aba Bloqueados **não** é lida) | - | - | - |
Sem listener amplo; a única consulta nova é a página de bloqueados.

## Compatibilidade e rollout
- Quem não ativou as amizades: nada muda (a aba/ações só existem dentro do `SocialGate`; teste). Nenhuma regra nova: o app novo funciona com as regras finais já publicadas; **com regras antigas** bloquear falha de forma visível ("Não foi possível bloquear agora...") sem perder nada (teste `rulesLive = false`). Documentos de bloqueio antigos (sem nome/foto) aparecem como "Usuário". Índice: o da lista é automático (campo único), nada a publicar. Rollback do app é seguro (os bloqueios ficam e são ignorados); **nunca voltar as regras**.

## Testes e resultados (rodados por mim)
- `flutter analyze`: 0 problemas. `flutter test`: **1343** passaram, 0 falhas (os 1228 anteriores + 115 novos). `flutter build web --release`: ok. `npm test` (regras, emulador): **325/325**. `npm run test:mutations`: **37/37 mortas**.
- Novos: `test/firestore_social_data_source_test.dart` (7), `test/social_block_test.dart` (45: bloquear em cada estado, sem leitura, efeitos no bloqueado, desbloquear, lista, deactivate/exclusão/exportação, controladores, vazamento entre contas), `test/friends_slice4_screens_test.dart` (64: aba, estados, diálogos, teclado/semântica, 320 a 1440 px x 1x/2x/3x x claro/escuro, "Atualizar"), golden com 4 cenários + a consulta, replay (+42).
- **Ajustes em testes antigos (justificados)**: `friends_slice3_screens_test.dart` assumia duas abas (ciclo das setas voltava de "Pedidos" para "Amigos", `FriendsTab` de 2 valores, 2 nós de foco, 48 px para "Amigos"/"Pedidos"): agora são três abas, o teste cobre o ciclo completo e inclui "Bloqueados". `friends_screens_test.dart` afirmava que "Bloqueados" não aparecia na tela (placeholder da fatia 2): agora é uma aba real; o teste afirma só o rótulo da aba e que a lista não é desenhada na aba Pedidos. Nenhum outro teste mudou.
- Mutações à mão nos testes Dart: guarda de geração em `block` (derrubada pelo teste de troca de conta), `dropLocal` do amigo em `afterBlock` (derrubado pelo teste de bloqueio via busca), `showSnackBar` do cooldown (3 testes), `if (false)` no teto do cruzado (1 teste).

## Correções do code review (docs/66)
- **🟡-1 corrida na busca**: `_block` e `_sendRequest` (`add_friend_screen.dart`) só aplicam o resultado ao cartão se `_card?.uid` ainda é o da pessoa da operação; o SnackBar continua (é verdadeiro sobre a pessoa original). Testes de corrida (bloqueio de Bruno em voo + busca de Caio; pedido a Bruno em voo + busca de Caio: o cartão do Caio mantém "Enviar pedido" e nada o marca). Mutação (guarda trocada por `if (true)`) derruba os 2 testes.
- 🟢 releitura dupla em `uncertain`: `afterBlock` pula a lista própria (`runFor` já a relê); teste: 1 leitura da própria e 1 de cada outra. 🟢 chave ocupada: `block`/`blockSender` devolvem `kBusyFailure` (nunca sucesso); teste. 🟢 `invalidate()` só quando a pessoa pode ter pedido (pedido recebido/busca), não ao bloquear amigo; teste (0 `count()`). 🟢 SnackBar do cooldown: `clearSnackBars()` antes; teste de 3 toques sem fila. 🟢 vírgula em `privacidade.html`. 🟢 nome/foto mostrados logo após bloquear passam pelo mesmo normalizador da lista; teste. 🟢 diálogo de desativar: "Os bloqueios também são apagados: quem você bloqueou poderá encontrar você de novo." (teste em `social_section_test.dart`, expectativa de `bloqueios` passou de 1 para 2 ocorrências, justificado).
- Final: analyze 0; `flutter test` 1343; build web ok; `npm test` 325/325; mutações 37/37.

## Riscos / não verificado
- **Não verificado**: Firestore real (cobrança das leituras de regra e de deletes em documentos inexistentes; `existsAfter` em batch); o executor padrão do `FirestoreSocialDataSource` contra o emulador via Dart (as costuras testam a lógica da classe, o replay `.mjs` testa as regras com os mesmos payloads); aparência real em navegador/dispositivo (só `flutter test` em 320 a 1440 px e fonte 3x, e `flutter build web`); leitor de tela real; comportamento do `SnackBar` com leitores de tela.
- Corrida de dois aparelhos bloqueando a mesma pessoa: o segundo é negado (`notBlocked`, relê as listas): sem dano.
- A lista de bloqueados não tem teto (paginada de 20 em 20); o custo é só de quem bloqueia muitas pessoas.
- O bloqueado continua vendo a amizade na memória do app até 5 min ou "Atualizar" (sem listener, por cota).

## Arquivos
`lib/data/{social_payloads,social_data_source,firestore_social_data_source}.dart`, `lib/social/social_models.dart`, `lib/repositories/social_repository.dart`, `lib/providers/{social_lists_providers,social_providers}.dart`, `lib/screens/{friends_screen,add_friend_screen}.dart`, `lib/widgets/{block_dialogs,privacy_summary}.dart`, `web/privacidade.html`, `README.md`, `docs/62` (linha 13), `firestore_rules_test/{dart_payloads.test.mjs,mutations.mjs,fixtures/social_payloads.json}`, testes listados acima e `test/support/fake_social_cloud.dart`.
