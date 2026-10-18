# 89 - Release: Perfil social, Fase 2

> Autor: SRE/DevOps · Data: 2026-10-18 · Branch `feat/social-profile`, candidato a release em `aac57b5` (mais este documento), fast-forward sobre `origin/main` `9c57327` (Fase 1 em produção; último deploy verde: run `38008891641`, 2026-10-10).
> Entradas: regras e índice já publicados ([docs/84](./84-fatia0-regras-perfil-social.md), fechamento), fundação e `epsAt` ([docs/85](./85-fatia1-fundacao-perfil-social.md), "Checklist de release (Fase 2)"), Meu perfil ([docs/86](./86-fatia2-meu-perfil-social.md)), perfil de amigo ([docs/87](./87-fatia3-perfil-de-amigo.md)), Recomendados ([docs/88](./88-fatia4-recomendados.md), "Checklist de release (Fase 2, Fatia 4)"), cota e rollout ([docs/82 §11, §12, §14](./82-design-perfil-social.md)), smoke base ([docs/83 §5](./83-testabilidade-perfil-social.md)). Modelo: [docs/80](./80-release-fase-1.md).
> Somente leitura: nenhum merge, push, deploy de regras/índices ou deploy do app foi feito.

---

## 1. O que muda em produção nesta release

| Item | Situação | Ação nesta release |
|---|---|---|
| `firestore.rules` (468 linhas, sha256 `6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612`) | **Já publicado** pelo Orquestrador em 2026-10-10 (docs/84) | **Nenhuma.** Só conferir (§3, passo 3). |
| `firestore.indexes.json` (2 compostos da Fase 1 + isenção `favorites.epsAt`) | **Já publicado** em 2026-10-10 (docs/85) | **Nenhuma.** Só conferir (§3, passo 4). |
| App Flutter web (Fatias 1 a 4: `epsAt`, "O que seus amigos veem", perfil de amigo, Recomendados) | Na branch | Merge fast-forward na `main` = deploy no Pages. |
| `web/privacidade.html` ("Última atualização: 18/10/2026") | Na branch | Vai **junto** com o app (mesmo deploy). Se o release não for em 18/10/2026, corrigir a data no commit de release (§4, passo 8). |
| `.github/workflows/deploy-pages.yml` | Única mudança: `env: TZ: America/Sao_Paulo` no passo **Test** (docs/85, rodada 3) | Roda pela primeira vez no CI no push de release (§4, passo 11). |

Conferido em `aac57b5` (somente leitura):
- `git merge-base --is-ancestor origin/main aac57b5`: **sim** (fast-forward possível; 42 commits, 120 arquivos).
- `shasum -a 256 firestore.rules` = `6135322e…e612`, o mesmo do docs/84. O `firestore.rules` da `origin/main` ainda é o da Fase 1 (`7cf76481…f0f3`): é esperado, o repositório só alcança o que já está publicado quando o merge acontecer.
- Sem secret novo: o diff não toca `pubspec.yaml`/`pubspec.lock` (nenhuma dependência nova), `firebase.json`, `.gitignore` nem `lib/firebase_options.dart`; nenhum `String.fromEnvironment` novo; nenhum padrão de chave (`AIza…`, `ghp_…`, `sk-…`) nas linhas adicionadas. O único secret do CI continua sendo `TMDB_API_KEY`.
- **CI não roda na branch**: o workflow só dispara em push na `main` e por `workflow_dispatch`, e o ambiente `github-pages` só aceita a `main`. Não há run para `aac57b5` (a `origin/feat/social-profile` está em `4aeb4bd`, desatualizada). "CI verde na branch" é, portanto, a reprodução local dos passos do workflow (§3, passo 5). Não use `workflow_dispatch` na branch: o job de deploy seria recusado pelo ambiente e deixaria um run vermelho sem ganho.

---

## 2. Checklist de release

