# 14 - Code review: tab bar mobile (feat/mobile-tabbar)

Revisor: Code Reviewer. Alvo: mudanças não commitadas vs `main` (10 arquivos alterados, +149/-114; novos: `lib/widgets/app_shell.dart`, `test/mobile_tabbar_test.dart`, `docs/13`).

## Veredito: APROVADO COM RESSALVAS

Nada bloqueia o push da branch em si (sem bug encontrado no código). Bloqueia o **merge/release** apenas a verificação visual (QA ou dev) em 390 px, 320 px com fonte grande e 1024 px, que ninguém fez. Eu também não: a extensão do Chrome não estava conectada (`tabs_context_mcp` falhou), então **não verifiquei visualmente**. O servidor local foi subido só para testar a conexão e já foi encerrado.

## Verificações executadas por mim
- `flutter analyze`: No issues found.
- `flutter test`: 280/280 passaram.
- `flutter build web --release`: sucesso (só avisos de wasm dry-run e da fonte Cupertino, ambos esperados).

## Requisito
- Breakpoint: `isMobileWidth` usa `width <= 768` (app_shell.dart:14). Em 769 volta ao desktop. Teste cobre 768/769. OK.
- Logo: no mobile fica em `MobileTopBar`, fora da área rolável (app_shell.dart:58-96), nas 5 telas principais. Nos detalhes, `detailAppBar` põe o logo antes do título (app_shell.dart:112). Também ganhou AppBar o estado "não está mais nos favoritos", que antes não tinha. OK.
- Tab bar só nas principais; detalhes ficam fora do `ShellRoute` com botão voltar. Coerente com o doc 13.

## Regressões
- Login: `onSelected` chama `signInWithFeedback` direto do callback do toque (app_shell.dart:177-179), sem await antes. Popup preservado. Enquanto a sessão carrega, vai a `/profile` e o redirect não age. OK.
- Redirect de `/profile` intocado (router.dart). Deslogado, o "Entrar" não navega. OK.
- SyncBanner: no desktop continua no `builder` (main.dart:82-85); no mobile fica no shell e em `DetailBottomBanner`. Sem duplicação, porque os dois lados usam o mesmo predicado de largura. Cruzar 768 redimensionando a janela alterna corretamente (ambos reagem ao MediaQuery).
- Deep links: as rotas mantêm os mesmos paths, o `ShellRoute` não muda URL. O botão voltar dos detalhes continua dependendo de `push` (comportamento anterior; um deep link direto em `/movie/:id` não tem voltar, como já era).
- Perda de rolagem ao trocar de aba: aceitável para este escopo (documentado). Vira 🟡 abaixo porque a Home refaz a montagem de todas as seções.

## Findings

### 🔴 Bloqueantes
Nenhum no código.

### 🟡 Importantes
1. **Sem verificação visual** (processo). Corrigir: rodar o app em 390, 320 (textScale 2.0) e 1024 antes do merge.
2. **Teclado na aba Busca no mobile** (search_screen.dart:~77 + app_shell.dart:185-221). O shell é uma `Column` sem `Scaffold`; o `Scaffold` interno desconta todo o `viewInsets.bottom` embora sua borda inferior esteja acima do teclado (tab bar e banner ficam entre os dois). Cenário: teclado aberto no celular, a área útil fica menor que o necessário (uma faixa morta de ~tab bar + banner) e a tab bar fica atrás do teclado. Correção: em `AppShell`, aplicar `MediaQuery.removeViewInsets(removeBottom: true)` no filho e esconder/colocar a barra acima do teclado; ou validar no aparelho e registrar como aceito.
3. **Alvos de toque e fonte grande não testados.** Cinco destinos em 320 px dão ~64 px cada; "Favoritos" e "Explorar" com textScale alto podem cortar ou quebrar. Os testes de 320 px não definem `textScaler`, então "sem exceção de layout" não cobre o caso pedido. Correção: adicionar teste com `MediaQuery(textScaler: 2.0)` ou `tester.platformDispatcher.textScaleFactorTestValue = 2`, ao menos em 320 px.
4. **FavoriteButton mudou também no desktop** (discovery_section.dart:~221): removido `visualDensity: compact`, o botão passa de 40 para 48 px nos carrosséis e na grade do Explorar em todas as larguras. Isso contraria "desktop não pode regredir" (visualmente, o círculo sobre o pôster cresce). Correção: aplicar 48 px só quando `isMobileWidth`, ou aceitar explicitamente com o Manager. Além disso, o estado `isPending` continua com ~32 px, então o botão encolhe ao tocar.
5. **Paisagem em celular** (ex.: 640x360, largura <= 768): barra superior 56 + NavigationBar ~80 + banner deixam ~220 px de conteúdo. Considerar `labelBehavior: onlyShowSelected`/esconder rótulos em altura baixa, ou validar. Risco de UX, não de crash.

### 🟢 Sugestões
6. Testes fracos (test/mobile_tabbar_test.dart):
   - Linha 112-119 ("detail route"): `find.byType(Image)` passa com qualquer imagem; deveria buscar `BrandMark` dentro do AppBar.
   - Linha 121-134 (SyncBanner): `find.text('Entrar').first` pode pegar o item da tab bar, e as duas asserções finais são redundantes; compare `bannerBox.bottom <= bar.top` com o `SyncBanner` encontrado e confirme o texto da mensagem.
   - Linha 56-62: dois `pumpApp` no mesmo teste reaproveitam a árvore; funciona, mas é frágil. Separe em dois testes.
   - Linha 136-145: o teste de overflow não toca em `/profile`, nem nos detalhes.
   - Não há teste do SyncBanner no desktop (1024) nem do detalhe no mobile.
7. Ruído de reformatação: ganchos só de formatação em catalog_screen.dart (favoriteKeys), discovery_section.dart (2 hunks), movie_details_screen.dart (`matches`), search_screen.dart (`favoriteKeys`), tv_details_screen.dart (3 hunks). Em home_screen.dart e favorites_screen.dart o diff grande vem só da re-indentação do ternário `appBar:`. Conferi com `git diff -w main`: **nenhuma lógica escondida**. Em um PR de 150 linhas o ruído atrapalha pouco, mas prefira não misturar formatação.
8. Semântica: item "Entrar" tem rótulo "Entrar" e tooltip "Entrar com Google"; revisar para o leitor de tela anunciar igual ao visual (ou manter). `NavigationBar` M3 já fornece papel de aba e estado selecionado.
9. Durante o carregamento da sessão, o toque no 4º/5º item vai a `/profile` e pode mostrar "Você não está conectado" por um instante. Cosmético.
10. `MobileShellScope.updateShouldNotify => false` é correto (valor constante por subárvore), mas ao cruzar 768 o shell muda de estrutura e recria a tela; aceitável.
11. `DetailBottomBanner` dentro de `bottomNavigationBar`: confirmar que o `SyncBanner` respeita a safe area inferior (iPhone com home indicator); não verifiquei.

### Segurança / LGPD
Sem pontos: nenhuma coleta, log, rede ou segredo novo; o login reutiliza o fluxo existente.

## O que bloqueia o push
Nada. Antes do merge: item 1 (verificação visual), 3 (fonte grande) e decisão do Manager sobre 4 (FavoriteButton no desktop). O item 2 deve ser validado em aparelho real.
