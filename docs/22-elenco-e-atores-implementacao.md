# 22 - Implementação: elenco nos detalhes, página de pessoa e ressalvas do review

Branch `feat/cast-and-people` (sem commit). Contrato: [`docs/19`](./19-especificacao-elenco-e-atores.md) (fatias 1 a 3; fatia 4 fora, decisão do Manager). Ressalvas: [`docs/21`](./21-conferencia-favoritos-polish.md).

## Parte A - Elenco e pessoa

### Endpoints TMDB (sem dependência nova; chave só no cliente existente)
| Uso | Endpoint | Observação |
|---|---|---|
| Elenco de filme | `GET /movie/{id}/credits` | `cast`, ordem do TMDB, 1 entrada por pessoa (personagens repetidos unidos por " / ") |
| Elenco de série | `GET /tv/{id}/aggregate_credits` | elenco da série toda; personagem = 1º e 2º `roles` unidos por " / " (❓16) |
| Pessoa | `GET /person/{id}` | `language=pt-BR` padrão do cliente; 2ª chamada com `language=en-US` só se a biografia pt-BR vier vazia |
| Filmografia | `GET /person/{id}/combined_credits` | chamada separada, para a falha da filmografia não derrubar o perfil |
Não verifiquei os endpoints contra a documentação atual do TMDB nem contra a API real (testes usam dublê/MockClient); o formato dos campos segue a spec e a API pública conhecida. Fotos de perfil usam `w185` (tamanhos válidos de perfil: w45, w185, h632, original; `w342` é de pôster).

### Decisões
- **Elenco em chamada própria** (não `append_to_response`): `aggregate_credits` de séries tem centenas de pessoas; separar mantém `titleDetailsProvider` leve e isola o erro (spec A: erro do elenco não substitui a tela).
- **Cache em memória**: `FutureProvider.autoDispose.family` com `ref.keepAlive()` só em sucesso (`_cacheOnSuccess`): voltar/reabrir não refaz chamada; erro não fica preso, "Tentar novamente" (`ref.invalidate`) refaz só aquela parte. Nada em Hive/Firestore; `FavoriteDoc` e `firestore.rules` intactos.
- **Rotas** (todas fora do shell): `/person/:id`, `/movie/:id/cast`, `/tv/:id/cast` (subrotas: deep link para o elenco completo empilha o detalhe por baixo, voltar funciona). `_parseId` com `int.tryParse` e `> 0`; inválido mostra `NotFoundScreen` ("Pessoa/Filme/Série não encontrada" + "Ir para o início"). 404 do TMDB na pessoa mostra o mesmo "Pessoa não encontrada" (sem "Tentar novamente"); demais erros usam `ErrorState` com retry. `/movie/:id` e `/tv/:id` também estão protegidos.
- **Voltar em deep link**: `detailAppBar` passou a mostrar seta que vai a `/` quando `Navigator.canPop` é falso (vale para filme, série, elenco e pessoa). Logo continua na AppBar (fora da rolagem) em <= 768 px; sem tab bar.
- **Elenco**: carrossel de até 15 (`kCastCarouselLimit`), "Ver todos" aparece quando há mais de 15 e abre `CastScreen` (lista lazy, largura máx. 720). Vazio oculta a seção; erro mostra mensagem + botão; carregando mostra esqueleto com rótulo "Carregando elenco". Cartão = 1 botão semântico "<nome>, <personagem>" (foto excluída da semântica), `InkWell` focável (Enter/Espaço). Arrastar com mouse habilitado no carrossel (por padrão o Flutter só aceita toque/trackpad); Tab leva o foco e rola o cartão.
- **Pessoa**: foto, nome (cabeçalho semântico), área ("Acting" -> "Atuação", demais mapeadas, desconhecida exibida como veio), nascimento/falecimento/idade (relógio `catalogClockProvider`, testável; data estrita `yyyy-MM-dd`, inválida some; falecido mostra idade ao falecer; morte antes do nascimento omite idade), local, biografia (pt-BR; fallback en-US com "Biografia em inglês"; sem biografia: "Biografia não disponível"), "Ler mais"/"Mostrar menos" acima de 5 linhas (medido com `TextPainter` e escala de texto; botão com `expanded` e rótulo anunciados), "Conhecido por" (3 mais populares, ❓12), Filmes/Séries (sem repetir título; por data decrescente; sem data no fim; adultos fora; 20 itens + "Mostrar mais (N)" que revela o restante, lista lazy). Largura máx. 800 no desktop.
- **Atribuição (revisada após o code review, docs/24)**: logo oficial do TMDB + aviso exigido "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB." (`kTmdbNotice`) e a linha "Dados fornecidos pelo TMDB.", no widget `TmdbAttribution`, em 3 lugares: rodapé da pessoa, Perfil e `web/privacidade.html`. O logo é o SVG oficial público (themoviedb.org/about/logos-attribution, 2 KB, conferido: só gradiente e paths) renderizado com `rsvg-convert` para `assets/tmdb_logo.png` (820 px, 10 KB; cópia em `web/tmdb_logo.png` para a página de privacidade); **sem flutter_svg**, sem dependência nova. Fica em pílula branca de 110 px (menos proeminente que o logo do CineTrack, legível no modo escuro), `semanticLabel` "Logo do TMDB". Texto antigo (versão "This product uses...") substituído.
- ~~Atribuição anterior~~: rodapé da pessoa com "Dados fornecidos pelo TMDB." e o texto padrão em inglês "This product uses the TMDB API but is not endorsed or certified by TMDB." (a spec só define o texto pt-BR curto; mantive o oficial literal para não parafrasear termo legal). (substituído acima). O Orquestrador deve conferir termos/logo antes de publicar (decisão 4 do Manager). Não há atribuição em outras telas; vale decidir se vai também ao Perfil/Sobre.

