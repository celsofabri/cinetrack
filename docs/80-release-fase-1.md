# 80 - Release: Amizades, Fase 1

> Autor: SRE/DevOps · Data: 2026-10-09 · Branch `feat/social-friends` em `b3d9610`, fast-forward sobre `main` `c60a393` (= `origin/main`, último deploy verde: run `37312280131`).
> Entradas: Code Review aprovado ([docs/78](./78-conferencia-final-fase-1-rodada-3.md)), QA aprovado ([docs/79](./79-reteste-qa-fase-1-rodada-3.md)), publicação no console ([docs/51 §7](./51-regras-sociais-fatia-0.md#7-passo-a-passo-do-console-manager)), cota ([docs/50 §9](./50-design-amizades.md), [docs/73](./73-social-fechamento-fase-1.md)).
> Somente leitura: nenhum merge, push ou deploy foi feito. Este documento não está commitado.

---

## 1. Pipeline: o que o `deploy-pages.yml` roda e o resultado na branch

O workflow roda a cada push na `main` (e por `workflow_dispatch`): checkout → Flutter **3.47.5** stable → bloqueio do `firebase_options.dart` placeholder → `flutter pub get` → `.env` fictício → `flutter analyze` → `flutter test` → `flutter build web --release --base-href "/cinetrack/" --dart-define=TMDB_API_KEY=<secret>` → `404.html` + `.nojekyll` → upload → deploy. O ambiente `github-pages` só aceita deploy da `main` (política de branch conferida via API). **Merge na `main` = deploy em produção.**

Rodei os mesmos passos localmente em `b3d9610` (Flutter 3.47.5 stable, a mesma versão do workflow), em 09/10:

| Passo do workflow | Resultado local |
|---|---|
| Ensure Firebase is configured | `grep -c PLACEHOLDER lib/firebase_options.dart` = **0**; arquivo real (projeto `cinetrack-d9398`). **Passa.** |
| `flutter pub get` | ok (exit 0). Única dependência nova: `unorm_dart ^0.3.3` (pub.dev, travada no `pubspec.lock`). |
| `flutter analyze` | **No issues found** (2,8 s) |
| `flutter test` | **1531 passaram**, 0 falharam, 0 pulados (≈ 49 s). Bate com o docs/79 (1531). |
| `flutter build web --release --base-href "/cinetrack/" --dart-define=TMDB_API_KEY=…` | **✓ Built build/web** (compilação 25 s; `main.dart.js` 3,98 MB; `build/web` 41 MB). `<base href="/cinetrack/">` conferido; `privacidade.html` presente. A chave veio do `.env` local, sem ser impressa. |
| Prepare Pages artifact | `404.html` e `.nojekyll` criados sem erro. |

Avisos não bloqueantes (já existiam na `main`): "Wasm dry run succeeded…" e "Expected to find fonts for … CupertinoIcons". Diferença conhecida em relação ao CI: localmente o `flutter test` usou o `.env` real em vez do fictício; os testes não acessam a rede, então não muda o resultado.

**Secrets e configuração:** o diff `main..b3d9610` (120 arquivos) **não** introduz secret, chave, `String.fromEnvironment` novo nem variável de CI nova. Os achados de uma varredura por `api_key|secret|token|password|AIza|sk-|ghp_` são texto de documentação e testes de regras (`sign_in_provider`, `'password'` como nome de provedor). O workflow **não foi alterado**; o único secret continua sendo `TMDB_API_KEY` (já configurado: os 5 últimos deploys estão verdes). `firebase.json`, `.gitignore` e `.github/` não mudaram.

---

## 2. Índices: o que o código usa x `firestore.indexes.json`

Consultas sociais do app (`lib/data/social_payloads.dart`, executadas por `lib/data/firestore_social_data_source.dart`):

| Consulta | Filtros / ordem | Índice necessário |
|---|---|---|
| Pedidos recebidos (`receivedQuery`) | `to == uid`, `orderBy createdAt desc`, `limit` + `startAfterDocument` | **Composto** `to ASC, createdAt DESC` |
| Pedidos enviados (`sentQuery`) | `from == uid`, `orderBy createdAt desc`, `limit` + `startAfterDocument` | **Composto** `from ASC, createdAt DESC` |
| Contadores (`receivedCountQuery`, `sentCountQuery`) e varreduras de exclusão | só `to ==` ou `from ==` | automático (campo único) |
| Amigos (`friendsQuery`, `friendsCountQuery`, varredura) | `members array-contains uid` | automático (campo único) |
| Bloqueados (`blocksQuery`) | subcoleção `users/{uid}/blocks`, `orderBy createdAt desc` | automático (campo único) |

`firestore.indexes.json` tem **exatamente esses 2 compostos** em `friend_requests`, escopo `COLLECTION`, e `fieldOverrides: []`. Nada falta, nada sobra. Os automáticos dependem de **não** haver isenção de índice de campo único em produção para `to`, `from`, `members` ou `createdAt` (não há como conferir daqui; o passo 4 manda olhar).

---

## 3. Checklist de release

```markdown
## Release: CineTrack web — Amizades Fase 1 (b3d9610)
- [x] QA: aprovado (docs/79, 0 bugs abertos)
- [x] Code review: aprovado (docs/78)
- [x] Pipeline local: analyze 0 issues · test 1531/1531 · build web ok (§1)
- [ ] Migrações: regras (aditivas, 64 → 359 linhas) e 2 índices publicados ANTES do app, índices "Enabled"
- [x] Feature flag: não há; o recurso é opt-in por usuário e desligado por padrão (quem não ativa não grava nada social)
- [ ] Janela: fora de pico (ver abaixo); nada de sexta à tarde nem fim de semana
- [x] Canary: não se aplica (GitHub Pages é tudo ou nada). Substituto: smoke completo com 2 contas logo após o deploy, antes de divulgar
- [x] Rollback: só do app (re-run do run 37312280131 ou git revert); regras nunca voltam (§5)
- [ ] Monitoramento: console do Firestore (Uso) + aba Actions na 1ª semana (§6)
- [ ] Comunicação: só divulgar o recurso depois do smoke 100% ✅
```

**Janela recomendada:** terça a quinta, entre **9h e 11h (horário de Brasília)**. O público de filmes e séries usa mais à noite (≈ 19h–23h) e nos fins de semana. A cota do Spark zera à meia-noite do Pacífico (≈ 4h–5h de Brasília), então de manhã sobra o dia inteiro de cota para o smoke. Reserve ~1h30: ~15 min de console, ~5 min de pipeline e ~45 min de smoke. Hoje (09/10) é sexta: **não recomendo publicar hoje à tarde**.

**Pré-requisitos:** acesso de dono ao console do Firebase (projeto `cinetrack-d9398`) e ao repositório no GitHub; conta **A** (a sua, com favoritos) e uma conta Google de teste **B**; o app atual aberto em https://celsofabri.github.io/cinetrack/.

---

## 4. Passo a passo (Manager, na ordem; não pule nem inverta)

### (a) Linha de base e cópia de segurança
1. Abra o app **atual** com a conta A > **Perfil** > "Seus dados" > **Exportar meus dados**. Guarde o `cinetrack-export-AAAA-MM-DD.json` fora do navegador.
2. Anote os números do Perfil: filmes, séries, episódios, assistidos e recomendados (é o passo 0 do docs/79 §3).

### (b) Autenticação, regras e smoke do app atual
3. Console Firebase > **Authentication** > **Método de login**: deixe **somente o Google** habilitado (desative Anônimo e E-mail/senha se aparecerem). As regras novas exigem `google.com` para criar dados sociais.
4. Console > **Firestore Database** > **Índices** > aba **Campo único** (Single field): confirme que **não** há isenção para `to`, `from`, `members` ou `createdAt`. Se houver, pare e avise o Orquestrador.
5. Abra o `firestore.rules` **da branch** (não o da `main`):
   ```bash
   cd /Users/celsofabrijr/Documents/projects/cinetrack-social
   git rev-parse --short HEAD          # deve mostrar b3d9610
   wc -l firestore.rules               # deve mostrar 359
   shasum -a 256 firestore.rules       # 7cf76481ff498171f11ad40a950065323dec34877afa710146d7fbd20132f0f3
   pbcopy < firestore.rules            # copia o conteúdo inteiro
   ```
6. Console > **Firestore Database** > **Regras**: selecione tudo no editor, cole e confira que começa com `rules_version = '2';` e tem `match /friend_requests/{key}`, `match /social/{uid}`, `match /handles/{h}` e `match /invites/{code}`. Clique em **Publicar**.
7. Na mesma aba, confira a **data/hora da publicação** e que o editor **não mostra erro**. Espere ~1 min para a propagação.
   - **Se o console recusar (erro de sintaxe):** não publique nada parcial. Fica valendo a regra anterior e nada mudou para ninguém. Pare aqui e avise o Orquestrador. A suspeita principal é o `matches` com `\p{Cc}`/`\x{...}` em `validName` (docs/51 §7). A correção é publicar uma versão corrigida, para frente.
8. **Smoke do app ATUAL com as regras novas** (conta A, em https://celsofabri.github.io/cinetrack/, recarregue a página):
   - os favoritos carregam; os números do Perfil são os mesmos do passo 2;
   - marque **e desmarque** um episódio de uma série com progresso; desfaça;
   - favorite e desfavorite um título; marque e desmarque "Recomendo";
   - edite o apelido e volte ao original;
   - nenhuma faixa "alteração recusada pelo servidor".
   - **Se algo falhar:** não continue. **Não volte as regras** sem falar com o Orquestrador. Registre a tela e a mensagem. As regras são aditivas e o `social_compat.test.mjs` prova que o app atual funciona com elas, então uma falha aqui é inesperada e vira incidente.

### (c) Índices
9. Console > **Firestore Database** > **Índices** > **Compostos** > **Criar índice**:
   - ID da coleção: `friend_requests`
   - Campo 1: `to`, **Crescente**
   - Campo 2: `createdAt`, **Decrescente**
   - Escopo da consulta: **Coleção** (não "Grupo de coleções")
   - **Criar**
10. Repita com o campo 1 `from` (**Crescente**) e o campo 2 `createdAt` (**Decrescente**), escopo **Coleção**.
11. Espere os **dois** com status **"Ativado"/"Enabled"** na lista de índices compostos. Com a coleção vazia leva poucos minutos. Enquanto mostrar "Criando…", **não avance**.
    - Alternativa por linha de comando (o `firebase-tools` já está em `firestore_rules_test/node_modules`): na raiz do repositório, `firestore_rules_test/node_modules/.bin/firebase login` e depois `firestore_rules_test/node_modules/.bin/firebase deploy --only firestore:indexes --project cinetrack-d9398`. Se ele perguntar se deve **apagar** índices ou overrides que não estão no arquivo, responda **não**. Prefira o console: é mais simples e não corre esse risco.

### (d) Merge e push (Orquestrador, só depois do OK do Manager nos passos 1 a 11)
12. O Orquestrador faz o fast-forward e o push, sem alterar nada:
    ```bash
    git fetch origin
    git rev-parse origin/main                      # tem de ser c60a3936d23d28f1e900e3daa4e39661645da9fe
    git switch main && git merge --ff-only feat/social-friends
    git rev-parse HEAD                             # b3d9610…
    git push origin main
    ```
    Se `origin/main` tiver mudado, pare: refaça o §1 sobre o novo topo antes de publicar.

### (e) Pipeline
13. GitHub > **Actions** > "Deploy to GitHub Pages" > run do commit `b3d9610` (ou `gh run watch`). Os jobs **build** e **deploy** têm de ficar verdes (≈ 3–6 min nos últimos runs).
    - **build** vermelho: nada foi publicado e o app atual continua no ar. Abra o log do passo que falhou e avise o Orquestrador. Não force nada.
    - **deploy** vermelho com build verde: re-execute só os jobs com falha (*Re-run failed jobs*). Se falhar de novo, é incidente do Pages, e o app anterior continua no ar.
14. Abra https://celsofabri.github.io/cinetrack/ numa **aba anônima** (o service worker do Flutter pode servir a versão antiga em abas já abertas; nas suas abas use Ctrl/Cmd+Shift+R). Em **Perfil** deve aparecer a seção "Amizades".

### (f) Smoke pós-deploy
15. Execute o **roteiro do docs/79 §3, passos 1 a 16**, com as contas A e B, marcando ✅/❌. Atenção especial (riscos residuais do QA, só verificáveis em produção):
    - passos 4 e 5: as listas Enviados e Recebidos carregam, o que prova os índices;
    - passo 2: ativar com apelido com acento e emoji (ex.: "José 🎬"), o que prova que o regex de `validName` roda em produção;
    - passos 6 e 7: foto do Google (`providerData`).
16. Só **depois de tudo ✅** divulgue o recurso.

---

## 5. Go/no-go e rollback

### Critérios de GO (antes do passo 12)
- regras publicadas sem erro, com data/hora conferida (passo 7);
- smoke do app atual ok (passo 8);
- 2 índices compostos "Enabled" (passo 11);
- `origin/main` = `c60a393` e a branch = `b3d9610`;
- dentro da janela (§3) e com ~1h30 livre para acompanhar.

Qualquer item faltando = **NO-GO**: o app atual segue no ar e nada se perde. Regras e índices novos podem ficar publicados indefinidamente sem o app novo; o app atual nunca usa as coleções sociais.

### Critérios de sucesso (depois do passo 15)
Todos os passos do docs/79 §3 ✅; dados da conta A iguais à linha de base; nenhuma faixa de erro de servidor no uso normal.

### Rollback: só do app, nunca das regras
**Nunca** republique as regras antigas: amizades, pedidos e handles já criados ficariam sem regra (`match /{document=**}` nega), e a exclusão de conta e a exportação não conseguiriam mais limpá-los. Correções de regra são só para frente. Índices também ficam (são inofensivos).

Rollback do app, do mais rápido ao definitivo:
1. **Rápido (≈ 3–5 min):** GitHub > Actions > run **37312280131** ("docs: mark ADR-005 as accepted", `c60a393`) > **Re-run all jobs**. Ele reconstrói e publica o app anterior. É temporário: o próximo push na `main` publica a `main` de novo. O re-run de um run antigo só é possível até 30 dias depois dele (até ~04/11).
2. **Definitivo:** reverter na `main` com um commit (sem reescrever histórico):
   ```bash
   git switch main && git pull --ff-only
   git revert --no-commit c60a393..b3d9610
   git commit -m "revert: roll back friendships phase 1 app (rules stay)"
   git push origin main        # o workflow publica o app anterior
   ```
   O CI roda analyze, test e build do código revertido antes de publicar.

**O que acontece com quem já ativou amizades no app novo, se voltarmos:** os documentos sociais continuam no Firestore e o app antigo os ignora. Nada de favoritos se perde. Mas no app antigo "Excluir conta" **não apaga** os dados sociais e a exportação não os inclui. Se o rollback durar mais que horas, liste no console as coleções `social`, `handles`, `friend_requests`, `friendships` e `invites` e trate com o Orquestrador antes de qualquer limpeza manual (que é ação em produção e precisa de aprovação do Manager).

### Se o smoke falhar em cada etapa
| Onde falhou | Ação |
|---|---|
| Passo 7: console recusa as regras | Nada publicado, nada muda. Pare e avise o Orquestrador (correção para frente). |
| Passo 8: app atual quebra com as regras novas | Pare. Não publique o app. Abra incidente (SEV2: favoritos afetados) com o Orquestrador. Não volte as regras por conta própria; a decisão é do Manager com o diagnóstico em mãos. |
| Passo 11: índice com erro ou parado em "Criando" por mais de ~30 min | NO-GO. Apague o índice com erro e crie de novo. Se persistir, avise o Orquestrador. |
| Passo 13: build vermelho | Nada publicado. Log para o Orquestrador. |
| Docs/79 §3 passo 1 (dados antigos diferentes, favoritos sumindo, erro ao marcar episódio) | **Rollback do app imediato** (re-run) e incidente SEV1/SEV2. Compare com o JSON do passo 1. |
| Passo 2 (ativar falha: "Amizades ainda não estão disponíveis") | Regras não propagaram ou não foram publicadas: confira a aba Regras. Se o `validName` recusar acento/emoji em produção: não divulgue, mantenha o app (é opt-in e nada se perde) e peça correção para frente das regras. |
| Passos 4 e 5 (Enviados/Recebidos com erro) | Índice faltando ou não "Enabled": confira o passo 11. O console costuma mostrar o link de criação no erro. Sem rollback se o resto funciona. |
| Passos 6 a 14 (falha funcional social) | Não divulgue. Registre e mande ao Orquestrador. Rollback do app só se afetar quem **não** usa amizades ou corromper dados. |
| Passo 15 (dados antigos não batem) | Rollback do app imediato + incidente. |
| Passo 16 (exclusão de B deixa resíduo) | Não divulgue. Mande ao Orquestrador (LGPD). |

---

## 6. O que monitorar na 1ª semana

Não há APM nem alertas neste projeto. A observabilidade é manual, pelo console. Sugestão: 1 olhada por dia, ~5 min, de 10/10 a 16/10.

1. **Console Firebase > Firestore Database > Uso** (leituras, gravações e exclusões por dia; cota Spark: 50 mil leituras, 20 mil gravações e 20 mil exclusões por dia):
   - anote o consumo de **hoje (antes do deploy)** como linha de base, porque o consumo atual nunca foi medido (docs/50 §9);
   - compare o aumento diário com a estimativa do docs/50 §9: ≈ 90 leituras por usuário social ativo por dia (≈ 9 mil/dia com 100 usuários = 18% da cota);
   - **gatilho de atenção:** leituras diárias acima de **60% da cota (30 mil)** em qualquer dia, ou crescimento muito acima de ~90 × usuários sociais. Ação: avisar o Orquestrador para revisar TTLs e caches. **Não** ativar o Blaze (decisão do ADR-003).
2. **Faixas de erro no app:** "limite diário gratuito atingido" (cota estourada) e "alteração recusada pelo servidor" (regra negando um fluxo legítimo). Qualquer relato de usuário = registrar e mandar ao Orquestrador.
3. **Console > Firestore > Regras > Monitor de regras** (*Rules monitor*), se disponível no plano: avaliações "Deny" fora do normal após o deploy.
4. **Console > Firestore > Índices:** os 2 compostos continuam "Enabled".
5. **GitHub > Actions:** nenhum push novo na `main` sem passar pelo fluxo de gates nesta semana.
6. **Dia 7:** registre leituras, gravações e exclusões por dia e o número de documentos em `social` (usuários que ativaram) para fechar a estimativa do docs/50 §9 com dados reais.

---

## 7. Bloqueios e observações para o go/no-go

- **Bloqueios técnicos: nenhum.** O pipeline passa na branch, o `firebase_options` real está presente e não há secret nem configuração de CI nova.
- **Dependências manuais do Manager** (fora do alcance do CI): Authentication só Google, regras, 2 índices "Enabled", conta Google de teste B.
- **Janela:** hoje é sexta-feira. Recomendo de terça a quinta, das 9h às 11h.
- **Não verificado (só o smoke em produção prova):** o regex de `validName` aceito pelo console de produção, a criação dos índices, a cobrança de leituras de regra e o `providerData` do Google (riscos residuais do docs/79).
