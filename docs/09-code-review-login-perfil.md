# Review: feat/login-perfil (login Google + favoritos na nuvem + Perfil), Fatias 1 e 2

Veredito: **APROVADO COM RESSALVAS** para a branch `feat/login-perfil`. **Merge/deploy na `main` BLOQUEADO até** o item B1 (guard no workflow) e a configuração real do Firebase (ver seção 3).

Resumo: troca o armazenamento de favoritos de Hive local para Firestore por usuário (`users/{uid}/favorites/{key}`), atrás de `FavoritesDataSource`; Auth com Google; intenção pendente após login; Perfil; regras do Firestore com testes de Emulator. Arquitetura limpa e coerente com o design. O código novo é bem fatiado (mapper puro, data source injetável, fakes). Nada de segredo versionado. Os riscos reais estão no que ainda não foi verificado contra o SDK/projeto real e no deploy automático da `main`.

## Verificação independente (rodada por mim)

| Comando | Resultado real |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | 143/143 passaram |
| Testes de rules (`firebase emulators:exec`, JDK 24 via `openjdk@24`; o JDK 11 padrão da máquina é recusado pelo firebase-tools) | 15/15 passaram, 5 grupos |
| `flutter build web` | não reexecutado por mim (declarado ok pelo dev) |

Observação: o `npm test` do README exige JDK 21+; com o `java` padrão desta máquina (11) falha com mensagem clara. Documentado no README, ok.

## 🔴 Bloqueantes

### B1. Deploy automático da `main` publicaria um app que não grava nada
- Arquivos: `.github/workflows/deploy-pages.yml` (não alterado), `lib/firebase_options.dart:1-14` (placeholder que lança), `lib/services/firebase_bootstrap.dart:19-31`.
- Cenário: merge na `main` dispara o deploy (`on: push: main`). O build passa em analyze/test/build, o site vai ao ar com `DefaultFirebaseOptions.currentPlatform` lançando, `initFirebase()` retorna false, não há botão de login, e "favoritar" mostra "Login indisponível". O Hive legado não é lido. Resultado em produção: o Manager perde, na prática, a funcionalidade principal do app (os dados antigos ficam no navegador, mas invisíveis). Só a nota do README protege contra isso, e isso é só convenção humana.
- Correção sugerida (barata): passo no workflow antes do build que falha se o placeholder ainda existir, por exemplo `grep -q "PLACEHOLDER" lib/firebase_options.dart && { echo "::error::Firebase não configurado"; exit 1; }`. Alternativa: não fazer merge desta branch até rodar `flutterfire configure`, com as regras publicadas. Recomendo as duas coisas. Este é um bloqueante de **merge**, não de continuar a branch.

## 🟡 Importantes

### I1. Erros de escrita engolidos (`_fire`): perda silenciosa
- `lib/data/firestore_favorites_data_source.dart:101-108`.
- Cenário: regra rejeita (`permission-denied`, por exemplo `addedAt` avançando num `set` sobre doc existente vindo de outro aparelho, `eps` inválido, doc > 1 MiB) ou cota estourada. A UI já mostrou o favorito (otimista), o SDK reverte o cache local, o item some sozinho e o usuário nunca sabe. Pior em `addTvShow`: se o `add` for rejeitado, o `setSeasonSummaries` seguinte (`update`) falha também, silenciosamente.
- Concordo que não se pode aguardar o ack (trava offline), e a decisão é correta. Mas "log em debugPrint" não é produção: em release o log não chega a ninguém. Aceitável nesta fatia desde que a Fatia 3 (status de sync/erro visível) fique como tarefa registrada **antes do release**, e que o item B1 impeça publicar sem ela. Sugestão adicional: expor um `Stream` de erros de escrita no data source para a Fatia 3 consumir, em vez de redescobrir.

### I2. `get()` com `Source.cache` e fallback para servidor pode lançar offline, e a idempotência depende dele
- `lib/data/firestore_favorites_data_source.dart:45-60`; usado em `favorites_repository.dart` (`addMovie`, `addTvShow`, `toggle*`, `setSeasonWatched`).
- Cenário: logo após login (listener ainda não populou o cache) ou em aparelho novo offline, `Source.cache` falha, o fallback `ref.get()` offline lança `unavailable`/"client is offline". A exceção sobe pela UI (`runWrite` só trata `AuthRequiredException`), e `_addFavorite`/toggle terminam com exceção não tratada em vez de mensagem. Fora do offline, há também uma janela em que `get` retorna null por cache frio e `toggleEpisodeWatched` vira no-op silencioso. Não verificado contra SDK real (o próprio arquivo declara UNVERIFIED).
- Correção: capturar `FirebaseException` do fallback e tratar como "indisponível, tente novamente" (ou assumir inexistente apenas para `add`, nunca para toggle); cobrir no spike S1.

