# 74 - Re-review integrado: amizades, fechamento da Fase 1

> Revisor: Code Reviewer (gate antes da publicação). Escopo: working tree NÃO commitado sobre `feat/social-friends` (`5755b85`), rastreado em [docs/73](./73-social-fechamento-fase-1.md). O que confiro: os achados do [docs/71](./71-code-review-integrado-fase-1.md) e as lacunas L1–L4 do [docs/72](./72-parecer-qa-fase-1.md).
>
> Como trabalhei: somente leitura no worktree; todas as execuções em cópias isoladas no scratchpad. `firestore.rules`, `lib/`, `test/`, fixtures e `*.mjs` foram conferidos com `cmp`/`diff -r` contra o worktree antes e depois das execuções. As regras rodaram na porta 8192, porque o QA re-testava na 8080.
>
> `git status` do worktree: igual antes e depois, exceto este documento. Durante a revisão apareceram `docs/75-reteste-qa-fase-1.md` e `firestore_rules_test/firebase-debug.log` (ignorado), ambos do QA, não meus.

**Veredito: 🔁 REPROVADO** (0 🔴, 1 🟡, 2 🟢).

O fechamento está bem feito. Fecham todos os achados do docs/71 (🟡-1, 🟡-3 e G1 a G10) e, do ponto de vista de código, L1 a L4. O 🟡-2 está implementado e testado, mas eu o reabro como 🟡-R1: com alta probabilidade a fonte da foto (`user.photoURL` do Firebase Auth) não muda quando a pessoa troca a foto no Google. Nesse caso a funcionalidade decidida pelo Manager nunca dispara em produção, e a política promete algo que não acontece. A correção é de uma linha.

