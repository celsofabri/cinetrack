# CineTrack: instruções para o Claude

App Flutter (web no GitHub Pages; Android/iOS no repositório) para favoritar filmes e séries e acompanhar o progresso episódio a episódio. Catálogo vindo do TMDB. Login Google e dados na nuvem com Firebase Auth + Cloud Firestore, no **plano Spark: sem Cloud Functions e sem Blaze**. O README traz setup, stack e deploy; este arquivo traz as regras de trabalho.

## Onde e como trabalhar

- **Um único diretório:** `/Users/celsofabrijr/Documents/projects/cinetrack`. Toda evolução acontece aqui, trocando de branch (`feat/...`, `fix/...`). **Nunca crie git worktrees nem diretórios irmãos** (`cinetrack-xxx`). Cópias descartáveis para testes paralelos vão em `/tmp` via `git archive`, nunca no projeto.
- Nada de `git stash` puro; prefira commit WIP. Merge na `main` só por fast-forward (`--ff-only`); nada de `--force`.
- Commits terminam com a linha `Co-Authored-By` indicada na sessão.
- **Push na `main` = deploy** no GitHub Pages (`.github/workflows/deploy-pages.yml`).

## Comandos

```bash
flutter pub get
flutter analyze                                   # tem de dar "No issues found"
TZ=America/Sao_Paulo flutter test                 # o CI roda neste fuso
TZ=UTC flutter test                               # rode também em UTC
flutter test --platform chrome test/shared_reading_web_safe_test.dart test/qa_a2_friend_profile_test.dart   # semântica numérica do web (dart2js)
flutter build web --release --base-href "/cinetrack/"
python3 tool/dart_mutations.py <cópia em /tmp>    # mutações Dart; recusa rodar num checkout git
```

Regras do Firestore (Emulator; precisa de JDK 21+, o `java` padrão da máquina é o 11):

```bash
cd firestore_rules_test
JAVA_HOME=/opt/homebrew/opt/openjdk@24 PATH=/opt/homebrew/opt/openjdk@24/bin:$PATH npm test
JAVA_HOME=/opt/homebrew/opt/openjdk@24 PATH=/opt/homebrew/opt/openjdk@24/bin:$PATH npm run test:mutations
```

O Emulator usa as portas 8080, 9150, 4400 e 4500. Para rodar em paralelo, use uma cópia em `/tmp` trocando **todas** essas portas no `firebase.json` da cópia.

## Segredos

- A chave do TMDB fica no `.env` (ignorado pelo git) em local e no secret `TMDB_API_KEY` no CI. **Nunca imprima, commite ou cole a chave** em log, doc ou handoff.
- Em builds locais não passe `--dart-define=TMDB_API_KEY=...` com valor de teste: ele tem prioridade sobre o `.env` e quebra as chamadas ao TMDB. Para testes, um `.env` fictício com `TMDB_API_KEY=test` basta.

## Restrições absolutas

1. **Nenhum usuário perde dados.** Toda mudança em dados, regras ou payloads precisa provar compatibilidade com os documentos e o app que estão em produção (fixtures `firestore_rules_test/fixtures/firestore.rules.v*` e `social_compat`).
2. **Regras antes do app, e regras nunca voltam.** Publicar `firestore.rules`/índices pelo CLI (`firebase deploy --only firestore:rules` / `firestore:indexes --project cinetrack-d9398`) antes do app que depende delas. Nunca usar `--force` nem aceitar apagar índices. Antes de publicar, conferir que o sha256 das regras de produção é o esperado.
3. **Visibilidade só entre amigos mútuos.** `users/{uid}/favorites` nunca é legível por terceiros. O que amigos veem sai só de `shared_profiles/{uid}`, com consentimento por seção.
4. **Cota gratuita do Spark.** Estime leituras e escritas de toda feature nova. Quem não usa o social não gera escrita nova.
5. **Orçamento de expressões das regras está apertado:** a pior escrita do app usa ~64% do limite de 1000 expressões, travado por `firestore_rules_test/rules_budget.test.mjs`. Se ele falhar, reveja o NFR ou otimize as regras; nunca afrouxe o teste.
6. Exclusão de conta (`AccountDeleter`), desativação de amizades e "Exportar meus dados" precisam cobrir todo dado novo.

## Convenções

- Textos de UI e documentação em **português**. Layout de 320 a 1440 px, fonte até 3×, claro/escuro, acessível por teclado (ordem de Tab, Esc) e com rótulos de leitor de tela.
- Testes com **fakes** (sem Firebase real), testes de regras no Emulator, mutações Dart e de regras: toda mutação nova tem de morrer.
- Documentos numerados em `docs/` (o próximo número segue o último) e ADRs em `docs/adr/` para decisões de arquitetura.
- Leitura de dados de terceiros é sempre tolerante e estrita com números: use `readSafeInt` (`lib/shared_profile/safe_int.dart`); no web, `Infinity` passa em `is int`.

## Processo do squad

O time e os papéis estão em `/Users/celsofabrijr/Documents/team` (Orquestrador, Product Analyst, Arquiteto, Devs, Code Reviewer 🛑, QA 🛑, SRE). Fluxo de cada feature:

1. Especificação (PA) + design e ADR (Arquiteto) + revisão de testabilidade (QA).
2. **Parar para o Manager decidir** as questões de produto e privacidade, com recomendações. Nada de código antes disso.
3. Fatias com Code Review e QA até **APROVADO sem ressalvas**: todo 🔴/🟡 é corrigido, e os 🟢 baratos também.
4. Revisão e QA integrados, checklist do SRE, publicação (regras pelo CLI se houver, depois fast-forward na `main`) e roteiro de smoke com 2 contas para o Manager.

## Estado do plano social (5 fases)

amizades (publicada) → perfil social (publicada; smoke do Manager pendente, `docs/89` §8) → ranking (em andamento, `docs/90`–`93`) → avaliações → comentários. Cada fase só é publicada com a anterior funcionando em produção.
