# 23 - Plano de atualização de dependências

Autor: Arquiteto | Data: 2026-10-03 | Status: Proposta (aguarda decisão do Manager)
Escopo: somente análise. Nenhum arquivo do projeto foi alterado. Os experimentos rodaram numa **cópia descartável** (scratchpad) do working tree, em `pub get`/`analyze`/`test`/`build web` isolados.

## 0. Como foi verificado

- `flutter pub outdated` e `flutter pub deps --no-dev` no projeto (somente leitura).
- Changelogs em pub.dev: flutter_riverpod, go_router, cached_network_image, flutter_dotenv, flutter_lints, intl.
- Código-fonte do riverpod 3.4.3 já presente no pub-cache (para confirmar o parâmetro `retry`).
- Cópia do projeto: baseline = `analyze` limpo, 354 testes verdes. Depois apliquei os lotes abaixo e medi.
- **Não verificado:** changelogs de url_launcher, meta, vector_math, test_api, octo_image (patch/minor, sem leitura); guia oficial de migração do Riverpod 3 além do changelog; comportamento em runtime/dispositivo (android/ios); `flutter build apk/ios`; smoke manual no navegador.

Base atual: Flutter 3.47.5 (Dart 3.12, confirmado no `pubspec.lock`: `dart: ">=3.12.0 <4.0.0"`). O `pubspec.yaml` declara SDK `>=3.3.0 <4.0.0`, bem abaixo do que o CI realmente usa.

## 1. Diretas x transitivas

**Diretas (pubspec.yaml)** - ação nossa:

| Pacote | Atual | Alvo | Observação |
|---|---|---|---|
| url_launcher | 6.3.2 | 6.3.3 | patch, já resolvível dentro de `^6.3.2` |
| flutter_lints (dev) | 4.0.0 | 6.0.0 | puxa `lints` 4.0.0 -> 6.1.0 |
| intl | 0.19.0 | 0.20.3 | |
| flutter_dotenv | 5.2.1 | 6.0.1 | |
| cached_network_image | 3.4.1 | 4.0.4 | puxa platform_interface 5.0.3, _web 2.0.3, octo_image 2.1.2 |
| go_router | 14.8.1 | 18.0.2 | |
| flutter_riverpod | 2.6.1 | 3.4.3 | puxa `riverpod` 3.4.3 |

Sem atualização pendente: firebase_core 4.15.0, firebase_auth 6.7.0, cloud_firestore 6.10.0, google_sign_in 7.2.0, hive, hive_flutter, http (nenhum aparece no `outdated`).

**Transitivas** - só mudam por resolução; não editar: cached_network_image_platform_interface, cached_network_image_web, octo_image, riverpod, lints, code_assets, hooks, jni, objective_c, record_use, meta, vector_math, test_api, material_color_utilities.
Observações:
- `code_assets`, `hooks`, `jni`, `objective_c`, `record_use` pertencem à cadeia de native assets do toolchain/plugins; `meta`, `test_api`, `material_color_utilities`, `vector_math` vêm do SDK Flutter. Estas últimas ficam **presas ao Flutter 3.47.5** (os "disponíveis" divergem do que o SDK permite - `test_api` 0.7.12 aparece como resolvível = 0.7.12). Só mudam se o Flutter do CI subir. Não tentar forçar com `dependency_overrides`.
- Aparecem como novas no resolvido (não estão no lock): `material_ui`, `cupertino_ui`, `listen`, `flutter_localizations`. `material_ui`/`cupertino_ui` entram com cached_network_image 4 e go_router 18 (o changelog diz que migraram de material.dart para material_ui). Isso aumenta a árvore de dependências; observar tamanho do bundle web (não medido).

## 2. Análise por dependência direta

### 2.1 url_launcher 6.3.2 -> 6.3.3 (risco baixo, esforço mínimo)
Patch dentro da faixa atual. Uso: `lib/providers/account_providers.dart`. Coberto indiretamente pelos testes de conta.