```markdown
## Release: CineTrack web — Perfil social Fase 2 (aac57b5 + docs/89 [+ data da política])
- [ ] QA: aprovado em todas as fatias (docs/84–88) e no reteste final do Orquestrador
- [ ] Code review: aprovado em todas as fatias
- [ ] Regras em produção = firestore.rules do repositório (sha 6135322e…e612) — §3 passo 3 (se diferir: PARE)
- [ ] Índices em produção = firestore.indexes.json (2 compostos + isenção favorites.epsAt) — §3 passo 4
- [ ] Pipeline local no candidato: analyze 0 issues · test (TZ=America/Sao_Paulo e TZ=UTC) · build web · npm test — §3 passo 5
- [ ] Diff do candidato contra aac57b5 = só docs/89 (+ 1 linha de data da política) — §3 passo 6
- [x] Migrações: nenhuma nesta release (regras e índice já publicados em 2026-10-10, antes do app, como manda o docs/82 §12)
- [x] Feature flag: não há; tudo é opt-in por usuário e desligado por padrão (D2). Quem não liga nada não grava nada novo além de epsAt nas próprias marcações
- [ ] Política: web/privacidade.html sai no MESMO deploy, com a data do dia do release
- [ ] Janela: terça a quinta, 9h–11h (Brasília); hoje (18/10) é domingo — não publicar hoje
- [x] Canary: não se aplica (Pages é tudo ou nada). Substituto: smoke completo com 2 contas antes de divulgar
- [x] Rollback: só do app, e com consulta ao Manager se alguém já ligou compartilhamento (§6); regras nunca voltam
- [ ] Monitoramento: Firestore > Uso + faixas de erro + sonda epsAt na 1ª semana (§5)
- [ ] Comunicação: divulgar só depois do smoke 100% ✅
```

**Janela recomendada:** terça 20/10 a quinta 22/10, entre **9h e 11h (Brasília)**, pelos mesmos motivos do docs/80 §3 (uso de noite e no fim de semana; a cota do Spark zera ≈ 4h–5h de Brasília, então de manhã sobra o dia inteiro para o smoke, que inclui uma marcação em massa). Reserve ~2h: ~15 min de verificação, ~5 min de pipeline e ~1h30 de smoke (este é maior que o da Fase 1).

**Pré-requisitos:** acesso de dono ao console do Firebase (`cinetrack-d9398`) e ao repositório; conta **A** (a do Manager, com favoritos) e a conta Google de teste **B**, já amigas desde a Fase 1 (se não forem, o smoke começa por fazer a amizade); um navegador com DevTools (modo offline); um leitor de tela (VoiceOver ou NVDA).

---

## 3. Verificação pré-deploy (Orquestrador + Manager; qualquer item falho = NO-GO)

### (a) Linha de base
1. **Manager**, no app **atual** com a conta A: Perfil > "Seus dados" > **Exportar meus dados**. Guarde o JSON fora do navegador. Anote os números do Perfil (filmes, séries, episódios, assistidos, recomendados) e quantos amigos A tem.
2. Console Firebase > **Firestore Database** > **Uso**: anote leituras, gravações e exclusões de **ontem** e dos últimos 7 dias. É a linha de base para o §5 (a Fase 1 nunca teve consumo medido antes; agora há uma semana de dados).

### (b) Regras: produção tem de ser byte a byte o arquivo do repositório
3. Console > **Firestore Database** > **Regras**:
   - a publicação vigente tem de ser a de **2026-10-10** (aba de histórico do editor). Se houver publicação **posterior**, PARE e avise o Orquestrador: alguém mexeu nas regras fora do processo;
   - copie o conteúdo inteiro do editor para `/tmp/prod.rules` (no Mac: selecione tudo no editor, copie e rode `pbpaste > /tmp/prod.rules`) e compare:
     ```bash
     cd /Users/celsofabrijr/Documents/projects/cinetrack-profile
     shasum -a 256 firestore.rules     # 6135322e766b37f8f5c8a6057ff9863a54dcda5b6a2e1fb554f2f1f91300e612
     shasum -a 256 /tmp/prod.rules
     diff /tmp/prod.rules firestore.rules && echo IGUAL
     ```
     A cópia pelo navegador pode perder só a quebra de linha final; nesse caso o `diff` mostra apenas `\ No newline at end of file` e vale como igual. **Qualquer outra diferença = PARE.** Não publique regras para "acertar": a decisão é do Orquestrador com o Manager, e regras nunca voltam (§6). Sinais rápidos de que é a versão certa: 468 linhas, `match /shared_profiles/{uid}` presente e `'epsAt'` no `hasOnly` de `validFavorite`.
   - **Nunca** use `firebase deploy` como forma de conferir: ele publica.
   - Por que é bloqueante: se produção estiver com as regras da Fase 1 (`7cf76481…`), o app novo funciona (a sonda vê `permission-denied` e marca sem data), mas os interruptores ficam "ainda não disponível" e o smoke inteiro da Fase 2 é inválido; e se alguém republicar regras antigas **depois** que aparelhos já confirmaram a sonda, entra o risco da fila offline do docs/85 ("Risco da autocorreção").

