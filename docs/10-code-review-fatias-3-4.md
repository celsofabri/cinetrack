# Review: feat/login-perfil, Fatias 3 (sync robusto) e 4 (perfil, apelido, estatísticas, exclusão de conta, privacidade)

Veredito: **APROVADO COM RESSALVAS**. Não há bug de código que impeça continuar a branch. Mas atenção: o guard do workflow (B1 do review anterior) deixou de proteger, porque `lib/firebase_options.dart` agora tem a configuração real do projeto `cinetrack-d9398`. **Merge na `main` = deploy público no GitHub Pages = app aberto a qualquer pessoa.** Por isso os itens R1 a R3 (seção "Antes de abrir o app") são bloqueantes de **merge/deploy**, não de seguir desenvolvendo.

Resumo: o I1 do review anterior está resolvido no desenho (toda rejeição de escrita vai para o `SyncFailureSink` e vira estado visível). A exclusão de conta é bem pensada (passos idempotentes, marcador, retomada, lotes de 400, sonda online). Os riscos que restam são (a) comportamento do SDK real que nenhum teste cobre, (b) uma corrida de estado na troca de conta e (c) pontos de LGPD/operação fora do código.

## Verificação independente (rodada por mim, neste working tree)

| Comando | Resultado real |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | **225/225** passaram |
| Rules (`npm test` em `firestore_rules_test`, JDK `openjdk@24`) | **34/34** passaram, 7 suítes, saída 0 |
| `flutter build web --release` | Sucesso (`build/web`, `privacidade.html` copiada). Aviso não bloqueante: "Expected to find fonts for (MaterialIcons, packages/cupertino_icons/CupertinoIcons)" |

Os números do dev conferem. Ressalva sobre o que eles provam: tudo roda contra fakes ou contra o Emulator de **rules**. Nenhuma linha de `FirestoreFavoritesDataSource`, `FirestoreProfileDataSource` ou `FirebaseAuthRepository` foi executada por teste (grep em `test/`: zero ocorrências).

## 🔴 Bloqueantes (de merge/deploy; o código em si não tem)

### R1. Exclusão de conta nunca executada de ponta a ponta
- Arquivos: `lib/data/firestore_profile_data_source.dart`, `lib/auth/firebase_auth_repository.dart:50-75`, `lib/account/account_deleter.dart`.
- Cenário: reauth por popup, `Source.server`, timeout de 30 s, `User.delete` e os códigos de erro reais são hipóteses. O próprio registro do dev lista tudo isso como "não verificado". É o único caminho que apaga dado irreversivelmente e o único pré-requisito legal (LGPD) que o Manager colocou antes de abrir o app.
- Correção: um roteiro manual (ou teste com o Emulator do Auth + Firestore) cobrindo: exclusão feliz; queda de rede no meio e retomada; `requires-recent-login`; conta errada no popup. Registrar o resultado no doc 08 antes do deploy.

### R2. Configuração do projeto Firebase real não verificada
- A `apiKey` está no repositório (correto por design, ADR-003). A proteção depende de passos manuais que não consigo ver: restringir a API key por referrer (`celsofabri.github.io`, `localhost`) e às APIs necessárias, listar só os domínios certos em Authentication > Authorized domains, e **publicar as rules da versão atual do repositório** (o dev mesmo registra que a rodada anterior mudou `updatedAt`). Se o projeto estiver com rules em modo teste ou desatualizadas, todo o isolamento deste review não vale.
- Correção: checklist assinado pelo Manager (ver seção final) e `firebase deploy --only firestore:rules` com conferência no console.

### R3. Política de privacidade sem controlador identificado e com canal inadequado
- `web/privacidade.html` (seção "Contato"). A LGPD (art. 9 e 41) pede identificar o controlador e um canal de contato. A página não diz quem é o controlador e manda o titular abrir uma issue **pública** no GitHub. Para um pedido sobre dados pessoais, um canal público expõe a pessoa e não serve para verificar identidade.
- O repositório remoto é mesmo `celsofabri/cinetrack` (`git remote -v`), então a URL do dev bate; o problema não é a URL, é o canal.
- Correção: nomear o controlador (nome do Manager ou do projeto) e dar um e-mail dedicado. Manter a issue só para dúvidas gerais.

