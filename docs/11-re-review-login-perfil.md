# Re-review: feat/login-perfil, correções do parecer doc 10 (Code Reviewer)

Veredito: **APROVADO COM RESSALVAS**. O código dos itens I1-A/B/C, I2, I4, I7 (parte testável) e o reflow estão resolvidos, sem regressão que eu tenha encontrado. Restam duas ressalvas de comportamento (I6 e a frase das 1 h na política) e a lacuna de sempre: **nada que toque o Firebase real foi executado**. Isso continua bloqueando **merge/deploy** (merge na `main` = app público): R1, R2, S1 e os ajustes de texto da política listados no fim.

## Verificação independente (rodada por mim, neste working tree)

| Comando | Resultado real |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | **252/252** passaram (eram 225) |
| Rules (`npm test`, JDK `openjdk@24`) | **35/35**, 7 suítes, saída 0 (eram 34) |
| `flutter build web --release` | Sucesso. Mesmo aviso não bloqueante de `cupertino_icons` (S10 do review anterior, inalterado) |

Isto confirma o que o dev declarou. Continua valendo: tudo roda contra fakes ou contra o Emulator de **rules**; `FirestoreFavoritesDataSource`, `FirestoreProfileDataSource` e `FirebaseAuthRepository` não são executados por nenhum teste.

## Status dos findings anteriores

| Item | Status | Observação |
|---|---|---|
| I1-A (cota/sessão nunca chegam ao callback) | ✅ resolvido | O dev leu o código do SDK (`@firebase/firestore` 4.17.2) e a conclusão bate com a minha suspeita: só erros permanentes rejeitam a escrita. Sinal por tempo implementado (`syncStallProvider`, 30 s). Resíduos em N1/N2 abaixo. |
| I1-B (corrida na troca de conta) | ✅ resolvido | Geração por `build()` (`sync_providers.dart:24-30`), `current()` checado após o `await` (`:94`), `verifySession(expectedUid)` preso à conta dona (`firebase_auth_repository.dart:96-99`). Testes com verificação em voo. |
| I1-C (só funciona se observado) | ✅ resolvido | `sink.unacknowledged` lido no `build()` (`:70-73`). Ver 🟢 N6 sobre o efeito do retry. |
| I2 (escrita enfileirada sobrevive ao timeout) | ✅ resolvido | `guardDeletionStep(write:)`: timeout de escrita vira `uncertain`, de leitura vira `offline`; frase ambígua removida. O limite (o timeout não cancela a escrita) está declarado, correto. |
| I3 (dados órfãos) | 🟡 parcial | (ii) resolvido: `userStillExists` antes de regravar o marcador; nunca escreve em `users/{uid}` sem certeza. (i) é risco residual aceito sem mitigação possível no Spark, mas o texto na política está mal escrito (N3). |
| I4 (apagar o mesmo uid) | ✅ resolvido | `reauthenticate(expectedUid)` e `deleteCurrentUser(expectedUid)` verificam antes de agir; `wrongAccount` não regrava marcador. Entre os dois passos, escritas de X com sessão de Y são negadas pelas rules (seguro). Ver 🟢 N7. |
| I5 (política incompleta) | 🟡 parcial | Base legal (art. 7º, V, inciso correto), IP/dados técnicos de Google e GitHub, e-mail do controlador: feitos. Faltam: nome do controlador, TMDB no parágrafo de IP, sessão do Firebase Auth no armazenamento local, transferência internacional, "Acesso: tudo no Perfil" ainda impreciso (N4). |
| I6 (cache após exclusão) | 🟡 parcial | Implementado de forma defensável (flag + `clearPersistence` na próxima abertura), mas o caminho web real nunca rodou e tem custos (N5). |
| I7 (testes das camadas) | 🟡 parcial | `wipeInPages` extraído e testado (0/1/400/401/800/950, falha no 2º lote + retomada, teto, timeouts) e laço de 950 docs no Emulator. Data sources e `FirebaseAuthRepository` seguem sem teste direto (N8). Aceito, desde que o roteiro manual abaixo seja executado. |
| R3 (controlador/canal) | 🟡 parcial | Canal por e-mail resolve o problema do canal público. Falta o **nome** do controlador (N4). |
| R1, R2, S1 | 🔴 não resolvidos (dependem do Manager) | Não são código. Ver roteiro. |
| Reflow de formatação | ✅ resolvido | `git diff --stat`: catalog 2/1, search 2/1, movie_details 5/3, tv_details 13/10, discovery_section 2/16, favorites_section 15/3, providers.dart +119/0. Li os hunks de catalog, search, discovery, favorites: só mudança real (imports de `auth_gate`, `runWrite`, gate). Só sobra a ordem de imports (S9 antigo, nit). |

