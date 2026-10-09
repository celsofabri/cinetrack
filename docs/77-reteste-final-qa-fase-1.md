# 77 - Re-teste final QA: Amizades, Fase 1 (rodada 2)

> Autor: QA Engineer (gate) · Data: 2026-10-09 · Working tree **não commitado** sobre `feat/social-friends` (`5755b85`) · Entradas: [docs/75](./75-reteste-qa-fase-1.md) (N1 a N3), [docs/74](./74-re-review-integrado-fase-1.md), [docs/73 "Rodada 2"](./73-social-fechamento-fase-1.md). Decisão do Manager (09/10) para N1: **"Religar é manual"**.
> Somente leitura. Mutações e reprodução rodaram em cópias no scratchpad. Antes de cada execução do emulador conferi que a porta 8080 estava livre (`lsof`). `git status` antes e depois: igual, exceto este documento.

---

## Parecer QA: Amizades Fase 1 (rodada 2) — ❌ REPROVADO

- **N1 (religar manual):** fechado conforme a decisão do Manager. Há teste de 2 sessões e o texto aparece na UI e na política.
- **N3:** fechado. A mutação E2 agora morre.
- **N2:** a origem da foto foi corrigida para o caso comum. Porém a **regra de fallback** introduzida em `pickPhotoUrl` cria um defeito novo, o **P1**: quando o provedor Google existe mas **não tem foto**, o app usa o `photoURL` de topo. O próprio comentário do código diz que esse campo só é preenchido na criação da conta, ou seja, está velho. Resultado: a remoção da foto no Google **republica no cartão público uma foto antiga**, contrariando a política. Reproduzi numa cópia (§3).
- **Regressão:** passou. Os 880 testes da `main` estão na suíte; os únicos arquivos antigos de teste alterados continuam sendo os 3 do docs/72. `social_compat.test.mjs`, `firestore.rules.test.mjs` e `recommended.test.mjs` não foram alterados e passam. `firestore.rules` não mudou desde a rodada 1 (`cmp` idêntico) e continua só com adições contra a `main`. **Nenhum dado atual em risco.**
- **Bugs abertos:** S1: 0 | S2: 1 (P1, condicionado ao que o Google devolve; ver §3) | S3: 0 | S4: 0
- A correção é de poucas linhas, mais 2 testes (§3).

---

## 1. Números reais (rodados por mim, 09/10)

