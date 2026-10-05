# 58. Conferência final da fatia 1 (amizades)

Revisor: Code Reviewer. Base: docs/57 (REPROVADO só por 🟡-3 + 🟢). Fatia 1 = working tree não commitado sobre 8c5d9dd. Somente leitura (mutações em cópia descartada; `git status` idêntico antes e depois).

## Veredito: **APROVADO**

Nenhum 🔴, nenhum 🟡.

## Números
- `flutter analyze`: 0 issues.
- `flutter test`: 958 passaram, 0 falhas.
- `flutter build web`: ok.
- `npm test` (emulador): 238/238.
- `firestore.rules` e testes de regras existentes: sem diff. Diff do app sem churn de formatação (`git diff -w --stat` = `git diff --stat`: 25 arquivos, +340/-29 nos rastreados).

## (1) Amarração Dart ↔ regras (🟡-3): fechada
- Toda escrita do `FirestoreSocialDataSource` sai de `SocialPayloads` (`activate`, `changeHandle`, `updateCard`, `close`, `sweepDelete`) e é executada por `_applyTx` / `_commit`, que só traduzem `SocialOp` em `tx/batch.set|update|delete` com sentinela trocada por `FieldValue.serverTimestamp()`. As consultas de varredura vêm de `sweepQuery`. Grep: nenhum campo/path montado fora de `social_payloads.dart` (o restante são leituras `get`).
- O golden cobre 11 cenários de escrita (activate com/sem foto, changeHandle com/sem foto, 4 updateCard, close, close com convite, close só-ponteiro, sweepDelete) e as 4 consultas. O fixture inclui `mode` (transaction/batch), a ordem das operações, o tipo da op e os paths.
- `dart_payloads.test.mjs` lê o JSON e executa cada `write` com o mesmo modo (`runTransaction` ou `writeBatch`), mesmas ops, ordem e paths, contra as regras reais; os casos negativos são derivados do fixture (clone + alteração).
- Mutações em cópia:
  1. Renomear `nickname`→`nick` no Dart: o golden quebra.
  2. Mudar o tipo de `discoverable` (bool→string) no Dart: o golden quebra; regenerando o fixture de propósito, `npm test` quebra (5 falhas: activate, activate_with_photo, limites, changeHandle x2).
  3. Mudar o path no JSON (`social/uid-ana`→`social/uid-zzz`): o golden quebra E `npm test` quebra (2 falhas). Trocar `mode` no JSON também quebra o golden.
- 🟢 (não bloqueia) O executor escolhe transação/batch pelo método (`activate` usa `runTransaction`, `close` usa `_commit`), não lendo `write.mode`. Se alguém mudar o `mode` no payload sem mudar o executor, o golden é regenerado e o `.mjs` testa um modo que o app não usa. Sugestão futura: o executor derivar do `mode` (ou um assert). A atomicidade, a ordem e os campos já estão travados hoje.
- 🟢 Cobertura da execução real contra o Firestore continua "não verificada com projeto real" (documentado no cabeçalho da classe); é o limite do emulador.

## (2) 🟢a/b/c/d/e
- a. Política "Dados no seu aparelho" descreve o cache local e o aviso de limpeza pendente: ok.
- b. Export de doc desconhecido: só `fields` com nome e tipo (`_typeName`), `uid`/`nickname` nulos, sem valores: ok (ver 4).
- c. `deactivate`: varre, fecha, varre de novo; falha da última varredura vira `cleanup-pending` (retomável); exclusão fecha a porta antes e varre depois; resíduo de bloqueios de terceiros documentado como aceito: ok.
- d. `LocalStore.socialCleanupPending(uid)`: ver 3.
- e. `AppUser.isGoogle` default `true` aceito. Único construtor de produção é `_toAppUser` do `FirebaseAuthRepository`, que passa o valor explícito de `providerData`; `UnavailableAuthRepository` não constrói usuário; os demais usos de `AppUser(` são testes (um teste cobre `isGoogle: false`). Nenhum caminho usa o default por engano.

## (3) Persistência do cleanup-pending
- Chave `socialCleanup:$uid` na box de descoberta (Hive): não vaza entre contas (a leitura usa o uid atual; troca de conta lê outra chave). Gravada ao receber `cleanup-pending`; apagada em `deactivate` bem-sucedido e em `finishCleanup` concluído. Só é exibida com `profile == null`. Falhas do Hive são engolidas (a UI funciona sem a flag). Teste de nova sessão (`social_section_test`) prova persistência e limpeza.
- 🟢 Na exclusão de conta a chave do uid removido permanece no aparelho (um booleano sem dado pessoal, uid nunca reutilizado). Pode ser limpa na exclusão numa próxima fatia.

## (4) Export sem vazamento
Unknown vira `{key, uid:null, nickname:null, fields:{nome: tipo}}` e uma issue `notRecognized`; nenhum valor. Listas de terceiros: só uid e apelido, nunca foto. O cartão do próprio usuário traz a própria foto (dado dele; documentado em serializer, política e README). Schema 2 aditivo.

## (5) Política / README / diálogos
Consistentes: `privacidade.html` (data 05/10/2026), `PrivacySummary`, README e diálogo de ativação dizem o mesmo (opt-in; nada gravado sem ativar; o que é copiado; exclusão/exportação/desativação; cache local; só Google).

## (6) Primeira revisão
Continua válido: nada social é gravado para quem não ativou (leituras apenas; `readSocial` tolera regra negada); exclusão de conta com passo social retomável e fechando a porta primeiro; export schema 2; validadores iguais às regras (31 reservados lidos de `firestore.rules`); UI com matriz 320 a 1440 px, fonte 3x, claro/escuro e alvos >= 48 px (testes verdes).

## (7) Decisão do Manager
"Aparecer na busca" nasce LIGADO: `kDiscoverableByDefault = true` usado pelo diálogo e pela seção; decisão de 2026-10-06 registrada em docs/50 (seção "Decisão do Manager") e docs/55.
