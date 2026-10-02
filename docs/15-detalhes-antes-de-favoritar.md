# 15 - Detalhes antes de favoritar

## Causa real
- `/movie/:id` e `/tv/:id` só liam o item de `favoritesListProvider`. Título não favoritado caía no fallback "não está mais nos favoritos". Os cartões de Início/Explorar já navegavam; o destino é que não tinha conteúdo.
- Na Busca, tocar na linha de um título não favoritado o **favoritava** (só abria detalhes se já fosse favorito). Foi o conflito de toque real.
- Coração desabilitado (já favorito) deixava o toque "vazar" para o cartão e abrir detalhes.

## Comportamento novo
- Tocar no cartão/linha abre o detalhe em Início, Explorar, Busca e Descoberta, favoritado ou não, logado ou não. O coração só favorita; qualquer toque nele (inclusive desabilitado ou pendente) não navega.
- Detalhe de não favorito: busca no TMDB (`titleDetailsProvider`, `TitleDetails`): título, pôster, sinopse, ano, nota, gêneros e, em séries, temporadas; episódios sob demanda ao expandir a temporada (`seasonProvider`, já existente). Estados: carregando, erro com "Tentar novamente" (offline mostra "Sem conexão com a internet."). Para favoritos, os dados salvos continuam sendo a fonte; o TMDB só complementa ano/gêneros/temporadas ausentes e seu erro é ignorado (funciona offline).
- Botão "Favoritar" / "Remover dos favoritos" (`FavoriteToggleButton`) com estado real, spinner anti-duplo-toque, altura mínima 48 px no mobile e rótulo semântico. Substitui o ícone de lixeira da AppBar. Ao remover, a tela permanece (agora mostrando "Favoritar"), em vez de voltar.
- Login: toda escrita passa por `runWrite`; deslogado vira `PendingIntent` e é reexecutada após o login. A chamada ocorre direto do toque (sem `await` antes), preservando o popup do Google.

## Decisões de produto
1. **Marcar como assistido um título não favorito favorita-o automaticamente e então marca** (progresso vive no documento do favorito). Filme: `markMovieWatched`. Série: `addResult` + `setEpisodeWatched` (episódio) ou `setSeasonWatched` (temporada). O caminho é decidido no toque, então a reexecução pós-login faz o mesmo e usa valores explícitos (não toggle), sem risco de desmarcar numa conta que já tinha o título.
2. **Desfavoritar apaga o progresso.** Antes não havia confirmação; agora, se houver progresso (filme assistido, ou série com episódios assistidos no documento ou no cache), aparece diálogo "Remover dos favoritos?" (Cancelar/Remover). Sem progresso, remove direto.

## Correções da revisão (docs/16)
- `seasonProvider` agora é invalidado por `ref.listen(favoriteDocsProvider)` em cada temporada quando o documento da série aparece, some ou muda os episódios assistidos. Resolve o check "fantasma" após desfavoritar e o check que não atualizava após a repetição pós-login (episódio e temporada).
- Coração: `excludeFromSemantics` no absorvedor de toque, então o coração desabilitado não é anunciado como acionável.
- Erros: `runDetailWrite` mostra snackbar para qualquer falha. Falha após favoritar e antes de salvar o progresso vira `PartialWriteException` ("favoritado, mas não foi possível salvar o assistido"); favorito sem progresso nesse caso é aceito e informado.
- Episódio fica desabilitado enquanto sua escrita está em andamento (sem toque duplo).
- Confirmação ao desfavoritar série: se `favoriteDocsProvider` ainda não tem valor (carregando/erro), assume que pode haver progresso e confirma.
- Remover offline: a tela guarda o último favorito visto e mantém o conteúdo se o TMDB estiver fora.
- Bug corrigido de passagem: filme favorito sem pôster e sem detalhes TMDB quebrava a tela (null check).
- Não feito: busca com coração desabilitado ainda deixa o toque abrir o detalhe (comportamento desejado e inofensivo); `providers.dart` reformatado e `detailsErrorMessage` no arquivo do filme (cosmético).

## Não alterado
Regras do Firestore, modelo salvo (`FavoriteDoc`), tab bar (detalhe fora do shell, voltar e logo mantidos).

## Código
`lib/models/title_details.dart`, `lib/widgets/detail_actions.dart`, `titleDetailsProvider` em `providers.dart`, `markMovieWatched`/`setEpisodeWatched` em `favorites_repository.dart`, telas de detalhe, `FavoriteButton` (absorve toque), `search_screen.dart`, `ErrorState.retryLabel`. Testes: `test/details_before_favorite_test.dart`.