## 🟡 Importantes

### I1-A. Resposta do SDK a quota e a sessão: o banner pode nunca aparecer
- `lib/data/sync_status.dart:90-106`, `lib/providers/sync_providers.dart:55-67`, testes `sync_widgets_test.dart:108-150`.
- Cenário: o desvio 3 do dev assume que só rejeição definitiva chega ao callback. Concordo com a premissa, mas ela tem um corolário que os testes ignoram: pelo que conheço do SDK do Firestore (confiança média, **não verifiquei na versão 12.19**), `resource-exhausted` e `unauthenticated` são tratados como transitórios e o SDK **repete a escrita em vez de falhar o Future**. Se for assim, estourar a cota da Spark (que num app aberto é o cenário mais provável) não dispara `reportCode`: o usuário vê o ícone "Sincronizando alterações" para sempre, sem explicação. Os testes de banner de cota/sessão injetam o erro direto no sink, caminho que o SDK real talvez nunca percorra (teste que passa por construção).
- Correção: complementar com um sinal por tempo: se `hasPendingWrites` continua verdadeiro e `fromCache == false` por mais de ~30 s, mostrar "Não conseguimos confirmar suas alterações" (mensagem genérica, sem afirmar causa). Validar no spike S1 o que o SDK entrega com cota estourada (simulável no Emulator derrubando a rede ou no projeto real).

### I1-B. Corrida na troca de conta / retry: falha da conta A pode aparecer na conta B
- `lib/providers/sync_providers.dart:18-22` (`_disposed` é um campo do notifier, reposto para `false` a cada `build()`), `:55-67` (`_onFailure` espera `verifySession()` e depois só confere `_disposed`).
- Cenário: A tem uma escrita recusada; `_onFailure` está esperando `getIdToken(true)` (pode levar segundos). A faz logout e B entra (ou o usuário aperta "Tentar novamente"): `ref.onDispose` põe `_disposed = true`, mas o `build()` seguinte põe `false` de volta. Quando o `await` de A termina, a checagem passa e `state.copyWith(failure: ...)` grava a falha de A no estado de B. Além disso `verifySession()` olha `currentUser`, que já é B. O teste "a failure of one account never shows up for the next one" (`sync_status_provider_test.dart:137`) cobre falha emitida depois da troca, não a que estava em voo.
- Correção: variável local por build (`var disposed = false; ref.onDispose(() => disposed = true)`) capturada pelo closure, ou um contador de geração; comparar o uid de início com `currentUidProvider` depois do `await`. Adicionar teste com `verifySession` atrasado (Completer).

### I1-C. `SyncStatusNotifier` só funciona enquanto observado (fragilidade pedida no escopo)
- `lib/data/sync_status.dart:67-109` (`StreamController.broadcast`, sem buffer).
- Hoje é seguro: `SyncBanner` está no `builder` do `MaterialApp` (`main.dart`) e faz `watch`; `AccountController` também escuta. Mas o `fire()` publica num broadcast sem assinante possível antes do primeiro build do notifier, e a rejeição se perde sem rastro. Basta alguém mover o banner para uma rota para o I1 voltar a existir silenciosamente.
- Correção barata: o sink guardar a última falha (`SyncFailure? last`) e o notifier ler `sink.last` no `build()`; ou ler `syncStatusProvider` uma vez em `main()`. Teste: reportar antes de qualquer `listen` e depois construir o notifier.

### I2. Exclusão: escrita enfileirada sobrevive ao timeout
- `lib/data/firestore_profile_data_source.dart:70-77, 84-94, 101, 105-116`.
- Cenário: a rede cai durante `markDeleting`, o commit do lote ou `deleteProfile`. O `Future` não completa, o `timeout(30s)` dispara e o usuário vê "Você precisa estar online ... Nada foi apagado ou a exclusão pode ser retomada" (`account_deletion_failure.dart:46`). Mas a operação **continua na fila persistente do SDK** (persistência ligada em `firebase_bootstrap.dart`): ao reconectar, o lote apaga os favoritos (e o delete do perfil é enviado), mesmo que o usuário tenha desistido. Quem leu "nada foi apagado" perde dados sem ter confirmado de novo. A mensagem também é ambígua: "Nada foi apagado ou ... pode ser retomada" são situações opostas.
- Correção: (a) mensagem para o caso de timeout: "A exclusão pode ter sido iniciada. Reconecte para concluir"; (b) a falha por `timeout` deveria deixar claro no estado que a exclusão está pendente (o marcador `deleting` já cobre se `markDeleting` foi aceito). O pré-check offline (`account_providers.dart:75-83`) reduz o caso mas não o elimina (rede cai depois da sonda).

