# ADR-005: Modelo social de amizades sem Cloud Functions (Firestore Spark)

Status: **Aceita** (Manager, 2026-10-05) · Autor: Arquiteto · Data: 2026-10-05
Relacionados: [ADR-003](./adr-003-firebase-auth-e-persistencia-na-nuvem.md) (Firebase/Spark, "regras como único guarda"), [ADR-004](./adr-004-biblioteca-e-favoritos.md), [docs/49](../49-especificacao-amizades.md), [docs/50](../50-design-amizades.md).

## Contexto
O CineTrack é hoje 100% privado: cada usuário só lê `users/{uid}/...` do próprio `uid`. O Manager quer um conjunto social em 5 features (amizades, perfil de amigo, ranking, avaliações com média dos amigos, comentários). A feature 1 (amizades) é a **base**: as outras vão perguntar, dentro das Firestore Security Rules, "X e Y são amigos mútuos?" e "X bloqueou Y?".

Restrições que moldam a decisão:
- **Plano Spark**: sem Cloud Functions, sem triggers, sem Blaze. Consistência = escritas do cliente (batch/transaction) + validação em `firestore.rules`.
- Nunca abrir `users/{uid}/favorites` a terceiros. Dados visíveis a outros ficam em documentos separados, com schema validado.
- Não existe conteúdo público: "público" = visível só a amigos mútuos. Para não amigos, só apelido e avatar (e o usuário pode ficar fora da busca).
- Desfazer amizade/bloquear revoga o acesso na hora, nos dois sentidos, **sem reescrever dados de outras features**.
- Exclusão de conta (retomável, em lotes) e exportação cobrem os dados novos; ao excluir, o usuário some da lista dos outros.
- Rollout: regras antes do app; regras nunca voltam atrás depois que há dados novos; documentos antigos continuam válidos.
- Cota gratuita (50 mil leituras/dia, 20 mil escritas/dia, 20 mil deletes/dia, por projeto): evitar listeners amplos e fan-out.