| Verificação | Resultado |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test`, execução 1 | **1530 passaram**, 0 falharam, 0 pulados (2 min 07 s) |
| `flutter test`, execução 2 | **1530 passaram**, 0 falharam, 0 pulados (1 min 13 s): **sem flaky** |
| `npm test` (emulador, JDK 24 via `JAVA_HOME`, 8080 conferida livre) | **376 testes: 376 passaram**, 0 falharam, 0 pulados |
| `npm run test:mutations` | **BASELINE ok** (325 `ok`, 0 `not ok`) e **"All 52 mutations were killed."** (exit 0) |
| `tool/dart_mutations.py` (cópia sem `.git`) | **15/15 mortas**: D4, D5, D9 a D19, **E2**, **E4** ("All Dart mutations were killed.") |
| Minhas mutações Dart (cópia) | E1 (cartão recebido aceita qualquer texto como @handle): **morta** · E3 (payload sem `fromHandle`): **morta** · E2: morta (agora dentro da ferramenta) |
| Minha mutação de regra R1 (aceite exige o `fromHandle` atual) | **morta**: 287/289; falham exatamente "handle changed AFTER sending: …" e "their request was sent under a handle they no longer have: still accepted" |
| Reprodução do P1 (cópia, teste temporário) | **falha como previsto**: `Expected: null, Actual: 'https://lh3.googleusercontent.com/a/foto-da-criacao-da-conta'` |

Evolução: 1490 → 1522 → **1530** Dart; 364 → **376** regras; 48 → **52** mutações de regra; 13 → **15** mutações Dart da ferramenta.

---

## 2. Achados do docs/75: verificação

| Id | Correção conferida | Evidência | Status |
|---|---|---|---|
| N1 | Decisão do Manager "Religar é manual". Google sem foto → cartão sem foto e "Mostrar minha foto" desligado; foto nova não volta sozinha. Subtítulo do interruptor: "Seu cartão está sem foto. Se a foto sumiu do Google, ela não volta sozinha: para voltar a mostrar, ligue 'Mostrar minha foto'." Política (`web/privacidade.html` l. 115 a 120) e resumo no app alinhados. | `test/social_closing_test.dart` "Google photo removed, then a new one in a later session: the card stays without a photo until the user turns it back on; turning it on uses the new photo" e os 2 testes de widget do subtítulo; D13 morta | ✅ fechado |
| N2 | `pickPhotoUrl`: provedor `google.com` > `user.photoURL` > nenhuma; `_toAppUser` usa essa função | `test/app_user_mapping_test.dart` (4 testes); E4 morta | ✅ no caso comum / ❌ **P1** no fallback |
| N3 | O fake registra tentativas (`FakeSocialCloud.attempts`) | "offline: the photo sync is not even attempted; back online in the same session the first server read syncs it"; E2 morta | ✅ fechado |

---

## 3. P1 · S2 · Foto removida no Google faz o cartão público voltar a uma foto ANTIGA

- **Onde:** `lib/auth/app_user.dart`, função `pickPhotoUrl`: quando o provedor `google.com` existe com `photoUrl` nulo ou vazio, cai para `topLevel`. Fixado pelo teste `test/app_user_mapping_test.dart` "Google provider without a photo: falls back to the top-level photoURL".
- **Por que está errado:** o comentário da própria função afirma que o `photoURL` de topo "is only filled when the account is created". Logo, ele é a foto de **quando a conta foi criada**, não a atual. Quando o Google informa "sem foto", essa é a informação verdadeira, e cair para o topo publica uma foto velha.
- **Passos (cenário):**
  1. Conta criada com a foto X; o usuário trocou para Y no Google.
  2. Cartão com "Mostrar minha foto" ligado mostra Y.
  3. O usuário **remove** a foto no Google, sai e entra de novo com o Google.
- **Esperado (política, l. 117 a 118; decisão N1):** "Se a foto não existir mais no Google, o cartão fica sem foto" e o interruptor fica desligado.
- **Obtido:** `pickPhotoUrl` devolve X (topo). A sincronização vê X ≠ Y e **grava X no cartão** (`handles/{h}`, visível a quem busca o identificador), no convite e na metade de cada amizade.
- **Evidência (reprodução numa cópia, sem tocar no worktree):** teste temporário com `_Rig(googlePhoto: pickPhotoUrl(topLevel: X, providers: [(google.com, null)]), cardPhoto: Y)` → `Expected: null`, `Actual: 'https://lh3.googleusercontent.com/a/foto-da-criacao-da-conta'`.
- **Condição (não verificado):** só acontece se o Firebase devolver o provedor Google **sem** foto. É possível que, sem foto personalizada, o Google devolva uma URL de avatar padrão (letra), caso em que o P1 não ocorre. Como não há como provar isso antes da produção e o código trata o caso explicitamente de forma errada, classifico como **S2**: é uma exposição de dado pessoal que o usuário removeu, em contradição com a política publicada.
- **Correção:** quando houver uma entrada `google.com` em `providerData`, usar **a foto dela ou `null`**; cair para `topLevel` só quando **não existir** provedor Google.
- **Testes a criar ou alterar:**
  - `test/app_user_mapping_test.dart`: trocar "Google provider without a photo: falls back to the top-level photoURL" por `'Google provider without a photo: null (never the stale top-level photo)'`, com `photoUrl: null` e `' '` → `isNull`.
  - `test/social_closing_test.dart`: novo `'photo removed at Google (provider photo null): the card goes without a photo, never back to the account-creation photo'`, igual à reprodução acima, esperando cartão, convite e metade `null` e "Mostrar minha foto" desligado.
  - `tool/dart_mutations.py`: mutação E5 "Google provider without a photo falls back to the top-level photoURL" (o código atual), que precisa morrer.

---

## 4. Matriz de rastreabilidade (linha atualizada)

A matriz completa está no [docs/72 §2](./72-parecer-qa-fase-1.md#2-matriz-de-rastreabilidade), com as alterações do [docs/75 §3](./75-reteste-qa-fase-1.md#3-matriz-de-rastreabilidade-mudanças-desde-o-docs72). A linha N-c passa a ser esta:

| # | Cenário / requisito | Teste(s) | Status |
|---|---|---|---|
| **N-c** | **Foto do Google trocada ou removida atualiza cartão, convite e metades no próximo login com o Google; religar é manual** (docs/49:238, decisão do Manager 09/10) | `t/social_closing_test.dart` grupo "🟡-2" (mudou, removida, igual, desmarcada, offline sem tentativa e sincronização ao voltar a rede, sem laço, URL fora do padrão, amizades desligadas, 2 sessões com religar manual, subtítulo ligado/desligado); `t/app_user_mapping_test.dart` (provedor Google vence o topo; sem provedor usa o topo; nada → `null`); mutações D12, D13, D14, E2 e E4 mortas | ⚠️ **P1**: provedor Google sem foto cai para a foto de topo (velha) |

Todas as demais linhas estão ✅, incluindo N-a e N-b (`fromHandle`), revalidadas nesta rodada pelas mutações M39, F11, F12, D17, D18, E1, E3 e R1.

---

## 5. Roteiro de smoke DEFINITIVO pós-publicação (para o Manager)

Substitui o docs/72 §7 e o docs/75 §6. Contas: **A** (a sua, com favoritos) e **B** (conta Google de teste). Marque ✅/❌ em cada passo; qualquer ❌ deve ser reportado antes de divulgar.

**Ordem do rollout (obrigatória):**
1. Exportar a conta A com o app atual e anotar os números do Perfil.
2. Publicar **esta** versão de `firestore.rules` e fazer um smoke do app atual: abrir favoritos e marcar um episódio.
3. Publicar os índices e esperar os 2 compostos de `friend_requests` em **"Enabled"**.
4. Só então fazer o merge na `main`, que publica o app. Conferir o job "deploy" verde no GitHub Actions.

**Rollback:** só do app. **Nunca** voltar as regras.

**Passos:**
0. **Linha de base (app antigo):** Perfil > "Exportar meus dados (JSON)" da conta A; anotar filmes, séries, episódios, assistidos e recomendados.
1. **App novo, A sem ativar:** favoritos, Recomendo, progresso e apelido iguais; o ícone Amigos **não** aparece.
2. **Ativar** A (`teste_a`, "Mostrar minha foto" e "Aparecer na busca" ligados) e B (`teste_b`). Em B, tentar `teste_a` mostra "Esse identificador não está disponível."
3. **Buscar (B):** ` @TESTE_A ` mostra o cartão de A. `naoexiste123` mostra "Nenhum usuário encontrado com esse identificador."
4. **Pedido B → A:** "Pedido enviado"; A aparece em Enviados (índice `from`); reenviar avisa que já foi enviado.
5. **Aceitar (A):** recarregar mostra o contador "1". Em Pedidos > Recebidos (índice `to`), o cartão mostra **"@teste_b"** abaixo do apelido. Aceitar: os dois aparecem na lista um do outro (em B, depois de "Atualizar").
6. **Foto trocada no Google:** com A fora do app, trocar a foto da conta Google de A, **sair e entrar de novo com o Google**. O cartão de A (Perfil > Amizades), a foto de A na lista de amigos de B (depois de "Atualizar") e o convite mostram a foto nova.
7. **Foto removida no Google (religar manual):** remover a foto da conta Google de A, sair e entrar.
   - O cartão fica **sem foto** e "Mostrar minha foto" aparece **desligado**, com o texto "Seu cartão está sem foto. Se a foto sumiu do Google, ela não volta sozinha…".
   - **Confira que não aparece uma foto antiga de A** (é o P1).
   - Pôr uma foto nova no Google, sair e entrar: o cartão **continua sem foto**.
   - Ligar "Mostrar minha foto": a foto nova aparece no cartão e, para B, depois de "Atualizar".
8. **Remover amigo (A):** "Remover amizade" no cartão de B. O diálogo abre com o foco em "Cancelar"; confirmar. Os dois somem da lista um do outro, sem aviso.
9. **Pedido cruzado:** A pede a B; B busca `teste_a` e envia. Aparece "Vocês agora são amigos" e não sobra pedido.
10. **Handle trocado com pedido pendente** (só se a conta já puder trocar, 30 dias após a ativação; senão pule e registre): B envia pedido a A; B troca o identificador; A ainda vê o pedido com o **@handle antigo** e consegue aceitar.
11. **Bloquear e desbloquear (A bloqueia B):** B some e vai para Bloqueados; B busca `teste_a` e vê "não encontrado"; B não é avisado. Desbloquear: a amizade **não** volta.
12. **Fora da busca (A):** desligar "Aparecer na busca": B não acha A. A ainda busca `teste_b` e envia pedido; B vê **"@teste_a"** no pedido recebido e recusa.
13. **Convite (A):** criar o link, copiar e abrir logado como B: aparece o cartão de A; "Enviar pedido" gera um pedido normal (A vê "@teste_b"). Revogar: o link passa a mostrar "Este convite não está disponível."
14. **Exportar (A):** `schemaVersion: 2`, seção `social` com handle, amigos, pedidos, bloqueios e convite. Os favoritos batem com o JSON do passo 0.
15. **Dados antigos intactos:** números do Perfil iguais aos do passo 0; 2 favoritos antigos (um filme assistido e uma série com progresso) conferidos.
16. **Excluir B:** B some das listas de A; `teste_b` volta a dar "não encontrado" e fica livre.
17. **Console:** leituras e escritas do dia anotadas durante a primeira semana, para comparar com o docs/50 §9.

---

## 6. Para o próximo re-teste
- Corrigir o P1 com os 2 testes e a mutação E5 da §3.
- Vou rodar de novo `flutter analyze`, `flutter test` 2 vezes, `npm test`, `npm run test:mutations`, `tool/dart_mutations.py` (E5 tem de morrer) e a reprodução do P1, que tem de passar.
- Se nada mais mudar, o parecer passa a ✅ APROVADO.