### (c) Índices: produção = `firestore.indexes.json`
4. Conferir que produção tem exatamente: compostos `friend_requests` (`to` ASC, `createdAt` DESC) e (`from` ASC, `createdAt` DESC), escopo **Coleção**, ambos **Ativado/Enabled**; e a isenção de campo único `favorites.epsAt` sem índices.
   - **Console:** Firestore > **Índices** > **Compostos** (os 2, "Ativado") e > **Campo único** / *Isenções* (`favorites` · `epsAt` · todos os índices desativados). Na mesma aba, confirme que **não** há isenção para `to`, `from`, `members` ou `createdAt` (as consultas da Fase 1 dependem dos automáticos).
   - **Ou pela CLI, somente leitura** (lista o que está publicado no formato do arquivo; não publica nada):
     ```bash
     cd /Users/celsofabrijr/Documents/projects/cinetrack-profile
     firestore_rules_test/node_modules/.bin/firebase firestore:indexes --project cinetrack-d9398 > /tmp/prod.indexes.json
     ```
     e compare com `firestore.indexes.json` (a ordem dos campos pode diferir; o conteúdo, não). Se a CLI pedir login, o token fica no `~/.config`; não cole tokens em lugar nenhum.
   - Índice faltando ou diferente: NO-GO e avise o Orquestrador. **Não** rode `firebase deploy --only firestore:indexes` por conta própria; se o Orquestrador decidir publicar, nunca com `--force` e respondendo **não** a qualquer pergunta de apagar índices (docs/84).
   - Authentication > Método de login: continua **só Google** (as regras exigem `google.com` para criar `shared_profiles`).

### (d) Pipeline no candidato (Orquestrador, local, mesma versão do workflow: Flutter 3.47.5 stable)
5. No worktree, no HEAD do candidato, rode os passos do workflow e registre os números neste documento antes do merge:
   ```bash
   cd /Users/celsofabrijr/Documents/projects/cinetrack-profile
   grep -c PLACEHOLDER lib/firebase_options.dart        # 0
   flutter pub get
   flutter analyze                                      # No issues found
   TZ=America/Sao_Paulo flutter test                    # o mesmo fuso do CI novo; esperado 1981/1981 (docs/88 rodada 2)
   TZ=UTC flutter test                                  # o fuso do CI antigo; 1981/1981
   (cd firestore_rules_test && npm test)                # regras: 518 pass, 0 fail, 0 todo (docs/85)
   flutter build web --release --base-href "/cinetrack/" --dart-define=TMDB_API_KEY=<do .env, sem imprimir>
   grep -c "18/10/2026" build/web/privacidade.html      # 1 (ou a data do release, §4 passo 8)
   ```
   Qualquer vermelho = NO-GO.
6. O candidato só pode diferir de `aac57b5` (o que os gates aprovaram) por documentação e pela data da política:
   ```bash
   git diff --stat aac57b5..HEAD     # só docs/89-… (e web/privacidade.html, 1 linha, se a data mudou)
   ```

### (e) Critérios de GO (todos)
- regras de produção = repositório (passo 3) e índices = arquivo (passo 4);
- pipeline local verde no candidato (passo 5) e diff mínimo (passo 6);
- `origin/main` = `9c5732715c2e6d032c96250641f29c5a76a95703` (se mudou, refaça o §3 sobre o novo topo);
- dentro da janela, com ~2h livres, conta B disponível;
- Manager deu OK explícito.

