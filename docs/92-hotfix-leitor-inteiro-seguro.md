# 92 - Hotfix A2: leitor de inteiro seguro (perfil de amigo, Fase 2)

> Autor: Dev · Data: 2026-10-18 · Branch: `fix/safe-int-readers` (base `827cec5`, produção)
> Entradas: docs/91 §5.1–5.2 (design do ranking, Fase 3: spike A2 do Arquiteto e hotfix proposto; o arquivo está na branch da Fase 3, ainda não na `main`), [docs/82](./82-design-perfil-social.md) §4.4 (tabela de tetos), [docs/85](./85-fatia1-fundacao-perfil-social.md), [docs/87](./87-fatia3-perfil-de-amigo.md), [docs/88](./88-fatia4-recomendados.md) (leitores).
> **`firestore.rules` não foi alterado** (sha256 `6135322e…e612`, o publicado). Nenhum dado muda. Nada publicado: sem push, sem deploy.

## HANDOFF
De: Dev → Para: Code Reviewer e QA, depois Orquestrador (SRE: passo novo da CI)
Demanda: Hotfix A2: números de amigo absurdos ou que quebram a seção de estatísticas no web
Fluxo: hotfix | Etapa: implementação
Prioridade: P3 (severidade baixa, docs/91 §5.1)

### Problema (resumo do docs/91 §5.1)
Em produção (dart2js) todo número JS inteiro "é `int`", inclusive `Infinity` e `1e300`. Os leitores do lado do amigo (`readCount`, itens de atividade e de recomendados) usavam `v is int`, então um amigo mútuo que grava o próprio documento por fora do app (as regras aceitam, D12) conseguia: `WatchTimeFormatter.format(Infinity)` ⇒ `UnsupportedError` ⇒ a seção de estatísticas do perfil dele virava o `ErrorWidget` para os amigos; contagens "Infinity"; links `/tv/Infinity`; textos absurdos com `1e300`. `12.0` era 12 no web e "—" na VM (inconsistente). A CI só rodava na VM, por isso nenhum teste pegou.

### O que foi feito
**Leitor único** `readSafeInt(v, {min = 0, max = 2^53 − 1})` (`lib/shared_profile/safe_int.dart`)
- Aceita `int` e `double` finito sem parte fracionária dentro de `[min, max]`; recusa NaN, ±Infinity, fração, fora da faixa, não número. Nunca lança. `-0.0` lê como `0` comum nas duas plataformas (no web `-0.0` "é int", mas o `toInt` do dart2js já devolve 0; conferido no Chrome).
- Diferença para o esboço do docs/91 §5.2: os limites são checados **antes** de qualquer outra coisa, e o `isFinite` explícito e a normalização `n == 0 ? 0 : n` saíram. Motivo: com limites sempre finitos ele é redundante (±Infinity cai no limite; NaN cai no teste de fração, `NaN != NaN`), e checar antes do `toInt` evita que a VM "sature" um `1e300` para 2^63 − 1. A normalização de `-0` sobreviveu como mutação também no Chrome (1ª rodada, A5): é redundante, porque o `toInt` do dart2js (`| 0`) já devolve 0; saiu, e o teste de `-0.0` (valor 0, não negativo, texto "0") continua verde nas duas plataformas. Com isso toda condição do leitor é necessária.

