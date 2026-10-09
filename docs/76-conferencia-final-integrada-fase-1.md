# 76 - Conferência final integrada: amizades, Fase 1 (rodada 2 do fechamento)

> Revisor: Code Reviewer (gate antes da publicação). Escopo: working tree NÃO commitado sobre `feat/social-friends` (`5755b85`), seção "Rodada 2" do [docs/73](./73-social-fechamento-fase-1.md). O que confiro: 🟡-R1, R2 e R3 do [docs/74](./74-re-review-integrado-fase-1.md) e N3 do QA.
>
> Como trabalhei: somente leitura no worktree; execuções em cópias isoladas no scratchpad, conferidas com `cmp`/`diff -r`. As regras rodaram na porta 8193, com hub, logging e websocket próprios, porque o QA usava 8080/9150 no worktree. `git status` do worktree igual antes e depois, exceto este documento.

**Veredito: 🔁 REPROVADO** (0 🔴, 1 🟡, 1 🟢).

R2, R3 e N3 estão fechados. O 🟡-R1 mudou de forma: a foto agora vem do provedor Google, como pedi, mas o recuo para o `photoURL` do topo, quando o provedor Google está **sem** foto, publica de novo a foto da criação da conta. Reproduzi isso em teste. A correção é pequena.

## Números que eu mesmo rodei
| Verificação | Resultado |
|---|---|
| Regras, índices e fixture nesta rodada | **sem mudança**: `cmp` de `firestore.rules`, `diff -r` das fixtures e `cmp` de cada `*.mjs` contra a cópia da rodada anterior; `git diff -- firestore.indexes.json` vazio |
| `flutter analyze` | **No issues found** |
| `flutter test` | **1530 passaram**, 0 falhas (`+1530: All tests passed!`) |
| `flutter build web --base-href /cinetrack/` | **✓ Built build/web** |
| `npm test` (JDK 24 só no comando; porta 8193) | **376/376**, 41 suítes, 0 falhas, 0 pulados (cópia isolada, porta 8193, `firestore.rules` idêntico por `cmp`) |
| `npm run test:mutations` | **BASELINE ok** (325 `ok`, 0 `not ok`) e **"All 52 mutations were killed"**, 52 `KILLED`, 0 `ERROR`, exit 0 |
| Prova do 🟡-R2 (teste meu, só na cópia) | "REVIEW PROOF": `pickPhotoUrl(topLevel: criação, google.com sem foto)` + a sincronização da sessão grava a **foto da criação** no cartão e no convite (o teste passa, logo o defeito existe) |

Observação sobre G9: a 1ª tentativa de `test:mutations` disputou a websocket 9150 com o emulador do QA. A linha de base **abortou** ("BASELINE FAILED ... 325 not ok") em vez de contar 52 mortes falsas. É exatamente o que a correção G9 deveria fazer. Encerrei o emulador órfão meu (porta 8193) e rodei de novo com portas próprias.

## Situação dos achados
| Id | Situação | Como conferi |
|---|---|---|
| 🟡-R1 fonte da foto | **Parcial**: a fonte mudou, mas o recuo é inseguro (ver 🟡-R2 abaixo) | `lib/auth/app_user.dart:53-62`, `firebase_auth_repository.dart:159-165`. Os consumidores de `AppUser.photoUrl` são o avatar do app (`account_widgets.dart:23`), a sincronização do cartão (`social_providers.dart:237`), ativar e "Mostrar minha foto" (`:267,:297`), o diálogo de ativar (`social_dialogs.dart:70`) e `friends_screen.dart:1156`. A exportação não usa (a foto não vai no arquivo). Testes antigos: 1530 passam |
| R2 religar é manual | **Fechado** | Legenda do interruptor `social_section.dart:237` (`kPhotoOnHint`/`kPhotoOffHint`); política `privacidade.html:114-120`; resumo do app; docs/49:238; teste de 2 sessões e 2 testes de widget |
| R3 portas | **Fechado** | README: rodar isolado e trocar a porta em `emulators.firestore.port`. Ver 🟢-1 |
| N3 (QA) cache não sincroniza | **Fechado** | `FakeSocialCloud.attempts` conta a tentativa antes da recusa; o teste offline espera 0 tentativas e 1 ao voltar; a mutação E2 está em `tool/dart_mutations.py` |
| Textos | **Coerentes**, exceto a 1ª frase de `docs/49:238` (🟢-2) | política, resumo, legenda, README:49, docs/49 |

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes
**🟡-R2. Foto removida do Google recoloca a foto da criação da conta: `lib/auth/app_user.dart:53-62` (`pickPhotoUrl`).**
Quando existe a entrada `google.com` em `providerData` mas ela está sem foto, `pickPhotoUrl` recua para `user.photoURL` do topo. Pelo próprio comentário da função (e pelo docs/74), esse campo é o da **criação** da conta e nunca muda.

