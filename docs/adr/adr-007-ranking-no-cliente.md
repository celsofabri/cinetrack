# ADR-007: Ranking entre amigos montado no cliente a partir de `get` por id dos snapshots, sem regra nova

Status: **Proposta** · Autor: Arquiteto · Data: 2026-10-18
Relacionados: [ADR-005](./adr-005-modelo-social-amizades.md) (`isFriend`, invariante "amigo ⇒ não bloqueado"), [ADR-006](./adr-006-snapshot-perfil-social.md) (snapshot `shared_profiles/{uid}`, fonte única de estatísticas), [docs/50 §7](../50-design-amizades.md) (limites de chamadas por consulta), [docs/90](../90-especificacao-ranking.md) (especificação), [docs/91](../91-design-ranking.md) (design).

## Contexto
A Fase 3 ordena eu + amigos mútuos por uma estatística e um período. Restrições: plano Spark (sem Cloud Functions), uma única fonte de estatísticas (o snapshot da F2), só amigos mútuos que compartilham "Estatísticas", remoção ou bloqueio valendo na hora, regras antes do app e cota gratuita.

Fatos (código em `main` 827cec5 e spikes descartáveis, docs/91 §4.3 e §5.1):
1. A regra atual de `shared_profiles` já permite `get` a amigo mútuo Google (1 `exists`) e nega `list` a todos.
2. Uma consulta `documentId in [...]` com regra por documento só passou com ≤ 10 ids no emulador. Um não amigo no lote nega o lote inteiro. O custo cobrado é igual ao de 10 `get`.
3. `rankOk` aceita qualquer número ≥ 0: `Infinity`, `1e300`, `1.5` e `month > total` são gravados e lidos de volta.
4. No Flutter web (dart2js), `Infinity` e `1e300` passam em `v is int`. O leitor tolerante da F2 aceita `Infinity`, e o formatador de tempo lança erro com esse valor.
5. O orçamento de expressões das regras está em ≈ 64% na pior escrita (ADR-006, decisão 9).
6. Não há listener de amizades (decisão da F1); o app não sabe sozinho se tem amigos.

## Opções
| Opção | Prós | Contras |
|---|---|---|
| **A. `get` por id dos snapshots dos amigos (≤ 50), 10 simultâneos, regra intacta; ordenação no cliente** | nada a publicar; um ex-amigo só afeta a própria leitura; reaproveita `readFriend` e o cache do perfil de amigo | N requisições; números só tão confiáveis quanto o leitor |
| B. Abrir `list` com `documentId in [≤ 10]` | menos requisições | regra nova e publicação antes do app; lote negado por um ex-amigo; mesmo custo cobrado |
| C. Documento agregado de ranking, ou coleção nova de entradas | leitura barata ou ordenável no servidor | 2ª fonte de estatísticas; escrita cruzada entre usuários; reescrita ao desfazer amizade; inviável sem Functions |
| D. Endurecer `rankOk` (`is int` + tetos nos 15 campos) | números sãos garantidos no servidor | ≈ 30 expressões a mais numa escrita em ≈ 64% do limite; publicação de regras; não resolve números plausíveis falsos |

## Decisão
1. **Opção A.** O ranking lê `shared_profiles/{uid}` por `get` (`Source.server`) de no máximo **50** amigos (1ª página da lista de amigos), com no máximo **10 leituras simultâneas** e timeout de 8 s por leitura. Cota acaba com tudo; um disjuntor encerra a carga quando as 10 primeiras falham. `firestore.rules` **não muda** (sha256 `6135322e…e612`) e `list` continua negado.
2. **Ordenação e períodos numa função pura** (`RankingTable.rank`), com classificação de competição (1º, 1º, 3º), empate resolvido por apelido e uid, e valores desconhecidos no fim, sem posição. Cada participante é medido no próprio mês/ano, no fuso dele; chave de período velha conta 0. O relógio do leitor é `max(ServerClock, maior updatedAt lido)`.
3. **Leitor estrito só do ranking**: inteiro, finito, ≤ tetos da tabela docs/82 §4.4 e coerência `mês ≤ ano ≤ total` por métrica. Qualquer outra coisa é "—". **Independente** de o hotfix da F2 ter entrado. Hotfix proposto (separado): `readSafeInt` nos leitores tolerantes da F2.
4. **Cache de memória compartilhado** com o perfil de amigo (`FriendProfileCache`, TTL 5 min, limpo em troca de conta, desativação, remoção e bloqueio). `permission-denied` tira a pessoa da tela, do cache e da lista de amigos em memória e dispara uma recontagem.
5. **Visibilidade da aba** por um contador de amigos: contagem agregada 1×/sessão (1 leitura), pista local com TTL de 24 h, ajustes ±1 nas ações deste aparelho, descarte de resposta em voo quando houve ajuste e recontagem em revogação. A rota `/ranking` é protegida pelo `redirect` do go_router, que ouve esse sinal.
6. **Zero escritas.** O ranking não grava nada no servidor nem no disco (só a pista booleana de "tem amigos").

## Consequências
**Positivas**
- Nenhuma publicação de regras nem índices nesta fase; orçamento de expressões intocado; rollback só do app.
- Privacidade por construção: só o que a regra da F2 já permite; ex-amigo e bloqueado negados pela regra na próxima leitura.
- Trocar filtro custa 0; reabrir e abrir o perfil de um amigo pelo ranking dentro do TTL custam 0.
- Um ex-amigo ou um documento malformado afeta só a própria linha.

**Negativas / aceitas**
- Cota linear: 2 leituras por amigo a frio (3 com a lista fria); limite prático de 50 amigos, com aviso acima disso.
- Números falsos **plausíveis** continuam possíveis (D12 da F2): o leitor só barra os absurdos.
- Remoção feita pelo outro lado aparece só na próxima leitura do servidor (≤ TTL ou "Atualizar"); a aba pode demorar a sumir até a recontagem.
- Perto da virada do mês, "este mês" de amigos em fusos diferentes cobre intervalos diferentes.
- Bugs de representação numérica do dart2js exigem testes com `--platform chrome` (passo novo de CI proposto).

**Reversão**: se o volume de amigos crescer ou o Spark deixar de ser restrição, a Opção B (consultas `in` em lotes de 10) ou um agregado no servidor (Functions) podem substituir a leitura sem mudar a função pura nem o leitor estrito.
