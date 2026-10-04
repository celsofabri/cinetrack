# 46 - Code review: detalhe, trailer e episódios (docs/45)

Branch `feat/detail-trailer-episodes` (não commitada). Revisão somente leitura.

**Veredito: REPROVADO** (sem 🔴; 3 🟡 a corrigir antes de aprovar, regra "APROVADO limpo").

## Resultados reais
- `flutter analyze`: 0 issues. `flutter test`: 874 passaram. `flutter build web --release`: ok.
- Churn: `git diff --stat` 457+/549-; com `-w` 365+/457-. Cerca de 92 linhas são só reformatação (favorites_repository, tmdb_api_client `_uri`, favorite_mapper.stripWatched, tv_details_screen_test, episode_cache).
- Navegador (Chrome, build local em :8098, rotas públicas): `/tv/1396` mostra chips Favoritar, Recomendo, Marcar como assistido, Assistir trailer; o modal abriu só depois do toque, tocou o vídeo e fechou pelo X; temporada expandida mostra imagem 16:9, "E1 · nome", data/duração e descrição. Não verificado: celular, leitor de tela, Pages, Android/iOS, fluxo logado.

## Não perda de dados: sem achado bloqueante
- `EpisodeCache`: campos novos opcionais; `toJson` só grava o que existe; `fromJson` com padrões; o `watched` nunca está no catálogo (vem do `eps` do Firestore) e `stripWatched`/`copyWith` preservam os campos novos. Cache Hive antigo (listas de mapas JSON, sem adapter) carrega sem quebrar.
- `loadSeason`: enriquece só a temporada aberta; falha/offline/vazio mantém o cache antigo; não favorito não grava. OK.
- `planNewSeriesBulk`: em memória, cancelar não deixa rastro; se o item já existe cai em `planSeriesBulk`. Confirmar = `addResult` (idempotente via `_exists`) + `applySeriesBulk`, que relê o documento e grava só a diferença por campo (nunca `set` completo sobre item existente). Limite 5000 validado sobre o tamanho final. Deslogado→login repete a mesma confirmação como marcação, nunca alterna. Mixin: lógica movida literalmente (testes do docs/30 inalterados e verdes).

## 🟡 Importantes (corrigir)
1. **Lista de episódios não é preguiçosa** (`lib/screens/tv_details_screen.dart`, `Column` com `for` dentro do `ExpansionTile`, ~linha 400). Ao expandir, TODOS os `EpisodeTile` são construídos e TODAS as imagens `w300` pedidas de uma vez (Image.network não espera visibilidade), com `TextPainter` por episódio. Temporadas de 100+ episódios (novelas, diários, animes) geram centenas de requisições, jank e memória de imagem; antes eram só texto. Sem teste com temporada grande. Correção: lista com construção sob demanda (ex.: `SliverList` expandido por temporada, ou paginar/"mostrar mais" a cada 20-30 episódios, ou carregar a imagem só quando visível) e teste com 150 episódios (sem overflow, número de imagens construídas limitado).
2. **`sandbox` do iframe descartado sem causa** (`lib/widgets/trailer_player_web.dart:~37`). Julgamento: o risco é baixo (origem cruzada `youtube-nocookie.com`, sem dado do usuário), mas a justificativa "com sandbox ficou em branco" é provavelmente falta de flag. Teste meu no mesmo build: `sandbox="allow-scripts allow-same-origin allow-presentation allow-popups"` com `allow="autoplay; encrypted-media; picture-in-picture; fullscreen"` renderizou o player normalmente (embed sem query, sem autoplay). Correção: aplicar esse sandbox (acrescentar `allow-popups-to-escape-sandbox` para o link "YouTube"/logo) e validar no Chrome com a URL real (`autoplay=1`, fullscreen, play); se algo quebrar, registrar no docs/45 qual flag e o resultado medido, em vez de "causa não investigada".
3. **Lacunas de teste do que é crítico**: (a) nada testa o `<iframe>` real (src, `title`, `allow`, `referrerpolicy`, ausência/presença de sandbox, remoção ao fechar): `trailer_player_web.dart` só é exercitado manualmente; um teste de navegador (`flutter test --platform chrome`) ou ao menos extrair a montagem do elemento numa função testável; (b) o caminho do detalhe não tem teste de troca de conta com o diálogo aberto, nem de 5000 episódios/`BulkTooLargeException`, nem de "tela velha: lista diz não favorito mas o documento existe" (só o caminho do cartão tem); (c) `embedUri` confia que `key` já foi validada em `fromTmdb`; revalidar no getter (defesa em profundidade) e testar.

## 🟢 Sugestões
- Churn de formatação: reverter reformatações não relacionadas para diff revisável.
- Desfazer de série que não era favorita reverte os episódios e mantém o favorito (coerente com docs/15), mas a mensagem não diz que continua favoritada.
- Foco/Esc: foco inicial no X já existe; falta uma dica visível ("Esc não funciona dentro do vídeo; use Fechar") e fechar com foco no iframe segue limitação do navegador.
- Sem CSP no `index.html`/Pages (nada a quebrar hoje); considerar `<meta http-equiv="Content-Security-Policy">` com `frame-src https://www.youtube-nocookie.com` depois de testar o Flutter web.
- `registerViewFactory` com id novo a cada abertura acumula fábricas (pequeno vazamento por abertura).
- Vídeos em outros idiomas (ex.: só `ko`) são descartados e o botão some; aceitável, mas vale registrar.
- Modal é sempre `Dialog` (não há bottom sheet no mobile); funciona 320-1440 px nos testes.
- `loadSeason` com resposta vazia repete a requisição a cada abertura (sem erro).
- docs/45: honesto sobre o que não foi verificado; acrescentar a medição do sandbox e a de temporada grande quando feitas.

## Segurança
Chave do vídeo validada por regex `^[A-Za-z0-9_-]{11}$` na borda e `Uri.https` com path/params; só YouTube; `youtube-nocookie.com`; nada carregado antes do toque (teste existe); `referrerpolicy` definido; política de privacidade e README coerentes. Sem segredo no diff.

## Para aprovar
Corrigir 🟡1, 🟡2 e 🟡3, rodar analyze/test/build e reverificar o modal e uma temporada grande no Chrome.
