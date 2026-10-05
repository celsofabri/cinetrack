# 56 - Code review: Amizades, fatia 1 (ativação, exclusão, exportação, privacidade)

> Revisor: Code Reviewer (gate) · 2026-10-05 · Branch `feat/social-friends` (fatia 0 em `8c5d9dd`; fatia 1 = working tree não commitado). Contrato: ADR-005, docs/49, docs/50, docs/51 (regras finais), docs/55. Somente leitura: nenhum código foi alterado.

## Veredito: REPROVADO (correções pequenas; nenhum bloqueio de produção)

O Manager exige APROVADO limpo (nenhum 🔴 nem 🟡). Não há 🔴. Há **2 🟡**, ambos de correção curta e sem risco para as regras (que não mudam). Corrigidos e re-conferidos, o veredito passa a APROVADO.

## Resultados reais (rodados por mim)

| Verificação | Resultado |
|---|---|
| `flutter analyze` | 0 issues |
| `flutter test` | **952 passam**, 0 falhas |
| `flutter build web --release` | OK (`build/web`) |
| `npm test` (regras, emulador, JDK 24) | **219/219**, 0 falhas |
| `git diff -- firestore.rules firestore_rules_test firestore.indexes.json` | vazio (intocados) |
| `git diff --check` | sem erro de espaço em branco; diff dos arquivos antigos mínimo (sem ruído de formatação) |
| **Replay no emulador das escritas exatas do `FirestoreSocialDataSource`** (script Node, mesmo protocolo do SDK web) | **9/9** (ver abaixo) |
| Chrome / tela no navegador | **Não verificado**: o Perfil exige login Google; não há como abrir a tela sem login. Só os testes de widget (320-1440 px, fonte 3x, claro/escuro, semântica) foram vistos passar |

### Replay contra o emulador (o buraco que o dev declarou)
Escrevi `dart_payloads.test.mjs` (no scratchpad da sessão: `.../scratchpad/rv/`, usando `social_helpers.mjs` e `firestore.rules` reais) que reproduz, operação a operação, `activate`, `changeHandle`, `updateCard`, `closeSocial` e as varreduras do Dart (transações com `tx.get` antes de `tx.set`, `serverTimestamp`, `photoURL: null`, `schemaVersion: 1`, batch com cartão + ponteiro, queries `from`/`to`/`array-contains`/`blocks` com `limit(400)`). Resultado, todos como esperado:
- ativar sem foto, com foto e com `discoverable:false` => aceito; contexto não-Google (`password`) e sem claim => negado;
- handle reservado (`admin`) => negado; handle alheio oculto => `tx.get` negado (o cliente mapeia para "indisponível"); inexistente => `get` permitido;
- apelido de 20 emoji aceito, 21 negado, 40 CJK aceito (contagem em unidades UTF-16 igual à do cliente);
- trocar handle em < 30 dias negado; > 30 dias aceito, ponteiro e cartão movidos na mesma transação, handle antigo fica livre para outro usuário;
- `updateCard` (apelido, `discoverable`, `photoURL` null/valor, combinados) aceito;
- `closeSocial` + 4 varreduras com amigo, pedidos enviado/recebido e bloqueios: nada sobra (cartão, ponteiro, par, pedidos); bloqueio de terceiro contra o usuário permanece (aceito pelo docs/50); idempotente; **conta sem social**: `closeSocial` e as 4 queries vazias são permitidas (a exclusão de conta não trava).
Limite: o emulador **não impõe índices** (as queries são de campo único/igualdade/`array-contains` sem `orderBy`, então não pedem índice composto, mas só o projeto real prova) e o Dart em si não rodou (a leitura linha a linha confere com o replay). Recomendação 🟢-1 abaixo.