### I3. Exclusão: janela em que dados órfãos podem ser recriados depois que a conta some
- `lib/account/account_deleter.dart:66-80`.
- Cenário: (i) outro aparelho/aba com a mesma conta continua com ID token válido por até ~1 h após `User.delete` (o token não é revogado na hora) e as rules só olham `request.auth.uid`; qualquer escrita pendente nessa janela recria `users/{uid}/favorites/...` sem conta para excluir depois. (ii) No caminho de falha, `markDeleting()` é regravado depois de `User.delete` ter lançado; se o `delete` tinha de fato sucedido no servidor mas a resposta se perdeu (erro de rede), o `set` recria `users/{uid}` de uma conta já inexistente. Resultado possível: **dado sem dono**, que contraria a promessa "tudo apagado".
- O que está certo: a ordem favoritos, perfil, usuário garante que, em falha normal, nunca fica "conta apagada com dados presentes" nem dado órfão (a conta segue existindo e a retomada funciona). Testado no Emulator (`firestore.rules.test.mjs`, suíte "account deletion sequence", incluindo o caso do marcador regravado).
- Correção: documentar o risco residual no doc 08 e na política ("cópias técnicas ..."); mitigar (ii) tratando `network` em `deleteCurrentUser` como "estado incerto": reautenticar/`reload()` o usuário antes de regravar o marcador. Limpeza definitiva só com Cloud Functions/TTL (fora do plano Spark, registrar como dívida).

### I4. Exclusão: não garante que apaga o mesmo uid dos dados
- `lib/account/account_deleter.dart:59-66`, `lib/auth/firebase_auth_repository.dart:50-73`.
- Cenário: `AccountDeleter` recebe um `ProfileDataSource` já preso ao uid X, mas `reauthenticate()` e `deleteCurrentUser()` operam em `FirebaseAuth.currentUser` no momento da chamada. O Firebase Auth web sincroniza sessão entre abas: se numa outra aba o usuário entrar com a conta Y enquanto a exclusão de X está no meio, o `User.delete` apaga **Y** (que nem teve dados apagados), e X fica com `deleting=true` e conta viva. Janela estreita, mas é "apaga só o uid autenticado" violado.
- Correção: passar o `uid` esperado a `deleteCurrentUser(expectedUid)` e `reauthenticate(expectedUid)`; abortar com `sessionExpired`/`wrongAccount` se `currentUser.uid != expectedUid`. Teste com `FakeAuthRepository` trocando de uid no meio.

### I5. Política de privacidade incompleta em relação ao que o app realmente faz
- `web/privacidade.html`.
- O texto bate com o essencial (UID, favoritos, apelido, Firebase, TMDB, GitHub Pages, cache local que sobrevive ao logout, exclusão). Faltam: (a) endereço IP e dados técnicos que Google (Firebase/gstatic para o CanvasKit, conforme `flutter_bootstrap.js`), TMDB (pôsteres) e GitHub Pages recebem como qualquer servidor; "as buscas ... não levam seu nome" é verdade, mas pode soar como "não levam nada"; (b) base legal (execução do serviço/consentimento); (c) o que o app guarda em `localStorage`/IndexedDB do Firebase (sessão e cache); (d) portabilidade está declarada como "não disponível", o que é honesto, mas o direito de acesso diz que "tudo aparece no Perfil" (o Perfil mostra contagens, não a lista completa; a lista está em Favoritos, ok, mas não o histórico de datas).
- Correção: acrescentar (a), (b), (c) em 3 frases. Tudo texto, sem código.