**Aplicado em todos os leitores do lado do amigo da Fase 2**, com os tetos da tabela docs/82 §4.4 (o app oficial nunca grava acima: o validador limita antes de gravar):
| Leitor | Campo | Faixa aceita | Fora da faixa |
|---|---|---|---|
| `SharedStatsReading.read` / `PeriodReading.read` | `favorites`, `movies`, `series`, `watchedMovies`, `watchedSeries`, `completedSeries` (total, ano, mês) | 0..100 000 | "—" |
| idem | `watchedEpisodes` (total, ano, mês) | 0..1 000 000 | "—" |
| idem | `minutes` (total, ano, mês) | 0..52 560 000 | "—" |
| idem | `undatedMovies` / `undatedEpisodes` | 0..100 000 / 0..1 000 000 | 0 (nota não aparece, como hoje) |
| `SharedRecsReading.read` | `count` | 0..100 000 | "Recomendações: —", sem "e mais" |
| `SharedRecsReading._item` | `id` | 1..999 999 999 | item ignorado |
| `ActivityItem.tryParse` | `id` | 1..999 999 999 | item ignorado |
| idem | `count` / `season` / `episode` | 1..5000 / 0..1000 / 0..100 000 | campo desconhecido (null), como um tipo errado hoje |
| `FriendSharedView.parse` | `tz` | −840..840 | 0 (UTC), como hoje |
- `readCount(v, {max})` continua existindo (agora delega a `readSafeInt`), para a Fase 3 reutilizar.
- Leitura tolerante mantida: desconhecido = "—"/ignorado, nunca erro.

**Lado do dono** (`_nonNegInt` em `SharedSectionParsers`, documento próprio): mesmo leitor, **sem tetos** (docs/91 §5.2). `ActivityItem.tryParse` é compartilhado entre dono e amigo, então o documento próprio também passa pelos tetos de item. Escrita do dono **inalterada**: o que o app grava sai do `SharedProfileValidator.clamp` (ids 1..999 999 999, `count`/`season`/`episode` nas faixas, números inteiros), e a leitura disso dá exatamente o mesmo valor de antes; a comparação "só grava se mudou" continua igual (suíte do motor `shared_profile_sync_test` e golden de payloads verdes). Só um documento próprio escrito **por fora do app** com `Infinity`/fora da faixa passa a ser lido como seção/item ausente, o que leva a uma regravação com os números certos (antes também regravava, porque `Infinity` ≠ o calculado). `tz`/`calc` do documento próprio não foram tocados (de propósito: mudar ali poderia evitar uma regravação que hoje acontece).

**`WatchTimeFormatter` nunca lança** (`lib/services/watch_time.dart`): `format` e `accumulatedHours` limitam a entrada a `0..kMaxFormattedMinutes` (= 2^53 − 1). Diferença para o docs/91 §5.2 (que sugeria limitar a 100 anos): o teste existente `accumulated hours with pt-BR thousands separator` usa 1 234 567 h (> 100 anos) para o **total do próprio dono**; limitar a 100 anos mudaria a tela do dono. Com 2^53 − 1 a aritmética é segura no web, `Infinity` não lança (vira o teto) e nada que o app mostra hoje muda. O teto de 100 anos dos números de amigo já vem do leitor.

**Testes** (`test/shared_reading_web_safe_test.dart`, 29 testes, sem `dart:io`/Hive; roda na VM **e** com `--platform chrome`)
- `readSafeInt`: `Infinity`, `-Infinity`, `NaN`, `1e300`, `12.0` (= 12 nas duas), `12.5`, `-1`, `-1.0`, 2^53, 2^53 + 2, 2^53 − 1 (aceito), `-0.0` (= 0, não negativo, texto "0"), string, `null`, `bool`; limites inclusivos.
- Fronteira de **cada** teto: valor no teto aceito, teto + 1 desconhecido, e `Infinity`/`1e300`/`NaN`/fração/negativo desconhecidos, para os 8 números do total, os 5 de mês/ano, `undated*`, `recs.count`, `id` de recomendado, `id`/`count`/`season`/`episode` de atividade, `tz`.
- Documento inteiro com `Infinity` em tudo: estatísticas "—", item de atividade com `id` infinito ignorado, `count`/`season`/`episode` infinitos desconhecidos, item de recomendado com `id` infinito ignorado, `recs.count` desconhecido, `tz` = 0.
- Documento próprio (dono): `Infinity` derruba a seção, `12.0` = 12, 2^53 − 1 aceito (sem teto).
- Formatador: 100 anos continua "100 anos"/"876.000 h no total"; 2^53 − 1, 2^53 e (2^53 − 1) × 1000 dão o mesmo texto (teto); negativo = 0; **no web** `Infinity` (que lá "é int") não lança. Na VM o ramo web é pulado e o teste confere que `kIsWeb` é falso (não passa em branco por engano).
- **Widget** `SharedStatsView.reading` (a seção de estatísticas do perfil de amigo) com documento cheio de `Infinity`/`1e300`: nenhuma exceção, nenhum `ErrorWidget`, nenhum texto "Infinity" ou "e+", "Tempo assistido: —" nos 3 períodos. No web, também com `Infinity` entregue direto à view (sem passar pelo leitor): renderiza com o teto.

