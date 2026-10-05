# 53 - Re-review das regras sociais (Code Reviewer, olhar de segurança de regras)

> Data: 2026-10-05 · Branch `feat/social-friends` (não commitado sobre `main` c60a393) · Entrada: [docs/51](./51-regras-sociais-fatia-0.md), parecer anterior [docs/52](./52-code-review-regras-sociais.md).
> `firestore.rules` (348 linhas) relido INTEIRO, de forma adversarial. Somente leitura: `git status` idêntico antes e depois (só este arquivo é novo).

## Veredito: REPROVADO (1 pendência 🟡 de documentação/contrato; nenhum 🔴)

As regras em si estão corretas e não achei brecha de segurança nem bloqueio irreversível. A única pendência é de contrato: o docs/50 (que o dev de Dart vai seguir) ainda contradiz as regras finais na foto e falta um requisito de cliente. Corrigir em 5 minutos e o veredito vira APROVADO, sem tocar em `firestore.rules`.

## Resultados reais
| Execução | Resultado |
|---|---|
| `npm test` | **208/208 passam**, 0 falhas (64 existentes + 144 sociais) |
| `npm run test:mutations` | **20/20 mortas** (M1..M20) |
| Minhas 9 mutações novas (cópias no scratchpad) | 7 mortas, 2 sobreviveram por redundância de projeto, 1 delas revelou lacuna de teste (abaixo) |
| `git diff --stat` | `firestore.rules` **+284/−0** (o docs/51 diz +274: ver 🟢-1) |

Mutações minhas (cada uma remove/relaxa UMA coisa de uma cópia):
| # | Mutação | Resultado |
|---|---|---|
| R1 | `friendships` create sem `isGoogle()` | MORTA ("only Google sign-in can ... create a pair") |
| R2 | `social` create sem `isGoogle()` | SOBREVIVEU: **equivalente por desenho**. `social` exige `getAfter(handle).uid` e `handles` create exige `isGoogle()` no mesmo batch; sem handle Google não há `social`. Nenhum vetor. |
| R3 | `handles` create sem `isGoogle()` | SOBREVIVEU: idem (o `social` create ainda exige `isGoogle()`). Remover as duas juntas é a M15/helper, morta. |
| R4 | foto sem a `/` depois de `.com` (`...com.*$`) | MORTA |
| R5 | bidi U+202A–202E removido do filtro | MORTA |
| R6 | reservado `anonymous` removido | MORTA |
| R7 | zero-width U+200B removido | MORTA |
| R8 | `\p{Cc}` removido | MORTA |
| R9 | foto aceita prefixo antes de `lh<n>` (`^https://[^/]*lh...`: permitiria `https://evil.com?lh3.googleusercontent.com/x`) | **SOBREVIVEU: lacuna de TESTE** (a regra real está certa, ancorada em `^https://lh`). Ver 🟢-2. |

