# 79 - Re-teste QA: Amizades, Fase 1 (rodada 3)

> Autor: QA Engineer (gate) · Data: 2026-10-09 · Working tree **não commitado** sobre `feat/social-friends` (`5755b85`) · Entradas: [docs/77](./77-reteste-final-qa-fase-1.md) (P1), [docs/73 "Rodada 3"](./73-social-fechamento-fase-1.md).
> Somente leitura. Mutações e a reprodução rodaram em cópias no scratchpad. Antes de cada execução do emulador conferi com `lsof` que as portas 8080, 9150, 4400 e 4500 estavam livres. `git status` antes e depois: igual, exceto este documento.

---

## Parecer QA: Amizades Fase 1 — ✅ APROVADO

- **P1 (docs/77):** fechado.
  - `pickPhotoUrl` agora devolve a foto da entrada `google.com` quando ela existe, inclusive `null`. A foto de topo só é usada quando não há entrada do Google.
  - A minha reprodução do docs/77 §3, rodada sem alteração numa cópia, **agora passa**: o cartão fica sem foto e nunca volta à foto da criação da conta.
  - A mutação E5 da ferramenta e a minha (que restaura o recuo para o topo) **morrem**.
- **Critérios de aceite:** 32/32 do docs/49 cobertos por teste que falha. Requisitos do Manager: 18/18. Contratos novos (`fromHandle`, foto do Google com religar manual) cobertos.
- **Regressão:** passou.
  - Os 880 testes da `main` estão na suíte e passam; os únicos arquivos antigos de teste alterados continuam sendo os 3 do docs/72 (alterações legítimas).
  - `social_compat.test.mjs`, `firestore.rules.test.mjs` e `recommended.test.mjs` não foram alterados e passam.
  - `firestore.rules` está idêntico ao da rodada 1 (`cmp`) e continua só com adições contra a `main`.
  - **Nenhum dado atual de usuário em risco.**
- **Bugs abertos:** S1: 0 | S2: 0 | S3: 0 | S4: 0
- **Riscos residuais** (não são lacunas de teste; o smoke §3 confere em produção):
  - o SDK real nunca rodou contra o emulador; o contrato está provado por pontos de injeção e pelo replay dos payloads contra as regras reais;
  - índices compostos, cobrança de leituras de regra e `providerData` do Google não foram verificados em produção.

---

## 1. Números reais (rodados por mim, 09/10)

