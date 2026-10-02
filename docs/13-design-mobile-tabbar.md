# 13 - Design: navegação mobile (tab bar)

- **Breakpoint:** largura <= 768 px (`kMobileBreakpoint` em `lib/widgets/app_shell.dart`, único ponto). 769 px ou mais mantém o menu do topo atual.
- **Estrutura:** `ShellRoute` envolve `/`, `/catalog`, `/search`, `/favorites`, `/profile` com `AppShell`. No mobile: barra superior fixa com logo (fora da área rolável, sempre visível) + indicador de sync, conteúdo, `SyncBanner` e `NavigationBar` M3 (safe area tratada pelo próprio widget). O conteúdo fica num `Expanded` acima da barra, então nada rola por trás dela.
- **Itens (5):** Início, Explorar, Busca, Favoritos (tooltip "Meus favoritos"), Perfil / Entrar. Deslogado, "Entrar" chama `signInWithFeedback` direto do toque (popup permitido). Durante o carregamento da sessão, vai a `/profile` (o redirect existente não age enquanto carrega). O redirect de `/profile` não mudou.
- **Telas das abas no mobile:** sem AppBar própria (o shell fornece o logo); Busca ganha o campo no corpo, sem autofocus; os botões de topo (busca/explorar/favoritos/avatar) não aparecem, pois estão na tab bar.
- **Detalhe (`/movie/:id`, `/tv/:id`):** fora do shell, **sem tab bar** (padrão dos apps), com botão voltar e o logo antes do título; o `SyncBanner` aparece no rodapé via `DetailBottomBanner`.
- **SyncBanner:** no mobile fica logo acima da tab bar (no shell) e no rodapé das telas de detalhe; no desktop continua no `builder` do app.
- **Estado:** `ShellRoute` (não `StatefulShellRoute`) para quebrar menos; trocar de aba reconstrói a tela (rolagem não é preservada).
- **Ajustes de densidade:** grade do Explorar com colunas maiores (190 px) no mobile; botão de favoritar com alvo de 48 px; padding do Perfil 16 px.
