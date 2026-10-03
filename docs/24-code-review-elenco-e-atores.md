# 24 - Code review: elenco e atores (feat/cast-and-people)

Revisor: Code Reviewer. Contrato: docs/19 (+ Decisões do Manager), implementação: docs/22.

## Veredito: APROVADO COM RESSALVAS

Nada bloqueia o push do código em si. Antes de PUBLICAR em produção, o item 🟡 1 (atribuição TMDB sem logo) precisa ser decidido pelo Manager/Orquestrador.

## Verificações executadas por mim
- `flutter analyze`: No issues found.
- `flutter test`: 398/398 passaram.
- `flutter build web --release`: OK (aviso de fonte CupertinoIcons é pré-existente/inofensivo).
- `firestore.rules`, `pubspec.yaml`, `pubspec.lock`, `lib/models/favorite_doc.dart`: sem diferença contra main. Nenhum acesso ao Firestore nas telas novas.
- Verificação visual: NÃO feita (extensão do Chrome não conectada). Nenhum item de layout/foco abaixo foi visto em tela; só por leitura de código e pelos testes de widget (320 px, 200% texto, desktop).
- Termos TMDB: consultados via WebFetch em themoviedb.org/api-terms-of-use (resumo de modelo pequeno; vale o Orquestrador reler a página).

## Aderência à spec e decisões do Manager
- Data decrescente, sem data no fim, dedupe por (tipo,id) com papéis unidos: OK (`person.dart` Filmography).
- "Ver todos" completo: OK (`/movie|tv/:id/cast`, ListView lazy, ordem TMDB, AppBar com logo/voltar). Aparece só se > 15.
- Selos de favorito fora: OK. Adultos: créditos filtrados. Sem alteração de modelo/regras.
- Elenco filme: `/credits`; série: `/aggregate_credits`, 2 primeiros papéis. Carrossel 15, ocultado se vazio, erro isolado.

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes
1. **Atribuição TMDB incompleta** (`lib/screens/person_screen.dart:18,441`). Os termos pedem (a) o logo do TMDB, (b) aviso "uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB", (c) posição "prominently in or on your Application". O app mostra só texto, sem logo, e o aviso em inglês está na redação antiga ("uses the TMDB API but is not endorsed or certified by TMDB"). Também só aparece na tela de pessoa; não há "Sobre"/Perfil com atribuição (grep). Correção: adicionar logo oficial (menos proeminente que a marca do app) e a redação atual, idealmente num lugar global (Perfil/rodapé). Decisão do Manager por ser jurídico/marca.
2. **Falha transitória do fallback en-US vira "Biografia não disponível" cacheada na sessão** (`providers.dart` personProvider, `catch (_) {}`). Se a 2ª chamada falhar por rede/429, o resultado é cacheado como sucesso sem biografia e só some ao recarregar o app; "Tentar novamente" não aparece. Correção: não cachear quando o fallback falha (relançar/ `link.close()` e devolver sem keepAlive), ou só engolir 404.
3. **Offline na web não mostra "Sem conexão"** (`tmdb_api_client.dart:35`, pré-existente mas agora exigido pela spec A). `_get` só captura `SocketException`; no navegador o pacote http lança `ClientException`, e a UI cai em "Não foi possível carregar os detalhes. Verifique a conexão." (texto genérico, não o da spec). Não quebra, só diverge. Correção: capturar `http.ClientException` também. Testes usam dublê e não pegam isso.
4. **Runtime que falha por rede nunca é retentado na sessão** (`catalog_sync_providers.dart`, `_runtimeTried.addAll` antes da tentativa; `force` só pelo botão do banner, que só aparece se houver falha de catálogo). Aceitável como ressalva B do doc 21 (evita martelar o TMDB), mas é uma troca: tempo assistido pode ficar incompleto até recarregar. Registrar como risco aceito ou limpar `_runtimeTried` das chaves com erro de rede.
5. **Cascata de chamadas na pessoa**: créditos só são pedidos depois que o perfil chega (`_PersonBody` assiste o provider), e a biografia vazia adiciona uma 3ª chamada sequencial. Spec dizia no máx. 2 (permitido o fallback por ❓4), mas a latência soma 2-3 RTTs. Sugestão: disparar `personFilmographyProvider` em paralelo no `PersonScreen`.

## 🟢 Sugestões
1. `person.dart` `_byDateDesc`: no ramo sem data em ambos o desempate é só popularidade; `List.sort` não é estável, então empate total pode reordenar entre execuções. Acrescentar `a.id.compareTo(b.id)`.
2. `PersonProfile.fromTmdb` usa `json['id'] as int` (lança TypeError se faltar). Cai no estado de erro, não trava, mas melhor retornar "não encontrado".
3. Pessoa com `adult: true` no perfil não é filtrada (só os créditos). Alcançável apenas por deep link ou elenco; considerar ocultar.
4. Cache `keepAlive` sem limite: cada título/pessoa visitado fica na memória da sessão (elenco de séries pode ter centenas de itens). Para uso normal é pequeno e a spec pediu cache de sessão; sem TTL, bio corrigida no TMDB só aparece após recarregar. Aceitável.
5. `_Biography`: `Semantics(excludeSemantics: true)` em volta do `TextButton` ("Ler mais") mantém button/expanded/onTap, então a ação não se perde; não foi testado com leitor de tela real (só com `bySemanticsLabel`). Conferir no QA com VoiceOver/TalkBack e foco por Tab na web.
6. `CastScreen` chama `titleDetailsProvider` só para o título da barra; em deep link isso é uma chamada a mais se a tela abaixo não a mantiver viva (na prática a pilha tem o detalhe, então cache).
7. `detailAppBar` seta "Ir para o início": `Navigator.canPop` é avaliado só no build; aditivo, sem regressão vista nas telas existentes (testes verdes). Em deep link `/movie/1/cast` a pilha tem o detalhe, então voltar vai para ele, coerente.

## Respostas aos focos
- (2) Rotas: `_parseId` rejeita não numérico, 0 e negativo para `/person`, `/movie`, `/tv` e `/cast` (testado); 404 em pessoa mostra "Pessoa não encontrada". Redirect só afeta `/profile`. Logo no AppBar fora da área rolável.
- (3) Providers: erro nunca fica cacheado (`link.close()` no catch); sem vazamento de listener; riscos de stale/limite listados em 🟢 4 e 🟡 2.
- (4) Parsing defensivo bom: tipos checados, listas vazias, dedupe, datas inválidas, sem data. `jsonDecode` com corpo inválido vira erro genérico (pré-existente). 401/404/429 mapeados.
- (5) Biografia renderizada como texto puro (`Text`), parágrafos preservados, sem HTML/links. Alvos mínimos 48 px nos botões; cartões e linhas passam de 48. Overflow 320/200% coberto por teste, não visto em tela.
- (6) Retry: botão force limpa falhas e tentativas; automático respeita 5 min; testes novos A/B e de geração cobrem. Ver 🟡 4.
- (8) Regressões: suíte completa verde, favoritos/sync/login inalterados no diff exceto `retry(force)` e `_runtimeRunningGeneration`.
- (9) Testes: razoáveis e com dublê; lacunas: nenhum teste de falha parcial do fallback en-US (🟡 2), de `ClientException` (🟡 3), de ordem estável com datas ausentes e empate total, e de semântica real de leitor de tela.

## O que bloqueia o push
Nada. Recomendo corrigir 🟡 2 e 🟡 3 (pequenos) neste PR e levar 🟡 1 ao Manager antes do deploy.
