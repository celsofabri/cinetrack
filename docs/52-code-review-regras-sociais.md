# 52 - Code review (gate) das regras sociais da Fatia 0

> Revisor: Code Reviewer, olhar de segurança de regras do Firestore · Data: 2026-10-05 · Branch `feat/social-friends` (mudanças não commitadas sobre `main` c60a393).
> Contrato: [ADR-005](./adr/adr-005-modelo-social-amizades.md), [docs/49](./49-especificacao-amizades.md), [docs/50](./50-design-amizades.md) (Decisões do Manager 2026-10-05), [docs/51](./51-regras-sociais-fatia-0.md).
> Escopo lido: `firestore.rules` inteiro (338 linhas), `firestore.indexes.json`, `firestore_rules_test/*` (helpers, mutações, orçamento, compat) e docs/51. Somente leitura (`git status` idêntico antes e depois).

## Veredito: REPROVADO (somente por 2 correções de documentação; o `firestore.rules` não precisa mudar)

Critério do Manager: só APROVADO limpo. Não encontrei nenhum 🔴 e nenhum furo explorável nas regras após leitura linha a linha, 42 mutações extras e sondas maliciosas próprias. Os 2 🟡 abaixo são omissões do docs/51 que o Manager precisa conhecer **antes** da publicação irreversível (o item 9 do gate pede honestidade sobre o que não foi verificado e passo a passo completo). São edições de texto de poucos minutos; nenhuma exige alterar regra, índice ou teste, então a re-revisão é só reler o docs/51.

## Resultados reais das execuções

| Execução | Resultado |
|---|---|
| `npm test` (JDK 24, emulador) | **180/180 passam**, 0 falhas (64 existentes sem edição + 94 + 13 + 9) |
| `npm run test:mutations` (dev) | **14/14 mortas** |
| Minhas 28 mutações extras (cópias em `/private/tmp`, rodando `social.test.mjs` + `social_compat.test.mjs`) | **28/28 mortas** (0 sobreviventes) |
| `git diff firestore.rules` | +274 / **0 linhas removidas**; `fixtures/firestore.rules.v2` idêntico ao `firestore.rules` de `HEAD` |
| `git status` antes/depois das rodadas | idêntico (nada alterado no worktree por mim, exceto este doc) |

Minhas mutações (todas mortas): amizade sem checar bloqueio; `members` sem ordem; foto `https://.*`; `list` aberto em `invites` e em `handles`; sem lista de reservados; `social` delete sem checar convite; amizade que mantém meu pedido de ida; cartão sem `isBlockedEither`; pedido sem `exists(social)`; `get` de pedido por qualquer um; `expiresAt` sem teto de 30 dias; delete de par por qualquer um; `createdAt` do pedido forjável; `handleChangedAt` mutável; troca de handle sem apagar o antigo; delete de handle/convite sem ponteiro; rotação de convite que deixa o antigo; `social` sem `validUid`; metade do outro lado não conferida; pedido sem `!isFriend`; bloqueios legíveis por qualquer um; `social` legível por qualquer um; delete "no escuro" de qualquer id; convite legível por quem foi bloqueado; código de convite curto; handle com `_` nas pontas.

Sondas maliciosas próprias (todas negadas como esperado): handle com `\n` final, maiúsculas e full-width unicode; foto com `@evil.com`, `evil.com/.googleusercontent.com`, `http://`, subdomínio duplo, host nu, quebra de linha; código de convite com `\n`; aceitar com foto do outro forjada ou omitida; terceiro apagando handle/convite/social alheios; bloqueado criando pedido ao bloqueador.

## Análise por item

### 1. Amizade (OK)
- Nasce só com `get(requestPath(other, me))` (pedido DELE para mim, imutável: `update: false`) e `!existsAfter` dos dois pedidos no mesmo batch (`firestore.rules:183-184`). Terceiro não usa pedido alheio: `me in members` e o pedido lido é sempre `other_me`.
- `get` lê o estado anterior ao batch; o pedido é imutável e só o remetente o cria/apaga. TOCTOU: se o outro cancela/recria entre a leitura do cliente e o commit, a regra reavalia no commit (nega se sumiu; nega se a "metade" divergiu). Sem furo.
- Metade do outro lado igual ao gravado por ele (`:177-178`): não forjável (nem foto, testado). Id composto sem ambiguidade (`validUid` sem `_` e `/`, `:105-107`). `createdAt == request.time`, campos extras negados, `members[0] < members[1]` impede membro duplicado. Pedido cruzado por batch/transação: completa e consome os dois.
- Update: só a própria metade (`:192-197`). Delete: qualquer membro (um único documento: "remover dos dois lados" é intrínseco).