NO-GO não custa nada: o app da Fase 1 segue no ar e convive com as regras e o índice novos indefinidamente (`social_compat.test.mjs`).

---

## 4. Deploy do app (na ordem)

### (a) Data da política
7. Abra `web/privacidade.html` e confira a linha `Última atualização: 18/10/2026.`
8. **Se o release não for em 18/10/2026** (o recomendado é 20 a 22/10): o Orquestrador troca só essa data pela do dia, num commit próprio na `feat/social-profile` (ex.: `chore(policy): set release date of the privacy policy`), refaz o passo 5 (build e `grep` da data) e o passo 6. Nenhum teste depende da data (conferido: `test/`, `lib/` e `firestore_rules_test/` não a citam). A política **nunca** sai antes nem depois do app: ela descreve o compartilhamento de recomendados e a data das marcações, que só existem no app novo, e o texto antigo dizia que recomendações não eram compartilhadas (docs/85, 86, 88).

### (b) Merge fast-forward e push (Orquestrador, só depois do GO)
9. A `main` está no checkout principal (`/Users/celsofabrijr/Documents/projects/cinetrack`, hoje desatualizado em `c60a393`). Fast-forward **somente**:
   ```bash
   cd /Users/celsofabrijr/Documents/projects/cinetrack
   git fetch origin
   git rev-parse origin/main                    # 9c5732715c2e6d032c96250641f29c5a76a95703
   git switch main && git pull --ff-only        # main -> 9c57327
   git merge --ff-only feat/social-profile      # recusa se não for fast-forward
   git rev-parse HEAD                           # = HEAD do candidato no worktree cinetrack-profile
   git push origin main                         # o push também recusa não fast-forward
   ```
   Se qualquer `--ff-only` recusar: pare. Nada de merge commit, rebase ou `--force`.
10. Opcional, para registro: `git push origin feat/social-profile` (a remota está em `4aeb4bd`). Não dispara deploy.

### (c) Pipeline
11. GitHub > **Actions** > "Deploy to GitHub Pages" > run do commit de release (`gh run watch`). **build** e **deploy** verdes (≈ 3–6 min). Pontos de atenção:
    - o passo **Test** agora roda com `TZ: America/Sao_Paulo`; confira no log do passo que a variável aparece (`env: TZ: America/Sao_Paulo`) e que o total é o mesmo do passo 5;
    - **build vermelho** (inclusive se o Test falhar só por fuso no runner): nada foi publicado, a Fase 1 continua no ar. Log para o Orquestrador; correção para frente, nunca tirar o `TZ` para "passar";
    - **deploy vermelho com build verde**: *Re-run failed jobs*. Se repetir, é incidente do Pages; o app anterior continua no ar.
12. Abra https://celsofabri.github.io/cinetrack/ numa **aba anônima** (o service worker pode servir a versão antiga em abas abertas; nas suas, Ctrl/Cmd+Shift+R). Perfil > deve aparecer "O que seus amigos veem" com **3 interruptores desligados** (Estatísticas, Atividades recentes, Recomendados).
13. Abra https://celsofabri.github.io/cinetrack/privacidade.html (aba anônima): "Última atualização" = **a data do release**, item "O que seus amigos veem" com Recomendados e o parágrafo novo de "Minhas recomendações". Data antiga ou texto antigo = cache: recarregue sem cache; se persistir, o deploy não levou a política e isso é NO-GO para divulgar (o app pode ficar, porque tudo é opt-in, mas ninguém deve ser convidado a ligar nada até a política estar no ar).

### (d) Smoke
14. Executar o **Smoke manual (Manager)** do §8, com A e B. Só divulgar depois de 100% ✅.

---

## 5. Pós-deploy e monitoramento (1ª semana: D0 a D+6, ~5 min por dia)

Não há APM nem alertas; observabilidade manual pelo console, como na Fase 1.

### 5.1 Firestore > Uso (cota Spark: 50 mil leituras, 20 mil gravações, 20 mil exclusões por dia)
Estimativas da Fase 2 (docs/82 §11, para 100 usuários sociais ativos, 30% compartilhando, 20 marcações/dia, 5 perfis abertos/dia, 3 sessões/dia), com os acréscimos das fatias:

| Origem | Leituras | Gravações |
|---|---|---|
| Fase 1 (docs/50 §9) | ≈ 9 000/dia | — |
| Perfis de amigo: 2 cobradas a frio pela lista (`get` + `isFriend`), **3** por endereço sem lista, **1** para não amigo por endereço, 0 no TTL de 5 min (docs/87) | ≈ 1 000/dia | 0 |
| Estado do dono por sessão (com amizades) / sonda `epsAt` (sem amizades: 1 por aparelho, uma vez) | ≈ 300/dia | 0 |
| Ligar uma seção: transação + **releitura** = 2 leituras + 1 de regra (docs/86 desvio, docs/88) | raro | 1 |
| Motor de quem compartilha: ≤ 1 gravação coalescida por 5 s (máx. 2/min contínuo) + pulso ≤ 1/dia; dois aparelhos na mesma janela: ≤ 1 gravação extra (docs/86) | 0 | ≈ 270/dia |
| Marcação de quem não compartilha | 0 | **0 a mais** (`epsAt` vai no mesmo `update`) |
| **Total estimado** | **≈ 10,3 mil/dia (≈ 21%)** | **≈ 1,4% + a Fase 1** |

Ação diária: anotar leituras/gravações/exclusões e comparar com a linha de base (§3 passo 2) e com a tabela.
- **Gatilho de atenção:** qualquer dia acima de **60%** de uma cota (30 mil leituras, 12 mil gravações ou 12 mil exclusões), ou crescimento de gravações muito acima de ≈ 9 por usuário que compartilha. Ação: avisar o Orquestrador (rever coalescência, TTL e sonda). **Não** ativar o Blaze (ADR-003).
- Gravações subindo **sem** ninguém compartilhar = suspeita de motor gravando para quem não ligou (não deveria: 0 escritas sem interruptor). Incidente para o Orquestrador.
- Dia de pico esperado: D0 (smoke com marcação em massa de ≥ 1000 episódios = 1 `update` grande, mas o recálculo e as releituras somam).
- **D+6:** registrar os 7 dias e o número de documentos em `shared_profiles` (quantos ligaram algo) para fechar a estimativa do docs/82 §11 com dados reais.

### 5.2 Faixas de erro e relatos de usuários
Qualquer relato de uma destas mensagens = registrar (tela, hora, conta, o que fez) e mandar ao Orquestrador:
- "O servidor recusou uma alteração e ela não foi salva…" (banner dos favoritos): regra negando um fluxo legítimo. Na Fase 2 o caso crítico é marcação com data recusada (deveria se autocorrigir em silêncio, docs/85); se aparecer em marcação comum, trate como possível regressão de regras e confira a aba Regras (§3 passo 3) **sem republicar nada**.
- "O limite diário gratuito do serviço foi atingido…": cota estourada; cruzar com o §5.1.
- "Não conseguimos confirmar suas últimas alterações…" persistente: fila do SDK presa.
- "O perfil compartilhado ainda não está disponível." ao ligar um interruptor: em produção, com as regras certas, **não deveria acontecer**. Se acontecer, a sonda/regra está negando: confira as regras e mande ao Orquestrador.
- "Ainda não confirmado…" que não se resolve: interruptor incerto sem reconciliação (risco do §7).

### 5.3 Comportamento da sonda `epsAt`
O app só manda datas depois de **ver** regras que as aceitam (`SharedRulesGate`): 1 sonda por sessão até confirmar, depois guarda a confirmação no aparelho. Em produção, com as regras de 2026-10-10, o esperado é `ready` na primeira sessão de cada aparelho.
- **Como conferir (D0, no smoke, e uma vez no D+1):** com a conta A, marque um episódio hoje; Perfil > "O que seus amigos veem" > prévia (com Estatísticas ligado) > "Este mês" conta esse episódio. No console > Firestore > Dados > `users/{uid de A}/favorites/{a série}`: o campo `epsAt` existe e tem a chave do episódio com o instante da marcação.
- **Sinal de problema:** marcações novas sem `epsAt` (a sonda viu regras antigas ou a recusa da data fechou o portão), ou "Este mês" sem as marcações de hoje com a nota "Marcações anteriores a esta versão contam só no total." para marcações feitas **depois** do deploy. Nada se perde (a marcação grava sem data e conta no total), mas é sinal de regra divergente: confira o §3 passo 3 e avise o Orquestrador.
- Custo: leituras de sonda acima de ≈ 1 por aparelho por dia indicam que o portão não está guardando a confirmação.

