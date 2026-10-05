# 51 - Regras sociais FINAIS da Fase 1 (Fatia 0): regras, índices e testes

> Autor: Dev BE + QA de regras · Data: 2026-10-05 · Entrada: [docs/49](./49-especificacao-amizades.md), [docs/50](./50-design-amizades.md) (contrato + "Decisões do Manager"), [ADR-005](./adr/adr-005-modelo-social-amizades.md) (Aceita).
> Escopo: **só** `firestore.rules`, `firestore.indexes.json` e testes de regras. Nenhum código Dart/UI. Branch `feat/social-friends`.
> **As regras abaixo serão publicadas UMA vez, antes do app, e não podem voltar atrás.** Por isso incluem desde já o convite por link (Fatia 5), desativar o social e o refresh de foto/apelido nos pares.

## 1. O que mudou (diff)
`git diff firestore.rules`: **+284 linhas, 0 removidas**. Tudo o que existia (`isOwner`, `validProfile`, `validFavorite`, `users/{uid}`, `favorites/*`, o `match /{document=**}` final) está **byte a byte igual**; o bloco novo entra antes do "deny all". `firestore.indexes.json`: +2 índices. `package.json`: script `test:mutations`.

| Coleção / função | Acesso | Resumo |
|---|---|---|
| `isFriend(a, b)` | função | `a != b && exists(friendships/par)`: **1** chamada |
| `isBlocked(a, b)` / `isBlockedEither` | função | "a bloqueou b": **1** chamada (2 no `Either`) |
| `friend_requests/{de}_{para}` | get/list: remetente e destinatário; create: remetente; update: nunca; delete: os dois | pedido direcional imutável |
| `friendships/{menor}_{maior}` | get/list: membros; create: só com o pedido do outro lado consumido no batch; update: só a própria metade; delete: qualquer membro | 1 doc por par |
| `users/{uid}/blocks/{b}` | só o dono lê/cria/apaga; criar exige par e pedidos apagados no mesmo batch | bloqueio |
| `handles/{h}` | get exato (sem list); create/update/delete pelo dono com ponteiro | reserva + cartão de busca |
| `social/{uid}` | só o dono | ativação + ponteiros (`handle`, `inviteCode`) |
| `invites/{code}` | get exato (sem list); create/update/delete pelo dono com ponteiro | **novo**: convite por link |

Invariantes garantidas pelas regras: um lado não cria amizade sozinho; **amigo ⇒ não bloqueado** (bloqueio só nasce se o mesmo batch desfez par e pedidos, e par/pedido não nascem com bloqueio em nenhum sentido); pedido cruzado completa; troca de handle a cada 30 dias; handle único por reserva (criar sobre existente é `update`, negado a outro); 1 handle e 1 convite ativos por usuário (ponteiros em `social/{uid}`); desativar/excluir só com handle e convite liberados no mesmo batch; "Aparecer na busca" (`discoverable`).

## 2. O que foi acrescentado além do docs/50
Cada item foi pedido pela instrução ou fecha uma brecha encontrada ao revisar o trecho do docs/50. Todos têm teste e (quando crítico) mutação.

1. **Convite por link, revogável (Fatia 5)** `invites/{code}`. Projeto:
   - Código = id do documento (segredo). Formato `^[A-Za-z0-9]{22,40}$`; o cliente gera com RNG seguro (≥ 22 caracteres base62 ≈ 131 bits). **As regras só impõem formato e tamanho, não entropia.**
   - Só `get` por id; `list` negado (sem enumeração). Inexistente/revogado = "não existe"; expirado ou de quem bloqueou/foi bloqueado = `permission-denied` (o app mostra a mesma mensagem). O dono sempre lê o próprio.
   - Campos: `uid` (= dono), `nickname`, `photoURL?` (só `lh<n>.googleusercontent.com`), `createdAt` (servidor), `expiresAt` (no futuro e **≤ 30 dias**). O dono pode renovar/atualizar o cartão (uid e `createdAt` imutáveis).
   - **1 convite ativo por usuário**: ponteiro opcional `social/{uid}.inviteCode`; criar, trocar (rotação) e revogar são batches `invite + social`. Sem isso um usuário criaria convites sem limite (cota do projeto).
   - **Revogar = apagar o documento**: efeito imediato. Revogar/rotacionar exige mover o ponteiro no mesmo batch (sem ponteiro pendurado nem convite órfão).
   - Usar o convite **não cria amizade**: revela o cartão (uid, apelido, foto) e o visitante envia um pedido normal; o dono ainda aceita (D12: oculto é alcançável por uid conhecido). Funciona com "Aparecer na busca" desligado.
   - Desativar o social exige apagar o convite junto (`social` delete checa `existsAfter(invite)`).