### 2. Bloqueio (OK, com 1 limitação inerente não documentada: 🟡-1)
- Invariante "bloqueio ⇒ sem par nem pedidos" vale nos dois sentidos: criar bloqueio exige `!existsAfter` do par e dos 2 pedidos (`:216-218`); pedido e par exigem `!isBlockedEither` (pré-estado) e um bloqueio não nasce no mesmo batch de pedido/par (o `existsAfter` do bloqueio nega). Corrida bloqueio × aceite/pedido: o commit reavalia; nenhum interleaving deixa par com bloqueio.
- Leitura do bloqueio só pelo dono; desbloquear (delete pelo dono) não restaura nada.
- Cartão (`handles`) e convite: o bloqueado recebe `permission-denied`, igual a "oculto" (cartão) e "expirado" (convite); inexistente/revogado = "não existe". OK.
- **Resíduo inevitável**: o bloqueado que conhece o uid do bloqueador tenta criar pedido: negado (bloqueio, ou o outro sem `social`), enquanto o sucesso prova "usa o social e não me bloqueou". Não há como esconder isso sem servidor (a invariante exige negar a criação). Ver 🟡-1.

### 3. Handles / social / busca (OK)
- Unicidade por reserva: criar sobre existente vira `update`, só do dono; 3 transações concorrentes: 1 vence (testado). Ponteiros mútuos `social.handle` ↔ `handles/{h}` com `getAfter` nos dois sentidos; não há handle sem `social` nem o inverso (create/update/delete checados).
- Regex `^[a-z0-9_]{3,20}$` ancorada; só ASCII minúsculo, então maiúsculas/unicode/homógrafos/quebra de linha não entram (sondado). Reservados exatos não são contornáveis por caixa/unicode. Contornos que **não** dá para impedir: `cine_track`, `admin1`, `suport3` (🟢-1).
- Troca a cada 30 dias e contorno por desativar/reativar: D2 aceito. Não encontrei abuso pior: um usuário segura no máximo 1 handle por vez (testado); squatting em massa exige muitas contas Google (ver 🟡-2 sobre outros provedores). Reuso do handle liberado ("sniping" de quem trocou) é consequência do D2.
- Enumeração: `handles`/`invites` só `get` (nenhum `list`; `collectionGroup` cai no deny final). Existência de um handle exato é sondável (`not-found` × `permission-denied`), inevitável e sem revelar quem. `social` só o dono lê. Oculto e quem me bloqueou: negado inclusive a amigos.
- Foto: `https://<um rótulo>.googleusercontent.com/...` ≤ 512, sem `@`, sem host extra. Aceita qualquer subdomínio de um rótulo (ex.: `translate.googleusercontent.com`), que continua sendo infraestrutura Google (🟢-2).

### 4. Convite por link (OK)
- `list: false`; `get` por id com formato `^[A-Za-z0-9]{22,40}$` (sondado: `\n` negado). Expiração checada **na leitura** (`:317`), teto de 30 dias na escrita, dono sempre lê o seu, bloqueio nos dois sentidos nega. Revogar = delete + mover ponteiro no mesmo batch; 1 convite ativo por usuário (ponteiro); código alheio não pode ser tomado/sobrescrito/apontado (`getAfter(...).uid == uid` e update só do dono). Usar o convite só revela o cartão; o pedido é o normal (dono aceita).
- Entropia: as regras só impõem formato/tamanho; um cliente com RNG fraco expõe o convite do próprio usuário (🟢-3).

### 5. Privacidade e dados (OK)
- Nenhuma regra nova toca `users/{uid}` ou `favorites` (nem `isFriend` entra ali; M10 e o teste de compat provam que abrir seria detectado). Sem e-mail/progresso em `handles`, `friendships`, pedidos, convites.
- Terceiros não escrevem em `users/{uid}`. Exclusão em sequência viável: `social` + `handles` + `invites` saem no mesmo batch (cada delete exige o outro `existsAfter`), pares e pedidos são apagáveis por qualquer lado sem exigir `social` (e "no escuro" só para ids próprios), bloqueios pelo dono. Fica de fora (limitação do modelo): documentos `users/{outro}/blocks/{eu}` de terceiros e uma conta cujo Auth foi apagado sem rodar a limpeza deixa handle fantasma (inevitável sem servidor).
- Exportação: `get` de `social`/`handles`/`invites` (dono), `list` de pares/pedidos (filtro por membro) e bloqueios (dono) são permitidos.

### 6. Orçamento (OK)
Conferido pelo texto e pelo `rules_budget.test.mjs` (que passou): criar pedido 5, criar par 7 (2 `social`, 2 bloqueios, 1 `get`, 2 `existsAfter`), criar bloqueio 3, trocar handle ≤ 4, cartão/convite 2; máx. 7 por operação (≤ 10) e um batch de aceite fica em 7 (≤ 20). `isFriend` e `isBlocked` custam 1 (10 distintos passam, 11 negam). F2–F5 usarão `isFriend(authorId, me)` (1 por documento); lotes `authorId in` de 10 por regra de projeto. O comportamento em produção não foi medido (declarado no docs/51 §8).

