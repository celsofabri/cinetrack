# CineTrack

App Flutter para favoritar filmes e séries e acompanhar o progresso episódio por episódio. Catálogo via [TMDB API](https://www.themoviedb.org/documentation/api); favoritos e progresso salvos **somente localmente** no aparelho (Hive), sem conta e sem sincronização entre dispositivos.

Contexto do produto e decisões técnicas: [`docs/01-especificacao.md`](docs/01-especificacao.md), [`docs/02-design.md`](docs/02-design.md), [`docs/adr/adr-001-stack.md`](docs/adr/adr-001-stack.md).

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

Sem a chave configurada, o app abre normalmente mas a busca por novos filmes/séries mostra um erro de configuração (itens já favoritados continuam funcionando offline).

## Stack

Flutter · Riverpod (estado) · Hive (persistência local) · go_router (navegação) · TMDB API (catálogo). Detalhes e trade-offs em `docs/adr/adr-001-stack.md`.

## Testes

```
flutter test
```

- `test/progress_calculator_test.dart` — lógica de progresso/próximo episódio (unitário, sem Flutter).
- `test/tmdb_api_client_test.dart` — parsing de busca e mapeamento de erros HTTP (401/429) do TMDB.
- `test/catalog_screen_test.dart` — tela Explorar: filmes/séries, filtro por gênero e paginação ao rolar.
- `test/search_screen_test.dart` — busca ao digitar (a partir de 2 caracteres, com debounce).
- `test/favorites_screen_test.dart` — estados vazio, filme, série e filtro na tela "Meus favoritos".
- `test/home_screen_composition_test.dart` — composição da home e navegação pelo menu do topo até "Meus favoritos".

## Estrutura

```
lib/
  models/        # FavoriteItem, SeasonCache, EpisodeCache, SearchResult...
  services/      # TmdbApiClient, LocalStore (Hive), ProgressCalculator
  repositories/  # FavoritesRepository — única camada que decide rede x cache
  providers/     # Riverpod providers
  screens/       # Home, Explorar (catálogo por gênero), Meus favoritos, Busca, Detalhes
  widgets/       # Componentes reutilizáveis (poster, badge de progresso, estados)
```

## Deploy (GitHub Pages)

O deploy é automático via GitHub Actions (`.github/workflows/deploy-pages.yml`) a cada push na `main` (ou manualmente em Actions > Run workflow). O pipeline roda `flutter analyze` e `flutter test`; se falhar, nada é publicado.

**Configuração única no repositório:**
1. Settings > Pages > Build and deployment > Source: **GitHub Actions**.
2. Settings > Secrets and variables > Actions > New repository secret: `TMDB_API_KEY` com a sua chave do TMDB.

**Atenção:** em app web a chave do TMDB é compilada no JavaScript publicado e pode ser extraída por qualquer visitante. Use uma chave dedicada/gratuita, sem outros usos, e revogue-a no TMDB se houver abuso. A chave nunca é commitada nem impressa nos logs.

**Rollback:** em Actions, abra um run anterior bem-sucedido e clique em "Re-run all jobs" (republica aquela versão); ou faça `git revert` do commit problemático na `main` e o deploy roda de novo.