Cenário:
1. Ana criou a conta com a foto A e depois trocou para B no Google. Ao entrar, o cartão passa a mostrar B (correto).
2. Ana remove a foto no Google e entra de novo. O provedor vem sem foto, `pickPhotoUrl` devolve **A**, e `_syncGooglePhoto` grava A no cartão, no convite e, pelo refresh, em todos os amigos.

Resultado: uma foto que a pessoa abandonou volta a ser publicada, contra a decisão do Manager de 09/10 ("Google sem foto → cartão sem foto e interruptor desligado") e contra a política (`privacidade.html:117-118`). Os testes não pegam porque `social_closing_test.dart` injeta `AppUser.photoUrl` direto (`_ana(photo: null)`), sem passar por `pickPhotoUrl`, e `app_user_mapping_test.dart:35-45` **fixa** o recuo como correto. Reproduzi a composição na cópia ("REVIEW PROOF", acima).

Correção:
- em `pickPhotoUrl`, quando existir uma entrada `google.com`, devolver `usable(p.photoUrl)`, que pode ser `null`, **sem** recuar para o topo. O topo só vale quando não há entrada `google.com`;
- trocar o teste `app_user_mapping_test.dart:35-45` para esperar `null`;
- acrescentar um teste de composição (`pickPhotoUrl` → `AppUser` → sincronização) que prove "removida = cartão sem foto, nunca a foto da criação";
- incluir uma mutação Dart (por exemplo, "E5 recuo para o topo com provedor Google sem foto").

Não verificado: se, ao remover a foto, o Google devolve `null` ou um avatar de letra gerado (`lh3.../a/...`). No segundo caso o cartão mostraria o avatar de letra em vez de "sem foto". Conferir no passo de foto do smoke (docs/75 §6) e, se for o caso, ajustar o texto da política.

## 🟢 Sugestões (baratas)
- **🟢-1. README sem portas auxiliares.** A websocket (9150), o hub (4400) e o logging (4500) também colidem entre execuções paralelas. Acrescentar em `README.md:94` que a cópia precisa trocar também `emulators.firestore.websocketPort`, `emulators.hub.port` e `emulators.logging.port` (foi o que derrubou a minha 1ª tentativa).
- **🟢-2. Frase antiga no docs/49.** `docs/49-especificacao-amizades.md:238` começa com "até o dono reabrir o app", o que contradiz o fim do mesmo item ("na próxima vez que a pessoa entrar com o Google"). Trocar a 1ª frase.

## ❓ Perguntas
Nenhuma.

## Segurança: ponto 🟡-R2 (republica uma foto abandonada). Regras inalteradas e sem brecha nova; dados atuais (favoritos, progresso, assistido, recomendações) não são tocados.

## O que NÃO verifiquei
- Projeto Firebase real: se o `providerData` é de fato renovado a cada login e o que o Google devolve quando a pessoa remove a foto.
- Navegador real.

## Para a próxima conferência
- Corrigir o 🟡-R2 com os testes e a mutação indicados.
- Aplicar 🟢-1 e 🟢-2.
- Repetir `flutter analyze` e `flutter test`. As regras não mudam; se mudarem, repetir `npm test` e `test:mutations` isolados.
