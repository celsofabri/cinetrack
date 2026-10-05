# 57 - Re-review: Amizades, fatia 1 (ativação, exclusão, exportação, privacidade)

> Revisor: Code Reviewer (gate) · 2026-10-05 · Branch `feat/social-friends` (fatia 0 em `8c5d9dd`; fatia 1 = working tree). Contra o docs/56. Somente leitura; nenhum código alterado.

## Veredito: REPROVADO (1 🟡 novo; os 2 🟡 do docs/56 estão resolvidos)

O 🟡-2 (deactivate) e o 🟡-1 (textos) foram corrigidos de verdade. Resta **uma** pendência relevante, a que o Manager pediu para tratar como 🟡: o replay `dart_payloads.test.mjs` continua espelhado à mão, sem amarra com a classe Dart (🟡-3). Correção pequena, abaixo.

## Números (rodados por mim)

| Verificação | Resultado |
|---|---|
| `flutter analyze` | 0 issues |
| `flutter test` | **956 passam**, 0 falhas |
| `flutter build web --release` | OK |
| `npm test` (emulador, JDK 24) | **228/228**, 0 falhas |
| `git diff -- firestore.rules firestore_rules_test` | vazio (o `.mjs` novo é arquivo não rastreado; nenhum teste existente alterado) |
| `git status` antes/depois | idêntico (nada mexi) |

## Status por item

### 🟡-1 Textos de privacidade: RESOLVIDO (com 1 🟢 residual)
- Política: "nem a foto de ninguém" removido; agora "não inclui seu e-mail, que não guardamos... o cartão traz o endereço da sua própria foto; fotos de amigos, de pedidos e de bloqueados nunca entram". Confere com `SocialExport` (amigos/pedidos/bloqueios só `uid`+apelido+datas; cartão e ponteiro brutos são do próprio usuário) e com o comentário do `ExportBuilder`.
- "(seção abaixo)" virou "acima": ok. "Para que usamos" agora cita o uso social, só se ativar, e quem vê (busca exata e "Aparecer na busca" ligado; depois, amigos). Confere com a regra de `handles` (`get` só por id, `discoverable == true` e sem bloqueio, ou dono) e com o consentimento no diálogo. "Como excluir" e "Portabilidade" também atualizados; README, `PrivacySummary`, diálogo de excluir e de apelido coerentes entre si. Data da política atualizada.
- 🟢 residual: "Dados no seu aparelho" continua falando só de "listas e catálogo"; o cartão/ponteiro do próprio usuário também ficam no cache local (pedi no docs/56). Uma frase resolve; não bloqueia sozinho.
- 🟢 residual: em `SocialExport.add`, um documento NÃO reconhecido (amizade/pedido corrompido) é exportado com o `data` bruto, que poderia conter `aPhoto`/`fromPhoto`. A frase "nunca as fotos deles" fica falsa nesse caso extremo e improvável. Remover chaves `*Photo` do `data` bruto ou ressalvar o texto.

### 🟡-2 `deactivate`: RESOLVIDO
Fluxo: `sweepAll` → `closeSocial` (cartão + convite + ponteiro num batch) → `sweepAll`.
- **As regras negam criar depois do fechamento?** SIM (`firestore.rules`): `friend_requests` create exige `exists(socialPath(from)) && exists(socialPath(to))` (linha 150) e `friendships` create exige `exists(socialPath(me)) && exists(socialPath(other))` (linha 189). Sem `social/A` ninguém cria pedido nem par envolvendo A, e o aceite também fica negado. Logo, a 2ª varredura basta.
- Interleavings: escrita antes ou durante a 1ª varredura → pega a 1ª ou a 2ª; entre a varredura e o fechamento → pega a 2ª (é o cenário do teste); durante o fechamento → batch atômico, a regra avalia contra o estado do commit (ou entra antes e a 2ª pega, ou é negada); depois → negada pelas regras. Falha na 1ª varredura/fechamento: continua "ativo" (ponteiro existe), retry idempotente. Falha só na 2ª: `cleanup-pending`, seção mostra "Concluir limpeza" (`finishCleanup` = `sweepAll`), idempotente. Limite do loop: `maxPages` 500 x 400 = 200 mil, vira `too-many-pages`. Custo: +4 queries vazias na 2ª varredura (leituras mínimas).
- Mutação mental: sem a 2ª varredura, o teste "a pair/request created between the first sweep and the close" falha (`leftoversOf` não vazio, pois o `beforeClose` do fake semeia amizade, pedido e bloqueio depois da 1ª varredura). O teste "cleanup-pending" prova a falha só na última varredura, o estado do ponteiro e a conclusão. Testes reais.
- 🟢: (a) `blocks` de A não exigem `social`: outro aparelho de A pode criar um bloqueio depois do fechamento (dado do próprio dono, sem UI nesta fatia; a exclusão de conta também varre). (b) `cleanupPending` é estado em memória: se o app for fechado após `cleanup-pending`, o botão some (resíduo só por corrida + falha de rede; a exclusão de conta limpa). Aceitável; registrar.