## 1. Compatibilidade cliente x regras (conferida campo a campo)
Sem divergência encontrada.
- `activate` (`firestore_social_data_source.dart:68-92`): cartão com exatamente `uid, nickname, photoURL (null ou URL), discoverable, createdAt, updatedAt` (`hasOnly`/`hasAll` ok; `photoURL` nulo passa em `validPhoto`), `createdAt == updatedAt == request.time` via `serverTimestamp`; ponteiro `handle, handleChangedAt (serverTimestamp), schemaVersion:1` sem `inviteCode`; os dois no mesmo commit (`getAfter` satisfeito). Leitura prévia do handle de outro (oculto) cai em `permission-denied` e vira "indisponível" corretamente.
- `changeHandle` (`:95-132`): apaga o cartão antigo, cria o novo e atualiza o ponteiro na mesma transação (`!existsAfter(old)`, `getAfter(new).uid`, `handleChangedAt == request.time`); o `inviteCode` fica fora do `update` (mescla, `n == o`). Intervalo checado no cliente (relógio local) e pelas regras (relógio do servidor).
- `updateCard` (`:135-150`): `update` com `uid`/`createdAt` intactos, `updatedAt` serverTimestamp, `getAfter(social).handle == h` (ponteiro não escrito => estado atual).
- `closeSocial` (`:153-180`): batch apaga só documentos que existem (nunca "no escuro" em `handles`/`invites`, onde a regra exigiria `resource`), ponteiro junto (`!existsAfter`). Cartão órfão/ausente tolerado.
- Varreduras e `deleteRefs`: pedidos (`from`/`to`), pares (`array-contains`) e bloqueios; apagar documento que o outro lado já removeu é aceito pelas regras (`resource == null` com uid no id).
- Reservados: 31 no cliente = 31 em `firestore.rules` (o teste `social_validation_test.dart:30` **lê o arquivo de regras** e compara: mutar qualquer lado quebra o teste). Regex do handle idêntica; `_` nas pontas idêntico.
- Apelido: cliente remove controles, zero-width, bidi, tags e converte NBSP/U+3000/quebras em espaço **antes** de apará-los e de contar (UTF-16, igual à regra); sempre mais estrito ou igual ao `validName`. NFC não é exigido pelas regras (só normaliza o que vai). Foto: mesma regex, `<= 512`, e o cliente ainda rejeita espaços/quebras (mais estrito). Se a foto não passa, o cartão vai sem foto (null), nunca derruba a escrita.
- `serverTimestamp` vs `request.time`, `createdAt/updatedAt`, `null` vs ausente: ok (provado no replay).

## 2. `AppUser.isGoogle` x claim `firebase.sign_in_provider`
`isGoogle` vem de `providerData.any(google.com)` (`firebase_auth_repository.dart:160`), e as regras olham o **provedor do login atual**. Divergem só se a conta tiver Google **vinculado** mas entrou por outro método. O app só oferece login Google (web: popup; mobile: credencial Google) e não há vínculo de provedores, então hoje não diverge. Se divergir, a regra nega e o cliente mostra a mensagem única "Amizades ainda não estão disponíveis. Tente mais tarde." (genérica, sem distinguir causa, como pedido). Ver 🟢-3.

## 3. Privacidade / LGPD / consentimento
- O que se copia e quando: apelido, handle e (se marcado) a **URL** da foto, só ao tocar "Ativar amizades" (texto de consentimento no próprio diálogo). O apelido não vem pré-preenchido com o nome do Google (usa o apelido do app); "Usar meu nome do Google" é ação explícita. Nada social é gravado sem ativar (testado: conta sem social só faz leituras).
- "Aparecer na busca" nasce LIGADO, com interruptor visível e legenda clara no diálogo. Meu juízo: **aceitável** para esta fatia (a ativação é a ação consentida, o interruptor está na mesma tela, o docs/49 só fala "ligada/desligada" e o D10 já adota "foto ligada por padrão, destacada"; e ainda não existe busca, então a exposição efetiva só começa na fatia 2). Mas é decisão de privacidade: pedir **confirmação explícita do Manager** (❓-1). Se preferir o padrão mais protetor, é trocar `_discoverable = true` por `false` (`social_dialogs.dart:64`) e o texto do README.
- Custo/privacidade da leitura: 1 leitura de `social/{uid}` por sessão ao abrir o Perfil (+1 do cartão se ativo); nada em logs além do código de erro (`debugPrint` só com `e.code`, sem PII).
- Textos: ver 🟡-1 (imprecisões na política e na documentação do export).