## Status por item pedido
**(1) `isGoogle()`: OK.**
- Claim: a doc oficial de regras e Auth ([Security Rules and Firebase Authentication](https://firebase.google.com/docs/rules/rules-and-auth)) define `request.auth.token.firebase.sign_in_provider` como o provedor usado para obter o token, valores `custom, password, phone, anonymous, google.com, facebook.com, github.com, twitter.com`. O app (`lib/auth/firebase_auth_repository.dart`) só usa `signInWithPopup(GoogleAuthProvider())` (web) e `signInWithCredential(GoogleAuthProvider.credential(...))` (nativo): ambos produzem `google.com`. Não há Apple/e-mail/anônimo no código. (Não consegui abrir a página com o texto literal via fetch; confirmei pelo resultado de busca da própria doc oficial. Marcado como "não verificado no Firebase real".)
- Provedor vinculado depois / token antigo: o claim reflete o login **atual**; quem entrar por e-mail/senha numa conta com Google vinculado perde apenas as CRIAÇÕES sociais (continua lendo, atualizando, apagando). O `reauthenticateWithPopup` da exclusão mantém `google.com`. Token antigo mantém o claim até expirar (1 h) e é renovado igual. Sem claim = erro = negado (seguro).
- Só em CRIAÇÃO: conferido linha a linha. `social` create, `handles` create, `friend_requests` create, `friendships` create, `invites` create têm `isGoogle()`; **nenhum** update/delete tem. Exclusão em sequência da conta (`social`/`handles`/`invites` delete, varredura de pedidos/pares/blocos) e desbloquear/cancelar/recusar/desfazer funcionam para qualquer provedor. `blocks` create não exige Google (bloquear é defesa). Refresh/fan-out de foto e apelido (`friendships` update própria metade, `handles` update, `invites` update) não usa `isGoogle`. Troca de handle é update de `social` + create de `handles`: exige Google, o que é o caso do app. Nenhuma operação do docs/50 fica fora do alcance do app Google legítimo. Nenhuma chamada nova (`isGoogle` lê só o token).

**(2) RE2 de `validName`: OK com risco residual declarado.**
- Construções usadas: `(?s)`, `.*`, classe `[...]` com `\p{Cc}`, `\x{HHHH}` e faixas `\x{202A}-\x{202E}`: todas sintaxe RE2 padrão (o `matches` de Firestore rules é RE2 sobre a string inteira). A página oficial que li (regex de Realtime Database) lista só um subconjunto básico e **não** menciona `\p{}`; não consegui abrir a referência de Firestore `rules.String` (retornou página errada). **Não verificado em produção**; o emulador aceita.
- Risco: se produção não compilar a regra, a publicação é **rejeitada** com erro de sintaxe no console (seguro, nada muda). Se compilar mas falhar em runtime, `matches` vira erro = negado: toda criação social negaria nome (travaria só o social novo, o app atual segue). Detecção pelo Manager: (a) ao clicar Publicar, o editor mostra erro e não publica; (b) o smoke com 2 contas (passo 5) ativa/pede e falharia na hora. Se ocorrer: republicar as regras sem a linha do `matches` do `validName` (as regras são só texto, republicar é possível; "não voltam atrás" é decisão de produto, não limite técnico). Sugestão 🟢: o Manager fazer o smoke ANTES de lançar o app (já é o passo 5/4).
- Aceitos: acentos, CJK, emoji, ZWJ (U+200D de fora de propósito), espaços internos: testados. Limites 1/40 testados. DoS: RE2 é linear, string ≤ 40 após `size()` (o `&&` curto-circuita antes do regex).
- Lacunas conhecidas (🟢-3): `trim()` não remove NBSP/U+3000/U+2800/tags U+E00xx/soft hyphen: apelido "invisível" possível; homógrafos impossíveis de filtrar sem servidor. Contagem de `size()` (code points x UTF-16 x bytes) em produção não testada com 40 emojis.

**(3) Reservados: OK.** 31 itens. Maiúsculas barradas pelo formato `[a-z0-9_]`; `_` nas pontas barrado; `admin1`, `cinetrack_oficial`, `staff_1`, `cine_fan` passam (decisão aceitável: só nomes exatos; prefixos seriam excessivos). Sem handle do dono/projeto específico (`cinetrack` e `cine` estão). Homógrafos impossíveis (ASCII só). Teste cobre 22 dos 31 (🟢-1).

**(4) Foto: OK nas regras.** `^https://lh[0-9]+[.]googleusercontent[.]com/.*$`: ancorada, `https` obrigatório, sem userinfo/`@`/`//` antes do host, sem `.evil.com`, ≤ 512, `.` não casa quebra de linha (negado). Formatos reais do Firebase Auth passam: `https://lh3.googleusercontent.com/a/ACg8oc...=s96-c`, `lh4..lh6`, formato antigo `/-XdU.../photo.jpg` (testados `lh3`/`lh12`). Risco residual: usuário cuja `photoURL` não case (host novo) teria o pedido negado; ver a pendência 🟡-1 (cliente deve enviar `null`).

**(5) Validações da 1ª revisão: continuam verdadeiras.** Reli todos os blocos: amizade só com `get(pedido do outro)` e pedido(s) consumido(s) no mesmo batch (`!existsAfter` x2), nome do outro lado vem do pedido; bloqueio só nasce com par/pedidos apagados no batch e par/pedido/convite/cartão negados nos dois sentidos; `handles` e `invites` só `get` (sem `list`), `social` só do dono; invariante amigo ⇒ não bloqueado; máx. 7 chamadas por operação (≤ 10), `isGoogle` não acrescenta; compat com regras antigas v1/v2 e favoritos fechados cobertos por `social_compat.test.mjs`. Diff só aditivo (0 remoções). Existência de handle oculto x inexistente distinguível (`permission-denied` x "não existe"): inerente (criar handle ocupado também revela), mitigado pelo requisito da mensagem única.

**(6) docs/51: OK, com 2 imprecisões 🟢.** Passo 0 (somente Google), conferência pós-publicação (data/hora, sem erro no editor), resíduo de bloqueio + mensagem genérica, ordem índices/regras, "Enabled", propagação ~1 min: tudo presente e correto. **docs/49-50: parcial** (ver 🟡-1).

**(7) Não verificado declarado: OK** (docs/51 §8: nada em Firebase real, índices, cobrança das leituras de regra, entropia do convite, RE2 em produção, relógio). Acrescento: contagem de `size()` e o texto literal da doc do claim.

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes (corrigir para aprovar)
**🟡-1. Contrato de foto desatualizado no docs/50 e falta requisito de cliente.**
- `docs/50-design-amizades.md` ainda diz que a foto é `https://*.googleusercontent.com/...` (linha ~40) e traz a função `validPhoto` antiga com `^https://[A-Za-z0-9-]+[.]googleusercontent[.]com/.*$` (linha ~141); a lista de reservados (11) e `validName` do docs/50 também divergem das regras finais. O docs/50 é o contrato que o dev Dart seguirá.
- Corrigir: (a) atualizar essas linhas/trecho para o padrão final `^https://lh[0-9]+[.]googleusercontent[.]com/.*$` (ou apontar "ver `firestore.rules` e docs/51 §2" como fonte única); (b) acrescentar nos "Requisitos acrescentados" de docs/49 e docs/50: **o cliente só envia `photoURL` se casar com esse padrão e ≤ 512 caracteres; caso contrário envia `null`/omite**, e normaliza o apelido (trim, ≤ 40, sem controle/zero-width/bidi) antes de gravar, para nunca ter um pedido negado por foto/nome do próprio perfil Google.

## 🟢 Sugestões
- 🟢-1: docs/51 diz "+274 linhas" (o diff é +284) e "22 reservados negados" (são 31 na regra; 9 sem teste individual). Ajustar os números.
- 🟢-2: acrescentar teste de foto com `https://evil.com?lh3.googleusercontent.com/x` e `https://evil.com#lh3.googleusercontent.com/x` (mata a R9) e, se quiser, uma mutação 21 para isso.
- 🟢-3: apelidos só de caracteres invisíveis (NBSP, U+3000, U+2800, tags) passam; filtrar `\p{Zs}`-só exigiria regex extra: aceitar e registrar como limitação.
- 🟢-4: teste de 40 CJK/emoji (confirma o que `size()` conta em produção ao fazer o smoke).

## Segurança
Sem 🔴. `isGoogle()` correto, só em criação; `validName`, reservados e foto endurecem sem quebrar o app atual nem criar bloqueio irreversível. Único risco novo é de compilação/runtime do RE2 em produção, detectável na publicação e no smoke, de impacto limitado ao social novo.
