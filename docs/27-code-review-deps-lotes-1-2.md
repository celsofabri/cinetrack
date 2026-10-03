# 27 - Code review: atualização de dependências (lotes 1 e 2)

Revisor: Code Reviewer. Escopo: `git diff 1f85c38..chore/deps-batch-1-2` (08021b0, 2b4479a, a266c3c). Contrato: docs/23 e registro docs/26. Revisão somente leitura; nenhum código alterado, `.env` não lido.

## Veredito: APROVADO COM RESSALVAS

Nada bloqueia o merge/push do ponto de vista de código. A ressalva (🟡) é de processo: confirmar o CI real no push e verificar Android/iOS, que não pude testar aqui.

## Comandos executados (resultados reais, branch chore/deps-batch-1-2)

| Comando | Resultado |
|---|---|
| `flutter pub get` | OK; 8 pacotes com versões mais novas fora da restrição (cached_network_image 4, go_router 18, riverpod 3 etc., fora de escopo) |
| `flutter analyze` | No issues found (sem infos) |
| `flutter test` | 405 testes, All tests passed |
| `flutter build web --release --base-href "/cinetrack/" --dart-define=TMDB_API_KEY=dummy` | Built build/web (aviso de dry-run Wasm e aviso de fonte CupertinoIcons, informativos) |
| `dart format --output=none --set-exit-if-changed lib test` | 117 arquivos, 109 mudariam |
| `git status` | limpo após tudo |

## Checagens pedidas

1. Fixes do `dart fix`: todos equivalentes.
   - `required this._x` (account_deleter, firestore_favorites/profile_data_source, discovery_repository, favorites_repository, catalog_reconciler): o parâmetro nomeado público continua `auth:`, `profile:`, `sink:`, `api:`, `store:`, `saveSummaries:`, `now:` (o `_` é removido do nome). Nenhum chamador ou teste mudou além dos curingas, e analyze/test passam, o que confirma. `now` em FavoritesRepository continua nullable (`this._now` é `DateTime Function()?`), mesma semântica.
   - `(_, _)`, `(_, _, _)`: curingas, sem efeito de runtime.
   - `{'language': ?language}` em tmdb_api_client.dart:176 vs `if (language != null) 'language': language`: idêntico. Nulo omite a chave; string vazia é incluída nos dois casos.
   - Sem mudança de lógica escondida: o diff de lib/ e test/ é só isso.
2. pubspec: só mudaram sdk, flutter_dotenv, intl, url_launcher, flutter_lints (conforme aprovado). Lock: além dos diretos, só transitivas (code_assets 2.1.0, hooks 2.2.0, jni 1.1.0, objective_c 9.6.2, record_use 1.1.1, lints 6.1.0, meta 1.19.0, octo_image 2.1.2, vector_math 2.4.3). firebase_*, cloud_firestore, google_sign_in, flutter_riverpod/riverpod, go_router e cached_network_image inalterados (lock e yaml). `sdks` do lock: dart >=3.12.0, flutter >=3.44.0.
   - Native assets (jni/hooks/objective_c/code_assets/record_use) são usados só nos hooks de build de Android/iOS/desktop; o build web release passou, então não há risco no web. Android/iOS: não pude verificar (sem build apk/ios aqui; só resolução + análise).
3. SDK: Flutter 3.47.5 local traz Dart 3.13.4, que satisfaz `>=3.12.0`. O workflow fixa `flutter-version: 3.47.5`, igual ao instalado aqui. Recurso de parâmetros nomeados privados exige Dart 3.12, então o piso é justificado. Não achei outro lugar que fixe SDK (analysis_options, android/settings.gradle.kts usam flutter.sdk local; sem .fvm/.tool-versions).
4. intl 0.20.3: único uso é `DateFormat('dd/MM/yyyy')` em tv_details_screen.dart:344, sem locale; formato numérico, sem mudança. flutter_dotenv 6.0.1: `dotenv.load(fileName: '.env')` e `dotenv.env[...]` em main.dart:23-24 usam a mesma API; main.dart não mudou. O caminho `--dart-define` não toca o dotenv (só tenta o .env se a chave for vazia), e o build com define passou.
5. CI: sequência equivalente (pub get, analyze, test, build web com --base-href e --dart-define) passou localmente. O passo "Ensure Firebase" não foi alterado e firebase_options.dart não consta no diff. O .env local existe e não foi tocado.
6. `dart format`: concordo com o dev. 109 de 117 arquivos já divergem do formatter, e o CI não executa format. Aplicar agora misturaria um diff gigante a um PR de dependências; faça em chore separado. O que o diff alterou continua na formatação existente.
   - firestore.rules, modelo salvo (lib/models) e `firestore_rules_test`: sem mudanças no diff.

## Findings

### 🔴 Bloqueantes
Nenhum.

### 🟡 Importantes
- pubspec.yaml:7: o piso do SDK sobe de 3.3.0 para 3.12.0. Consequência: qualquer Flutter anterior a ~3.44 deixa de resolver (já é o caso para o CI, que usa 3.47.5). Correção: nenhuma no código; registrar no README/doc que o mínimo local é Flutter >= 3.44 e acompanhar o primeiro run do GitHub Actions após o merge.
- Android/iOS não verificados: transitivas de native assets mudaram de versão (jni 1.0.3 para 1.1.0, objective_c 9.5.0 para 9.6.2). Cenário: falha de build nativo só aparece em `flutter build apk/ios`. Correção: se o app mobile é alvo, rodar `flutter build apk --debug` e `flutter build ios --no-codesign` antes de publicar mobile. Para o deploy web (único workflow) não há risco.

### 🟢 Sugestões
- Aplicar `dart format` e adicionar `dart format --set-exit-if-changed` ao CI numa tarefa à parte.
- Tirar `cupertino_icons` das referências de fonte (aviso no build web, pré-existente e não relacionado).

## O que bloqueia merge/push
Nada. Pode seguir para merge/push; após o push, o QA/Manager confirma o run verde do workflow `deploy-pages.yml`.