## Novos findings

### 🟡 N1. Sinal de "pendente demais" fica mudo quando a cota de LEITURA estoura
- `lib/data/sync_status.dart:152-157` (`phase`: `offline` vem antes de `stalled`), `lib/providers/sync_providers.dart:46`.
- Cenário: cota da Spark estourada para leituras (50 mil/dia) faz o listener falhar e voltar a `fromCache == true`. O sinal só conta com `!fromCache`, então a fase vira "offline" (Sem conexão) e nunca "stalled". Não é silêncio total (há ícone), mas o diagnóstico é errado e a pessoa fica olhando o próprio Wi-Fi. Já com cota de escrita estourada e leitura ok, o sinal funciona. O contrário (falso positivo): ele não dispara offline, correto.
- Correção: aceitar como está e registrar; ou, se `offline` persistir por mais de ~2 min com a rede do navegador (`navigator.onLine`) verdadeira, usar o mesmo texto genérico "não conseguimos confirmar". Validar no S1 (ver roteiro, passo 6).

### 🟢 N2. Detalhes do timer de stall (verificado, sem bug)
- `sync_providers.dart:44-63`. Sem vazamento: o timer é cancelado quando as escritas somem, quando fica offline, e no `onDispose`; `current()` protege disparo tardio após troca de conta. Falso positivo possível: conexão muito lenta com escritas contínuas (nunca zera `hasPendingWrites` por 30 s); a mensagem é genérica e some sozinha, aceitável. Limite: só observa a coleção de favoritos; um apelido pendente (perfil) não conta. O banner "stalled" não tem ação nem dispensa (`sync_widgets.dart:110`); some sozinho, ok.

### 🟡 N3. Política: a frase das 1 h está mal escopada e não diz a consequência
- `web/privacidade.html:80-81`: "Se a internet cair no meio da exclusão, a sua sessão pode continuar válida por até cerca de 1 hora em outro aparelho ou aba; por isso, conclua a exclusão com o app aberto e conectado."
- Problemas: (1) a janela de ~1 h existe **mesmo sem queda de rede**: depois do `User.delete`, outro aparelho com a mesma conta mantém token válido; a condição "se a internet cair" é falsa. (2) Não diz o efeito real: esse outro aparelho pode gravar dados que ficam sem dono (I3-i), contrariando "os dados são apagados". (3) "ou aba" provavelmente não vale: abas do mesmo navegador recebem o logout pelo armazenamento compartilhado; o risco é de **outro aparelho**. (4) "conclua com o app aberto e conectado" não mitiga nada disso.
- Correção (texto): "Se você usa a mesma conta em outro aparelho, saia dela lá antes de excluir. Por até cerca de 1 hora depois da exclusão, esse aparelho ainda pode gravar dados que ficariam sem conta associada; se isso acontecer, peça a remoção por e-mail." Manter coerente com a promessa "definitivo".

### 🟡 N4. Política: faltam o nome do controlador e três frases de LGPD
- `web/privacidade.html:91-95`. A LGPD (art. 9º, III) pede a **identificação** do controlador; hoje há "uma pessoa física" e um e-mail, sem nome. Dado que o Manager é o dono do projeto, escrever o nome (ou como o app o identifica publicamente).
- Frases a acrescentar: (a) transferência internacional (art. 33): só o Firestore está em São Paulo; o Firebase Authentication e o GitHub Pages podem processar fora do Brasil; (b) o parágrafo de IP cita Google e GitHub; o TMDB também recebe IP, pois as imagens e consultas saem do navegador; (c) o armazenamento local guarda também a **sessão do login** (Firebase Auth), não só listas e catálogo; (d) "Acesso: tudo o que guardamos aparece no seu Perfil e nas suas listas" não cobre as datas de marcação (`lastWatchedAt`); trocar por "quase tudo" ou listar. Também: "a cópia do navegador é limpa na próxima abertura" vale só para o navegador onde a exclusão foi feita; em outros aparelhos o cache permanece até limpeza manual ou até a sessão cair (e o app só o mostra para a conta logada).
- Base legal: o inciso V do art. 7º (execução de contrato) é a escolha adequada para um serviço que o titular pede ao entrar. Sem objeção.