| Verificação | Resultado |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test`, execução 1 | **1531 passaram**, 0 falharam, 0 pulados (1 min 54 s) |
| `flutter test`, execução 2 | **1531 passaram**, 0 falharam, 0 pulados (1 min 24 s): **sem flaky** |
| `npm test` (emulador, JDK 24 via `JAVA_HOME`) | **376 testes: 376 passaram**, 0 falharam, 0 pulados |
| `npm run test:mutations` | **BASELINE ok** (325 `ok`, 0 `not ok`) e **"All 52 mutations were killed."** (exit 0) |
| `tool/dart_mutations.py` (cópia sem `.git`) | **16/16 mortas**: D4, D5, D9 a D19, E2, E4, **E5** ("All Dart mutations were killed.") |
| Minhas mutações Dart (cópia) | E1 (cartão recebido aceita qualquer texto como @handle): **morta** · E3 (payload sem `fromHandle`): **morta** · P1 (provedor Google sem foto volta a cair para o topo): **morta** |
| Minha mutação de regra R1 (aceite exige o `fromHandle` atual) | **morta**: 287/289; falham exatamente "handle changed AFTER sending: …" e "their request was sent under a handle they no longer have: still accepted" |
| Reprodução do P1 (docs/77 §3, mesmo arquivo de teste, cópia) | **passa** (`+1: All tests passed!`): cartão sem foto, nunca a foto da criação |

Evolução: Dart 1490 → 1522 → 1530 → **1531**; regras 364 → **376**; mutações de regra 48 → **52**; mutações Dart da ferramenta 13 → 15 → **16**.

---

## 2. Matriz de rastreabilidade: linha N-c (final)

Matriz completa: [docs/72 §2](./72-parecer-qa-fase-1.md#2-matriz-de-rastreabilidade), com as alterações do [docs/75 §3](./75-reteste-qa-fase-1.md#3-matriz-de-rastreabilidade-mudanças-desde-o-docs72). Todas as linhas estão ✅.

| # | Cenário / requisito | Teste(s) | Status |
|---|---|---|---|
| **N-c** | **Foto do Google trocada ou removida atualiza cartão, convite e metades no próximo login com o Google; provedor Google sem foto = sem foto (nunca a foto de topo); religar é manual** (docs/49:238, decisão do Manager 09/10) | `t/app_user_mapping_test.dart`: "the Google provider photo wins over the top-level photoURL …", "no Google provider data: top-level photoURL is used", "Google provider without a photo: null (never the stale top-level photo)", "no photo anywhere: null". `t/social_closing_test.dart` grupo "🟡-2": mudou, removida, igual, desmarcada, offline sem tentativa e sincronização ao voltar a rede, sem laço, URL fora do padrão, amizades desligadas, 2 sessões com religar manual, subtítulo ligado/desligado, e o teste de **composição** "photo removed at Google (provider photo null): the card goes without a photo, never back to the account-creation photo". Mutações D12, D13, D14, E2, E4, E5 e P1 (minha) **mortas**. | ✅ |

---

## 3. Roteiro de smoke DEFINITIVO pós-publicação (Manager)

Confirma o [docs/77 §5](./77-reteste-final-qa-fase-1.md#5-roteiro-de-smoke-definitivo-pós-publicação-para-o-manager), com o reforço do passo de foto removida do docs/73 "Rodada 3". Contas: **A** (a sua, com favoritos) e **B** (conta Google de teste). Marque ✅/❌ em cada passo; qualquer ❌ deve ser reportado antes de divulgar.

**Ordem do rollout (obrigatória):**
1. Exportar a conta A com o app atual e anotar os números do Perfil.
2. Publicar **esta** versão de `firestore.rules` e fazer um smoke do app atual: abrir favoritos e marcar um episódio.
3. Publicar os índices e esperar os 2 compostos de `friend_requests` em **"Enabled"**.
4. Só então fazer o merge na `main`, que publica o app pelo `deploy-pages.yml`. Conferir o job "deploy" verde.

**Rollback:** só do app. **Nunca** voltar as regras.

**Passos:**
0. **Linha de base (app antigo):** exportar a conta A e anotar filmes, séries, episódios, assistidos e recomendados.
1. **App novo, A sem ativar:** favoritos, Recomendo, progresso e apelido iguais; o ícone Amigos não aparece.
2. **Ativar** A (`teste_a`, "Mostrar minha foto" e "Aparecer na busca" ligados) e B (`teste_b`). Em B, tentar `teste_a` mostra "Esse identificador não está disponível."
3. **Buscar (B):** ` @TESTE_A ` mostra o cartão de A. `naoexiste123` mostra "Nenhum usuário encontrado com esse identificador."
4. **Pedido B → A:** "Pedido enviado"; A aparece em Enviados (índice `from`); reenviar avisa que já foi enviado.
5. **Aceitar (A):** recarregar mostra o contador "1". Em Recebidos (índice `to`), o cartão mostra **"@teste_b"**. Aceitar: os dois aparecem na lista um do outro (em B, depois de "Atualizar").
6. **Foto trocada no Google:** com A fora do app, trocar a foto da conta Google, **sair e entrar de novo com o Google**. O cartão de A, a foto de A na lista de B (depois de "Atualizar") e o convite mostram a foto nova.
7. **Foto removida no Google (reforço do docs/73):** remover a foto da conta Google de A, sair e entrar.
   - O cartão fica **sem foto** e "Mostrar minha foto" aparece **desligado**, com a explicação "…ela não volta sozinha…".
   - **Nenhuma foto antiga de A** (nem a de quando a conta foi criada) aparece no cartão, na lista de amigos de B ou no convite.
   - Pôr uma foto nova no Google, sair e entrar: o cartão continua sem foto.
   - Ligar "Mostrar minha foto": a foto nova aparece (para B, depois de "Atualizar").
8. **Remover amigo:** o diálogo abre com o foco em "Cancelar"; confirmar. Os dois somem da lista um do outro, sem aviso.
9. **Pedido cruzado:** A pede a B; B busca `teste_a` e envia. Aparece "Vocês agora são amigos" e não sobra pedido.
10. **Handle trocado com pedido pendente** (só se a conta já puder trocar, 30 dias após a ativação; senão pule e registre): B envia pedido a A; B troca o identificador; A ainda vê o **@handle antigo** e consegue aceitar.
11. **Bloquear e desbloquear (A bloqueia B):** B some e vai para Bloqueados; B não acha A e não é avisado. Desbloquear: a amizade **não** volta.
12. **Fora da busca (A):** desligar "Aparecer na busca": B não acha A. A ainda envia pedido a B; B vê **"@teste_a"** e recusa.
13. **Convite (A):** criar o link, copiar e abrir como B: gera um pedido normal. Revogar: o link mostra "Este convite não está disponível."
14. **Exportar (A):** `schemaVersion: 2`, seção `social` com handle, amigos, pedidos, bloqueios e convite. Os favoritos batem com o JSON do passo 0.
15. **Dados antigos intactos:** números do Perfil iguais aos do passo 0; um filme assistido e uma série com progresso conferidos.
16. **Excluir B:** B some das listas de A; `teste_b` volta a dar "não encontrado" e fica livre.
17. **Console:** leituras e escritas do dia durante a primeira semana, para comparar com o docs/50 §9.