### 5.4 Outros
- Firestore > Índices: os 2 compostos continuam "Ativado" e a isenção `epsAt` continua lá.
- Firestore > Regras: nenhuma publicação nova na semana.
- GitHub > Actions: nenhum push na `main` fora do fluxo de gates.

---

## 6. Rollback

### Regras e índice: NUNCA voltam
As regras de 2026-10-10 ficam, aconteça o que acontecer com o app. Voltar para as da Fase 1 (`7cf76481…`) faria as regras negarem **toda** marcação de episódio que leve `epsAt` (o `update` inteiro é recusado) e deixaria `shared_profiles` sem regra (nem o dono apagaria a própria cópia). Com a persistência offline ligada, marcações com data ainda na fila seriam reenviadas pelo SDK na sessão seguinte sem a autocorreção e **se perderiam** (docs/85, "Risco da autocorreção"). Correção de regra é só para frente, por gate. A isenção `favorites.epsAt` é inofensiva e fica.

### App: possível, mas perigoso depois que alguém ligar o compartilhamento
O app da Fase 1 (`9c57327`) **não sabe desligar** Estatísticas, Atividades recentes nem Recomendados (não tem os interruptores). Quem tiver ligado algo fica com `shared_profiles/{uid}` publicado e **sem como revogar o consentimento** pelo app enquanto o rollback durar (docs/86, docs/88, docs/82 §14 risco 12). Por isso:

1. **Antes de qualquer rollback do app, consultar o Manager.** É decisão dele, não do SRE nem do Orquestrador sozinhos. A exceção é dano a quem **não** usa o social (favoritos sumindo, marcação de episódio quebrada para todos): aí o rollback rápido pode ser feito na hora e o Manager é avisado em seguida.
2. Levantar no console quantos documentos existem em `shared_profiles`:
   - **0 documentos:** rollback tão seguro quanto o da Fase 1.
   - **> 0:** o rollback mantém o conteúdo publicado sem botão de desligar. Preferir **corrigir para frente**. Se o rollback for inevitável, remédios (registrar quem e quando):
     - durante o rollback ninguém vê esse conteúdo pelo app oficial (a versão anterior não tem a tela de perfil de amigo nem lê `recs`); o risco é de consentimento (o dono não consegue desligar), não de exibição;
     - o dono pode **desativar as amizades** na versão anterior: a amizade some e a leitura exige `isFriend`, então ninguém mais lê; o documento fica órfão (a versão anterior não o apaga);
     - a pedido do dono, apagar `shared_profiles/{uid}` pelo console: é ação em produção e precisa de aprovação do Manager. **Não perde dado nenhum**: o documento é uma cópia derivada dos favoritos e é recalculado pela versão nova quando o dono religar;
     - ao voltar para a versão nova, o dono desliga ou o documento é apagado pela desativação/exclusão de conta da versão nova.
3. Procedimento, do mais rápido ao definitivo (como no docs/80 §5):
   - **Rápido (≈ 3–5 min):** Actions > run **38008891641** (`9c57327`, 2026-10-10) > **Re-run all jobs**. Temporário (o próximo push na `main` republica a `main`); possível só até 30 dias depois do run (até ~09/11/2026).
   - **Definitivo:** `git revert` do intervalo na `main` com um commit (sem reescrever histórico), push, CI roda analyze/test/build antes de publicar. **Não reverter** `firestore.rules` nem `firestore.indexes.json` no revert (reverter o arquivo não publica nada, mas deixaria o repositório mentindo sobre produção e convidaria um deploy errado): `git revert --no-commit 9c57327..<release>` e depois `git checkout <release> -- firestore.rules firestore.indexes.json` antes do commit.
   - A política: no rollback, `privacidade.html` volta à versão anterior junto com o app, o que é coerente (o app anterior não compartilha nada novo).