**Limites do Firestore Rules que pesam no desenho** (fonte: [Structuring Cloud Firestore Security Rules](https://firebase.google.com/docs/firestore/security/rules-structure), consultada em 2026-10-05): no máximo **10** chamadas `exists()/get()/getAfter()` por requisição de documento único ou consulta e **20** em leituras de vários documentos, transações e batches; chamadas em cache não contam; ruleset de até 256 KB; funções com profundidade até 20. Cada leitura feita pelas regras **é cobrada** como leitura ([Firestore billing](https://firebase.google.com/docs/firestore/pricing): "You are charged for reads that are necessary to evaluate your Cloud Firestore Security Rules", uma por documento dependente, mesmo referenciado várias vezes).

## Opções comparadas

Eixo A: como a amizade é guardada.

| Opção | Prós | Contras | Custo (Spark) | Risco |
|---|---|---|---|---|
| **A1. Um documento por par aceito** `friendships/{menorUid}_{maiorUid}` + pedido direcional em coleção separada `friend_requests/{de}_{para}` | `isFriend(a,b)` = **1** `exists()`. Atomicidade natural: criar/remover é uma escrita só, dos dois lados ao mesmo tempo. Id determinístico impede duplicata. Desfazer revoga os dois sentidos com 1 delete. Lista de amigos = 1 consulta `array-contains` | Dois membros escrevem no mesmo documento: regras precisam limitar o que cada um altera. Id composto exige ordenar uids (igual no Dart e nas regras) | Lista de N amigos = N leituras; sem escritas duplicadas | Baixo (testado no emulador) |
| A2. Espelhos `users/{a}/friends/{b}` e `users/{b}/friends/{a}` gravados em batch | Cada usuário "é dono" da sua lista; consultas naturais; padrão comum | `isFriend(a,b)` precisa de `get` no espelho de **um** lado e a regra tem de provar que os dois existem (2 `exists`) ou aceitar espelho órfão; um lado pode apagar só o seu espelho e deixar amizade "meio desfeita" (regra de delete precisa exigir apagar o outro com `existsAfter`); o dobro de documentos e de escritas; conta excluída deixa espelho órfão no outro lado | 2N documentos por amizade; mais escritas | Médio: invariantes entre dois documentos |
| A3. Lista de amigos como array dentro de `users/{uid}` ou documento `social/{uid}` | 1 leitura para toda a lista | Array cresce sem limite (1 MiB), escrita concorrente de dois usuários no mesmo array, regras não conseguem validar "o outro consentiu" nem "remover dos dois lados" atomicamente; `isFriend` precisa de `get().data.friends.hasAny` (leitura do documento inteiro) | Barato de ler, caro de manter correto | Alto |
| A4. Cloud Functions mantendo o grafo | Servidor garante invariantes | **Proibido** (exige Blaze) | n/a | n/a |

Eixo B: como o usuário é encontrado.

| Opção | Prós | Contras | Custo | Risco |
|---|---|---|---|---|
| B1. Busca por apelido (prefixo/contém) | Natural | Apelido não é único (ambíguo); exige `list` aberto sobre perfis (enumeração de todos os usuários, raspagem); as regras **não conseguem** checar bloqueio por documento em consultas de lista; Firestore não faz busca por contém | Várias leituras por busca | Alto (privacidade) |
| **B2. Handle único com busca exata** (`handles/{handle}`, id = handle) | Sem ambiguidade; só leitura por id (`get`), sem `list`, sem raspagem; regra checa "oculto" e "bloqueado" por documento; 1 a 3 leituras por busca | Usuário precisa escolher um handle; unicidade precisa de reserva gravada com regra (sem servidor); troca de handle exige cuidado | Muito baixo | Baixo |
| B3. Somente link/código de convite | Zero busca; máxima privacidade; "ficar fora da busca" vira o padrão | Atrito (quem recebe tem de abrir o link logado); sem como achar alguém que você conhece mas não tem o link; código precisa ser revogável | Baixo | Baixo |
| **B4. B2 + B3 (handle como principal; convite por link como complemento, fatia posterior)** | Cobre quem quer ser achado e quem prefere ser convidado | Mais escopo (coleção `invites`, não validada nesta rodada) | Baixo | Baixo |

Eixo C: onde mora o cartão público (apelido/avatar/oculto).

| Opção | Prós | Contras |
|---|---|---|
| C1. Em `users/{uid}` | Reaproveita o documento | `validProfile` e o documento são "só do dono"; abrir leitura a terceiros expõe o campo `deleting`, etc.; mistura privado e público |
| **C2. No próprio `handles/{handle}` + ponteiro único `social/{uid}`** | Busca = 1 documento (regra de visibilidade lê o próprio `resource.data`, sem `get` extra do perfil); um único lugar para `discoverable` (sem cópias a sincronizar); ativação do social é opt-in explícito (existência de `social/{uid}`) | Trocar de handle recria o cartão (batch de 3 escritas); precisa do ponteiro para garantir 1 handle por usuário |
| C3. Coleção `public_profiles/{uid}` + `handles` só reserva | Cartão por uid | Busca = 2 documentos + mais leituras de regra; `discoverable` duplicado ou lido por `get` |

## Decisão
1. **Amizade = A1**: `friendships/{menorUid}_{maiorUid}` (um documento por par, só existe se **aceita pelos dois**) e `friend_requests/{de}_{para}` (pedido direcional, imutável). Um lado nunca cria amizade sozinho: a regra de criação do par exige que **exista o pedido do outro lado para mim** e que o mesmo batch o apague. Pedido cruzado vira amizade quando o segundo lado "aceita" (o cliente trata "enviar" como "aceitar" se já existir o pedido inverso).
2. **Bloqueio** em `users/{blocker}/blocks/{blocked}` (só o dono lê; o bloqueado não tem como saber). Invariante nas regras: o bloqueio só é criado se o mesmo batch **removeu** amizade e pedidos (`existsAfter`), e amizade/pedido não podem ser criados com bloqueio em qualquer sentido. Logo, **"amigo" implica "não bloqueado"**: as features seguintes só precisam de `isFriend` para decidir leitura.
3. **Descoberta = B4**: handle único (`^[a-z0-9_]{3,20}$`), busca **exata** por id; o usuário pode ficar **oculto** (somente o dono lê o cartão; não amigos recebem "não encontrado", igual a inexistente/bloqueado). Link de convite com código revogável entra como fatia posterior.
4. **Cartão público = C2**: `handles/{handle}` {uid, nickname, photoURL, discoverable, ...} + `social/{uid}` {handle, handleChangedAt} como ponteiro. Unicidade do handle vem da própria regra (criar sobre documento existente é `update`, negado a quem não é o dono); o cliente usa transação/batch.
5. **Funções reutilizáveis** em `firestore.rules`: `isFriend(a, b)` (1 `exists`) e `isBlocked(a, b)` ("a bloqueou b", 1 `exists`), mais `isBlockedEither`. Estruturas de dados **não** usam `get()` encadeado: custo fixo e baixo por leitura.
6. **Snapshots de nome/foto** (a "metade" de cada lado) ficam no documento do par e do pedido, para a lista de amigos e de pedidos custar **uma consulta e nenhuma leitura extra de regra**.
7. **Sem contadores/limites no servidor**: limites de amigos e pedidos são do cliente (regras não contam coleções); o risco de spam está registrado e a mitigação é bloquear.

## Consequências
Positivas
- Spark-compatível; nenhum servidor; `isFriend` de custo fixo (1 leitura de regra) e revogação **imediata**, bilateral, sem tocar nos dados das outras features.
- Invariantes verificados no emulador do Firestore (47 testes novos + 64 existentes, ver docs/50 §11): um lado não cria amizade sozinho, não amigo não lê, bloqueio nos dois sentidos, pedido cruzado, schema, handle único sob concorrência, tentativas maliciosas.
- Regras aditivas: documentos e app atuais não mudam (`validProfile` intocado; `users/{uid}/favorites` continua só do dono).
- A exclusão de conta é uma varredura de 4 consultas + 1 batch; o usuário some dos outros porque o par é um documento só.

Negativas / custos
- Regras mais complexas (~230 linhas novas). Mitigação: suíte de regras como contrato; funções pequenas.
- Estimativa de cota depende de leituras de regra cobradas: ver docs/50 §9. A cota é do projeto inteiro (50 mil leituras/dia), não por usuário: crescer exige cache e TTL; o plano B é Blaze (fora de escopo).
- Dois membros escrevem o mesmo documento: só podem alterar a própria "metade" do snapshot (regra testada).
- Troca de nome/foto não propaga sozinha (sem Functions): fan-out limitado e raro (≤ N escritas, em lotes) ou snapshot desatualizado até a próxima ação. Ver decisão D8.
- O handle é público para quem o conhece; handles ofensivos não são moderáveis (sem servidor): só há bloqueio e o ocultar.
- Dados de terceiros (apelido/foto de amigos) aparecem na exportação do usuário (decisão D9).
- O desenho de F4/F5 precisa respeitar o limite de 10 chamadas por consulta (docs/50 §7): consultas `authorId in [...]` em lotes de até 10 autores.

## Decisões a validar com o Manager
Resumo (detalhes, opções e consequências em [docs/49](../49-especificacao-amizades.md) e [docs/50](../50-design-amizades.md)):

| # | Decisão | Default recomendado |
|---|---|---|
| D1 | Forma de descoberta | Handle exato agora; convite por link na fatia 5 |
| D2 | Formato e unicidade do handle | `^[a-z0-9_]{3,20}$`, reserva em `handles/{h}`, troca 1 vez a cada 30 dias, handle antigo liberado na hora |
| D3 | O que um não amigo vê | Handle, apelido e foto do Google (se o usuário deixar); nada mais |
| D4 | Pedido cruzado | Vira amizade automaticamente |
| D5 | Limites | 300 amigos, 50 pedidos enviados pendentes (só no app) |
| D6 | Ativação | Opt-in explícito no Perfil (exige apelido e handle); ninguém é exposto sem agir |
| D7 | Recusar | Apaga o pedido, em silêncio (sem estado "recusado") |
| D8 | Atualização do apelido/foto nos amigos | Fan-out raro e limitado, só quando muda |
| D9 | Exportação inclui apelido/foto dos amigos | Sim, só uid + apelido |
| D10 | Foto | Apenas URL do Google (`lh<n>.googleusercontent.com`) |
| D11 | Cota excedida/Blaze | Não ativar Blaze; mensagem e cache |
