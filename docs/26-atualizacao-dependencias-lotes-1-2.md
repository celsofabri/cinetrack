# 26 - Atualização de dependências: Lotes 1 e 2

Autor: Dev + SRE | Data: 2026-10-03 | Base: `main` 1f85c38 | Branch local: `chore/deps-batch-1-2` (sem push, sem merge)
Contrato: `docs/23-plano-atualizacao-dependencias.md`. Fora desta rodada: Lote 3 (cached_network_image 4), Lote 4 (go_router 18), Lote 5 (Riverpod 3), upgrade do Flutter do CI.

## Compatibilidade com o CI
`deploy-pages.yml` fixa Flutter 3.47.5, que embute **Dart 3.13.4** (`flutter --version`). O novo SDK mínimo `>=3.12.0 <4.0.0` é satisfeito. Workflow não precisou de alteração.

## Lote 1 - commit 08021b0
`chore(deps): batch 1 - SDK >=3.12, flutter_lints 6, url_launcher 6.3.3`

| Item | Antes | Depois |
|---|---|---|
| environment.sdk | >=3.3.0 <4.0.0 | >=3.12.0 <4.0.0 |
| flutter_lints (dev) | ^4.0.0 (4.0.0) | ^6.0.0 (6.0.0) |
| lints (transitiva) | 4.0.0 | 6.1.0 |
| url_launcher | ^6.3.2 (6.3.2) | ^6.3.3 (6.3.3) |
| Transitivas (pub upgrade, dentro das faixas) | | code_assets 1.2.1->2.1.0, hooks 2.0.2->2.2.0, jni 1.0.3->1.1.0, objective_c 9.5.0->9.6.2, record_use 0.6.0->1.1.1, octo_image 2.1.1->2.1.2, meta 1.18.3->1.19.0, vector_math 2.4.0->2.4.3 |

Firebase, riverpod, go_router, cached_network_image: inalterados.

### Correções de lint (dart fix --apply, 61 fixes em 23 arquivos .dart; sem mudança de comportamento)
Com SDK >=3.12 e flutter_lints 6 o analyze passou a reportar 54 infos (o plano previa 53):
- 41 `unnecessary_underscores`: `(_, __)`/`(_, __, ___)` -> `(_, _)` em callbacks (lib: account_providers, router, catalog_screen, home_screen, account_widgets, app_shell, cast_widgets, poster_image, tmdb_attribution; test: 9 arquivos).
- 12 `prefer_initializing_formals`: parâmetros nomeados privados `this._x` (recurso do Dart 3.12). O nome público do parâmetro nomeado continua o mesmo (`api:`, `store:`, `sink:`, `auth:`, `profile:`, `now:`, `saveSummaries:`), então nenhum chamador mudou. Arquivos: account_deleter, firestore_favorites_data_source, firestore_profile_data_source, discovery_repository, favorites_repository, catalog_reconciler.
- 1 extra `use_null_aware_elements` em `tmdb_api_client.dart:176`: `{if (language != null) 'language': language}` -> `{'language': ?language}` (equivalente).

Formatação: o repositório em main já não está formatado conforme o `dart format` do Dart 3.13 (rodar nos arquivos alterados reescreve ~1000 linhas). Por isso **não** foi rodado format; o diff é só o do `dart fix` (84 inserções / 96 remoções em 25 arquivos incl. pubspec). Sugestão: tratar a reformatação como chore separado.

## Lote 2 - commit 2b4479a
`chore(deps): batch 2 - intl 0.20.3, flutter_dotenv 6.0.1`

| Item | Antes | Depois |
|---|---|---|
| intl | ^0.19.0 | ^0.20.3 (0.20.3) |
| flutter_dotenv | ^5.1.0 (5.2.1) | ^6.0.1 (6.0.1) |

Sem alteração de código.

### Análise de comportamento
- intl: único uso é `DateFormat('dd/MM/yyyy')` em `tv_details_screen.dart:344`. Padrão puramente numérico com separadores literais, sem `initializeDateFormatting` nem locale explícito: a saída não depende de dados CLDR/locale, portanto 0.20 não altera o texto em pt-BR. Teste de tela cobre.
- flutter_dotenv 6: `load(fileName: '.env')` e `dotenv.env[...]` (main.dart:23-24) não usam as APIs alteradas (`testLoad` renomeado). Mudança relevante em 6.x: `.env` vazio passa a lançar `EmptyEnvFileError`/`FileNotFoundError` quando não `isOptional` - já capturado pelo `try/catch` em `main.dart`. No CI, `--dart-define=TMDB_API_KEY` torna `apiKey` não vazio e o `dotenv.load` nem é chamado; o `.env` dummy (`TMDB_API_KEY=test`) só serve de asset para analyze/test/build e tem conteúdo. Nada muda.

## Resultados (reais, por lote, Flutter 3.47.5 local)
| Verificação | Lote 1 | Lote 2 |
|---|---|---|
| flutter pub get | ok | ok |
| flutter analyze | No issues found | No issues found |
| flutter test | 405 passaram | 405 passaram |
| flutter build web --release | ok | ok (também com `--base-href /cinetrack/ --dart-define=TMDB_API_KEY=x`) |

Não verificado: smoke manual no navegador, build apk/ios, execução real do workflow no GitHub.

## flutter pub outdated (após os lotes)
- cached_network_image 3.4.1 (4.0.4) + cached_network_image_platform_interface/web: Lote 3, fora desta rodada.
- go_router 14.8.1 (18.0.2): Lote 4, fora.
- flutter_riverpod/riverpod 2.6.1 (3.4.3): Lote 5, adiado (risco alto).
- material_color_utilities 0.13.0 (0.13.1) e test_api 0.7.12 (0.7.14): presos ao SDK Flutter 3.47.5; sobem só com o Flutter do CI.
- cupertino_ui, material_ui, listen, flutter_localizations aparecem só como resolvíveis (entrariam com Lotes 3/4).
- Dev dependencies e Firebase: em dia.

## Como reverter por lote
```
git revert 2b4479a   # desfaz o Lote 2 (intl/flutter_dotenv)
git revert 08021b0   # desfaz o Lote 1 (SDK, lints, url_launcher e correções de lint)
flutter pub get
```
Reverter o Lote 1 com o Lote 2 aplicado: reverter o Lote 2 primeiro (ambos tocam pubspec.yaml/pubspec.lock; conflitos triviais se a ordem for outra). Rollback em produção: re-executar o workflow no commit anterior (`workflow_dispatch`).