### 🟡 N5. `clearPersistence()` agendado: seguro na ordem, mas com três custos reais não verificados
- `lib/services/firebase_bootstrap.dart:32-41`, `lib/providers/account_providers.dart:105`, `lib/main.dart` (chamada antes de `runApp`).
- O que está certo: a ordem é a exigida pelo SDK (`settings` e depois `clearPersistence`, antes de qualquer outra chamada; o SDK recusa com `failed-precondition` se já iniciado, lido em `clearIndexedDbPersistence`). Falha é capturada, a flag permanece e o app abre normalmente; `initFirebase` nunca lança. A flag só é gravada depois de `run()` retornar com sucesso, e nesse ponto a fila de escrita da conta excluída já foi confirmada (lotes aguardam o ack). Logout nunca limpa. Não vi caminho que apague dado de conta viva por engano.
- Custos: (1) apaga o banco inteiro do navegador, inclusive escritas offline **ainda não enviadas de outra conta** que tenha entrado entre a exclusão e a reabertura (o dev declarou). Ex.: exclui a conta A, entra com B, marca offline, fecha; na abertura seguinte o que B marcou e não enviou some, sem aviso. (2) Se houver outra aba aberta, o `deleteDatabase` não é bloqueado: o SDK da outra aba fecha a conexão ao receber `versionchange` e passa a errar a persistência dela (leitura do código do SDK; não testei no navegador). A aba que purga não sabe disso e marca a flag como cumprida. (3) O caminho web do plugin `cloud_firestore` (`clearPersistence` depois de `settings` com `WebPersistentMultipleTabManager`) **nunca rodou**: pode lançar sempre, e então a promessa da política ("limpa na próxima abertura") não se cumpre, sem ninguém notar.
- Correção: aceitar (1) e (2) como decisão do Manager, registrando-as no doc 08; validar (3) no roteiro (passo 5). Mitigação barata de (1): só agendar a purga se, no momento da abertura, não houver uid logado salvo; ou limpar a flag quando outra conta entrar.

### 🟢 N6. Falha não dispensada reaparece após "Tentar novamente"
- `sync_providers.dart:70-73`. Por design (`unacknowledged` até `acknowledge`), um `permission-denied` não dispensado volta a cada rebuild do notifier (retry de sincronização, e roda `verifySession` de novo). Coerente com a ideia, só vale saber ao testar: o retry sincroniza mas a faixa continua até o usuário dispensar.

### 🟢 N7. Laços de borda em `wrongAccount` e `userStillExists`
- `lib/auth/firebase_auth_repository.dart:84-95`: o código `user-not-found` está certo (é o `USER_DELETED` do SDK, conferido). Mas `reload()` de usuário excluído pode falhar com `user-token-expired`, e o SDK nesse caso **faz signOut local** (`_logoutIfInvalidated`). Resultado: `userStillExists` devolve `null` (falha `uncertain`, seguro) e o app mostra a faixa "Sessão expirada" para uma conta que talvez tenha sido excluída (a flag "esperado" já foi cancelada). Confuso, não perigoso. Tratar `user-token-expired` como `false` (conta indisponível) e chamar `expectSignOut` antes do `reload`.
- `AccountDeleter` com `wrongAccount` mostra "Entre com a mesma conta Google que está conectada" para o caso de aba trocada; o texto serve, mas o diálogo pertence à conta X enquanto a sessão agora é Y. Aceitável.
- Resíduo do S1 antigo: `AuthController.signOut` (`providers.dart:142`) ainda chama `expectSignOut()` sem `catch`/`cancelExpectedSignOut()`. Nit.

### 🟡 N8. Lacunas de teste que restam e o que o roteiro precisa cobrir
- Sem teste direto: `FirestoreProfileDataSource` (`Source.server`, `limit`, `batch`, timeout real), `FirestoreFavoritesDataSource`, `FirebaseAuthRepository` (popup, `user-mismatch`, `requires-recent-login`, `User.delete`). Sem `fake_cloud_firestore`, a única forma de exercitar isso é o roteiro manual ou o Emulator do Auth + Firestore com um teste de integração Flutter (recomendo como dívida registrada, não como bloqueio, se o roteiro for assinado).
- O laço paginado (pergunta d) está correto na leitura: lê do servidor, apaga a página, repete até vazio; a falha no meio mantém o marcador `deleting` e a retomada recomeça de onde a coleção estiver (idempotente, duplicação de lote abandonado é inofensiva); teto de 500 páginas é um guarda real. Único ponto não provado: um lote abandonado por timeout de escrita que o SDK ainda reenvia depois, coexistindo com a retomada. É idempotente, mas é o caso do passo 4 do roteiro.