### 2.2 flutter_lints 4 -> 6 (risco baixo; atenção ao SDK lower bound)
- Mudanças: 5.0.0 (Flutter 3.24/Dart 3.5) adiciona `invalid_runtime_check_with_js_interop_types`, `unnecessary_library_name`; remove 4 regras. 6.0.0 (Flutter 3.32/Dart 3.8) adiciona `strict_top_level_inference` e `unnecessary_underscores`.
- **O CI falha com infos?** O workflow roda `flutter analyze` sem `--no-fatal-infos`; por padrão o `flutter analyze` retorna código de saída não zero para qualquer issue, inclusive `info`. Portanto novas lints quebram o deploy.
- Medido na cópia: só com flutter_lints 6 e SDK `>=3.3.0` -> **0 issues** (a regra `unnecessary_underscores` só dispara com language version >= 3.7, e o pubspec está em 3.3). Ao subir o SDK mínimo para `>=3.12.0` -> **53 issues info**: 41 de `unnecessary_underscores` (os `(_, __)` e `(_, __, ___)` em callbacks, ~37 ocorrências em lib/test) e 12 de `prefer_initializing_formals` (ex.: `account_deleter.dart:41`, `favorites_repository.dart:44-46`). Todas corrigíveis mecanicamente (`dart fix --apply` resolve; **não rodado**, pois alteraria código).
- Decisão necessária: subir o SDK mínimo (recomendado, é a realidade do CI e é exigido de fato por go_router 18 / cached_network_image 4) e corrigir as 53 infos no mesmo lote, ou manter `>=3.3.0` e adiar as lints. Não recomendo desligar regras.

### 2.3 intl 0.19 -> 0.20.3 (risco baixo)
- 0.20.0 exige Dart ^3.3 (cumprido), suporte WASM, CLDR 48 na 0.20.3; sem breaking relevante para nós. O pacote `flutter_localizations` (SDK) já resolve com 0.20.3 (o `pub outdated` mostra 0.20.3 resolvível; o resolve da cópia funcionou).
- Uso real: apenas `DateFormat('dd/MM/yyyy')` em `lib/screens/tv_details_screen.dart:342`. Sem `initializeDateFormatting`/locales. Impacto concreto: nenhum esperado. Coberto por `tv_details_screen_test`.

### 2.4 flutter_dotenv 5.2.1 -> 6.0.1 (risco baixo)
- Breaking: `testLoad` renomeado para `loadFromString`; arquivo vazio com `isOptional` não lança mais. 6.0.1: erros mais claros e `isEveryDefined` lança `NotInitializedError` antes do init.
- Uso: `dotenv.load(fileName: '.env')` e `dotenv.env['TMDB_API_KEY']` em `lib/main.dart:23-24`, dentro de `try/catch`. Não usamos `testLoad`. Impacto: nenhum. Verificado na cópia (analyze e testes verdes). No build de produção a chave vem de `--dart-define`, então esse caminho nem roda no Pages.

### 2.5 cached_network_image 3.4.1 -> 4.0.4 (risco baixo-médio)
- 4.0.0: exige Flutter >= 3.44 / Dart ^3.12 (OK no CI) e troca material.dart por `material_ui` (compatibilidade com WebAssembly). Sem mudança de API pública relatada no changelog que li (confiança média: não li o diff do código).
- Uso: **um único ponto**, `lib/widgets/poster_image.dart:58` (`CachedNetworkImage(imageUrl, placeholder, errorWidget)`). Na web o app **não usa** o pacote (usa `Image.network`, por escolha documentada no comentário), então o risco na web é só de compilação/tamanho. Mobile (android/ios) é onde o pacote realmente roda: exige smoke em dispositivo (não coberto por testes automatizados; `flutter_cache_manager` 3.4.5 vem junto).
- Medido na cópia: analyze, 354 testes e `flutter build web --release` OK.
- **Conflito:** `poster_image.dart` está modificado (13 linhas) na branch em andamento.