### 🟡-3 (NOVO) Replay sem amarra com o Dart
`dart_payloads.test.mjs` declara no cabeçalho que os payloads são "mirrored by hand". Nada falha se `FirestoreSocialDataSource` mudar um campo (ex.: `schemaVersion`, `photoURL`, chaves do `update`) sem o `.mjs` acompanhar, ou o contrário. Divergência cliente x regras é a causa nº 1 de falha irreversível, e os testes Dart usam fake, então hoje nenhum teste liga o código real às regras. Meu docs/56 pediu "serializar os payloads do Dart e validar nas regras".

Correção concreta (pequena):
1. Extrair os mapas das escritas para funções puras em Dart (ex.: `lib/social/social_payloads.dart`: `activateCard(draft)`, `activatePointer()`, `handleChangeCard(...)`, `handleChangePointerPatch(...)`, `cardUpdate(patch)`), com um valor sentinela para `FieldValue.serverTimestamp()` (ex.: a string `"__serverTimestamp__"`, convertida em `FieldValue.serverTimestamp()` na borda do data source). O `FirestoreSocialDataSource` passa a usar essas funções.
2. Teste Dart (`test/social_payloads_golden_test.dart`) que serializa os payloads para um caso de cada operação e compara com `firestore_rules_test/fixtures/social_payloads.json` (golden versionado; falha com mensagem "atualize o fixture").
3. O `.mjs` lê esse JSON, troca o sentinela por `serverTimestamp()` e executa nas regras. Assim, mudar o Dart exige mudar o fixture, e o `npm test` valida o novo payload contra as regras.
Alternativa mínima, se o refactor for indesejado: o teste Dart lê `dart_payloads.test.mjs`, extrai a lista de chaves de cada `tx.set/update` e compara com as chaves emitidas pelo data source via as mesmas funções puras (menos robusto). Registrar também que o SDK nativo e os índices só se provam com smoke em projeto real.

### 🟢 `isGoogle`: justificativa ACEITA
Derivar do claim exigiria um fluxo assíncrono no login. Como o app só oferece login Google (sem vínculo de provedores), `providerData` e `sign_in_provider` coincidem. Se um dia houver login por e-mail/senha ou vínculo, o usuário com Google vinculado que entrou por outro método teria `isGoogle == true` no app e as regras negariam, e a UI mostraria a mensagem genérica "Amizades ainda não estão disponíveis", sem explicar a causa. Registrar como dívida condicionada à criação de outro provedor. 🟢: o default `isGoogle = true` no construtor de `AppUser` esconde esquecimentos em outras implementações de `AuthRepository`; preferir `required` ou default `false` com ajuste nos fakes.

### 🟢 `unorm_dart`: medido (+219.690 bytes, +6,1%; ~24,8 KB gzip). Aceitável.
### ❓ "Aparecer na busca" ligado: registrado como "a confirmar pelo Manager" com `kDiscoverableByDefault` e teste (trocar o padrão é uma constante). Segue pendente da decisão do Manager (não bloqueia o código).

### Itens da primeira revisão (5, 6): continuam válidos
Nada social gravado para quem não ativou (testes só-leitura); exclusão de conta com porta-primeiro e retomada; exportação schema 2 aditiva; validadores cliente x regras (reservados lidos de `firestore.rules`); UI/acessibilidade (teclado, semântica, 320-1440 px, fonte 3x, claro/escuro) passam. Regressões: nenhuma; os 4 testes antigos ajustados seguem legítimos; `firestore.rules` e testes de regras sem diff. Chrome real não verificado (Perfil exige login Google).

## Para virar APROVADO
1. 🟡-3: amarrar payloads Dart x `.mjs` por fixture golden (acima), com `npm test` e `flutter test` verdes.
2. (Mesma passada, baratos) 🟢: frase do cache local na política; ressalva/remoção de fotos no `data` bruto de documentos não reconhecidos.