### I6. Cache local persiste após logout e após exclusão da conta
- `lib/services/firebase_bootstrap.dart` (persistência ligada, `clearPersistence`/`terminate` nunca chamados).
- A política avisa para o logout (bom). Mas após **excluir a conta**, a expectativa do titular é "tudo apagado". Os documentos somem do cache porque o lote local é aplicado, mas o IndexedDB do SDK e o catálogo do Hive (não pessoal, ok) ficam. Em computador compartilhado, o apelido e títulos que a pessoa favoritou podem permanecer no armazenamento do navegador até o SDK compactar.
- Correção sugerida: após exclusão bem-sucedida, `FirebaseFirestore.instance.terminate()` seguido de `clearPersistence()` (só depois de confirmar que não há escritas pendentes de outra conta); registrar como tarefa se não for feito agora.

### I7. Cobertura de testes das camadas que mais importam
- Data sources Firestore, `FirebaseAuthRepository` e o timeout/lote de 400 não têm teste algum. O `InMemoryProfileDataSource.deleteAllFavorites` (`test/support/in_memory_favorites_data_source.dart:202-207`) faz `clear()` de uma vez: não exercita paginação, `limit`, timeout nem `Source.server`. Os testes de `AccountDeleter` validam a orquestração (bom), não a implementação real.
- Correção: testes com `fake_cloud_firestore` ou, melhor, com o Emulator do Firestore via script Node já existente (inclui 401+ favoritos para provar os lotes de 400 e o loop até esvaziar). Pelo menos um teste de integração do `FirestoreProfileDataSource` contra o Emulator.

## 🟢 Sugestões / nits

- S1. `SessionExpiryNotifier` (`lib/account/session_expiry.dart:19-27`): logout feito em **outra aba** (ou exclusão em outra aba) é visto aqui como "saiu sem eu pedir" e mostra "Sessão expirada". Falso positivo benigno (o botão é "Entrar"), mas confunde. Também `signOut()` (`providers.dart`, `AuthController.signOut`) chama `expectSignOut()` e, se `signOut` lançar, `_expected` fica `true` e engole uma expiração real depois; falta um `cancelExpectedSignOut()` no `catch`.
- S2. Carência de 5 s (`sync_providers.dart:12`): com rede lenta (>5 s) e cache vazio o app mostra "Não foi possível carregar seus favoritos" e "Tentar novamente"; é o comportamento projetado, só vale registrar que numa conexão móvel ruim isso acontecerá de verdade. Com cache não vazio nunca vira erro, bom. O falso "offline" fica restrito ao ícone.
- S3. `Nickname.errorFor` usa `String.length` (unidades UTF-16), enquanto o `TextField(maxLength)` conta clusters de grafema. Um apelido de 25 emojis passa pelo contador do campo e é recusado com "máximo 40" (`lib/models/nickname.dart:11-21`). As rules contam caracteres do Firestore, outro critério ainda. Use `characters.length` na validação e deixe a rule com folga (ex.: 40 no cliente, 60 na rule).
- S4. `NicknameDialog._save` (`nickname_dialog.dart:41-46`) mostra "Apelido salvo." mesmo se a rule recusar depois (o banner "recusou" cobre). Aceitável, mas o texto "salvo" é otimista; "Apelido atualizado" já seria mais honesto offline.
- S5. `DeleteAccountDialog.confirm` (`delete_account_dialog.dart:33-34`) faz `navigator.pop(true)` depois de a conta ser excluída. Nesse instante o `authState` vira `null` e o `go_router` redireciona `/profile` para `/`. Se o diálogo já tiver sido removido pela troca de páginas, o `pop(true)` desempilharia a Home. Não consegui provar nem descartar (nenhum teste usa o roteador real com o diálogo). Proteção: `if (navigator.canPop() && ModalRoute.of(context)?.isCurrent ?? false)`, ou fechar o diálogo antes do `User.delete`.
- S6. Acessibilidade do diálogo: correto no essencial (foco inicial no "Cancelar", Esc, `PopScope`, `liveRegion` no progresso e no erro, botões desabilitados durante a execução). Pequenos: `LinearProgressIndicator` sem `semanticsLabel`; `PrivacyPolicyLink` envolve um `TextButton` em `Semantics(link: true)` (papel duplicado); sem foco movido para a mensagem de erro após a falha.
- S7. `lib/widgets/sync_widgets.dart` `SyncBanner`: quando há `sessionExpired`, só essa mensagem aparece; se existir também falha de regra, é preciso entrar primeiro. Aceitável ("um aviso por vez").
- S8. `fire()` (`sync_status.dart:97`): ao reportar `not-found` (por exemplo, `setEpisodes` num documento removido em outro aparelho) o texto vira "Não foi possível sincronizar uma alteração. Tente novamente.", mas "tentar novamente" não resolve. Mapear `not-found`/`failed-precondition` para uma mensagem própria ("Este item foi removido em outro aparelho").
- S9. Imports fora de ordem alfabética em `main.dart`, `catalog_screen.dart`, `continue_watching_section.dart` (recorrente do review anterior, S6); só estilo.
- S10. O aviso do build sobre `cupertino_icons` indica referência a um font family não declarado. Provavelmente anterior à branch; checar com `git stash` se quiser silenciar.