### 2.6 go_router 14.8.1 -> 18.0.2 (risco médio, esforço baixo)
Breaking relevantes (changelog):
- 15.0.0: URLs passam a ser **case sensitive** (`caseSensitive` default true); mínimo Flutter 3.27.
- 16.0.0: case sensitivity corrigida; GoRouteData/go_router_builder >= 3.0 (não usamos).
- 17.0.0: `ShellRoute` passa a notificar observers por padrão (`notifyRootObserver`; não usamos observers).
- 18.0.0: mínimo Flutter 3.44/Dart 3.12; migra para material_ui/cupertino_ui.
- Não li o guia oficial de migração 14->15..18 completo (não verificado) - pode haver itens não listados no changelog.

Uso no projeto (`lib/router.dart`): `GoRouter(initialLocation, refreshListenable, redirect, routes)`, `ShellRoute` com `builder` usando `state.uri.path`, `GoRoute` com `:id` e `state.pathParameters`, `state.matchedLocation` no `redirect`, `context.go/push` em ~15 pontos. Nenhuma dessas APIs aparece como removida. Os testes constroem `GoRouter` próprio (7 arquivos) e leem `routerDelegate.currentConfiguration.uri.path`.
- Medido na cópia: com go_router 18 (junto de lote 1/cached_network_image 4): analyze sem erros, 354 testes verdes, build web OK.
- Riscos residuais: (a) case sensitivity nos deep links do GitHub Pages (`/movie/123` é minúsculo, baixo); (b) fallback SPA via `404.html` e `--base-href` com go_router 18 precisa de teste manual em Pages (não coberto); (c) comportamento de back/pop na web.
- **Conflito alto:** `router.dart` tem +57 linhas na branch em andamento, e as telas de detalhe também.

### 2.7 flutter_riverpod 2.6.1 -> 3.4.3 (risco **alto**, migração própria)
Breaking (changelog 3.0.0): `StateProvider` movido para `package:flutter_riverpod/legacy.dart`; `AsyncValue.valueOrNull` removido (usar `.value`, que agora retorna null em erro); **retry automático** de providers que falham; providers pausam quando todos os listeners pausam (TickerMode etc.); Notifiers recriados a cada rebuild; `Ref` unificado (sem `FutureProviderRef`...); updates filtrados por `==`; mínimo Dart 3.12 neste 3.4.3.

Impacto medido na cópia (aplicando só correções mecânicas):
- Compilação: 19 erros `valueOrNull` (lib e test; ~15 arquivos), 1 `StateProvider` (`providers.dart:116`, `pendingIntentProvider`, usado em `providers.dart` e `auth_gate.dart`), 1 `Override` não exportado no teste (`test/support/cloud_overrides.dart`, corrigido com `import 'package:flutter_riverpod/misc.dart' show Override;`).
- Com `valueOrNull -> value` e import `legacy.dart`: analyze fica sem erros, **mas 13 dos 354 testes falham** (341 passam): `continue_watching_provider_test` (timeout de 30 s e "provider disposed during loading state"), `mobile_tabbar_test` (timers pendentes), `discovery_section_test` (estado de erro + botão "tentar novamente" não aparece), 1 em `favorites_polish_test` (catálogo vazio). As pilhas mostram `ProviderElement.triggerRetry` criando timers de 1,6 s / 3,2 s: é o **retry automático**.
- Impacto de produto: erros do TMDB (429/rede) hoje mostram `ErrorState` com retry manual; com Riverpod 3 o provider fica em loading enquanto re-tenta, atrasando/alterando a UI de erro. Mitigação (confirmada no código 3.4.3: `ProviderScope(retry:)` e `ProviderContainer(retry:)` existem): configurar `retry: (_, __) => null` em `main.dart` e nos testes (8 arquivos criam `ProviderContainer`; mais os `ProviderScope` de teste via helpers), preservando o comportamento atual; adotar retry seletivo depois.
- Usos que **não** quebram (verificado por analyze): 5 `Notifier` (`AuthController`, `AccountController`, `CatalogSyncNotifier`, `SyncStatusNotifier`, `SessionExpiryNotifier`), `NotifierProvider`, `FutureProvider.family`/`autoDispose.family`, `ref.listen`, `overrideWithValue`. Não há `StateNotifier`, `ChangeNotifierProvider` nem `ProviderRef`.
- `ref.listen(authStateProvider)` em `router.dart` + `refreshListenable` e a pausa de listeners (item 3) merecem teste manual de login/logout.
- Ganho necessário para o produto: **nenhum identificado**. 2.6.1 funciona, e Riverpod 2.x não tem bloqueio com Flutter 3.47.5 (build/test verdes hoje).
- **Conflito alto:** `providers.dart` (+46) e `catalog_sync_providers.dart` (+48) estão em edição na branch.