### Garantias de dados no rollback
- **Favoritos e marcações (`eps`) nunca se perdem**: o app anterior ignora `epsAt` e `shared_profiles` (mapper antigo ignora campo desconhecido; `eps` intocado; testado em `social_compat` e no docs/85).
- O que se perde é só **data** de marcação: o que for marcado na versão anterior fica sem `epsAt` e conta "só no total"; ao desmarcar na versão anterior a data fica órfã e a versão nova a limpa (docs/85).
- A exclusão de conta da versão anterior **não apaga** `shared_profiles/{uid}` (órfão não exposto: sem amizades ninguém lê) e a exportação da versão anterior não o inclui. Se o rollback durar mais que horas, listar os órfãos e tratar com o Orquestrador antes de qualquer limpeza manual.
- Nada exige restaurar backup; o JSON do §3 passo 1 é só para comparação.

### Se o smoke falhar
| Onde falhou | Ação |
|---|---|
| §3 passo 3/4: regras ou índices divergentes | NO-GO. Nada é publicado. Orquestrador decide com o Manager; nunca "republicar para acertar" sem gate. |
| §4 passo 11: build vermelho | Nada publicado. Log para o Orquestrador. |
| §4 passo 13: política antiga no ar | Não divulgar; ninguém liga nada até a política estar no ar. Corrigir para frente (o app pode ficar). |
| Dados antigos de A diferentes da linha de base, favoritos sumindo, marcação/desmarcação de episódio falhando | **Rollback rápido imediato** (é dano a quem não usa o social) + incidente SEV1/SEV2; Manager avisado na hora. Compare com o JSON. |
| Marcação em massa de série longa (≥ 1000 episódios) recusada ou incompleta | Não divulgar. Incidente SEV2 para o Orquestrador. Rollback só com o Manager (a versão anterior marca a série inteira, mas sem datas); preferir correção para frente. |
| Interruptor não liga ("ainda não está disponível") | Regras: confira o §3 passo 3. Sem rollback (nada foi compartilhado). |
| Falha funcional social (perfil de amigo, recomendados, prévia, offline, leitor de tela) | Não divulgar. Registrar e mandar ao Orquestrador. Rollback só se afetar quem não usa o social ou corromper dados, e com o Manager se já houver `shared_profiles`. |
| Exclusão de conta de B deixa `shared_profiles/{uid de B}` | Não divulgar (LGPD). Orquestrador. |

---

## 7. Riscos aceitos e o que o smoke cobre