## 4. AccountDeleter, desativar e exportação
- Exclusão: `markDeleting` -> `wipeForAccountDeletion` (porta primeiro: cartão + convite + ponteiro num batch; depois varre pedidos, pares, bloqueios) -> favoritos -> perfil -> usuário. Idempotente e retomável (o rerun acha o ponteiro ausente e termina as varreduras; testado com falha no meio). Conta sem social: 1 leitura + 4 queries vazias, zero escritas. Regras antigas: leitura negada => retorna sem erro e a exclusão segue (testado). Não toca dados alheios além do permitido (só apaga pares/pedidos em que o usuário é parte; bloqueios de terceiros contra ele ficam, conforme docs/50 - registrar: neles fica uma cópia do apelido dele no documento do bloqueador, ver 🟢-6).
- Desativar: ver 🟡-2.
- Exportação: schema 2 aditivo (`social` null sem amizades; arquivo v1 sem a chave continua legível), D9 respeitado (uid + apelido dos outros; fotos de terceiros não entram), paginação por cursor de snapshot sem `orderBy` (sem índice novo), mapa bruto do cartão/ponteiro preservado, falha de servidor na parte social **aborta** (não perde dado em silêncio), regras antigas => `social: null` e o export continua funcionando.

## 5. Validação de cliente e a dependência `unorm_dart ^0.3.3`
Licença MIT, Dart puro (sem dependências transitivas; o `pubspec.lock` ganha só 1 pacote), SDK `>=2.12 <4.0.0` (compatível com Dart 3.13), mantido (tabelas Unicode recentes), ~256 KB de fonte de tabelas (tree-shaking do dart2js reduz; o build web passou; o tamanho adicional do bundle **não foi medido**). Alternativa sem dependência seria manter tabelas de composição à mão (mais código e mais risco): a escolha é razoável. Usada só em `social_validation.dart`. 🟢 apenas: ver 🟢-5 (tags/bandeiras).

## 6. UI
Seção "Amizades" no Perfil sem aba nova, desligada por padrão, estados carregando (altura mínima igual ao inativo: sem salto), indisponível/erro com "Tentar de novo", conta não Google, offline (ações desativadas com o motivo), ativo. Diálogo de desativar lista o que é apagado, foco inicial em "Cancelar", textos pt-BR coerentes; alvos >= 48 px, `liveRegion` nas mensagens; matriz 320-1440 px, fonte 3x, claro/escuro passa nos testes de widget. Não vi em navegador (ver tabela).

## 7. Regressões
Os 4 testes antigos ajustados são legítimos: `account_deleter_test` (construtor ganhou `social`), `export_serializer_test` (`schemaVersion` 2 e a fonte falsa ganhou os 2 métodos), `cloud_overrides` e `fake_export_data_source` (só adicionam o fake social). Nenhuma asserção antiga foi enfraquecida. Com regras ANTIGAS publicadas: a seção mostra "indisponível", exclusão e exportação ignoram o passo social, nada se perde (testado com `rulesLive=false`).

## 8. Testes (mutação mental)
Bons: reservados lidos de `firestore.rules`; ordem da exclusão por log; "só leituras" para quem não ativou; falha no meio + retomada; semântica/foco. Lacunas: (a) o adaptador Firestore real e o ramo `denied` do export só têm teste por fake (cobertos aqui só pelo replay manual); (b) não há teste de que `deactivate` não deixe resíduo criado durante a varredura (ver 🟡-2).

---

## Findings

### 🔴 Bloqueantes
Nenhum.

### 🟡 Importantes (corrigir antes de aprovar)

**🟡-1. Textos de privacidade imprecisos** (`web/privacidade.html`, `lib/export/export_serializer.dart:116-118`).
- A política diz que o arquivo exportado "não inclui seu e-mail, que não guardamos, **nem a foto de ninguém**". Mas `SocialExport.toJson` inclui o cartão bruto do próprio usuário (`social_export.dart:111-112`), com `photoURL` (a URL da foto dele) e o `uid` dele no cartão. Afirmação falsa em texto legal. Correção: "nem a foto de outras pessoas" (a sua própria URL de foto aparece no cartão, se você a mostrou) e ajustar o comentário do `ExportBuilder` ("Not included on purpose: uid, e-mail and photo URL" não vale mais para `social.card`/`pointer`).
- "Seu nome e e-mail ... **(seção abaixo)**": a seção Amizades está **acima** do parágrafo (`privacidade.html`, parágrafo "Seu nome, e-mail e foto vêm..."). Trocar por "acima".
- "Para que usamos" (`privacidade.html:75-78`) continua dizendo "Somente ... manter a sua conta e sincronizar suas listas" e "não compartilhamos seus dados". Acrescentar: "e, se você ativar as amizades, permitir que outras pessoas encontrem você e vocês sejam amigos (apenas o que a seção Amizades descreve)". Em "Dados no seu aparelho", citar que o cartão/ponteiro também ficam na cópia local.