2. **Desativar social**: já estava em `social` delete; agora também cobre o convite.
3. **Refresh de foto/apelido nos pares**: `friendships` update (própria metade, já no docs/50) + `handles` update + `invites` update. Pedidos e bloqueios têm instantâneo imutável.
4. **Nome do outro lado não é forjável**: ao criar o par, a "metade" do outro tem de ser igual ao que **ele** gravou no pedido (`fromName`/`fromPhoto`). Usa `get()` no lugar do `exists()` do mesmo caminho: **custo igual** (7 chamadas).
5. **`validUid`**: uid sem `_` e `/` (1 a 128). Ids compostos `a_b` ficam sem ambiguidade (`a_b`+`c` × `a`+`b_c`). Aplicado em pedido (`from`/`to`), par (`members`), bloqueio (`blocked`) e `social` (dono): um uid fora do padrão nunca consegue ativar o social. Firebase com Google gera uids alfanuméricos, então nada muda para usuários reais.
6. **Delete no escuro só para ids próprios**: apagar pedido/par inexistente (o batch de bloquear apaga "no escuro") só é aceito se o id contém o uid de quem chama. Antes qualquer logado podia gastar a cota de deletes apagando ids inexistentes.
7. **`handleChangedAt` do pedido de troca**: exige `== request.time` apenas quando o handle muda; sem mudança, imutável (já no docs/50, agora com teste).

8. **Só login Google** (`isGoogle()`: `request.auth.token.firebase.sign_in_provider == 'google.com'`): exigido ao **criar** `social`, `handles`, `friend_requests`, `friendships` e `invites`. Impede squatting de handle e spam por contas anônimas ou e-mail/senha. O app atual só tem login Google, então nada muda para os usuários; token sem o claim é negado. Apagar/cancelar/desbloquear continua permitido a qualquer provedor (limpeza dos próprios dados). `social` e `handles` se protegem mutuamente (um não existe sem o outro), então a checagem de provedor é redundante em camadas de propósito.
9. **Reservados ampliados**: além dos 11 do docs/50, `staff, oficial, official, moderador, moderator, sistema, system, seguranca, security, privacidade, privacy, contato, contact, equipe, team, null, undefined, anonymous, anonimo, cine` (31 no total).
10. **Host da foto** restrito a `https://lh<dígitos>.googleusercontent.com/...` (formato real da foto do Google no Firebase Auth, ex.: `lh3.googleusercontent.com`). Antes aceitava qualquer subdomínio.
11. **`validName`** rejeita caracteres de controle (`\p{Cc}`, inclui quebra de linha e tab), zero-width (U+200B, U+200C, U+2060, U+FEFF), marcas bidi/RTL (U+200E/F, U+202A–202E, U+2066–2069, U+061C) e separadores de linha/parágrafo (U+2028/9), por RE2 `matches` (o RE2 do emulador aceitou as classes Unicode; **produção não verificada**). Aceita acentos, CJK, emoji e emoji com ZWJ (U+200D fica de fora de propósito). Vale para todo nome/apelido gravado (cartão, convite, pedido, par, bloqueio).
12. **Convite: geração do código (requisito da Fatia 5)**: `Random.secure()`, ≥ 22 caracteres base62, **nunca derivado de uid, hora ou contador**. As regras não conseguem checar entropia.

