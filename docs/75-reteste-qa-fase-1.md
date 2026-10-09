# 75 - Re-teste QA: Amizades, Fase 1 (fechamento, docs/73)

> Autor: QA Engineer (gate) · Data: 2026-10-08 · Working tree **não commitado** sobre `feat/social-friends` (`5755b85`) · Entradas: [docs/72](./72-parecer-qa-fase-1.md) (meu parecer anterior), [docs/71](./71-code-review-integrado-fase-1.md) (Code Review integrado), [docs/73](./73-social-fechamento-fase-1.md) (correções). Mudanças de contrato do Manager (08/10): pedido grava `fromHandle` conferido pela regra; foto do Google trocada atualiza o cartão no início da sessão.
> Somente leitura. Mutações e reproduções rodaram em cópias no scratchpad. Antes de usar o emulador conferi que a porta 8080 estava livre (`lsof`). `git status` antes e depois: igual, exceto este documento.

---

## Parecer QA: Amizades Fase 1 (re-teste) — ❌ REPROVADO

- **Lacunas do docs/72:** L1, L2, L3, L4 e as 2 observações estão **fechadas**, com evidência na §2. As mutações D4 e D5 agora morrem, a mutação do L2 (M40) morre, a asserção literal do L3 existe e o teste do L4 existe.
- **Contrato novo (`fromHandle`):** coberto, sem lacuna.
- **Contrato novo (foto do Google):** 3 achados novos, descritos na §4:
  - **N1 · S3:** remover a foto no Google desliga para sempre a preferência "Mostrar minha foto" do usuário.
  - **N2 · S3:** a origem da foto (`User.photoURL`, campo de topo do Firebase Auth) pode não refletir a troca de foto no Google; não verificado, confiança média.
  - **N3 · S4:** a guarda "não sincronizar a partir do cache do aparelho" não tem teste que falhe (mutação E2 sobrevive).
- **Regressão:** passou. Os 880 testes da `main` seguem na suíte; os únicos arquivos antigos de teste alterados continuam sendo os 3 do docs/72. `social_compat.test.mjs` não foi alterado e passa. `firestore.rules` contra a `main` continua só com adições. **Nenhum dado atual em risco.**
- **Bugs abertos:** S1: 0 | S2: 0 | S3: 2 (N1, N2) | S4: 1 (N3)
- **Motivo da reprovação:** o Manager não aceita "com ressalvas". As 3 correções são pequenas. N1 precisa antes de uma decisão de produto (opções na §4).

---

## 1. Números reais (rodados por mim)