| Risco | Origem | Residual aceito | Coberto no smoke por |
|---|---|---|---|
| **D12** números falsos: um cliente modificado do dono publica números plausíveis inventados; as regras só checam forma, ≥ 0 no ranking, formatos, hora do servidor, `tz`, tamanho de listas, seção ⇔ consentimento | docs/81, ADR-006, docs/82 §14 r1 | Aceito pelo Manager (2026-10-10). Remédio: remover/bloquear. (Junto: **D16**, título arbitrário em recomendados/atividades; o leitor mostra só texto, limita a 50 e descarta pôster fora do formato) | Coerência no app oficial: prévia de A = números do Perfil de A, e o que B vê de A = a prévia de A. Não é testável em produção sem cliente modificado (coberto por testes de regra e do leitor tolerante). |
| **D15** ex-amigo que reabre o perfil em até 5 min, sem "Atualizar", revê o que já viu; cópia no cache persistente do SDK do leitor nunca exibida | docs/81 RF-F7, docs/87 | Aceito pelo Manager (2026-10-10) | Remover/bloquear pelo perfil e reabrir: com "Atualizar" ou depois de 5 min = mensagem neutra; reabrir no TTL = 0 leituras no console. |
| **Interruptor incerto**: timeout de 10 s ou `unavailable` depois de aplicar = "Ainda não confirmado…"; reconcilia depois; aviso que chega com o Perfil fechado não é mostrado (o estado do interruptor é sempre o real) | docs/86 decisão 3 e Riscos | Aceito (o estado mostrado é o do servidor; outro toque bloqueado enquanto incerto) | Ligar/desligar com a rede lenta ou caindo (DevTools: "Slow 3G"/offline no meio): o interruptor termina no estado real do servidor (conferir no console e pela visão de B). |
| **Fila offline + regressão de regras**: marcações com data na fila, se as regras regredirem, podem remarcar um episódio desmarcado depois ou **perder a marcação** quando o SDK reenvia na sessão seguinte sem a autocorreção | docs/85 "Risco da autocorreção" | Aceito **porque depende de regressão de regras**, que este processo proíbe | Não se testa provocando a regressão. A proteção é o §3 passo 3 (sha conferido antes) e o §6 (regras nunca voltam). O smoke cobre o caminho normal: marcar offline, reconectar, a marcação e a data gravam. |
| **Não verificado em produção: série grande (≥ 1000 episódios)** marcada em massa = 1 `update` com até 5000 `eps.*` + 5000 `epsAt.*`; o emulador só provou 24 + 24 | docs/85 Suposições e Checklist | Desconhecido até o smoke | Marcar a série inteira de uma série com ≥ 1000 episódios na conta **B** (ex.: uma série longa de anime), conferir no console que `eps` e `epsAt` têm todas as entradas, e desfazer. |
| **Não verificado: `Source.server` offline** falha em vez de cair no cache; `isFromCache` falso na resposta do servidor | docs/85, docs/87 Suposições | Desconhecido até o smoke | Perfil de amigo com DevTools offline: nenhum conteúdo compartilhado, "Sem conexão…", "Atualizar"/ações desabilitados; ao reconectar carrega sozinho. |
| **Não verificado: ciclo de vida `hidden`/`paused`** no navegador (o motor grava ao esconder a aba; sem o evento, grava no fim da janela de 5 s se a página continuar viva) | docs/86 Suposições | Sem perda de dado: o snapshot é derivado e é recalculado na próxima sessão; pior caso é ficar velho até A abrir o app | Com Estatísticas ligado em A, marcar um episódio e trocar de aba/fechar em menos de 5 s; em B, "Atualizar" no perfil de A mostra o número novo. |
| Divergência emulador × produção (limites de chamadas/expressões, `affectedKeys`, `request.time`) | docs/82 §14 r10 | — | O smoke inteiro (ligar cada seção, mudar consentimento, recálculo) e o console de uso (cobrança real: ≤ 2 a frio, 0 no TTL). |
| Rollback deixa conteúdo publicado sem botão de desligar | docs/82 §14 r12, docs/86, docs/88 | Tratado pela política do §6 | — |
| App antigo em outra aba (marca sem data; desmarca deixando órfã) | docs/85, docs/82 §14 r11 | Datas faltando; a versão nova limpa as órfãs | Aba antiga aberta durante o deploy: marcar nela e conferir que a aba nova (recarregada) mostra a marcação. |

---

## 8. Smoke manual (Manager)

> **Seção reservada.** O roteiro definitivo é o do QA (base: [docs/83 §5](./83-testabilidade-perfil-social.md), ampliado pelos riscos das Fatias 1 a 4) e será **inserido aqui pelo Orquestrador** antes do go/no-go. Até lá, este documento não está completo para o release.
>
> O roteiro inserido precisa cobrir, no mínimo, o que o §7 (coluna "Coberto no smoke por") e o §5.3 pedem: linha de base de A intacta; sonda `epsAt` (`epsAt` no console e "Este mês" na prévia); ligar/desligar cada seção com os textos literais, inclusive incerto/offline; perfil de amigo pela lista e por endereço, TTL com 0 leituras no console, offline real, remover/bloquear pelo perfil; Recomendados (prévia, 50/"e mais N", desligar não desmarca nada); marcação em massa de série com ≥ 1000 episódios na conta B; fechar a aba em menos de 5 s; política no ar com a data do release; leitor de tela real; exclusão de conta de B sem resíduo em `shared_profiles`. Marcar cada passo ✅/❌ e só divulgar com 100% ✅.