Resíduo inevitável de privacidade (aceito): **criar pedido para quem me bloqueou é negado, enquanto sem o bloqueio seria aceito**; quem conhece o uid de alguém consegue, por tentativa, inferir que foi bloqueado (o mesmo vale para ler cartão ou convite de quem bloqueou). Sem servidor não há como esconder isso nas regras. **Requisito para as Fatias 2 e 5: o app DEVE mostrar uma única mensagem genérica ("Não foi possível enviar") para qualquer negação ao criar pedido, ler cartão ou usar convite** (inexistente, oculto, bloqueado, expirado e `permission-denied` iguais). Registrado também em docs/49 e docs/50.
Também inerente: um usuário mal-intencionado pode gastar cota com `get`s em ids inexistentes (qualquer logado pode ler `handles/{h}` e `invites/{c}` inexistentes); não há como limitar sem servidor.

Limitações aceitas (documentadas, sem correção possível sem servidor):
- **Desativar e reativar contorna o intervalo de 30 dias** (o handle antigo é liberado na hora, decisão D2). O intervalo limita a troca, não impede a rotatividade.
- Sem contador no servidor: limites de 300 amigos e 50 pedidos são só do app. Quem tem `social` pode criar pedidos/bloqueios em volume (cada pedido exige que o destinatário tenha `social` e não tenha bloqueado). Mitigação: bloquear.
- `nickname`/`fromName` são texto livre (1–40): não há como impedir um apelido que imite outro (nem existe moderação sem servidor).
- Desativar o social **não** apaga amizades pelas regras (regras não iteram): o cliente varre pares/pedidos/bloqueios logo depois, como na exclusão da conta.

