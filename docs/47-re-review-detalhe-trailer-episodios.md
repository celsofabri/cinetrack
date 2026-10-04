# Re-review: detalhe com trailer e episódios (docs/45, 46)

Veredito: **REPROVADO** (1 item 🟡 aberto: ciclo de vida do iframe sem teste do widget completo).

Execuções reais: `flutter analyze` 0 issues; `flutter test` 880 passaram; `flutter build web` ok; `flutter test --platform chrome test/trailer_iframe_browser_test.dart` 2/2 passaram. Verificação visual no Chrome: NÃO feita (build gerado, mas não conectei/naveguei o navegador).

## Status por item
1. Paginação (🟡1 anterior): RESOLVIDO. `kEpisodePage=25`, `take(_shown)`, botão "Mostrar mais episódios (N restantes)" com TextButton de 48 px e texto como nome semântico; ordem preservada; futuros aparecem desabilitados; sem scroll aninhado (a lista é Column dentro do ExpansionTile). Marcar temporada usa `repo.setSeasonWatched` sobre a temporada completa (não depende do que está visível); o check por episódio usa o estado do doc. Teste com 150 episódios (25, depois 50 tiles/imagens, assistido intacto). 🟢 imagens não usam cacheWidth, mas são `w300` em 168 px: irrelevante.
2. Sandbox (🟡2 anterior): RESOLVIDO. Tokens: scripts, same-origin, presentation, popups e popups-to-escape. `allow-scripts`+`allow-same-origin` só anulam o sandbox se o conteúdo for da MESMA origem do pai; aqui é youtube-nocookie.com, cross-origin, então o sandbox continua isolando o app (sem forms, sem top-navigation, sem downloads). `allow-same-origin` é necessário para o player usar cookies/storage próprios; `popups-to-escape-sandbox` é necessário para o link "Assistir no YouTube" abrir sem herdar o sandbox: aceitável. Teste de Chrome passa.
3. Ciclo de vida do iframe: **ABERTO (🟡)**.
   - Implementação plausível: `_YoutubeIframeState.dispose` chama `TrailerFrame.close()` (src=about:blank + remove).
   - Mas nenhum teste cobre o widget: o teste de Chrome só chama `close()` isolado; os testes de widget usam builder falso. Se alguém remover o `dispose`, nenhum teste falha. O dev admitiu a lacuna e a contagem 1 logo após fechar não foi explicada por teste.
   - Além disso, `dispose` só roda ao fim da animação de saída do diálogo (a rota fica montada até lá): durante esse intervalo o vídeo/áudio continua tocando após Esc/X/toque fora.
   - Corrigir: (a) parar o vídeo no início do fechamento (ex.: ouvir `ModalRoute.of(context)!.animation` / `secondaryAnimation` e chamar `close()` quando status passar a `reverse`, ou trocar a árvore do player por SizedBox ao disparar o pop); (b) adicionar teste de widget com `@TestOn('browser')` que abre `TrailerDialog` com o player real (`trailerPlayerBuilderProvider` padrão), conta iframes (inclusive no shadow root), fecha por X, Esc e toque fora (também fechando no meio da animação), faz `pumpAndSettle` e espera 0 iframes; repetir abrir/fechar 3 vezes sem acúmulo.
4. Key/URL: OK. `isValidKey` (regex 11 caracteres) na entrada, em `embedUri` e `watchUri`; host fixo; nada do YouTube é criado antes do toque (iframe só no build do player dentro do diálogo; teste "NOTHING is loaded before the tap").
5. Dados: OK. Cache antigo coberto por `episode_cache_compat_test`; mixin/bulk, mensagens do Desfazer e `discardBulkUndo` na troca de conta (`ref.listen(currentUidProvider)`); testes de lista dizendo não favorito com doc existente e limite 5000 presentes. Nenhuma perda de dados identificada; nenhuma ação do usuário necessária.
6. Regressões/testes por motivo errado: nenhuma achada fora do item 3 (o teste do ciclo do widget com builder falso passa sem exercitar o iframe real).
7. CSP e bottom sheet mobile não feitos: justificativa aceitável (hardening opcional; o iframe já está sandboxed e o diálogo é acessível). Registrar como tarefa.
8. Diff: limpo, sem reformatação extra (16 arquivos modificados + novos).

## O que corrigir para aprovar
Apenas o item 3: parada do vídeo no início do fechamento e teste do ciclo completo do widget no Chrome (e rodar `flutter test --platform chrome` para ele).