**🟡-2. `deactivate` não é realmente "retomável/sem fantasmas" contra escrita concorrente** (`social_repository.dart:124-129`).
Cenário: A desativa; a varredura de pedidos recebidos já passou; B (com `social/A` ainda existente) envia pedido/aceita um pedido a A; só então o batch final apaga o ponteiro. Resultado: `friend_requests/B_A` (ou um par) fica com cópia do apelido de A, e **não há como repetir a varredura** (sem ponteiro, a UI mostra "desligado" e `deactivate` não é mais chamável). Hoje o cliente não cria pedidos (fatias 2-5), mas as regras já permitem e o código será reaproveitado. A exclusão de conta já faz certo (porta primeiro). Correção (3 linhas + 1 teste): em `deactivate()`, varrer, `closeSocial()`, e **varrer de novo** (`for kind in SweepKind.values: await _sweep(kind)`; as queries não dependem do ponteiro), ou fechar a porta primeiro como na exclusão e retomar a varredura quando o ponteiro estiver ausente mas houver resíduo. Manter o comportamento "falha antes do fim mantém ativo" para o caso de erro na 1ª varredura.

### 🟢 Sugestões / follow-ups (não bloqueiam)

1. **Persistir o replay**: transformar `dart_payloads.test.mjs` em teste permanente (fora de `firestore_rules_test/` nesta fatia, que não pode ter diff; ou na fatia 2) e/ou serializar os payloads do Dart (um teste Dart que emita JSON das escritas) e validar nas regras. Smoke com 2 contas reais do Manager continua necessário: índices e SDK nativo (Android/iOS) não são cobertos.
2. `handleProblem`/`isHandleFree` não são usados pela UI (código morto até a fatia 2): remover ou usar para checagem ao vivo.
3. `isGoogle` por `providerData`: mais robusto usar `getIdTokenResult().signInProvider` (o mesmo valor das regras). Hoje equivalente (só há login Google). A mensagem de negação ("ainda não estão disponíveis") seria enganosa nesse caso.
4. `SocialController._run` devolve `null` (sucesso) quando já está ocupado (`social_providers.dart:192`): devolver uma falha evita um "Amizades ativadas" falso se algum dia dois fluxos concorrerem (hoje os botões ficam desativados).
5. `SocialNickname.clean` remove tags U+E0000-E007F, o que quebra bandeiras de subdivisão (ex.: Inglaterra). Aceitável; documentar.
6. Bloqueios de terceiros contra o usuário excluído guardam `blockedName` dele (apelido). O docs/50 aceita; vale uma linha na política ("quem bloqueou você pode ter uma cópia do seu apelido até apagar o bloqueio").
7. Falha de relógio: se o relógio do aparelho estiver adiantado, o cliente libera a troca de handle e a regra nega ("indisponível"); mensagem enganosa. Raro.
8. Fora do escopo/regras antigas: durante o intervalo regras-não-publicadas todo usuário vê o cartão "Amizades ainda não estão disponíveis". Previsto no README (regras primeiro).
9. Medir o tamanho adicional do bundle web com `unorm_dart` quando houver baseline.

### ❓ Perguntas ao Manager
- ❓-1. "Aparecer na busca" ligado por padrão na ativação (interruptor visível): confirma? (Julgamento do revisor: aceitável, ver seção 3.)

## Checklist do que o dev precisa mexer para virar APROVADO
1. 🟡-1: corrigir os 3 trechos da política (+ comentário do `ExportBuilder`), sem tocar nas regras.
2. 🟡-2: `deactivate` com varredura após fechar (ou porta primeiro) + teste que cria um pedido "entre" a varredura e o fechamento e prova que não sobra nada.
3. Re-rodar analyze/test/build (e `npm test` não precisa mudar: regras intocadas).
