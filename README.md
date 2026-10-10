# CineTrack

App Flutter para favoritar filmes e séries e acompanhar o progresso episódio por episódio. Catálogo via [TMDB API](https://www.themoviedb.org/documentation/api); login com Google (Firebase Auth) e favoritos/progresso salvos **por usuário na nuvem** (Cloud Firestore, plano gratuito), acessíveis de qualquer dispositivo. Sem login, o catálogo (Home, Explorar, Busca, Detalhes) continua livre; gravar favoritos e progresso exige entrar.

Contexto do produto e decisões técnicas: [`docs/01-especificacao.md`](docs/01-especificacao.md), [`docs/02-design.md`](docs/02-design.md), [`docs/adr/adr-001-stack.md`](docs/adr/adr-001-stack.md). Login e dados na nuvem: [`docs/07-especificacao-login-perfil.md`](docs/07-especificacao-login-perfil.md), [`docs/08-design-login-perfil.md`](docs/08-design-login-perfil.md), [`docs/adr/adr-003-firebase-auth-e-persistencia-na-nuvem.md`](docs/adr/adr-003-firebase-auth-e-persistencia-na-nuvem.md).

> **Nota de versão: favoritos locais antigos.** Os favoritos e o progresso que ficavam só no aparelho (Hive) **não aparecem mais** nesta versão: decidimos não migrá-los. Os dados antigos não são apagados (continuam no armazenamento do aparelho/navegador); voltar para a versão anterior do app os exibe de novo. Ao entrar com o Google, você recomeça com a lista da sua conta.

## Setup

1. Instale as dependências:
   ```
   flutter pub get
   ```
2. Crie sua chave de API no TMDB (gratuita): https://www.themoviedb.org/settings/api
3. Copie `.env.example` para `.env` e cole sua chave:
   ```
   cp .env.example .env
   ```
4. Rode o app com um emulador/simulador ou aparelho conectado:
   ```
   flutter run
   ```

### Local x deploy (como a chave TMDB chega ao app)

| Ambiente | Como a chave entra | Comando |
|---|---|---|
| **Local** | Asset `.env` (arquivo ignorado pelo git) | `flutter run -d chrome`, ou `flutter build web` + servir `build/web` |
| **GitHub Pages** | `--dart-define` com o secret `TMDB_API_KEY` (o Pages não serve arquivos com ponto, como `.env`) | Automático no workflow |

`--dart-define=TMDB_API_KEY=...` tem prioridade sobre o `.env`. Por isso, **não passe um valor de teste** (ex.: `=x`) em builds locais: todas as chamadas ao TMDB voltam 401 ("Chave de API ausente ou inválida"). Em builds locais, não use `--dart-define`.

### Login com Google e dados na nuvem (Firebase)

O projeto Firebase é criado pelo mantenedor (passo a passo em [`docs/08-design-login-perfil.md`](docs/08-design-login-perfil.md), seção "Passo a passo manual do Manager"). Os identificadores do Firebase (`lib/firebase_options.dart`, `google-services.json`, `GoogleService-Info.plist`) são públicos por design e ficam versionados; a proteção real são as regras do Firestore ([`firestore.rules`](firestore.rules)). Nenhum segredo entra no repositório.

- **Estado atual:** `lib/firebase_options.dart` já é real, mas **só para web** (projeto `cinetrack-d9398`). Android/iOS ainda não foram configurados (fora de escopo). Se o arquivo voltar a ser o *placeholder*, o app abre como navegador de catálogo, sem botão de login ("Login indisponível no momento") e o deploy no CI é barrado.
- **Configurar outra plataforma/projeto:** `dart pub global activate flutterfire_cli` e, na raiz do projeto, `flutterfire configure` (sobrescreve `lib/firebase_options.dart`). No Android, cadastre a SHA-1 no console; no iOS, adicione o `GoogleService-Info.plist` ao Runner.
- **Desligar:** `--dart-define=CLOUD_SYNC=false` desliga login e nuvem (catálogo apenas). O padrão é ligado.
- **Regras:** publique `firestore.rules` no console (ou `firebase deploy --only firestore:rules`). Plano **Spark**, sem Blaze.

#### Sincronização, perfil e privacidade

- **Indicador de sincronização** (ícone de nuvem ao lado do avatar): sincronizado, enviando, sem conexão (mostrando dados do aparelho) ou com problema. Escritas funcionam offline e são enviadas ao reconectar.
- **Avisos** (faixa no rodapé): *sessão expirada* (as alterações pendentes ficam guardadas e seguem após entrar de novo **com a mesma conta**), *limite diário gratuito atingido* e *alteração recusada pelo servidor*. Na primeira carga, "não consegui carregar" nunca aparece como "você não tem favoritos": há um estado de erro com "Tentar novamente".
- **Detalhes (filme e série):** "Marcar como assistido" (série inteira com confirmação e Desfazer), episódios com imagem, descrição, data e duração, e **trailer** em janela (`docs/45-detalhe-trailer-episodios.md`). **Privacidade:** o player do YouTube (modo `youtube-nocookie.com`) só é carregado depois que você toca em "Assistir trailer"; nada é enviado ao Google antes disso e o app não envia dados da sua conta (a política de privacidade explica). Fora da web o trailer abre no YouTube.
- **Perfil:** apelido editável (1 a 40 caracteres), estatísticas (calculadas a partir dos dados, sem contadores guardados), "Membro desde", resumo de privacidade e link para a [política de privacidade](web/privacidade.html) (publicada como `privacidade.html` junto do app no GitHub Pages).
- **Amizades (Fase 1, concluída: fatias 0 a 5 + fechamento):** seção "Amizades" no Perfil, **opt-in e desligada por padrão**: identificador único (`@usuario`, 3 a 20 caracteres, troca a cada 30 dias), apelido, foto do Google (só se marcada) e "Aparecer na busca". Ativar copia identificador, apelido e a URL da foto para `handles/{h}` + `social/{uid}` (única ação com consentimento na tela); quem não ativa não grava nada social. "Desativar" apaga amigos, pedidos, bloqueios, convite, cartão e reserva. **Exclusão de conta** e **exportação** (schema 2, seção `social` com uid e apelido dos amigos) já cobrem esses dados; sem Cloud Functions. **Fatia 2:** ícone **Amigos** (barra superior no mobile, menu do topo no desktop, cartão "Gerenciar amigos" no Perfil; só com as amizades ativas), rotas protegidas `/friends` e `/friends/add`, **busca por identificador exato** (1 leitura por busca; mensagem única "Nenhum usuário encontrado com esse identificador." para inexistente, oculto, bloqueado ou você mesmo), **enviar pedido** (o pedido guarda uid, apelido e foto dos dois, a data e o **@identificador atual de quem pede**, conferido pelas regras: quem recebe vê o `@identificador`, que ninguém consegue falsificar; limite de 50 pendentes; pedido cruzado, quando os dois já pediram, vira amizade), **cancelar** e a lista **Pedidos enviados** (paginada, cache de 5 min, sem listener; recusas somem sem aviso). **Fatia 3 (fecha o ciclo "adicionar amigos"):** `/friends` tem duas seções, **Amigos | Pedidos** (abas acessíveis por teclado com setas; só a seção na tela é lida). **Pedidos recebidos**: lista paginada (20 por página, até 50 mostrados), **Aceitar** (um único batch cria a amizade `friendships/{menorUid}_{maiorUid}` e apaga o pedido) e **Recusar** (apaga em silêncio: a pessoa **não é avisada**). **Amigos**: lista paginada (50 por página, limite de 300) com apelido e foto do par e **Remover amizade** (some para os dois lados, com confirmação "A pessoa não será avisada"). **Indicador**: `Badge` numérico no ícone Amigos (mobile e desktop) e no cartão "Gerenciar amigos"; um `count()` agregado por 10 min, sem listener; em 320 px com fonte grande o ícone cede e o indicador vira um ponto em "Perfil". Um amigo vê **somente o seu cartão** (apelido e foto, o que você escolheu publicar); nada de favoritos, recomendações ou atividade é compartilhado. Remover amigo e recusar pedido não avisam ninguém. A exportação inclui amigos e pedidos recebidos/enviados (uid e apelido); desativar as amizades ou excluir a conta apaga os pares, então a pessoa some da lista dos outros. **Fatia 4 (bloqueio):** a terceira aba de `/friends` é **Bloqueados** (`?tab=bloqueados`; Amigos | Pedidos | Bloqueados, setas/Home/End). **Bloquear** (cartão de amigo, de pedido recebido e de resultado da busca; sempre com diálogo que explica o efeito) grava o bloqueio e, **no mesmo batch**, apaga a amizade e os pedidos pendentes nos dois sentidos, sem nenhuma leitura; a pessoa **não é avisada**, deixa de encontrar você na busca (mesma mensagem de "não encontrado") e não consegue pedir amizade (falha genérica); o que ela percebe é só que a amizade ou o pedido sumiram. O bloqueio guarda uid, apelido e foto da pessoa **como estavam no cartão que você viu** (para a lista) e a data, **legível só por você**. **Desbloquear** (com confirmação) apaga o registro e **não restaura** amizade nem pedidos. A lista é paginada (20), com cache de 5 min e sem listener. Desativar as amizades e excluir a conta apagam os bloqueios; a exportação os inclui (uid e apelido). **Fatia 5 (convite por link e refresh):** no cartão Amizades do Perfil, **"Convite por link"**: cria **um** link e um código (24 caracteres base62 de `Random.secure()`, nunca derivados de uid/hora/contador; validade 1, 7 (padrão) ou 30 dias, ≤ 30 pela regra), com **copiar link/código**, **Compartilhar** (Web Share do navegador, sem dependência nova), validade restante, **Novo link** (apaga o anterior) e **Revogar** (apaga o convite e move o ponteiro `social/{uid}.inviteCode` no mesmo batch; efeito imediato). O link é `<página>#/invite/<código>` (rota pública `/invite/:code` do `go_router`, estratégia hash: funciona sob o `base-href /cinetrack/` do GitHub Pages sem depender do 404.html). Abrir o link custa **1 `get`** de `invites/{código}`, só para quem está conectado com as amizades ativas (deslogado ou sem amizades, a tela pede para entrar/ativar e continua sozinha no mesmo endereço); mostra o cartão (apelido e foto, nunca o identificador) e **"Enviar pedido"**, que é um pedido **normal** (o dono ainda aceita; nunca cria amizade direta) e **funciona com "Aparecer na busca" desligado**. Código errado, revogado, expirado, de quem bloqueou você (ou que você bloqueou), oculto ou o seu próprio dão **a mesma mensagem** ("Este convite não está disponível"). "Adicionar amigo" ganhou "Tenho um convite" (cola link ou código). **Refresh de apelido/foto (D8):** ao mudar o apelido ou a foto o app atualiza **a sua metade** em cada amizade (lotes de 100, em segundo plano, sem avisar ninguém, só amizades; pedidos e bloqueios guardam o instantâneo), **retomável** (marcador por uid no aparelho, continua ao abrir o app), **coalescido** (várias trocas seguidas = uma passada + no máximo mais uma), parado por desativar/exclusão/troca de conta, com um aviso discreto no cartão. A exportação inclui o convite ativo (código e validade). Detalhes e cota: [docs/68](docs/68-social-fatia-5-implementacao.md). **Fechamento (docs/73):** o pedido é amarrado ao `@identificador` de quem pede (regras + cartão de pedido recebido); a **foto do Google trocada ou removida** chega ao cartão, ao convite e aos amigos na próxima vez que você entrar com o Google (foto do provedor `google.com`; 1 escrita, só se mudou; foto desmarcada continua desmarcada; se a foto sumir do Google, "Mostrar minha foto" desliga e religar é manual); uma ação com outra em andamento responde "Aguarde a operação anterior terminar." em vez de fingir sucesso; a exportação inclui resíduos de amizade/pedido/bloqueio mesmo sem o ponteiro. **Rollout: as regras (`firestore.rules`, finais) e os 2 índices de `firestore.indexes.json` precisam estar publicados (índices "Enabled") ANTES do app**; com as regras antigas ativar falha com "Amizades ainda não estão disponíveis" e nada se perde; nunca volte as regras. Detalhes: [docs/49](docs/49-especificacao-amizades.md), [docs/50](docs/50-design-amizades.md), [docs/51](docs/51-regras-sociais-fatia-0.md), [docs/55](docs/55-social-fatia-1-implementacao.md), [docs/59](docs/59-social-fatia-2-implementacao.md), [docs/62](docs/62-social-fatia-3-implementacao.md), [docs/65](docs/65-social-fatia-4-implementacao.md), [docs/68](docs/68-social-fatia-5-implementacao.md), [docs/73](docs/73-social-fechamento-fase-1.md).
- **Exportar meus dados (JSON):** no Perfil, seção "Seus dados". Baixa `cinetrack-export-AAAA-MM-DD.json` (schema 2) com todos os documentos de favoritos exatamente como estão no Firestore (inclusive campos que o app ainda não conhece), apelido, contadores e, com amizades ativas (ou resíduos delas), identificador, cartão, amigos, pedidos, bloqueios e convite (seção `social`, uid e apelido dos outros, nunca fotos deles); só leitura, do servidor e em páginas (sem limite de itens). Sem conexão, só exporta os dados do aparelho se o usuário escolher, avisando que podem estar incompletos. Entrega por download no navegador (web); em Android/iOS a seção explica que ainda não está disponível. Detalhes e formato em [docs/39](docs/39-exportar-meus-dados.md).
- **Minhas recomendações:** além de favoritar, você marca com **Recomendo** (polegar para cima, no detalhe e nos cartões de Favoritos) os títulos que realmente curtiu; eles aparecem na aba **Minhas recomendações** (`/recommendations`; no celular, a aba "Recomendo" da barra inferior, e a Busca vira a lupa da barra superior). É um campo opcional `recommended` no documento do favorito (ausente = não; nada é migrado nem reescrito) e é **privado por enquanto**: só você vê. Recomendar um título que não está em Favoritos o adiciona (numa só escrita); remover de Favoritos apaga a recomendação (com confirmação). Pediremos seu consentimento antes de qualquer compartilhamento. **Rollout: publique `firestore.rules` antes do app** (detalhes em [`docs/40`](docs/40-minhas-recomendacoes-implementacao.md)); nunca volte as regras depois da primeira marcação.
- **Excluir conta e dados:** pede para entrar com o Google de novo, apaga favoritos, recomendações, progresso e apelido em lotes e, com amizades ativas, identificador, cartão, amigos, pedidos, bloqueios e convite, e, por fim, a conta. É retomável: se for interrompida, o app oferece "Concluir exclusão". Exige estar online.

Sem a chave configurada, o app abre normalmente mas a busca por novos filmes/séries mostra um erro de configuração (itens já favoritados continuam funcionando offline).

## Stack

Flutter · Riverpod (estado) · go_router (navegação) · TMDB API (catálogo) · Firebase Auth + Cloud Firestore (login Google e dados por usuário, plano Spark) · Hive (apenas cache de catálogo/descoberta). Detalhes e trade-offs em `docs/adr/adr-001-stack.md` e `docs/adr/adr-003-firebase-auth-e-persistencia-na-nuvem.md`.

## Testes

```
flutter test
```

- `test/progress_calculator_test.dart` — lógica de progresso/próximo episódio (unitário, sem Flutter).
- `test/tmdb_api_client_test.dart` — parsing de busca e mapeamento de erros HTTP (401/429) do TMDB.
- `test/catalog_screen_test.dart` — tela Explorar: filmes/séries, filtro por gênero e paginação ao rolar.
- `test/search_screen_test.dart` — busca ao digitar (a partir de 2 caracteres, com debounce).
- `test/recommended_data_test.dart`, `test/recommendations_ui_test.dart` — "Minhas recomendações": campo `recommended` (mapper/repositório, escrita por campo, provas de não perda de dados), botão "Recomendo", aba, navegação (tab bar de 5 itens + lupa), estados e layout.
- `test/favorites_screen_test.dart` — estados vazio, filme, série e filtro na tela "Meus favoritos".
- `test/home_screen_composition_test.dart` — composição da home e navegação pelo menu do topo até "Meus favoritos".
- `test/favorites_repository_contract_test.dart` e `test/favorites_repository_test.dart` — contrato do `FavoritesRepository` (favoritar, `addTvShow`, assistido, temporada), independente do armazenamento.
- `test/favorite_mapper_test.dart` — mapper do documento da nuvem e merge por campo dos episódios.
- `test/login_widgets_test.dart`, `test/pending_intent_test.dart`, `test/account_isolation_test.dart` — login (sucesso, cancelado, popup bloqueado, sem rede, duplo toque), intenção pendente após login e isolamento/troca de conta, tudo com fakes (sem Firebase nem rede).

- `test/sync_status_test.dart`, `test/sync_status_provider_test.dart`, `test/sync_widgets_test.dart` — estado de sincronização (pendente/offline/erro), erros de escrita visíveis (regras, cota, sessão), erro x vazio no primeiro login, sessão expirada preservando pendências, indicador e faixa de avisos.
- `test/account_deleter_test.dart`, `test/profile_screen_test.dart`, `test/profile_stats_test.dart` — exclusão de conta retomável (ordem, offline, reauth cancelada/outra conta, falha no meio), diálogo acessível por teclado, apelido, estatísticas e link de privacidade.
- `test/social_friends_test.dart`, `test/friends_slice3_screens_test.dart` — amizades (fatia 3): aceitar/recusar/remover/pedido cruzado com fakes, limites (300 amigos, 50 recebidos), paginação, caches reconstruídos nos eventos certos, corrida do `socialHint`, contagem do indicador (TTL), desativar e excluir conta com amizades reais, exportação, abas por teclado, Badge e fallback de 320 px, estados, 320 a 1440 px, fonte 3x, claro/escuro.
- `test/social_block_test.dart`, `test/friends_slice4_screens_test.dart`, `test/firestore_social_data_source_test.dart` — amizades (fatia 4): bloquear em cada combinação de estado (sem nada, só amizade, só pedido recebido/enviado, os dois, tudo), bloqueado não encontra/não envia/não aceita, desbloquear sem restaurar, lista de bloqueados (paginada, cache), listas e indicador reconstruídos, sem vazamento entre contas, desativar/excluir/exportar com bloqueios reais, aba Bloqueados (estados, diálogos, teclado, semântica, 320 a 1440 px, fonte 3x, claro/escuro), feedback do "Atualizar" e o `FirestoreSocialDataSource` REAL (teto de 300 no pedido cruzado, bloquear) por costuras injetáveis sem Firebase.
- `test/social_invite_test.dart`, `test/social_refresh_controller_test.dart`, `test/social_invite_account_test.dart`, `test/invite_ui_test.dart` — amizades (fatia 5): código do convite (tamanho, alfabeto, unicidade em 20 mil amostras, `Random` injetável, nunca derivado de uid/hora), validade ≤ 30 dias, link sob o `base-href`, criar/substituir/revogar/abrir/usar com fakes, mensagem única, refresh das metades (só a minha, idempotente, lotes, interrompido e retomado, coalescido, parado por desativar e por troca de conta), desativar/excluir/exportar com convite real, guarda "ocupado" do bloqueio pela busca, seção Convite e tela `/invite/:code` (estados, teclado, semântica, 320 a 1440 px, fonte 3x, claro/escuro, deslogado → entrar → continua, sem amizades → ativar → continua). O golden e o replay (`dart_payloads.test.mjs`, 364 testes) cobrem as escritas novas contra as regras reais.
- `test/social_requests_test.dart`, `test/friends_screens_test.dart`, `test/friends_navigation_test.dart` — amizades (fatia 2): busca com resposta única, enviar/duplicado/cruzado/limite 50/cancelar/paginação, cota (zero leituras ao abrir a busca, TTL), exportação e exclusão com pedidos, telas `/friends` e `/friends/add` (estados, teclado, semântica, 320 a 1440 px, fonte 3x, claro/escuro), redirect e ícone Amigos.
- `test/social_validation_test.dart`, `test/social_repository_test.dart`, `test/social_export_test.dart`, `test/social_section_test.dart` — amizades (fatia 1): validadores iguais às regras (handle, 31 reservados lidos de `firestore.rules`, apelido UTF-16/NFC, foto), ativar/trocar handle/30 dias/desativar em lotes, exclusão de conta retomável com o passo social, exportação schema 2 e a seção do Perfil (estados, teclado, semântica, 320 a 1440 px, fonte 3x, claro/escuro).
- `test/export_serializer_test.dart`, `test/export_data_section_test.dart` — exportação de dados: formato, round-trip pelo `FavoriteMapper`, campos desconhecidos, documentos corrompidos, paginação (0 a 1500 itens), botão/estados/offline/erro no Perfil, troca de conta, nome do arquivo, 320 a 1440 px.

Todos os testes acima rodam no CI sem credenciais. Os **testes das regras do Firestore** exigem o Emulator (Node + JDK 21 ou superior) e não rodam no `flutter test`:

```
cd firestore_rules_test
npm install
npm test          # sobe o emulator, roda os testes e encerra (projeto "demo-cinetrack", sem rede)
```

Na máquina de desenvolvimento o `java` padrão é o 11 (recusado pelo firebase-tools): use `JAVA_HOME=/opt/homebrew/opt/openjdk@24 PATH=/opt/homebrew/opt/openjdk@24/bin:$PATH npm test`. **Rode `npm test` e `npm run test:mutations` isolados, um por vez:** as duas suítes usam o emulador na porta 8080 (`firebase.json`) e limpam o banco entre testes, então outra execução no mesmo emulador gera falhas espúrias (que as mutações contariam como "mortas"). Antes, confira `lsof -i :8080`; se estiver ocupada por outra execução, não a interrompa: rode numa cópia do diretório trocando, no `firebase.json` da cópia, **todas** as portas do emulador: `emulators.firestore.port` (8080), `emulators.firestore.websocketPort` (9150), `emulators.hub.port` (4400) e `emulators.logging.port` (4500); só a porta principal não basta, porque as auxiliares também colidem. A suíte cobre isolamento entre usuários, validação de schema, apelido (1-40) e a sequência da exclusão de conta: `firestore.rules.test.mjs` e `recommended.test.mjs` (que roda também contra `fixtures/firestore.rules.v1`, as regras anteriores), e, das amizades, `social.test.mjs` (regras sociais), `social_compat.test.mjs` (regras antigas x app novo e documentos antigos x regras novas), `rules_budget.test.mjs` (limites de chamadas de regra, custo de `isFriend`/`isBlocked`) e `dart_payloads.test.mjs` (reexecuta contra as regras finais os payloads que o app Dart grava, fixados por `fixtures/social_payloads.json`, gerado por `test/social_payloads_golden_test.dart`). Do perfil social (Fase 2, docs/84): `shared_profile.test.mjs` (leitura só dono/amigo mútuo Google, schema e consentimento de `shared_profiles/{uid}`), `shared_profile_shapes.test.mjs` (tipos errados contra as checagens otimizadas), `favorites_epsat.test.mjs` (campo aditivo `epsAt` nos favoritos e todos os payloads do app atual), `social_compat.test.mjs` também contra `fixtures/firestore.rules.v3` (regras de produção da Fase 1), `rules_budget.test.mjs` com o custo de chamadas e a folga de expressões travada (pior escrita do app ≤ 65%, pior documento ≤ 70%) e `shared_profile_payloads.test.mjs`, que reexecuta `fixtures/shared_profile_payloads.json` gerado pelo golden Dart; **enquanto esse fixture não existir o teste aparece como `todo`, e gerá-lo é gate da Fatia 1**. `npm run test:mutations` aplica mutações às regras e ao fixture e exige que cada uma derrube pelo menos um teste (roda antes uma linha de base sem mutação, que tem de passar).

## Estrutura

```
lib/
  models/        # FavoriteItem, SeasonCache, EpisodeCache, SearchResult...
  auth/          # AuthRepository (Firebase Auth + Google), AppUser, AuthFailure
  account/       # AccountDeleter (exclusão retomável), sessão expirada
  export/        # Exportar meus dados: serializador, paginação, entrega do arquivo (web)
  social/        # modelos, validação e código de convite das amizades
  data/          # FavoritesDataSource e ProfileDataSource (Firestore / deslogado), estado de sincronização
  services/      # TmdbApiClient, LocalStore (Hive: só caches), ProgressCalculator, FavoriteMapper
  repositories/  # FavoritesRepository — única camada que decide rede x nuvem x cache
  providers/     # Riverpod providers
  screens/       # Home, Explorar (catálogo por gênero), Meus favoritos, Busca, Detalhes, Perfil
  widgets/       # Componentes reutilizáveis (poster, badge de progresso, estados)
```

## Deploy (GitHub Pages)

O deploy é automático via GitHub Actions (`.github/workflows/deploy-pages.yml`) a cada push na `main` (ou manualmente em Actions > Run workflow). O pipeline roda `flutter analyze` e `flutter test`; se falhar, nada é publicado.

**Configuração única no repositório:**
1. Settings > Pages > Build and deployment > Source: **GitHub Actions**.
2. Settings > Secrets and variables > Actions > New repository secret: `TMDB_API_KEY` com a sua chave do TMDB.

**Atenção:** em app web a chave do TMDB é compilada no JavaScript publicado e pode ser extraída por qualquer visitante. Use uma chave dedicada/gratuita, sem outros usos, e revogue-a no TMDB se houver abuso. A chave nunca é commitada nem impressa nos logs.

**Rollback:** em Actions, abra um run anterior bem-sucedido e clique em "Re-run all jobs" (republica aquela versão); ou faça `git revert` do commit problemático na `main` e o deploy roda de novo.

**Antes de publicar na `main`:** o build de produção só consegue gravar favoritos com o Firebase configurado (`lib/firebase_options.dart` real, o que já vale para web) **e as regras do Firestore publicadas** (`firestore.rules` do repositório). O workflow barra o deploy se o arquivo ainda for o placeholder. O workflow não muda para o Firebase (config pública, sem secrets novos). A política de privacidade (`web/privacidade.html`) vai junto no build, em `/cinetrack/privacidade.html`.
