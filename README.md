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
- **Exportar meus dados (JSON):** no Perfil, seção "Seus dados". Baixa `cinetrack-export-AAAA-MM-DD.json` com todos os documentos de favoritos exatamente como estão no Firestore (inclusive campos que o app ainda não conhece), apelido e contadores; só leitura, do servidor e em páginas (sem limite de itens). Sem conexão, só exporta os dados do aparelho se o usuário escolher, avisando que podem estar incompletos. Entrega por download no navegador (web); em Android/iOS a seção explica que ainda não está disponível. Detalhes e formato em [docs/39](docs/39-exportar-meus-dados.md).
- **Minhas recomendações:** além de favoritar, você marca com **Recomendo** (polegar para cima, no detalhe e nos cartões de Favoritos) os títulos que realmente curtiu; eles aparecem na aba **Minhas recomendações** (`/recommendations`; no celular, a aba "Recomendo" da barra inferior, e a Busca vira a lupa da barra superior). É um campo opcional `recommended` no documento do favorito (ausente = não; nada é migrado nem reescrito) e é **privado por enquanto**: só você vê. Recomendar um título que não está em Favoritos o adiciona (numa só escrita); remover de Favoritos apaga a recomendação (com confirmação). Pediremos seu consentimento antes de qualquer compartilhamento. **Rollout: publique `firestore.rules` antes do app** (detalhes em [`docs/40`](docs/40-minhas-recomendacoes-implementacao.md)); nunca volte as regras depois da primeira marcação.
- **Excluir conta e dados:** pede para entrar com o Google de novo, apaga favoritos, recomendações, progresso e apelido em lotes e, por fim, a conta. É retomável: se for interrompida, o app oferece "Concluir exclusão". Exige estar online.

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
- `test/export_serializer_test.dart`, `test/export_data_section_test.dart` — exportação de dados: formato, round-trip pelo `FavoriteMapper`, campos desconhecidos, documentos corrompidos, paginação (0 a 1500 itens), botão/estados/offline/erro no Perfil, troca de conta, nome do arquivo, 320 a 1440 px.

Todos os testes acima rodam no CI sem credenciais. Os **testes das regras do Firestore** exigem o Emulator (Node + JDK 21 ou superior) e não rodam no `flutter test`:

```
cd firestore_rules_test
npm install
npm test          # sobe o emulator, roda os testes e encerra (projeto "demo-cinetrack", sem rede)
```

Na máquina de desenvolvimento o `java` padrão é o 11 (recusado pelo firebase-tools): use `JAVA_HOME=/opt/homebrew/opt/openjdk@24 PATH=/opt/homebrew/opt/openjdk@24/bin:$PATH npm test`. A suíte (`firestore.rules.test.mjs` e `recommended.test.mjs`, que roda também contra `fixtures/firestore.rules.v1`, as regras anteriores) cobre isolamento entre usuários, validação de schema, apelido (1-40) e a sequência da exclusão de conta (marcador, lotes de 400, perfil).

## Estrutura

```
lib/
  models/        # FavoriteItem, SeasonCache, EpisodeCache, SearchResult...
  auth/          # AuthRepository (Firebase Auth + Google), AppUser, AuthFailure
  account/       # AccountDeleter (exclusão retomável), sessão expirada
  export/        # Exportar meus dados: serializador, paginação, entrega do arquivo (web)
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