**CI** (`.github/workflows/deploy-pages.yml`): passo novo `Test (web semantics, Chrome)` depois de `Test`, com o mesmo `TZ: America/Sao_Paulo`: `flutter test --platform chrome test/shared_reading_web_safe_test.dart`. Só esse arquivo (≈ 26 s locais, incluindo a compilação dart2js). Os passos existentes não mudaram. Chrome: as imagens `ubuntu-latest` do GitHub trazem `google-chrome` no PATH (o nome que o `flutter_tools` procura no Linux); em modo `flutter test` o Chrome roda `--headless --no-sandbox` (conferido em `flutter_tools/lib/src/web/chrome.dart`, Flutter 3.47.5), então o sandbox de namespaces do Ubuntu 24.04 não atrapalha. YAML validado (parse com PyYAML, 12 passos na ordem).

**Mutações Dart** (`tool/dart_mutations.py`): o runner agora aceita listas de teste começando com `'--platform','chrome'` (passadas ao `flutter test` como estão). 33 mutações novas (A1–A4, A6–A13, B1–B21; a A5 foi removida, ver acima) e 5 antigas atualizadas porque as linhas mudaram (G8, V23, V31, K7, Z4; mesma intenção).

### Números
| Comando | Resultado |
|---|---|
| `flutter analyze` | No issues found |
| `TZ=America/Sao_Paulo flutter test` (2×) | 2012/2012 nas duas (eram 1983; +29) |
| `TZ=UTC flutter test` | 2012/2012 |
| `flutter test test/shared_reading_web_safe_test.dart` (VM) | 29/29 |
| `flutter test --platform chrome test/shared_reading_web_safe_test.dart` | 29/29 (≈ 26 s) |
| `flutter test --platform chrome test/watch_time_test.dart` (conferência extra, não está na CI) | verde |
| `flutter build web --base-href /cinetrack/` | ok |
| Mutações Dart das áreas tocadas, 1ª rodada (cópia em `/tmp/cinetrack-mut-a2`, 47) | 44 mortas; sobreviveram A5, A10, A12 (corrigidos, abaixo) |
| 2ª rodada, cópia nova depois das correções (A1–A4, A6–A13 + amostra B1, B8, B13, B14, B20) | **17/17 mortas** |
| `shasum -a 256 firestore.rules` | `6135322e…e612` (inalterado) |

Mutações (todas na cópia, nunca na árvore de trabalho; `python3 tool/dart_mutations.py /tmp/cinetrack-mut-a2 <ids>`, com os ids de todas as entradas cujos arquivos foram tocados: `safe_int.dart`, `shared_stats_reading.dart`, `shared_profile_models.dart`, `watch_time.dart`):
- Leitor: A1 sem limite superior (VM: 2^53 e tetos), A2 sem limite inferior (−1), A3 sem teste de fração (12.5, NaN), A4 recusa `double` inteiro (o comportamento antigo da VM: 12.0), A9 dono de volta a `is int` (12.0 na VM).
- **Só com semântica web** (rodadas com `--platform chrome`): A6 sem limite superior no web (`Infinity` "é int"); A7 leitor de estatísticas de volta ao `is int` original (o bug A2: `Infinity` passa); A8 `count` de atividade de volta ao `is int`; A11 formatador sem teto no web (`Infinity` lança `UnsupportedError`). Isso também prova que o arquivo novo pega o bug original no Chrome.
- Formatador: A10 sem teto, A12 `accumulatedHours` sem teto, A13 negativo não vira 0. A10/A12 sobreviveram na 1ª rodada (na VM, 2^53 e 2^53 − 1 dão o mesmo texto); o teste ganhou (2^53 − 1) × 1000 (int64 na VM), e as duas morreram na 2ª rodada.
- 1ª rodada: as 13 antigas das áreas tocadas (G8, V23, V31, K5, K7, K14, K15, K17–K19, Z4–Z6) e B1–B21 mortas. Na 2ª rodada só re-rodei o que as correções podiam afetar (leitor e formatador) mais uma amostra dos tetos; as B não dependem das linhas mudadas.
- Tetos, um por ponto de leitura: B1–B8 (cada número do total/mês/ano), B9 teto trocado (minutos com o de episódios), B10–B11 `undated*`, B12 `recs.count`, B13 `id` de recomendado, B14–B15 `id` de atividade (teto e mínimo 1), B16–B19 `count` (teto e mínimo 1), `season`, `episode`, B20–B21 `tz`.