## 3. Lotes sugeridos (pequenos e reversíveis)

Cada lote = 1 branch + 1 PR + `pubspec.yaml`/`pubspec.lock` num único commit `chore(deps): ...` (rollback = `git revert` desse commit).

**Lote 0 (pré-requisito, sem custo):** nada de código; confirmar que `main` está verde.

**Lote 1 - lints + SDK mínimo + patches (baixo).** `sdk: '>=3.12.0 <4.0.0'`, `flutter_lints ^6.0.0`, `url_launcher ^6.3.3`, mais um `flutter pub upgrade` dentro das faixas atuais (traz as transitivas permitidas). Corrigir as 53 infos (`dart fix --apply` + conferência manual; os 12 `prefer_initializing_formals` pedem leitura). Mudança só de estilo, mas toca muitos arquivos: ver conflitos (seção 5).
Pronto quando: `flutter analyze` sem issues, `flutter test` 354 verdes, `flutter build web --release` ok.

**Lote 2 - intl + flutter_dotenv (baixo).** `intl ^0.20.3`, `flutter_dotenv ^6.0.1`. Pode ir junto do lote 1 (medido verde). Pronto: igual ao lote 1 + smoke: data de episódio em `dd/MM/yyyy` na tela de série.

**Lote 3 - cached_network_image 4 (baixo-médio).** `^4.0.4`. Pronto: lote 1 + **smoke em Android e iOS**: pôsteres carregam, placeholder e erro (modo avião), cache funciona; `flutter build apk --debug` e build iOS (não verificados). Web sem mudança de comportamento (usa `Image.network`); conferir tamanho do bundle.

**Lote 4 - go_router 18 (médio).** `^18.0.2`. Pronto: lote 1 + smoke manual: login, redirect de `/profile` deslogado para `/`, tab bar (mobile 320-768 px), abrir `/movie/:id` e `/tv/:id` por link direto/recarregando na URL publicada do Pages (`404.html` fallback), botão voltar do navegador, favoritos. Fazer **depois** de a branch feat/cast-and-people mergear (toca router).

**Lote 5 - Riverpod 3 (alto) - projeto à parte, adiado.** Passos: (1) `valueOrNull -> value` (cuidado: `.value` retorna null também em erro; revisar os ~20 usos semanticamente, especialmente `router.dart:30` e `authStateProvider`); (2) `legacy.dart` ou, melhor, migrar `pendingIntentProvider` para `Notifier`; (3) `retry: (_, __) => null` em `main.dart` e nos helpers de teste; (4) corrigir os 13 testes; (5) smoke de login/logout, sync de favoritos, sessão expirada; (6) decidir retry seletivo para TMDB. Estimativa: 1-2 dias de dev + QA. Pronto: analyze limpo, 354+ testes, build web, smoke manual completo, sem regressão de UX de erro.

## 4. Recomendação: agora x adiar x não atualizar