## Ruído de formatação residual no diff

Nenhum arquivo ficou **só** com mudança de formatação (verifiquei comparando o texto sem espaços e vírgulas finais contra o `HEAD`), mas há hunks de reflow misturados com mudanças reais, que poluem o diff:

- `lib/screens/catalog_screen.dart` (reflow de `favoriteKeys`)
- `lib/screens/search_screen.dart` (reflow de `favoriteKeys`)
- `lib/screens/movie_details_screen.dart` (reflow de `matches`)
- `lib/screens/tv_details_screen.dart` (`onRetry`, `cachedSeasons`, `message:`; 3 hunks)
- `lib/widgets/discovery_section.dart` (`message:` e `favoriteKeys`)
- `lib/widgets/favorites_section.dart` (`title:`, `itemBuilder`, `progress`, `onTap`)
- `lib/providers/providers.dart` (`searchResultsProvider`, `seasonProvider`)

Sugestão: separar o commit de formatação, ou reverter os hunks de reflow; o restante do diff fica revisável (mudança líquida é pequena).

## Respostas ao foco do pedido

**1. Exclusão de conta**
- Ordem: reauth da mesma conta, sonda `Source.server`, marcador, favoritos (lotes de 400, página lida do servidor), perfil, `User.delete`. A ordem está certa para as rules: subcoleção antes do doc raiz, e as rules não dependem da existência do pai (confirmado no teste da suíte "account deletion sequence", 34/34).
- Falha em cada passo: reauth falha ou cancela, nada foi tocado. Offline detectado, nada tocado. `markDeleting` falha, nada tocado. Meio dos favoritos, marcador fica e a retomada continua (testado: `account_deleter_test.dart:128`). `deleteProfile` falha, marcador fica. `User.delete` falha, marcador regravado (testado `:146`, e no Emulator). Queda do app entre `deleteProfile` e `User.delete`: conta viva e vazia sem marcador (inofensivo, o usuário repete). Nenhum caminho de falha normal deixa "usuário sem conta e com dados". Os caminhos que deixam dado sem dono são os de I2 e I3.
- Idempotência/lotes: leitura da página no servidor + `batch.commit()` até esvaziar, teto `_maxPages=500`. Correto. Lacuna: nenhum teste com mais de 400 documentos (I7).
- Só o uid autenticado: parcialmente (I4).
- Estado `deleting`: tratado em perfil, banner e cartão. A UI do cartão não depende do `running` do diálogo. OK.

**2. Sync / I1**
- I1 resolvido para erros de **rejeição definitiva** (testado em unidade e widget). Resíduos: I1-A (cota/sessão podem nunca chegar), I1-B (corrida), I1-C (observação).
- Listeners e timers: `build()` cancela `metaSub`, `failureSub` e o `Timer` em `onDispose`. Sem vazamento que eu encontre. O `broadcast` do sink é fechado com `ref.onDispose(sink.dispose)`.
- Duplicação de callbacks: `retrySync` invalida só o data source; o notifier reconstrói (watch no data source) e reassina. OK.
- `verifySession`: `getIdToken(true)` offline cai em `unknown` e mantém "recusado"; correto e testado. Falha de rede ao verificar nunca declara sessão expirada.
- Sessão expirada: ver S1 e I1-A.

