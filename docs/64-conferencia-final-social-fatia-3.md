# 64 - Conferência final da fatia 3 (amizades, fase 1)

Revisor: Code Reviewer. Base: docs/63 (REPROVADO). Escopo: working tree da fatia 3 sobre 8c5d9dd, 091c664, dc5f100. Somente leitura; `git status` igual antes e depois (35 entradas). Mutações feitas em cópia fora do worktree.

## Veredito: APROVADO

Nenhum 🔴 e nenhum 🟡. Restam apenas 🟢 opcionais e itens não verificados, declarados abaixo.

## Números (rodados por mim)

| Verificação | Resultado |
|---|---|
| `flutter analyze` | 0 problemas |
| `flutter test` | 1228 passaram, 0 falhas |
| `flutter build web` | ok |
| `npm test` (regras, emulador) | 283/283 |
| `npm run test:mutations` | 26/26 mortas |
| `firestore.rules`, `firestore.indexes.json` | sem diff |
| `grep 2026-10-06` | vazio |

## 🟡-1 Badge que nunca renovava: RESOLVIDO

Leitura do código (`social_lists_providers.dart`, `app_shell.dart`, `router.dart`):

- `ReceivedCountController.ensureFresh` só lê se `loadedAt` for nulo ou mais antigo que 10 min (`receivedCountTtlProvider`), com relógio injetável (`socialClockProvider`). Não lê sem uid, sem amizades ativas, nem com leitura em andamento.
- Sem laço: `refreshBadge` roda no `build` de quem mostra o badge, mas só agenda pós-frame e `ensureFresh` retorna dentro do TTL. O resultado só reconstrói a barra se o número mudar (`select` em `count`). Na falha (offline ou negado) grava `loadedAt = agora`: tenta de novo só depois do TTL, sem martelar e sem erro na barra.
- `BadgeRefresher` no `ShellRoute` chama `refreshBadge` em `didUpdateWidget` (a cada navegação) e ao voltar ao primeiro plano; ambos limitados a 1 leitura por TTL. Vários eventos em sequência = 1 leitura (flag `loading` e `loadedAt`). Abrir a lista de recebidos renova o contador sem leitura extra (`fromList`).
- Contas: `build` observa `currentUidProvider` e `socialPeriodProvider` (época + amizades ligadas); troca de conta ou desativar zera o estado, e a geração descarta resposta de conta anterior. `_rememberHint` agora também confere uid e geração (fecha vazamento de dica entre contas).
- Mutação própria (cópia): removida a linha do TTL em `ensureFresh`. Os testes "badge renewal" falharam (3+), ou seja, protegem o comportamento. Nada de listener; custo: 1 `count()` por TTL por aba aberta do navegador (cada aba tem seu estado), aceitável.

## 🟡-2 Teto de 300 no pedido cruzado: RESOLVIDO no código, com ressalva de teste

- `FirestoreSocialDataSource.sendRequest`: no ramo cruzado confere `count()` de amigos antes do batch (`>= kMaxFriends` lança `friendsLimit`, mesma mensagem do aceite). Nada é escrito e o pedido do outro permanece. A transação só lê; o `inverse` é zerado a cada nova tentativa. Custo do cruzado: 4 leituras (conta de enviados, 2 `get`, conta de amigos), coerente com a tabela do doc 62.
- Corrida entre o `count()` e o batch, ou entre dois aparelhos, pode passar de 300 por 1: limite só de cliente (D5), documentado em docs/62 (Riscos).
- Ressalva (🟢-1 abaixo): essa lógica do dado real não tem teste automatizado. Mutação própria em cópia (`if (false)` no lugar do `count`): 164 testes passaram, ou seja, a mutação sobreviveu. Os testes "300 não cria nada / 299 vira o 300º" exercitam o espelho no fake (`fake_social_cloud.dart`), não o `FirestoreSocialDataSource`. A leitura do código está correta; o risco é regressão futura silenciosa. O mesmo vale para o `count()` do aceite (no repositório, esse sim testado).

## 🟢 da primeira revisão

- Ordem dos amigos: `collationKey` (minúsculas e acentos dobrados), desempate por uid; cada página é ordenada e acrescentada ao fim, nada exibido se move; amigo novo entra por nome sem reordenar o resto. Entre páginas (até 6 com 300 amigos) a ordem global não é garantida; está documentado (docs/62) e é aceitável: a consulta pagina por criação, e carregar tudo custaria 6 leituras de página só para ordenar.
- Atualizar: botões nas abas Amigos e Recebidos, desabilitados offline e durante "Ver mais", alvo de 48 px, com texto visível. Cooldown de 15 s retorna sem feedback (🟢-2).
- Aba na URL: `/friends?tab=pedidos`; `context.replace` ao trocar (voltar do navegador não acumula histórico por aba); `didUpdateWidget` trata o link do badge com a tela já aberta; deep link e redirect deslogado cobertos por teste.
- Ícone: dentro de `/friends` o `onPressed` leva à aba Pedidos quando há pendentes, sem regressão.
- Reformatação: `git diff --stat` vs `-w`: diferenças restantes (ex.: 827 vs 789 em `friends_screen.dart`) são de linhas realmente alteradas e reembrulhadas por `dart format` (por exemplo o nome longo de teste em `friends_navigation_test.dart`); nenhum arquivo fora do escopo foi tocado (README e docs: só a data).
- Política (`privacidade.html`, `privacy_summary.dart`): texto coerente com o comportamento (dica local, número do ícone só em memória). A data 06/10/2026 permanece com o comentário `<!-- ATUALIZAR ... -->`; o Orquestrador a atualiza no commit de publicação (item de checklist, não defeito).

## Primeira revisão: continua válida

Contrato Dart x regras (golden + replay `.mjs`, 283 testes, 26 mutações mortas incluindo M23 a M26), segurança de aceite/cruzado/recusar/remover (nada criado sem o pedido do outro; metade do outro não forjável; terceiros negados), privacidade (recusa silenciosa, mensagens genéricas), cota (sem listener, TTL, páginas), acessibilidade (rótulo do Amigos com número lido uma vez, ponto no Perfil quando o ícone não cabe), exportação, exclusão/desativar com amizades reais e os 1095 testes antigos (ajustes em testes antigos justificados no doc 62).

## Sugestões 🟢 (não bloqueiam)

1. Cobrir o ramo cruzado do `FirestoreSocialDataSource` (cap de 300, pedido do outro intacto) com teste contra o emulador ou um Firestore falso; hoje só o espelho no fake é testado.
2. O "Atualizar" dentro do cooldown de 15 s não faz nada e não diz nada; um aviso curto ("A lista acabou de ser atualizada") ou desabilitar o botão evitaria a impressão de botão quebrado.
3. docs/62 linha 13 ainda diz que o cruzado "não confere o teto, ver Riscos"; contradiz a linha 38 (corrigido). Ajustar o texto.

## Não verificado (declarado)

- Ramo cruzado e `count()` do `FirestoreSocialDataSource` contra Firestore real ou emulador via Dart (ver 🟢-1); só leitura de código e replay dos payloads no emulador de regras.
- Comportamento real de `AppLifecycleState.resumed` em navegadores móveis e em segundo plano (testado com o ciclo de vida simulado).
- Corrida de 300 amigos entre aparelhos (limite só de cliente, D5, aceito).
- Leitores de tela reais, uso em dispositivo físico e custo medido em produção.