- **Fazer agora (lotes 1+2, mais lote 3 se houver tempo de testar mobile):** baixo risco, medido verde, destravam o SDK mínimo correto e as lints atuais. Ressalva: tocam muitos arquivos por causa das 53 infos; combinar janela com o dev da branch.
- **Fazer depois do merge da feat/cast-and-people (lote 4, go_router 18):** viável e testado verde na cópia, mas o ganho é só manutenção; sem urgência. Valor está em não acumular 4 majors de atraso.
- **Adiar (lote 5, Riverpod 3):** risco alto (retry automático altera UX de erro e quebra 13 testes), esforço de 1-2 dias, **sem ganho funcional necessário**. Só vale se surgir feature que dependa de Riverpod 3 ou se um pacote exigir. Fica sem urgência; Riverpod 2.6.1 continua suportado no nosso Flutter.
- **Não atualizar manualmente (presas ao Flutter 3.47.5 / à resolução):** `meta`, `test_api`, `material_color_utilities`, `vector_math` (vêm do SDK; sobem quando o Flutter do CI subir) e as demais transitivas (code_assets, hooks, jni, objective_c, record_use). Não usar `dependency_overrides`.
- **Firebase:** nada a atualizar (firebase_core 4.15.0, auth 6.7.0, firestore 6.10.0, google_sign_in 7.2.0 já são os atuais no `outdated`). Em nenhum lote testado a resolução tentou mexer neles; os lotes não alteram versões firebase_* (confirmado em `pub deps` da cópia). Mantê-los fora de todos os lotes para o risco ser isolado.
- **Pin do Flutter no CI (3.47.5):** subir o Flutter é outra decisão; não é necessária para nenhum lote 1-5 (todos exigem <= Dart 3.12).

## 5. Conflitos com feat/cast-and-people (working tree atual, branch ativa)

Arquivos já modificados na árvore (`git diff --stat`): `pubspec.yaml` (+1), `lib/router.dart` (+57), `lib/providers/providers.dart` (+46), `lib/providers/catalog_sync_providers.dart` (+48), `lib/services/tmdb_api_client.dart` (+30), `lib/screens/movie_details_screen.dart`, `tv_details_screen.dart`, `lib/widgets/poster_image.dart`, `app_shell.dart`, `favorites_section.dart`, e testes (`catalog_refresh_test.dart`, `favorites_harness.dart`).

| Lote | Conflito | Quando |
|---|---|---|
| 1 (lints/SDK) | Médio: `dart fix` mexe em ~37 pontos de lib/test, incluindo arquivos em edição; também `pubspec.yaml` | Após o merge da feat/cast-and-people (ou combinar para o dev aplicar `dart fix` no fim da branch) |
| 2 (intl/dotenv) | Só `pubspec.yaml` (1 linha de ambos os lados) | Pode ir logo após o merge, ou junto do lote 1 |
| 3 (cached_network_image) | `poster_image.dart` em edição | Após o merge |
| 4 (go_router) | `router.dart` e telas de detalhe em edição: alto | Após o merge e estabilização |
| 5 (Riverpod 3) | `providers.dart`, `catalog_sync_providers.dart`: alto | Só em janela sem outras features de providers |

Regra: **nenhum lote começa antes do merge da feat/cast-and-people** (e `pubspec.yaml` em ambos os lados garante conflito se rodar em paralelo). Cada lote em branch curta a partir de `main` atualizada.

## 6. Plano de rollback

- Cada lote é um commit de dependências (pubspec + lock) isolado; rollback = `git revert <sha>` e novo deploy (workflow `deploy-pages.yml` roda em push na `main`).
- Não misturar mudança de lockfile com refactor de código no mesmo commit, exceto onde obrigatório (lote 1: lints; lote 5: API).
- Antes de cada merge, guardar o URL e o commit do deploy anterior no Pages. Rollback do Pages = re-executar o workflow no commit anterior (`workflow_dispatch`).
- Mobile: não há pipeline de release no repositório; o lote 3 só deve virar build de loja após smoke em dispositivo.

## 7. Decisões que o Manager precisa tomar

1. Autorizar subir o SDK mínimo para `>=3.12.0` (alinhado ao CI) e aceitar 53 correções de lint no lote 1.
2. Confirmar que nenhum lote começa antes do merge da feat/cast-and-people.
3. Riverpod 3: adiar (recomendado) ou agendar como projeto próprio com QA?
4. Há alvo mobile (android/ios) em uso? Se sim, o lote 3 exige smoke em dispositivo; se não, pode ir junto do lote 1.
5. Subir o Flutter do CI além de 3.47.5 está fora deste plano; confirmar que fica fora.