### O que você precisa fazer
- **Code Reviewer**: revisar `safe_int.dart`, os pontos de leitura (tabela acima) e a decisão do teto do formatador (2^53 − 1 em vez de 100 anos, motivo acima).
- **QA**: conferir no web (build local ou pós-deploy) um amigo com documento manipulado (emulador ou cópia) com `Infinity`/`1e300`: seção de estatísticas renderiza com "—"; atividade/recomendado com `id` absurdo não aparece. Conferir que um amigo normal continua igual.
- **SRE**: aprovar o passo novo da CI (tempo extra ≈ 30–60 s no runner, estimativa; não medido no GitHub).
- **Orquestrador**: decidir merge/deploy (regras não mudam, então é só o deploy do app pela CI).

### Artefatos
- Código: `lib/shared_profile/safe_int.dart` (novo), `lib/shared_profile/shared_stats_reading.dart`, `lib/shared_profile/shared_profile_models.dart`, `lib/services/watch_time.dart`.
- Testes: `test/shared_reading_web_safe_test.dart` (novo).
- CI: `.github/workflows/deploy-pages.yml`. Mutações: `tool/dart_mutations.py`.
- Design: docs/91 §5 (branch da Fase 3).

### Decisões tomadas (e por quem)
- Tetos do docs/82 §4.4 aplicados também no leitor de estatísticas de amigo (o docs/91 §5.2 deixava `readCount` sem teto e punha os tetos só no ranking); pedido explícito da demanda ao Dev. Efeito: número de amigo acima do teto vira "—" (o app oficial nunca grava acima). — Dev, conforme a demanda.
- Teto do formatador = 2^53 − 1, não 100 anos (preserva o total do próprio dono, coberto por teste existente). — Dev.
- `isFinite` explícito removido do leitor (redundante com limites finitos; ver acima). — Dev.
- `tz`/`calc` e ids de recomendado do **documento próprio** não foram tocados (lado do dono, autodano; mexer poderia evitar uma regravação de reparo). — Dev.

### Suposições (não verificadas)
- Chrome disponível e funcional no `ubuntu-latest` do GitHub (documentado pelo GitHub; não rodei a CI, não há push).
- Nenhum documento real de amigo tem número acima dos tetos gravado por versão antiga do app: o validador existe desde a Fatia 1 (antes do primeiro deploy da Fase 2), então todo documento gravado pelo app já está dentro deles.

### Riscos / atenção
- Um `12.0` passa a ser 12 também na VM (antes "—"); no web já era 12. Nada mais muda para dados do app oficial.
- O passo novo deixa a CI um pouco mais lenta e depende do Chrome do runner; se falhar por ambiente (não por teste), a mensagem do `flutter test` aponta "Chrome not found"; o contorno é definir `CHROME_EXECUTABLE`.
- `.env` desta worktree foi (re)criado com a chave fictícia `TMDB_API_KEY=test` para analyze/test (é ignorado pelo git; o build web local usou essa chave fictícia e não foi publicado).

### Critério de aceite deste handoff
- Code review sem achado aberto; QA confirma a seção de estatísticas do amigo renderizando com `Infinity` no web e nenhuma regressão no perfil de amigo normal; CI verde com o passo Chrome; `firestore.rules` com o sha `6135322e…e612`.