### 7. Compatibilidade (OK)
Diff só adiciona linhas; suíte existente intacta e verde; `fixtures/firestore.rules.v1`/`.v2` e `social_compat.test.mjs` cobrem app novo × regras antigas e regras novas × documentos antigos. Os 2 índices compostos (`to`+`createdAt desc`, `from`+`createdAt desc`) casam com as consultas descritas; `firebase.json` aponta para o arquivo.

### 8. Testes (OK)
Os testes falham pelo motivo certo: 42 mutações (14 do dev + 28 minhas) todas mortas, inclusive ordem dos membros, formatos, `list` aberto, leituras de terceiros e ponteiros. Sem lacuna maliciosa relevante achada (minhas sondas adicionais passaram sem exigir regra nova).

## Findings

### 🔴 Bloqueantes
Nenhum.

### 🟡 Importantes (corrigir antes de publicar; só documentação)
**🟡-1. docs/51 não declara o resíduo "criar pedido revela bloqueio".**
- Onde: docs/51 §2 "Limitações aceitas" e §5 (bloqueio).
- Cenário: Bruno foi bloqueado por Ana e conhece o uid dela (ex-amigo). Ele tenta criar `friend_requests/{bruno}_{ana}`: negado, ao passo que se não estivesse bloqueado seria aceito. Distingue "bloqueado" de "não bloqueado" (a única ambiguidade é Ana não usar o social). Idem `handles/{h}` (negado = oculto OU bloqueado) já está coberto por "não revela", mas este caminho não.
- Não é corrigível nas regras (a invariante exige negar o pedido). Correção: acrescentar a limitação ao docs/51 e registrar que o app deve mostrar mensagem genérica única ("não foi possível enviar") para negado ao criar pedido, cartão ou convite.

**🟡-2. Passo a passo do console sem a conferência de provedores de login.**
- Onde: docs/51 §7.
- Cenário: as regras exigem só `request.auth != null` (o app usa só Google, mas qualquer provedor habilitado no projeto serve): se "Anônimo" ou "E-mail/senha" estiver ativo, qualquer pessoa com a chave pública do app cria contas descartáveis, ativa o social e faz squatting de handles (irreversível depois de publicado) ou spam de pedidos, sem ser um usuário Google com foto/identidade. Não verifiquei o projeto real (não tenho acesso).
- Correção: adicionar ao §7, antes de publicar, "Authentication > Método de login: somente Google habilitado (desativar Anônimo e E-mail/senha se aparecerem)"; e ao §7 também "conferir na aba Regras a data/hora da publicação e que o editor não mostrou erro" e o prazo de propagação (até ~1 min). Alternativa mais forte (decisão do Manager, exigiria teste): `request.auth.token.firebase.sign_in_provider == 'google.com'` na criação de `social`.

### 🟢 Sugestões
- **🟢-1 Reservados**: a lista (`:119-120`) é curta e só barra nomes exatos. Considerar antes da publicação: `staff`, `oficial`, `official`, `moderador`, `moderator`, `sistema`, `system`, `seguranca`, `security`, `privacidade`, `privacy`, `contato`, `contact`, `equipe`, `team`, `null`, `undefined`, `anonymous`, `anonimo`, `cine`. Mudar depois só vale para novos cadastros (quem já pegou fica). Se alterar, repetir `npm test` e `test:mutations` (a mutação N6 minha prova que os testes pegam a lista).
- **🟢-2 Foto**: restringir o host a `lh[0-9]+` (`^https://lh[0-9]+[.]googleusercontent[.]com/...`) tiraria hosts como `translate.googleusercontent.com`. Hoje todos são Google; baixo risco.
- **🟢-3 Entropia do convite**: exigir no teste Dart da Fatia 5 `Random.secure()` (≥ 22 base62) e nunca derivar de uid/tempo.
- **🟢-4 Nome**: `validName` aceita caracteres de controle/zero-width/RTL (apelido invisível ou enganoso); o cliente deve normalizar na entrada e na exibição.
- **🟢-5 Cota**: leituras de `get` em `handles`/`invites` por usuários mal-intencionados contam na cota (inerente, qualquer coleção legível).

### ❓ Perguntas
Nenhuma pendente.

### Segurança: ok (nenhum furo explorável nas regras; pendências só de documentação)

## O que NÃO verifiquei
Projeto Firebase real (apenas emulador): limites de chamadas em consultas `in`, cobrança das leituras de regra, índices "Enabled", provedores de login habilitados, propagação das regras. Código Dart não existe nesta fatia.

## Para a re-revisão
Reler docs/51 com 🟡-1 e 🟡-2 incorporados. Se as regras não mudarem (nem a lista de reservados), não é preciso reexecutar nada; o APROVADO sai na releitura.