### Desvios da spec
1. Pessoa faz 3 chamadas quando a biografia pt-BR está vazia (spec: "no máximo 2"); o caso comum faz 2. Alternativa seria `append_to_response=combined_credits` (1 chamada), mas perde o erro independente da filmografia exigido na spec B.
2. "Mostrar mais" revela tudo de uma vez (spec: "expande a lista"), com renderização lazy.
3. Seta "ir para o início" estendida aos detalhes de título (spec exige só para pessoa); mudança aditiva.
4. Avatar redondo no elenco e retangular 2:3 na tela de pessoa (escolha visual).
Não discordo da spec em nada que mude comportamento.

### Não feito / fora
Selos de favorito/assistido (fatia 4), alternador de ordenação, diretor, busca de pessoas, créditos "Self".

### Correções do code review (docs/24)
- 🟡2 Fallback en-US: 404 = "sem biografia" (cacheado); qualquer outra falha (rede/429/5xx) agora vira erro com "Tentar novamente", nunca cacheia "Biografia não disponível".
- 🟡3 `_get` mapeia `http.ClientException` (o que o navegador lança offline) para "Sem conexão com a internet."; sem dart:io novo.
- 🟡5 `PersonScreen` observa perfil e filmografia juntos: as chamadas saem em paralelo (a en-US continua depois da pt-BR, só quando necessária); erros seguem isolados.
- 🟢 Desempate estável (popularidade, id) também sem data; `id` do perfil defensivo (usa o da rota); perfil com `adult: true` vira "Pessoa não encontrada".
- Testes novos: 7 (fallback com erro, paralelismo, adulto, logo/aviso em pessoa e Perfil, ClientException, ordem estável).

## Parte B - Ressalvas do docs/21
- **🟡-A** `CatalogSyncNotifier.retry({force})`: ao abrir Favoritos (`force: false`) séries que falharam só são tentadas de novo após `catalogRetryIntervalProvider` (5 min, relógio `catalogClockProvider`) desde a última falha; TTL/`settled` continuam sendo reavaliados a cada abertura. O botão "Tentar de novo" (`force: true`) ignora o intervalo. O banner de falha segue visível durante o intervalo.
- **🟡-B** `_runtimeTried` só é limpo no `force`. Títulos sem runtime no TMDB são perguntados uma vez por sessão (por conta, como antes). Efeito colateral aceito: um erro de rede na busca de runtime também não é repetido até o botão ou nova sessão.
- **🟢-C** `_runtimeRunning` virou `_runtimeRunningGeneration` (int?): o laço antigo não zera a trava do novo.
- **🟢-E** Teste do documento chegando dentro da janela do debounce (emite na hora; janela de 400 ms, checado em 50 ms).

## Testes (44 novos; 354 anteriores intactos)
- `test/cast_and_people_test.dart` (47): lógica pura (datas, idade, biografia, ordenação/separação/duplicados/adulto, conhecido por), cliente TMDB com `MockClient` (endpoints, idioma, 404/429), elenco em filme e série, 15 + "Ver todos", vazio/carregando/erro/429/retry só do elenco, lista completa e voltar, ids inválidos (`/person/abc|0|-3`, `/movie/abc`, `/tv/abc`, 404), pessoa completa, falecido, dados faltando, fallback en-US, biografia longa (expandir/recolher + semântica), 20 + "Mostrar mais", falha só na filmografia, falha do perfil, 320 px com texto 200% (sem overflow), desktop, toque no título, "Conhecido por", deep link volta a `/`, cadeia início > filme > ator > filme > ator e volta passo a passo com cache, sem redirect deslogado.
- `test/catalog_refresh_test.dart` (+4): ressalvas A, B, trava por geração e debounce. Conferi por mutação que os testes de A, B e geração falham com o código antigo.
- Dublês: `FakeTmdbApiClient` ganhou elenco/pessoa/créditos e portões para `/movie/{id}`.

## Resultados reais
`flutter analyze`: sem issues. `flutter test`: 405 testes, todos passam. `flutter build web --release`: OK (só o aviso conhecido de fonte/tree-shake). `firestore.rules`, `FavoriteDoc` e `pubspec.yaml` sem diff.

## Não verificado
Chrome/visual (390/1024/1440 px, claro/escuro, rolagem com mouse, foco por Tab, imagens reais de perfil do TMDB), chamadas reais ao TMDB (formato dos campos de `aggregate_credits`/`combined_credits` não conferido com a API), leitor de tela real (só árvore de semântica em teste), o intervalo de 5 min contra uso real de Favoritos.