## Números que eu mesmo rodei
| Verificação | Resultado |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` | **1522 passaram**, 0 falhas. A 1ª execução deu 1521 + 1 falha no golden, só porque a minha cópia ainda não tinha `firestore_rules_test/fixtures`. Com o fixture copiado, a suíte inteira deu **+1522: All tests passed** |
| `flutter build web --base-href /cinetrack/` | **✓ Built build/web** |
| `npm test` (JDK 24 via `JAVA_HOME` só no comando; cópia isolada, porta 8192, `firestore.rules` idêntico por `cmp`) | **376/376**, 41 suítes, 0 falhas, 0 pulados |
| `npm run test:mutations` (mesma cópia) | **BASELINE ok** (325 `ok`, 0 `not ok`) e **"All 52 mutations were killed"**, 52 `KILLED`, 0 `ERROR`, exit 0 |
| `tool/dart_mutations.py` (cópia sem `.git`) | **13/13 mortas** (D4, D5, D9 a D19) |
| `firestore.rules` vs `main` | só adições. Contra `5755b85`, muda só `validRequest` (`fromHandle`) e entram comentários. `users/**`, favoritos, `validProfile`, `validFavorite` e índices: sem mudança |

## Situação dos achados do docs/71
| Id | Situação | Como conferi |
|---|---|---|
| 🟡-1 busy = sucesso | **Fechado** | `social_providers.dart` `_run` devolve `SocialFailureKind.busy`. O botão do cabeçalho do Perfil fica travado (`profile_screen.dart:28,63`). Os testes (`social_closing_test.dart`) cobrem o meu cenário do docs/71. D10 e D11 mortas |
| 🟡-2 foto do Google | **Implementado, mas reaberto como 🟡-R1** (abaixo) | O fluxo do app está correto (uma vez por sessão, sem laço, respeita a foto desmarcada, nada offline, convite junto). O problema é a fonte do dado |
| 🟡-3 falsificação de identidade | **Fechado** | Ver a revisão adversarial abaixo |
| G1 README | **Fechado** | `README.md:49` ("Fase 1, concluída: fatias 0 a 5 + fechamento"), suítes de regras e `test:mutations`, `social/` na Estrutura (`:104`) |
| G2 docs/50 §9 | **Fechado** | leitura |
| G3 docs/39 (schema 2) | **Fechado** | leitura |
| G4 uid | **Fechado** | comentário em `export_serializer.dart` e política ("Quem vê o quê") |
| G5 exclusão engolindo `denied` | **Fechado** | `closeSocial` marca só a negação da leitura do próprio ponteiro (`kSocialReadDeniedCode`). `wipeForAccountDeletion` só retorna em silêncio nesse caso. Testes de leitura negada x batch negado. D15 morta |
| G6 resíduo na exportação | **Fechado** | `data_exporter.dart` lê as 4 listas sem ponteiro; `denied` sem ponteiro = nada; `social` continua `null` sem resíduo. D16 morta |
| G7 código morto | **Fechado** | `isHandleFree`/`handleProblem` removidos de todas as implementações |
| G8 duplicação | **Fechado, sem regressão** | `send_request_controls.dart` é usado pela busca e pelo convite com os mesmos textos e rótulos; as suítes de tela passam sem mudar asserções. A exportação reaproveita `FirestoreSocialDataSource.read` e `sweepQuery`/`socialQuery`. `RawSocialPage` |
| G9 mutações com linha de base | **Fechado** | Baseline visto no log. `KILLED` só com `not ok`; saída diferente de 0 sem teste falhando vira `ERROR` e o total falha |
| G10 `isFriend` com resíduo | **Fechado** | comentário em `firestore.rules:66-70` e docs/51 §2/§3 |

## Lacunas do QA (docs/72), do ponto de vista de código
- **L1, fechada.** `activate` lê `social/{uid}` antes do handle (D9). Leitura do próprio ponteiro negada vira `denied` ("Amizades ainda não estão disponíveis"). Handle escondido vira `handleTaken`, nunca "livre" (D4, D5 mortas no caminho real, via o ponto de injeção `SocialPlanner`). O fake foi alinhado.
- **L2, fechada.** Quem está fora da busca continua buscando, enviando, cancelando e aceitando. Há testes de regras, de replay e de widget, e a M40 morta. A regra não exige `discoverable` do remetente.
- **L3, fechada.** `kSearchNotFoundMessage` é a mensagem única. O teste confere o texto literal (D19).
- **L4, fechada.** O teste de cota esgotada confirma que Favoritos continua listando e marcando.

## Revisão adversarial do diff novo
- **`fromHandle` nas regras** (`firestore.rules:144-164`). O `get(socialPath(d.from)).data.handle == d.fromHandle` substitui o `exists` do mesmo caminho, então o custo continua 5 chamadas (`rules_budget`). Remetente sem `social`: o `get` falha e o pedido é negado. Tipo ou valor errado: a igualdade falha. Sem campo: `hasAll` nega.
  - **Pedido cruzado e aceite:** `validFriendshipCreate` não lê `fromHandle`, e os testes de cruzado e de aceite continuam passando.
  - **Troca de handle depois do envio:** o pedido pendente continua aceitável e pedidos novos exigem o handle novo, como o Manager decidiu (testado).
  - **Handle antigo reivindicado por outra pessoa:** os pedidos dela mostram `@antigo` de forma legítima. É a reutilização de handle já aceita em D2.
  - **Oculto:** o destinatário vê o `@handle` de quem está fora da busca. Isso está declarado na política e no resumo do app.
  - **Bloqueio:** inalterado (`!isBlockedEither`).
  - **Exibição no app:** o cartão recebido só mostra o handle se for canônico (`Handle.parse(h) == h`).
  - **Conclusão:** nenhuma brecha nova.
- **Foto** (`social_providers.dart:215-249`, `_syncGooglePhoto` em `:232`).
  - `_photoChecked` é zerado em `build()`, ou seja, também na troca de conta.
  - A releitura feita pelo próprio `_run` cai no guarda e não grava de novo (D14).
  - Se a seção estiver ocupada, a conferência fica para a próxima leitura.
  - Offline/cache: nada é gravado.
  - Foto desmarcada: nada é gravado (D13).
  - A geração é conferida antes do refresh.
  - Não achei laço nem escrita em outra conta.
- **G5/G6.** `closeSocial` com a leitura offline vira falha retomável, não um "pular". Exportação: `unauthenticated` continua mapeado como antes.
- **G8.** `readSocial` da exportação agora passa pelo `_guard` social. A tradução para `ExportReadFailureKind` preserva o comportamento anterior. Um convite ilegível vindo do servidor agora falha a exportação em vez de omitir o convite (mais correto).

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes
**🟡-R1. A foto do Google que o app compara provavelmente nunca muda: `lib/auth/firebase_auth_repository.dart:158` (`photoUrl: user.photoURL`).**
O 🟡-2 compara `currentUser.photoUrl` com o cartão, e esse valor vem do `user.photoURL` de nível superior do Firebase Auth. Esse campo é preenchido na criação da conta e depois **não** acompanha a foto do Google. Quem é atualizado no login com o Google é `providerData` (entrada `google.com`). Confiança média-alta: documentação e discussões do Firebase indicam isso ("Once initialized, the Firebase user-account is no longer updated"; para os dados do provedor, usar `providerData`). Não verifiquei num projeto real, e os testes usam o `FakeAuthRepository`, por isso não podem pegar.

Consequências:
- a conferência do 🟡-2 compara sempre o mesmo valor e nunca grava;
- `web/privacidade.html:114-117` ("na próxima vez que você abrir o app conectado") e `privacy_summary.dart:66` prometem uma atualização que não acontece;
- o docs/73 registra a dúvida como "não verificado", mas o item foi marcado como fechado.

Correção:
- em `_toAppUser`, usar a foto do provedor Google: `user.providerData.where((i) => i.providerId == 'google.com').map((i) => i.photoURL).firstWhere((p) => p != null, orElse: () => user.photoURL)`. Isso também atualiza o avatar do app;
- teste unitário do mapeamento (a função hoje é privada; extrair `appUserFrom(User)` ou testar via `mocktail`, ou ao menos cobrir a regra de escolha numa função pura);
- como `providerData` só é renovado num login com o Google (ou na reautenticação), ajustar o texto para "na próxima vez que você **entrar com o Google**" em `web/privacidade.html:116`, `privacy_summary.dart:66` e `docs/49:238`;
- incluir no smoke do docs/72 §7: trocar a foto no Google, sair, entrar e conferir o cartão.

Alternativa, se o Manager preferir evidência a código: fazer esse smoke em produção antes de fechar. Se `user.photoURL` mudar de fato, o item fecha sem alteração e a política só precisa dizer quando a foto atualiza.

## 🟢 Sugestões (baratas)
- **R2. Remover a foto no Google desliga "Mostrar minha foto" para sempre.** `photoVisible` é derivado de `photoUrl != null` (`social_models.dart:38`). Se o Google ficar sem foto, o cartão vira `null`, e quando a pessoa puser uma foto nova no Google ela não volta sozinha. É o lado seguro, mas a política diz só "o cartão fica sem foto". Acrescentar "para voltar a mostrar, ligue 'Mostrar minha foto'" em `web/privacidade.html:117` (e em docs/49:238).
- **R3. Interferência no emulador.** O baseline de `mutations.mjs` não protege contra outra execução que limpe o mesmo emulador no meio da rodada, porque isso geraria `not ok` espúrios contados como `KILLED`. Hoje o QA e o Dev rodam na 8080 no mesmo worktree. Documentar no README (`:94`) "rode isolado; com outra execução na 8080, use uma cópia com outra porta", ou ler a porta de `FIRESTORE_PORT` no `firebase.json` via variável.

## ❓ Perguntas
Nenhuma.

## Segurança: ok
O amarramento ao `@handle` fecha a falsificação de identidade sem custo de regra, e não achei brecha nova. Os dados atuais (favoritos, progresso, assistido, recomendações) não são tocados por nada deste diff.

## O que NÃO verifiquei
- Projeto Firebase real: a premissa do 🟡-R1, o `get()` em `validRequest` com cobrança real, os índices "Enabled".
- Navegador real e leitor de tela.

## Para a re-revisão
- Corrigir o 🟡-R1, ou trazer a evidência do smoke.
- Ajustar os textos de R1 e R2.
- Repetir `flutter analyze` e `flutter test` (as regras não mudam com essa correção; se mudarem, repetir também `npm test` e `test:mutations` isolados).