### I3. Regras: lacunas de validação de `eps`, `seasonSummaries` e `updatedAt`
- `firestore.rules:26-27` e `:23` (`seasonSummaries`).
- `eps` só valida "é map com <= 5000 entradas": chaves e valores arbitrários são aceitos (valores não-`true`, chaves fora de `^\d+_\d+$`, strings enormes). `seasonSummaries` valida só lista <= 100, sem validar elementos. `updatedAt` e `lastWatchedAt` em update não são exigidos como timestamp quando presentes em `updatedAt`. Isolamento entre usuários não é afetado (só o próprio dono escreve), então o risco é de dado sujo e abuso de cota do próprio usuário, e o limite de 1 MiB do documento contém o pior caso. Não bloqueia, mas o design promete "validação de campos".
- Correção: validar `updatedAt is timestamp` quando presente; para `eps`, não é possível iterar em rules, então aceitar o limite de tamanho e anotar a limitação no design; mantenha o teste de tamanho (hoje não há teste para `eps` > 5000 nem para `seasonSummaries` > 100: ver Q3).

### I4. `.gitignore` contradiz ADR-003 e README
- `.gitignore` (bloco "Credentials", `google-services.json` e `GoogleService-Info.plist`) vs ADR-003 item 7 e README ("ficam versionados").
- Cenário: após `flutterfire configure` e baixar os arquivos nativos, o `git add` os ignora; CI/outro clone não compila Android/iOS com Firebase nativo, ou alguém força `-f` sem saber. Decidir: são públicos por design (ADR) então remova-os do `.gitignore`; ou mantenha ignorados e corrija ADR/README. Segurança: nada sensível hoje no repositório (verifiquei: `firebase_options.dart` é placeholder, nenhum arquivo `google-services`/`plist` de Firebase rastreado, `.env` ignorado).

### I5. Splash pode ficar travado se o stream de auth nunca emitir
- `lib/main.dart` (`sessionKnown = !authStateProvider.isLoading`), `lib/widgets/app_splash.dart` (`ready`).
- Cenário: `authStateChanges()` do Firebase normalmente emite rápido, mas se a inicialização web ficar pendente (IndexedDB bloqueado, extensão), a splash cobre o app para sempre e o catálogo livre vira inacessível. Correção: teto de tempo (ex.: 3 s) após o qual `ready` vira true e a UI segue como deslogada; testar com um `AuthRepository` fake que nunca emite.

### I6. Perda de dados históricos do Manager sem plano de exportação
- Decisão do Manager (sem migração) está registrada e aceita; apenas reforço que o README promete "voltar à versão anterior mostra de novo", o que vale só enquanto a origem/box Hive não for limpa. Sugestão: tarefa registrada de um "exportar/importar" opcional, ou ao menos um script único do Manager, antes de ele limpar dados do navegador. Não bloqueia (decisão dele).

## 🟢 Sugestões

- S1. `FavoriteMapper.fromMap`: `addedAt ?? DateTime.now()` (favorite_mapper.dart) dá um valor instável a cada leitura se o campo faltar; prefira descartar o doc ou usar `DateTime.fromMillisecondsSinceEpoch(0)`.
- S2. `toggleMovieWatched`/`toggleEpisodeWatched` deslogado: `get` retorna null e a ação é um no-op **sem** `AuthRequiredException`, logo sem convite de login. Hoje inalcançável (deslogado não vê favoritos), mas frágil; considere lançar `AuthRequiredException` no `SignedOutFavoritesDataSource.get`... ou testar o contrato.
- S3. `lastWatchedAt` nulo até o ack (desvio 6): a ordenação do "Continuar assistindo" cai em `addedAt` por instantes; ok, mas o `snapshots(includeMetadataChanges: false)` com `ServerTimestampBehavior.estimate` evitaria o salto. Veja `doc.data(options: SnapshotOptions(serverTimestamps: ServerTimestampBehavior.estimate))`.
- S4. `FavoritesRepository.dataSource` opcional (desvio 5): aceitável, mas deixa a produção sem garantia de compilação caso alguém esqueça de injetar (cairia silenciosamente em "deslogado"). Prefira `required` e atualizar os fakes antigos, na primeira oportunidade.
- S5. `PendingIntentRunner`: o `catchError` vazio esconde falhas do replay; ao menos `debugPrint` do tipo.
- S6. Imports fora de ordem alfabética em `catalog_screen.dart`/`search_screen.dart` (`auth_gate` após `empty_state`) e `main.dart` (import de `auth/` depois de `providers/`); estilo apenas.
- S7. README: o texto "Sem a chave configurada..." ficou após a seção Firebase, separando-o do bloco de TMDB; reordene.

## Aderência ao design e desvios do dev