**3. Segurança / privacidade**
- Rules: apelido 1 a 40 com `trim()`, `hasOnly` no perfil, `deleting is bool`, isolamento por uid, negação padrão. Testes cobrem os limites (34/34). Limitações já anotadas (`eps` e `seasonSummaries`).
- Logs: `debugPrint` só com `e.code`/`runtimeType`. Nada de PII. OK.
- XSS/injeção em apelido: o Flutter desenha texto, sem HTML. Sem `dangerouslySetInnerHTML` equivalente. OK.
- `url_launcher`: URL fixa (`kPrivacyPolicyUrl`) ou derivada de `Uri.base` com caminho relativo fixo; `LaunchMode.externalApplication`; sem entrada do usuário. Seguro. Em modo hash o `Uri.base.resolve` devolve `/cinetrack/privacidade.html` (o app não usa `usePathUrlStrategy`).
- Dependências novas: `firebase_core`, `firebase_auth`, `cloud_firestore`, `google_sign_in`, `url_launcher`, dev `fake_async`. Pacotes oficiais da Firebase/Flutter. **Não rodei auditoria de vulnerabilidades** (não há ferramenta oficial para pub.dev); `fake_async` já vem transitivo do `flutter_test`.

**4. Desvios 1 a 8 do dev (Fatias 3 e 4)**
1. Estatísticas a partir de documentos: **concordo**. Resolve o aparelho novo e a nota do review anterior (Q4/I6.7). Detalhe: o `ref.watch(favoritesListProvider)` como gatilho hidrata tudo de novo a cada mudança; custo aceitável para a escala atual.
2. Sink injetado em vez de `Stream` no data source: **concordo**; melhor que o sugerido, porque o perfil também reporta. Ver I1-C.
3. "Não foi salva" em vez de "Tentaremos de novo": **concordo com o texto para `permission-denied`**; **contesto a premissa geral** (I1-A): nem tudo que falha chega ao callback, e para `resource-exhausted`/`unauthenticated` o texto "o limite foi atingido" pode nunca ser exibido.
4. Rules inalteradas, só testes: **concordo**; falta a conferência das rules **publicadas** (R2).
5. Testes antigos ajustados (`cloudOverrides`, `scrollUntilVisible`): **concordo**, mudança mecânica.
6. `url_launcher` + `fake_async`: **concordo**.
7. Contato por issues: **contesto** (R3).
8. Nada verificado com Firebase real: **concordo que está declarado**, mas isso é o bloqueante R1.

## Pré-requisitos antes de abrir o app a outras pessoas

**Bloqueantes** (merge = deploy):
1. R1: roteiro de exclusão de conta executado de ponta a ponta no projeto real.
2. R2: API key restrita (referrers + APIs), domínios autorizados do Auth, rules publicadas conferidas contra `firestore.rules` do repositório, região `southamerica-east1` confirmada.
3. R3: controlador e canal de contato na política (`web/privacidade.html`).
4. Spike S1 (premissa 5b, fila offline por uid) ao menos com uma checagem manual: Ana grava offline, sai, Bruno entra, Ana volta e as escritas seguem. Pelo que sei do SDK web a fila é por usuário, mas continua **não verificado** aqui.

**Recomendações** (podem ir em tarefa registrada):
- App Check com reCAPTCHA v3 no Firestore e Auth, primeiro em modo "monitorar" e só depois "enforce" (enforce prematuro tira o app do ar).
- Alerta de uso/cota: na Spark, estouro de cota derruba o serviço para todos (negação de serviço barata para um terceiro). Acompanhar o painel de uso e decidir o limite em que migrar para Blaze com teto de orçamento.
- I1-A (sinal por tempo para "pendente demais"), I1-B (corrida), I2 e I4 antes do primeiro divulgado, ou registrar como dívida com dono.
- Cloud Function/TTL para limpar órfãos (I3) quando houver Blaze.
- Exportar/portabilidade (já admitida na política).

## Condições para virar APROVADO
R1 a R3 e o spike S1 resolvidos e registrados; I1-B corrigido com teste (é pequeno); I4 corrigido ou aceito formalmente pelo Manager; I1-A, I2, I5, I6, I7 em tarefa registrada com dono.