| Verificação | Resultado |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test`, execução 1 | **1522 passaram**, 0 falharam, 0 pulados (1 min 41 s) |
| `flutter test`, execução 2 | **1522 passaram**, 0 falharam, 0 pulados (1 min 31 s): **sem flaky** |
| `npm test` (emulador, JDK 24 via `JAVA_HOME`, porta 8080 conferida livre) | **376 testes, 41 suítes: 376 passaram**, 0 falharam, 0 pulados |
| `npm run test:mutations` (com linha de base) | **BASELINE ok** (regras e fixture sem mutação: 325 `ok`, 0 `not ok`) e **"All 52 mutations were killed."** (52 linhas KILLED, nenhuma SURVIVED/ERROR, exit 0) |
| Mutações Dart do Dev (`tool/dart_mutations.py`, numa cópia) | **13/13 mortas** (D4, D5, D9 a D19); "Some tests failed" conferido em cada uma (nenhuma morta por erro de compilação) |
| Mutações Dart minhas (cópia) | E1 (cartão recebido mostra qualquer texto como @handle): **morta** · E3 (payload sem `fromHandle`): **morta** · E2 (sincronizar a foto a partir do cache): **SOBREVIVEU** (→ N3) |
| Mutação de regra minha (cópia, `RULES_PATH`) | R1 (o aceite exige `req.fromHandle` igual ao handle atual do remetente): **morta**. 287/289 passam; falham exatamente "handle changed AFTER sending: …" (`social.test.mjs`) e "their request was sent under a handle they no longer have: still accepted" (`dart_payloads.test.mjs`) |

Antes: 1490 Dart / 364 regras / 48 mutações. Agora: 1522 / 376 / 52.

---

## 2. Lacunas do docs/72: verificação

| Id | Correção conferida | Evidência | Status |
|---|---|---|---|
| L1 | Transações leem por `SocialPlanner` injetável. `activate` lê `social/{uid}` antes do handle. Handle negado = `handleTaken`; ponteiro próprio negado = `denied`. `isHandleFree` foi removido (G7). O fake agora concorda com o código real. | `test/firestore_social_data_source_test.dart`: "activate: a card the rules hide (hidden owner / block) is 'taken', never free", "activate with the OLD rules (own pointer denied): denied, not handleTaken", "changeHandle: a new handle hidden by the rules is taken", "changeHandle with the OLD rules …". Mutações D4, D5 e D9 **mortas** (rodei a ferramenta). | ✅ fechado |
| L2 | Testes com o **ator** oculto | `r/social.test.mjs` "a hidden user ('Aparecer na busca' off) still reads visible cards, sends, cancels and accepts" (destinatário oculto também aceita); `r/dart_payloads.test.mjs` "FROM a hidden user …" e "a HIDDEN recipient …"; `t/friends_screens_test.dart` "hidden from the search: I can still search, send and accept (docs/72 L2)". Mutação **M40** ("the sender must be visible") **morta**. | ✅ fechado |
| L3 | `kSearchNotFoundMessage = 'Nenhum usuário encontrado com esse identificador.'`; docs/49, docs/50, README e política alinhados | `t/friends_screens_test.dart:281` faz a asserção **literal**; mutação D19 (texto antigo) **morta** | ✅ fechado |
| L4 | Teste com a cota social esgotada e Favoritos funcionando | `t/friends_slice3_screens_test.dart` "social quota exhausted: the message shows and Favoritos still lists and toggles (docs/72 L4)" (lista o favorito, marca e desmarca assistido, conferido no "servidor" do fake) | ✅ fechado |
| Obs. 1 | Exclusão: só a leitura negada do próprio ponteiro é tratada como "regras não publicadas"; um batch de fechamento negado faz a exclusão falhar (retomável) | `t/firestore_social_data_source_test.dart` "wipeForAccountDeletion: read denied = nothing to delete; batch denied = FAILS"; `t/social_repository_test.dart` "a denied CLOSE … fails the deletion: no silent skip"; D15 **morta** | ✅ fechado |
| Obs. 2 | Exportação lê as 4 listas também sem ponteiro (resíduos) | `t/social_export_test.dart` grupo "residue WITHOUT the pointer is exported too"; D16 **morta** | ✅ fechado |

---

## 3. Matriz de rastreabilidade: mudanças desde o docs/72

A matriz completa continua no [docs/72 §2](./72-parecer-qa-fase-1.md#2-matriz-de-rastreabilidade). As linhas abaixo **substituem** as de lá ou são **novas**.

| # | Cenário / requisito | Teste(s) | Status |
|---|---|---|---|
| 3 | Handle já em uso | + `t/firestore_social_data_source_test.dart` "activate: a card the rules hide … is 'taken', never free" e "activate: a visible card of someone else is taken" | ✅ (era ⚠️ L1) |
| 5 | Disputa simultânea | `r/social.test.mjs` "3 concurrent transactions …"; no cliente, o perdedor relê e cai em `handleTaken` (testes de L1) | ✅ |
| 6 | Ficar fora da busca | + testes de L2 | ✅ (era ⚠️) |
| 11 | Mesma mensagem: bloqueado, oculto, inexistente | `t/friends_screens_test.dart` "missing / hidden / blocked / yourself / reserved: IDENTICAL text" (literal "Nenhum usuário encontrado com esse identificador.") | ✅ (era ⚠️ L3) |
| 30 | Regras ainda não publicadas | + `t/firestore_social_data_source_test.dart` "activate with the OLD rules (own pointer denied): denied, not handleTaken" (o caminho real agora mostra "Amizades ainda não estão disponíveis") | ✅ |
| 31 | Cota esgotada | + teste de L4 | ✅ (era ⚠️) |
| **N-a** | **Pedido leva o @handle atual do remetente; o destinatário vê o @handle** (docs/49, Manager 08/10) | Regras: `r/social.test.mjs` bloco "pedido amarrado ao @handle do remetente (fromHandle)" (atual aceito; ausente, com erro, do destinatário, de terceiro, maiúsculo, `null` ou de outro tipo negados) e "impersonation: copying another person's name, photo AND handle is denied; own handle is shown". Replay: `r/dart_payloads.test.mjs` "sendRequest carries the sender's CURRENT handle; the same payload is denied once the handle changed" (+ 3 casos de campo). Orçamento: `r/rules_budget.test.mjs` "send request with the handle binding … passes" (continua 5 chamadas). Dart: `t/friends_screens_test.dart` "the request carries MY current handle; a stale handle is refused by the rules"; `t/friends_slice3_screens_test.dart` "each card shows the sender's @handle: two 'Ana Souza' are told apart". Mutações M39, F11, F12, D17, D18, E1 e E3 **mortas**. | ✅ |
| **N-b** | **Pedido pendente com handle antigo continua aceitável depois da troca** | `r/social.test.mjs` "handle changed AFTER sending: the old request stays and can still be accepted; new requests need the new handle" (outra pessoa pega o handle antigo e o pedido antigo ainda é aceito); replay `r/dart_payloads.test.mjs` "their request was sent under a handle they no longer have: still accepted (snapshot, docs/73)". Mutação de regra minha **R1** (o aceite exige `req.fromHandle` igual ao handle atual): **morta** pelos 2 testes citados | ✅ |
| **N-c** | **Foto do Google trocada atualiza cartão, convite e metades no início da sessão** | `t/social_closing_test.dart` grupo "🟡-2": mudou (1 escrita, cartão + convite + metade), removida (`null`), igual (0), desmarcada pelo usuário (0), offline (0), sem laço, URL fora do padrão, amizades desligadas. D12, D13 e D14 **mortas**. | ⚠️ **N1, N2, N3** |
| **N-d** | Operação concorrente nunca responde "feito" (🟡-1) | `t/social_closing_test.dart` "updateNickname while the section is busy …", "deactivate while busy …", widget "the header 'Editar apelido' is disabled …"; D10 e D11 **mortas** | ✅ |
| **N-e** | Exportação do pedido não expõe o `fromHandle` de terceiro (privacidade) | docs/73 §Exportação (o formato das entradas não mudou); `t/social_export_test.dart` "with friendships …" segue verde | ✅ |

---

## 4. Achados novos (contrato da foto do Google)

### N1 · S3 · Remover a foto no Google desliga para sempre a escolha "Mostrar minha foto"
- **Onde:**
  - `lib/social/social_models.dart:38`: `bool get photoVisible => photoUrl != null;`. A preferência do usuário não é guardada em lugar nenhum; ela é deduzida de "o cartão tem foto".
  - `lib/providers/social_providers.dart` `_syncGooglePhoto`: se a foto do Google sumir (ou não passar em `SocialPhoto.sanitize`), grava o cartão com `null`.
- **Passos:**
  1. A ativa as amizades com "Mostrar minha foto" ligado.
  2. A remove a foto no Google (ou o Google passa a devolver uma URL fora de `lh<n>.googleusercontent.com`).
  3. A abre o app: o cartão fica sem foto (correto pelo docs/49:238).
  4. A coloca uma foto nova no Google e abre o app de novo.
- **Esperado:** a foto nova volta ao cartão, porque A nunca desligou "Mostrar minha foto".
- **Obtido:**
  - O interruptor "Mostrar minha foto" no Perfil passa a aparecer **desligado** sem ação do usuário.
  - A foto nova **nunca** é sincronizada, porque o código trata o caso como "desmarcada pelo usuário": `if (!profile.photoVisible …) return`.
- **Evidência:** decorre do código e de dois testes do próprio `test/social_closing_test.dart`:
  - "removed from Google: the card loses the photo (null)" produz `cardPhoto = null`;
  - "photo turned off by the user: stays off even with a Google photo" começa exatamente desse estado (`cardPhoto: null`) e confirma 0 escritas.
  - Logo, o estado depois de uma remoção no Google é indistinguível de "o usuário desligou".
  - Tentei uma reprodução em duas sessões numa cópia; a 2ª sessão do harness não terminou de carregar no tempo do teste, então a evidência fica no código mais esses dois testes.
- **Por que importa:** o docs/49 diz que a foto desmarcada pelo usuário continua desmarcada; o recíproco (a foto que o usuário NÃO desmarcou continua seguindo o Google) não vale. Uma preferência de consentimento muda sozinha.
- **Correção (precisa de decisão do Manager/PA; nenhuma opção mexe em dados existentes):**
  - (a) **Sem mudar as regras:** quando o Google não tiver foto, ou a URL não passar no teste, **não mexer** no cartão nem na preferência. A foto antiga fica até o usuário desligar; se a URL quebrar, a UI mostra as iniciais. Isso contraria o texto atual do docs/49:238 "o cartão fica sem foto", que precisaria mudar.
  - (b) Guardar a preferência fora do cartão, por uid. Os campos do cartão e de `social/{uid}` são fechados pelas regras (`hasOnly`), então isso exige mudar as regras **antes** da publicação, ou guardar só no aparelho, que fica inconsistente entre dispositivos.
  - (c) Aceitar o comportamento e documentar: na UI, sob o interruptor, "Sua foto do Google foi removida; ligue de novo para usar a nova". Mais a política.
- **Teste a criar:** em `test/social_closing_test.dart`, `'Google photo removed, then a new one in a later session: …'`, com a asserção conforme a opção escolhida. Na (a): o cartão mantém a foto até haver uma nova e "Mostrar minha foto" segue ligado. Na (c): o aviso aparece e o interruptor fica desligado.

### N2 · S3 · A origem da foto pode não refletir a troca no Google (não verificado; confiança média)
- **Onde:** `lib/auth/firebase_auth_repository.dart:158`: `photoUrl: user.photoURL`, o campo de topo do `User` do Firebase Auth.
- **Risco:** pelo que sei do Firebase Auth (não verifiquei neste projeto), o perfil de topo (`displayName`/`photoURL`) é preenchido a partir do Google na criação da conta e **não** é sobrescrito nos logins seguintes. O que é atualizado a cada login é `providerData` (`providerId == 'google.com'`). Se isso valer, o 🟡-2 decidido pelo Manager **nunca dispara em produção**, e todos os testes passam porque o fake injeta `photoUrl` diretamente. O próprio docs/73 lista o ponto como "não verificado".
- **Correção:** ler a foto de `user.providerData.firstWhere((i) => i.providerId == 'google.com').photoURL`, caindo para `user.photoURL` se não houver. Extrair o mapeamento para uma função pura (`appUserFromFirebase`) e testar em `test/auth_failure_test.dart` ou num novo `test/app_user_mapping_test.dart`:
  - `'the Google provider photo wins over the top-level photoURL (it is refreshed on every sign-in)'`;
  - `'no Google provider data: top-level photoURL is used'`.
- **Alternativa:** antes do merge, evidência real com a conta do Manager num build local: trocar a foto no Google, sair, entrar de novo e ver se `photoURL` mudou.
- Em qualquer caso, o passo S6 do smoke (§6) confere isso em produção.

### N3 · S4 · A guarda "não sincronizar a foto a partir do cache do aparelho" não tem teste que falhe
- **Onde:** `lib/providers/social_providers.dart`, `… && profile != null && !next.fromCache)`.
- **Evidência:** a mutação E2 (remover `!next.fromCache`) **sobrevive** a `test/social_closing_test.dart` (11 passam). O teste "offline (state from the device): nothing is written" passa mesmo assim, porque a escrita offline é recusada pelo fake de qualquer jeito.
- **Efeito sem a guarda:** offline, a sincronização tenta, falha e marca `_photoChecked`. Ao voltar a rede na mesma sessão, a foto não é sincronizada, e o aviso de falha do refresh pode aparecer.
- **Teste a criar:** em `test/social_closing_test.dart`, `'offline: the photo sync is not even attempted; back online in the same session the first server read syncs it'`. Deve verificar que `social.log` não tem nenhuma tentativa de `updateCard` enquanto offline (o fake precisa registrar tentativas) e que, depois de `offline = false` e `refresh()`, há exatamente 1 `updateCard` com `_new`.

---

## 5. Regressão e dados
- Os 880 testes da `main` estão na suíte e passam. Os arquivos de teste antigos alterados continuam só os 3 do docs/72 (`account_deleter_test`, `export_serializer_test`, `profile_screen_test`); os demais alterados nesta rodada são testes sociais da própria branch.
- `firestore.rules` contra a `main`: só adições. A única mudança de comportamento desta rodada é `validRequest` (`get(social/{from}).data.handle == fromHandle` no lugar de `exists`, mesmo caminho, mesmo custo). `users/**`, `favorites`, `validProfile` e `validFavorite` estão intactos. Os índices não mudaram.
- `social_compat.test.mjs` (regras v1/v2 com app novo; documentos legados com regras novas) não foi alterado e passa. `firestore.rules.test.mjs` e `recommended.test.mjs` não foram alterados e passam.
- Exportação: schema 2 inalterado. Quem nunca ativou continua com `social: null` (agora com 4 leituras a mais para procurar resíduos).
- **Nenhum caminho de perda de dados encontrado.**

---

## 6. Roteiro de smoke pós-publicação (atualizado; substitui o docs/72 §7)

Contas: **A** (a sua) e **B** (conta Google de teste). Ordem do rollout como no docs/72 §6: exportar, publicar **esta** versão das regras, publicar os índices e esperar "Enabled" (os 2 de `friend_requests`), e só então o merge na `main` (o merge publica o app).

0. **Com o app antigo:** exportar a conta A (Perfil > "Exportar meus dados (JSON)") e anotar os números do Perfil.
1. **App novo, A sem ativar:** favoritos, Recomendo, progresso e apelido iguais; ícone Amigos ausente.
2. **Ativar A** (`teste_a`, "Mostrar minha foto" e "Aparecer na busca" ligados) e **B** (`teste_b`). Em B, tentar `teste_a` antes mostra "Esse identificador não está disponível."
3. **Buscar (B):** ` @TESTE_A ` mostra o cartão de A. `naoexiste123` mostra **"Nenhum usuário encontrado com esse identificador."**
4. **Pedido B → A:** aparece "Pedido enviado", A está em Enviados, e reenviar avisa que já foi enviado (índice `from`).
5. **Aceitar (A):** recarregar mostra o contador "1". Em Pedidos > Recebidos (índice `to`), **o cartão mostra "@teste_b" abaixo do apelido de B (novo)**. Aceitar: um aparece na lista do outro.
6. **Foto do Google (novo):** com A **fora do app**, trocar a foto da conta Google de A, esperar alguns minutos, sair e entrar de novo no app.
   - **Esperado:** o cartão de A (Perfil > Amizades), a foto de A na lista de amigos de B (depois de "Atualizar") e a foto no convite mostram a foto nova.
   - **Se não mudar, é o N2** e deve ser reportado.
   - Opcional: desligar "Mostrar minha foto" e reabrir: a foto continua desligada.
7. **Remover (A):** "Remover amizade" no cartão de B. O diálogo abre com o foco em "Cancelar"; confirmar. Os dois somem da lista um do outro, sem aviso.
8. **Pedido cruzado:** A pede a B; B busca `teste_a` e envia. Aparece "Vocês agora são amigos" e não sobra pedido.
9. **Handle trocado com pedido pendente (novo; só se A já puder trocar, 30 dias após a ativação; senão use uma terceira conta ou pule):** B envia pedido a A; B troca o identificador; A ainda vê o pedido com o **@handle antigo** e consegue aceitar.
10. **Bloquear e desbloquear (A bloqueia B):** B some e vai para Bloqueados; B busca `teste_a` e vê "não encontrado"; B não recebe aviso. Ao desbloquear, a amizade **não** volta.
11. **Fora da busca (A):** desligar "Aparecer na busca": B não acha A. A ainda busca `teste_b`, envia pedido, e B **vê "@teste_a" no pedido recebido** mesmo com A oculto; B recusa.
12. **Convite (A):** criar o link, copiar e abrir como B: o cartão de A aparece; "Enviar pedido" gera um pedido normal com "@teste_b". Revogar: o link passa a mostrar "Este convite não está disponível."
13. **Exportar (A):** `schemaVersion: 2`, `social` com handle, amigos, pedidos, bloqueios e convite; os favoritos batem com o JSON do passo 0.
14. **Dados antigos intactos:** números do Perfil iguais aos do passo 0; 2 favoritos antigos (um filme assistido e uma série com progresso) conferidos.
15. **Excluir B:** B some das listas de A; `teste_b` volta a dar "não encontrado" e fica livre.
16. **Console:** leituras e escritas do dia anotadas na primeira semana, para comparar com o docs/50 §9.

---

## 7. Para o próximo re-teste
- **N1:** decisão do Manager/PA entre (a), (b) e (c), implementação e o teste indicado.
- **N2:** ler a foto do provedor Google, com testes do mapeamento, ou apresentar evidência real de que `User.photoURL` muda.
- **N3:** o teste offline que mata a mutação E2.
- Vou rodar de novo `flutter analyze`, `flutter test` 2 vezes, `npm test`, `npm run test:mutations` e `tool/dart_mutations.py`, além de E2 e R1.