1. Gate por `AuthRequiredException` + `PendingIntent` em vez de `requireLogin` prévio: **concordo**. Equivalente funcional, menos intrusivo. Ressalva: S2. O `Future.microtask` no replay é correto e o bug que o motivou foi coberto por teste (`pending_intent_test.dart`).
2. Escritas sem aguardar ack (`_fire`): **concordo com a decisão, discordo da lacuna de erro** (I1).
3. Sem Firebase/CLOUD_SYNC off = sem gravação, Hive legado não lido: **concordo com a decisão do Manager, mas é regressão grave de produto se publicada sem Firebase** (B1).
4. `firebase_options.dart` placeholder: **concordo**, desde que o guard (B1) o detecte.
5. `dataSource` opcional no repositório: **tolero** (S4).
6. `updatedAt` + `Source.cache` + `lastWatchedAt` nulo até o ack: **concordo**; I2 e S3 são os cuidados.
7. Progresso 0 sem catálogo local em aparelho novo: **concordo**, e a nota para a Fatia 4 usar `seasonSummaries` precisa virar tarefa registrada (hoje é só comentário no registro). Impacto percebido: "Continuar assistindo" vazio em aparelho novo até abrir as temporadas, o que contradiz parcialmente o objetivo "acessível de qualquer dispositivo"; ver Q4.
8. Testes de rules 15/15 e teste (a) como modelo da premissa 5b: **concordo**, e confirmei 15/15. O teste está honestamente rotulado ("modelled"), mas ver Q2.

## Segurança: ok, com pontos

- Isolamento: `firestore.rules` restringe `users/{uid}/**` ao próprio uid; `match /{document=**}` nega o resto (inclui futuras subcoleções); create/update validam chave via regex, `id`/`mediaType` contra a chave, campos permitidos (`hasOnly`), tipos e tamanhos; `addedAt` não avança. Testado no Emulator (isolamento A/B, não autenticado, fora do espaço). O data source é ligado a um único `uid` e o provider é recriado na troca de conta; leitura/escrita só passa pelo caminho `users/{uid}/favorites`. Sem queries `collectionGroup`.
- Cache local: `season_catalog` e `discovery_cache` não guardam `watched` (`stripWatched` na gravação e `overlayWatched` na leitura), então não vaza progresso entre contas, mesmo com catálogo legado contendo flags antigas (o overlay as sobrescreve). Verificado por leitura e pelos testes `account_isolation_test.dart`.
- Segredos: nenhum rastreado. `.env` ignorado. A chave TMDB já era pública no bundle web (fora de escopo, já reconhecido). Config Firebase é pública por design; a proteção são as rules + restrição de API key por referrer (a fazer pelo Manager, passo manual). Lembrete: sem App Check (débito aceitável no Spark).
- LGPD/logs: `debugPrint` só imprime código/tipo de erro, sem PII. Pontos I3 (validação) e a ausência de "excluir minha conta/dados" (campo `deleting` previsto nas rules, mas sem fluxo no cliente): confirmar que está na Fatia 3/4, pois a LGPD exige o direito de exclusão antes de abrir ao público.

## Testes e qualidade

- Q1. Redirect de `/profile` deslogado (`lib/router.dart:25-31`) **sem teste** (grep em `test/` não encontra). Comportamento de acesso, deve ter teste: deslogado vai a `/`, logado vê o perfil, e `isLoading` não redireciona.
- Q2. Teste `account_isolation_test.dart:111-138` "modelled" e o `InMemoryFavoritesDataSource` implementam a premissa 5b por construção: o teste não pode falhar por defeito do SDK, então só valida o fluxo do repositório. Está rotulado, ok, mas **não conta como evidência de isolamento da fila offline**. Spike S1 (Firebase real/emulator com SDK) continua pendente e é pré-requisito do release. Risco real: se a fila do SDK for por dispositivo (não por uid), a escrita offline da Ana poderia ser enviada sob a sessão do Bruno e rejeitada pelas rules (seguro, não vaza), resultando em perda silenciosa (I1), não em vazamento.
- Q3. Rules sem testes para: `eps` > 5000, `seasonSummaries` > 100, `overview`/`posterPath` oversized, `delete` do doc de perfil, e `update` de `users/{uid}` com campo extra.
- Q4. Nenhum teste cobre o cenário aparelho novo (nuvem com progresso, catálogo local vazio) e o que a Home mostra.
- Q5. Duplicação: `discovery_section.dart` repete a ramificação movie/tv que `FavoritesRepository.addResult` já encapsula; use `repo.addResult(result)`, como `catalog_screen` e `search_screen`.
- Q6. Tamanho: ~540 linhas alteradas em arquivos rastreados mais muitos arquivos novos (~1.6k linhas só em lib/auth, data, services novos). Acima da heurística de 400, mas coeso e já fatiado em Fatias 1/2; aceito, sugerindo dois commits (infra de dados / UI) para facilitar revisão.

## Perguntas

- ❓ Qual a política para o cache `Source.cache` em aparelho novo na primeira abertura logado: há aviso/skeleton enquanto o primeiro snapshot não chega? (relaciona-se com I2.)
- ❓ O `deleting` das rules do perfil tem fluxo planejado (exclusão de conta)? Em qual fatia?

## Condições para virar APROVADO (merge na main)

1. B1 resolvido (guard no workflow) e Firebase realmente configurado (`flutterfire configure`, regras publicadas, API keys restritas, domínio autorizado).
2. Spike S1 executado com SDK real/emulator (fila offline por uid, `Source.cache`, serverTimestamp).
3. I1 (feedback de erro de escrita) e I2 em tarefa registrada/entregues antes do release; I4 decidido.
4. Q1 (teste do redirect) adicionado.