## Respostas aos pontos de atenção

- (a) Sinal por tempo: correto no desenho (N1, N2). Sem vazamento de timer, sem contaminação entre contas.
- (b) `clearPersistence`: ver N5.
- (c) `wrongAccount`: cobre reauth (antes do popup, de forma síncrona, e conferindo o uid devolvido) e `deleteCurrentUser`; nenhum dado de terceiros é tocado. Ver N7.
- (d) Laço paginado: ver N8.
- (e) Risco de token ~1 h: continua residual, sem mitigação no Spark; está documentado no doc 08 mas **mal descrito na política** (N3). Dívida: Cloud Function/TTL no Blaze.
- (f) Reflow: revertido (tabela acima).
- (g) Lacunas: N8.

## Roteiro manual de validação (Manager, site real; conta Google de teste, 2 navegadores ou 1 janela anônima)

Pré: `firebase deploy --only firestore:rules` já feito e conferido no console (R2).
1. **Rules publicadas (R2):** console Firestore > Rules: o texto é idêntico a `firestore.rules` do repositório. API key restrita a `celsofabri.github.io/*` e `localhost`; Authorized domains só com esses. Região `southamerica-east1`.
2. **Login e isolamento (S1):** navegador A, conta Ana: favorita 2 filmes, marca 3 episódios. Abra DevTools > Network > Offline, marque mais 1 episódio, **saia** da conta (Ana), entre com Bruno (conta 2) e verifique que Bruno não vê nada de Ana. Volte a ficar Online e confirme no console do Firestore que a marcação offline de Ana **chegou** ao documento dela e não ao de Bruno. Saia e entre de novo como Ana: lista completa.
3. **Rejeição de regra:** com DevTools, tente gravar apelido > 40 caracteres burlando a UI (ou edite o limite no código local) e confirme o banner "O servidor recusou...".
4. **Exclusão feliz (R1):** crie uma conta de teste com 450+ favoritos (ou ao menos 3 e confira o lote no Emulator já testado). Perfil > Excluir. Reautentique com a **mesma** conta. Esperado: progresso, volta à Home deslogada, console Firestore sem `users/{uid}` nem subcoleção, Authentication sem o usuário. Conferir que não aparece "Sessão expirada".
5. **Limpeza do cache (N5):** na mesma sessão do passo 4, feche **todas** as abas, reabra e confira em DevTools > Application > IndexedDB que o banco `firestore/[DEFAULT]/...` foi recriado vazio; repita com **duas abas abertas** e observe se a segunda quebra e se a flag permanece.
6. **Exclusão interrompida:** inicie nova exclusão, ponha o navegador Offline no meio dos favoritos. Esperado: mensagem de "pode ter sido iniciada", cartão/faixa "Concluir" no Perfil. Volte Online, conclua. Verifique que não sobra nenhum documento. Repita derrubando a rede **depois** de `deleteProfile` (conta existe, vazia).
7. **Conta errada e sessão:** na reautenticação escolha outra conta Google. Esperado: "Entre com a mesma conta" e nada apagado. Com duas abas: troque a conta na aba 2 enquanto o diálogo da aba 1 está aberto e confirme.
8. **Stall/cota (N1):** Online, no DevTools bloqueie `firestore.googleapis.com` só para a rota de escrita (Request blocking `*Write*`) por 40 s: deve surgir "Não conseguimos confirmar...". Desbloqueie: some sozinha.
9. **Outro aparelho (I3-i):** com a conta aberta em dois aparelhos, exclua em um e observe o outro por 1 h: registre se ele consegue recriar `users/{uid}/favorites` (valida o texto de N3).
10. Registrar resultado e data em `docs/08-design-login-perfil.md`.

## O que ainda bloqueia merge/deploy

Bloqueantes (a ação é do Manager ou texto; nenhuma é mudança de lógica):
1. R1: roteiro passos 4 a 7 executados e registrados.
2. R2: passo 1 do roteiro assinado.
3. S1: passo 2 executado.
4. Política: corrigir N3 (frase das 1 h) e N4 (nome do controlador, transferência internacional); tudo texto.

Não bloqueiam (tarefa registrada com dono): N1 (cota de leitura), N5 mitigações (1) e (2), N7, N8 (teste de integração com Emulator do Auth + Firestore), App Check em modo monitorar, alerta de uso da cota, limpeza de órfãos por Cloud Function/TTL, ordem dos imports.
