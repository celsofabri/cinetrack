# 78 - Conferência final: amizades, Fase 1 (rodada 3 do fechamento)

> Revisor: Code Reviewer (gate antes da publicação). Escopo: working tree NÃO commitado sobre `feat/social-friends` (`5755b85`), seção "Rodada 3" do [docs/73](./73-social-fechamento-fase-1.md). Confiro o 🟡-R2 e as duas 🟢 do [docs/76](./76-conferencia-final-integrada-fase-1.md).
>
> Execuções em cópias isoladas no scratchpad, com **todas** as portas do emulador trocadas: firestore 8194, websocket 9194, hub 4494 e logging 4594. As portas padrão ficaram com o QA. Antes de relatar, conferi que as cópias continuam idênticas ao worktree: `cmp` de `firestore.rules`, de cada `*.mjs` e de `tool/dart_mutations.py`, e `diff -r` de `lib/`, `test/` e fixtures. Também conferi com `lsof` que nenhum emulador meu ficou aberto.
>
> Somente leitura; `git status` do worktree igual antes e depois, exceto este documento.

**Veredito: ✅ APROVADO.** 0 🔴, 0 🟡, 0 🟢 pendentes. Com isto e com os docs 71, 74 e 76, todos os achados do Code Review da Fase 1 estão fechados.

## Números que eu mesmo rodei
| Verificação | Resultado |
|---|---|
| Regras, índices e fixture | **sem mudança** nesta rodada (`cmp`/`diff -r` contra a cópia da rodada 2; `git diff -- firestore.indexes.json` vazio) |
| `flutter analyze` | **No issues found** |
| `flutter test` | **1531 passaram**, 0 falhas (`+1531: All tests passed!`) |
| `flutter build web --base-href /cinetrack/` | **✓ Built build/web** |
| `npm test` (JDK 24 só no comando) | **376/376**, 41 suítes, 0 falhas, 0 pulados |
| `npm run test:mutations` | **BASELINE ok** (325 `ok`, 0 `not ok`); **"All 52 mutations were killed"**, 52 `KILLED`, 0 `ERROR` |
| `tool/dart_mutations.py E4 E5` (cópia sem `.git`) | **2/2 mortas**. As outras (D4, D5, D9 a D19, E2) são do código que não mudou nesta rodada e já estavam mortas no docs/74 e no docs/76 |

## Situação dos achados do docs/76
| Id | Situação | Como conferi |
|---|---|---|
| 🟡-R2 recuo para a foto da criação | **Fechado** | `lib/auth/app_user.dart:53-62`: com uma entrada `google.com`, a resposta é a foto dela, inclusive `null` ou vazia; o `photoURL` de nível superior só vale sem entrada do Google. O teste invertido (`app_user_mapping_test.dart`) espera `null`, inclusive quando outro provedor tem foto. O teste de **composição** em `social_closing_test.dart` (`pickPhotoUrl` → `AppUser` → sincronização) prova: cartão, convite e metade da amizade sem foto, nunca a foto da criação, e interruptor desligado. É o cenário do meu "REVIEW PROOF", agora com a expectativa certa. A mutação E5, que restaura o recuo, está morta |
| 🟢-1 portas auxiliares no README | **Fechado** | `README.md:94` cita `websocketPort` (9150), hub e logging para a cópia isolada |
| 🟢-2 frase antiga no docs/49 | **Fechado** | `docs/49-especificacao-amizades.md:238` diz agora "até a próxima vez que a pessoa entrar com o Google", coerente com o resto do item |

Revisão adversarial do diff desta rodada: só `pickPhotoUrl` mudou no app. Não existe mais de uma entrada `google.com` em `providerData`. Sem a entrada do Google, o comportamento é o anterior. Os consumidores de `AppUser.photoUrl` (avatar, sincronização, ativar, "Mostrar minha foto", diálogo) recebem `null` quando o Google está sem foto e já tratavam `null`, porque o avatar cai nas iniciais. Não achei regressão: a suíte inteira passa.

## 🔴 Bloqueantes
Nenhum.
## 🟡 Importantes
Nenhum.
## 🟢 Sugestões
Nenhuma pendente.
## ❓ Perguntas
Nenhuma.

## Segurança: ok
Uma foto removida do Google não é mais republicada. As regras não mudaram nesta rodada e seguem sem brecha conhecida. Os dados atuais (favoritos, progresso, assistido, recomendações) não são tocados.

## O que NÃO verifiquei
Projeto Firebase real:
- se `providerData` é renovado a cada login;
- se o Google devolve `null` ou um avatar de letra ao remover a foto;
- a cobrança das leituras de regra;
- os índices "Enabled".

Isso é coberto pelo passo de foto do smoke (docs/75 §6) e pelo rollout de docs/73 (regras e índices publicados antes do app; nunca voltar as regras).