## 3. Orçamento de chamadas das regras (10 por requisição, 20 em batch)
Fonte do limite: [Structuring Cloud Firestore Security Rules](https://firebase.google.com/docs/firestore/security/rules-structure) (10 por requisição de documento único/consulta, 20 em leituras de vários documentos, transações e batches; chamadas em cache não contam), citada no ADR-005. Cobrança: [Firestore pricing](https://firebase.google.com/docs/firestore/pricing) ("você é cobrado pelas leituras necessárias para avaliar as regras").

**Verificado no emulador** (`rules_budget.test.mjs`, regras reais com coleções-sonda injetadas numa cópia):
| Fato | Resultado |
|---|---|
| `get` com 10 `exists()` distintos / 11 | passa / negado |
| mesmo caminho repetido 12× | passa (conta 1) |
| batch: 2 escritas × 7 chamadas / 3 × 7 (21) | passa / negado |
| **`isFriend` real**: 10 pares distintos / 11 | passa / negado ⇒ **custa 1 chamada** |
| **`isBlocked` real**: 10 distintos / 11 | passa / negado ⇒ **custa 1 chamada** |
| `isFriend` repetido 12× no mesmo par | passa (conta 1) |
| consulta `authorId in [N amigos]` com `isFriend(resource.data.authorId, me)` | N = 10, 11, 15, 20 passam; **21 e 30 negados**; um não amigo na lista nega a consulta toda |
| aceitar N pedidos num batch (par + 2 deletes cada) | N = 1, 3, 4 passam; **6 e 8 negados** |

O emulador deixou passar mais de 10 em consulta `in`; **regra de projeto: lotes de até 10 autores** (valor documentado). **Aceitar: 1 pedido por batch** (até 4 passou, mas o limite fica com folga).

Custo (chamadas) das operações reais, contado do texto das regras: criar pedido **5** (2 `social`, 2 bloqueios, 1 par) · criar par **7** (2 `social`, 2 bloqueios, 1 `get` do pedido, 2 `existsAfter`) · criar bloqueio **3** `existsAfter` · ativar 1–2 · trocar handle 2 (+2 se mexer no convite) · criar/revogar convite 1–2 · ler cartão 2 (`isBlockedEither`) · ler convite 2. Máx. por operação: 7 (≤ 10).

**Para F2–F5**: visibilidade = `isFriend(authorId, me)` apenas (1 chamada por documento/autor; "amigo ⇒ não bloqueado" dispensa `isBlocked`); autor sempre dentro do documento (`resource.data.authorId`), sem `get()` encadeado; consultas `authorId in [...]` em lotes de ≤ 10; escritas de F2–F5 com ≤ 3 chamadas por operação e ≤ 6 operações com chamadas por batch. Testado com coleções-sonda (não enviadas): leitura de amigo, estranho/ex-amigo/bloqueado negados, revogação imediata ao desfazer e ao bloquear, comentários Amigos/Privado.

## 4. Índices (`firestore.indexes.json`)
| Consulta | Índice |
|---|---|
| Recebidos: `friend_requests.where('to'==uid).orderBy('createdAt', desc)` | composto `to ASC, createdAt DESC` (**novo**) |
| Enviados: `friend_requests.where('from'==uid).orderBy('createdAt', desc)` | composto `from ASC, createdAt DESC` (**novo**) |
| Lista de amigos: `friendships.where('members', arrayContains: uid)` | automático (campo único) |
| Bloqueados: `users/{uid}/blocks.orderBy('createdAt')` | automático |
| Varredura da exclusão (`from==uid`, `to==uid`, `array-contains`, 400 por página, sem `orderBy`) | automáticos |
| Busca (`get handles/{h}`), convite (`get invites/{c}`), `social/{uid}` | só por id, sem índice |

O emulador **não exige índices**: nada aqui foi verificado contra o Firestore real. O Manager precisa criar os 2 compostos e esperar **Enabled** antes da primeira consulta do app.

## 5. Matriz de testes (`npm test`: 219 testes, todos passando)
Suíte existente (64, **sem edição**): `firestore.rules.test.mjs` + `recommended.test.mjs`. (O docs/50 cita 76; o repositório tem 64 nesta base. Todos passam contra as regras novas.)

| Arquivo | Testes | Cobre |
|---|---|---|
| `social.test.mjs` | 133 | ver abaixo |
| `rules_budget.test.mjs` | 13 | limites 10/11, batch 20/21, custo de `isFriend`/`isBlocked`, sondas F2–F5, aceitar N |
| `social_compat.test.mjs` | 9 | regras novas × documentos antigos; app novo × regras antigas `v1`/`v2` |

`social.test.mjs` por requisito:
- **Amizade só com o pedido do outro lado**: nenhum lado cria sozinho; remetente não confirma o próprio pedido; destinatário só se o batch consome o pedido (e o pedido inverso); terceiro não usa pedido alheio nem cria par de outros; pedido de outro par não vale; sem `social` em um lado nega; nome do outro lado forjado nega.
- **Leituras**: não amigo, terceiro e anônimo não leem pares, pedidos, `social`, bloqueios; `list` negado em `handles`, `invites`, `friend_requests` sem filtro.
- **Bloqueio nas duas direções**: cartão e convite escondidos nos dois sentidos; pedido e par negados; criar bloqueio exige apagar par, pedido de ida e de volta (3 omissões testadas); bloqueio no mesmo batch de pedido/par nega; o bloqueado não lê/apaga o bloqueio; desbloquear não restaura.
- **Pedido cruzado**: por batch, por transação, concorrente (2 transações cruzadas nunca deixam par + pedido), e dois pendentes coexistem e completam.
- **Schema e malícia**: campos extras, tipos errados, tamanhos (40/41, 512), foto fora de `googleusercontent.com`, uid forjado, `createdAt`/`updatedAt` forjado, id divergente, auto-pedido/auto-bloqueio, membros fora de ordem/3 membros, editar a metade do outro, apagar o doc do outro, uid com `_`.
- **Handle**: 3 transações concorrentes no mesmo handle, **só 1 vence**; 10 formatos inválidos; 2 handles para o mesmo usuário; troca com 29/1/0 dias nega e 31 passa; trocar sem liberar o antigo ou com `handleChangedAt` antigo nega; handle antigo reutilizável por outro; desativar só em batch.
- **Exclusão em sequência**: fecha a porta (handle+`social`), ninguém mais envia/aceita para o uid, varredura de pedidos/pares/bloqueios e a conta some da lista dos outros; handle livre na hora.
- **Revogação imediata**: ao desfazer e ao revogar o convite a leitura seguinte já falha/some.
- **Convite**: criar (inclusive junto da ativação); sem ponteiro nega; 1 por usuário e rotação; uso por outro usuário (sem list, anônimo nega); oculto continua alcançável; usar = pedido normal (nunca amizade direta); código inexistente/malformado; revogar (imediato, exige mover o ponteiro); expirar (negado a terceiros, dono lê); limites de `expiresAt` (passado, > 30 dias, tipo); renovar; **código alheio** (tomar, sobrescrever, estender, apagar, apontar o ponteiro para ele); schema; desativar com convite.
- **Favoritos nunca abertos a terceiros**: amigo, bloqueado, convidado, estranho e anônimo não leem, listam, criam, editam nem apagam `users/{uid}` nem `favorites/*` (`social.test.mjs` e `social_compat.test.mjs`); campos sociais em `users/{uid}` nega.
- **Endurecimento (revisão)**: provedor `anonymous`/`password`/`phone`/sem claim negados para ativar, pedir, criar convite e criar par, `google.com` aceito; provedor não Google ainda apaga os próprios pedidos/bloqueios; os 31 reservados negados (11 originais + 20 novos) e `staff_1`/`cine_fan` aceitos; apelido no limite (40 CJK, 20 emoji, 40 ASCII aceitos; +1 negado: `size()` conta unidades UTF-16); host da foto (`lh3`, `lh12` ok; `evil`, `lh`, `lh3x`, `drive`, sufixo falso, prefixo antes de `lh` como `https://evil.com/?https://lh3...`, `evil.com?lh3...` e `http://` negados); nomes com controle/zero-width/bidi negados (17 casos, no cartão e no pedido) e acentos/emoji/CJK/ZWJ aceitos.
- **Resíduo de bloqueio**: coberto como comportamento esperado (teste "block in either direction hides…"): a negação é `permission-denied` indistinguível de oculto/expirado; a mensagem única é requisito do app (acima).
- **Contrato de ordenação**: 56 pares de uids com dígitos/maiúsculas/minúsculas: a ordem `menor < maior` das regras coincide com a comparação ASCII do JS (o teste Dart equivalente continua a fazer na Fatia 1).

## 6. Mutações (`npm run test:mutations`)
O script remove **uma** checagem crítica de uma cópia das regras (em `tmp`; as regras reais não são tocadas), roda `social.test.mjs` + `social_compat.test.mjs` e exige falha. Resultado: **22 de 22 mortas** (cinco abaixo por exemplo; as demais no script).

| # | Mutação | Teste que quebra |
|---|---|---|
| M1 | par criado sem o pedido do outro lado (sem consentimento) | "neither side can create a friendship alone" e outros 5 |
| M4 | bloqueio sem exigir apagar o par | "block of a friend with pending requests…" |
| M5 | troca de handle sem o intervalo de 30 dias | "change within 30 days is denied" |
| M7 | convite expirado continua legível | "expiry: expired invite is denied to others" |
| M10 | `favorites` legível por amigos | "friend… see different results on favorites" e o teste de compat |
Também: M2 pedido não consumido, M3 pedido ignora bloqueio, M6 cartão sem ponteiro, M8 editar a metade do outro, M9 cartão oculto legível, M11 terceiro apaga pedido, M12 convite sem ponteiro, M13 uid com `_`, M14 bloqueio sem apagar pedidos, M15 qualquer provedor aceito, M16 pedido sem checagem Google, M17 convite sem checagem Google, M18 lista de reservados menor, M19 host da foto frouxo, M20 nomes com controle/bidi aceitos, M21 foto com prefixo antes de `lh` (regex sem âncora), M22 `admin` liberado. Mutações **R2/R3** (tirar `isGoogle()` só de `social` ou só de `handles`) **sobrevivem por redundância de desenho**: ativar exige `social` e `handles` no mesmo batch, e cada um checa o outro (`getAfter`); um sem o outro não existe, então basta um dos dois checar o provedor. Mantemos as duas checagens (defesa em profundidade); a mutação que tira **todas** (M15) é morta.

## 7. Passo a passo do console (Manager)
Ordem obrigatória (ver docs/50 §14). A Fase 1 será publicada inteira: **não existe app social até a Fatia 1**, então nada de smoke com 2 contas antes do app.
1. **Authentication**: console Firebase > Authentication > Método de login: deixar **somente Google** habilitado (desativar **Anônimo** e **E-mail/senha** se aparecerem). As regras já exigem `google.com`; isso evita contas de outros provedores no projeto.
2. **Exportar a própria conta** (Perfil > Exportar): *opcional, mas recomendado*. Serve de **cópia de segurança dos favoritos e do progresso** antes de qualquer mudança de regras; anote também os números do Perfil.
3. **Publicar `firestore.rules`**: console > Firestore Database > **Regras** > colar o conteúdo de `firestore.rules` > **Publicar** (ou `firebase deploy --only firestore:rules`). Em seguida, na mesma aba, conferir a **data/hora da publicação** e que o editor **não mostra erro**; a propagação leva até ~1 min. As regras são aditivas: o app atual continua igual.
   - **Se o console RECUSAR por erro de sintaxe** (suspeita principal: o `matches` com `\p{Cc}`/`\x{...}` em `validName`, aceito pelo emulador mas não verificado em produção): **NÃO publicar nada parcial** e avisar o Orquestrador. O conserto é publicar uma **versão corrigida das regras** (por exemplo, substituir a linha `&& !s.matches('(?s).*[...].*')` de `validName` por classes aceitas, ou trocar por uma lista de `matches` mais simples), **nunca voltar às regras antigas**.
4. **Criar os 2 índices**: `firebase deploy --only firestore:indexes` (se o prompt perguntar sobre índices existentes que não estão no arquivo, responder **não** para apagar) ou console > Firestore Database > **Índices** > **Compostos** > **Criar índice**: coleção `friend_requests`, `to` Crescente + `createdAt` Decrescente, escopo Coleção; repetir com `from`. Aguardar o **Status "Enabled"** na mesma tela (lista de índices compostos; pode levar minutos).
5. **Só então** o Orquestrador publica o app (Fatia 1 em diante).
6. **Smoke com 2 contas Google, DEPOIS do app no ar**: criar o perfil social com apelido com acento e emoji (ex.: "José 🎬"), buscar por handle, enviar pedido, aceitar; conferir o consumo de leituras no console. Isso detecta no mundo real se o RE2 de `validName` roda em produção.
**Nunca voltar as regras** depois que existir dado social; correções só para frente. Rollback seguro = só do app.

## 8. O que NÃO foi verificado
- **Nada contra um projeto Firebase real**: só Firestore Emulator. Produção pode divergir, em especial o limite de chamadas em consultas `in`, a cobrança das leituras de regra e o tratamento de `existsAfter`.
- Índices (o emulador não os exige) e o tempo até "Enabled".
- **Cobrança das leituras de regra** e consumo real de cota (50 mil leituras/dia).
- Entropia dos códigos de convite (as regras só validam formato; a geração segura é responsabilidade do cliente, a testar na Fatia 5).
- Código Dart, `SocialDataSource`, transações offline, abas simultâneas, texto jurídico/LGPD, comportamento com cota esgotada.
- Classes Unicode do RE2 em `validName` (`\p{Cc}`, `\x{...}`): aceitas pelo emulador; produção usa o mesmo RE2, mas não verifiquei.
- **Limitação aceita (apelidos invisíveis)**: apelido só de NBSP, U+3000 ou caracteres de tag (U+E0000–E007F) passa nas regras (testado como "known limit"); a normalização no cliente (NFC, remover invisíveis, `trim` Unicode) é requisito (docs/49 e docs/50).
- Data/relógio: os testes de 30 dias e expiração semeiam documentos com datas relativas à hora da máquina; assumem relógio do emulador igual ao da máquina.

## 9. Como rodar
```
cd firestore_rules_test && npm install
JAVA_HOME=/opt/homebrew/opt/openjdk@24 npm test           # 219 testes (existentes + sociais)
JAVA_HOME=/opt/homebrew/opt/openjdk@24 npm run test:mutations   # 22 mutações (ONLY=M5 para uma)
```
`RULES_PATH=/caminho/regras.rules` aponta `social.test.mjs`/`social_compat.test.mjs` para outro arquivo de regras. `fixtures/firestore.rules.v2` = regras de `main` antes do social (v1 = antes de `recommended`).
