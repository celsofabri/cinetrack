# Especificação — CineTrack (app de favoritos e progresso de episódios)

> Autor: Product Analyst (squad) · Consumidor único do produto: o próprio usuário/Manager.

## Problema
O usuário assiste vários filmes e séries em paralelo e perde o controle de **quais episódios/temporadas já assistiu** e **o que ainda quer assistir**. Hoje isso é feito de cabeça ou em anotações soltas.

## Resultado esperado
Um app mobile (Flutter, Android/iOS) onde o usuário:
1. Busca filmes/séries (via TMDB) e marca como favorito.
2. Para séries, marca episódio por episódio como assistido e vê o progresso (ex. "12/24 episódios · próximo: S02E05").
3. Vê sua lista de favoritos com status (não iniciado / assistindo / concluído).

## Métrica de sucesso
Uso subjetivo: o usuário consegue, em menos de 10s, responder "que episódio eu vi por último em X?" sem precisar lembrar de cabeça.

## Escopo

### Inclui (MVP)
- Busca de filmes e séries via TMDB API.
- Adicionar/remover favorito.
- Lista de favoritos com filtro (Todos / Filmes / Séries) e status de progresso, em tela própria ("Meus favoritos", rota `/favorites`) acessada pelo menu do topo da home.
- Tela de detalhes do filme: marcar como assistido (boolean simples).
- Tela de detalhes da série: lista de temporadas → lista de episódios, cada um com toggle "assistido"; contagem agregada por temporada e geral.
- Cálculo automático do "próximo episódio a assistir" (primeiro não marcado, em ordem de temporada/episódio).
- Persistência 100% local no aparelho (sem login, sem conta, sem sincronização entre aparelhos).
- Estados de tela: loading, vazio, erro (sem internet / TMDB fora do ar), sucesso.
- Uso offline dos dados já favoritados (poster, sinopse, lista de episódios ficam cacheados localmente após a primeira busca).

### Não inclui (fora de escopo do MVP)
- Login/conta de usuário e sincronização multi-aparelho.
- Recomendações personalizadas.
- Notificações de lançamento de novo episódio.
- Avaliação/nota pessoal do usuário para filme/episódio.
- Compartilhamento social da lista.
- Suporte a web/desktop (só mobile).

## Critérios de aceite

```gherkin
Cenário: Buscar e favoritar uma série
  Dado que estou na tela de busca
  Quando digito "Breaking Bad" e o TMDB retorna resultados
  Então vejo cartões com pôster e título
  E ao tocar em "favoritar" a série aparece na minha lista de favoritos

Cenário: Marcar episódio como assistido
  Dado que "Breaking Bad" está nos meus favoritos com temporadas carregadas
  Quando abro a temporada 1 e marco o episódio 3 como assistido
  Então o contador da temporada mostra "3/7 assistidos"
  E o "próximo episódio" passa a ser o episódio 4

Cenário: Progresso agregado na lista de favoritos
  Dado que tenho uma série com episódios parcialmente assistidos
  Quando abro a tela de lista de favoritos
  Então vejo o status "Assistindo · 12/24"

Cenário: Sem conexão com internet ao buscar
  Dado que estou offline
  Quando faço uma busca na tela de busca
  Então vejo uma mensagem de erro clara com opção de tentar novamente
  E a busca não trava o app nem quebra a tela

Cenário: Sem conexão, abrindo série já favoritada
  Dado que estou offline
  E já favoritei "Breaking Bad" e carreguei os episódios antes
  Quando abro os detalhes de "Breaking Bad"
  Então vejo os dados cacheados (poster, episódios, progresso) normalmente

Cenário: Lista de favoritos vazia
  Dado que não tenho nenhum favorito
  Quando abro a tela inicial
  Então vejo um estado vazio explicando como adicionar o primeiro favorito

Cenário: TMDB não tem episódios ainda carregados para a temporada
  Dado que abri uma temporada pela primeira vez
  Quando os episódios ainda não foram buscados na API
  Então vejo um loading local (só daquela temporada), não da tela inteira

Cenário: Remover favorito
  Dado que uma série está nos meus favoritos
  Quando escolho "remover dos favoritos"
  Então ela some da lista
  E seu progresso de episódios é apagado localmente
```

## Casos de borda
- Série sem pôster/sinopse no TMDB → mostrar placeholder, nunca quebrar layout.
- Série com temporada "especiais" (season_number = 0) → incluir, mas exibida por último.
- Série ainda em exibição (episódios futuros já listados pelo TMDB) → não deixam marcar como assistido antes da data de exibição (`air_date` futura desabilita o toggle).
- Rate limit / erro 429 do TMDB → mensagem de erro específica, não genérica.
- Chave de API do TMDB ausente/inválida → app não deve crashar; tela de busca mostra erro de configuração.
- Usuário favorita o mesmo item duas vezes (delay de rede + duplo toque) → operação idempotente, não duplica.
- Rotação de tela / app em background durante toggle de episódio → estado não pode ser perdido (persistir a cada toggle, não em lote).

## Perguntas em aberto ❓
- Nenhuma bloqueante. Decisões de fonte de dados (TMDB) e persistência (local) já aprovadas pelo Manager em 2026-09-23.

## Fatiamento sugerido
1. **Fatia 1 (núcleo):** modelo de dados local + busca TMDB + favoritar/desfavoritar + lista de favoritos.
2. **Fatia 2:** detalhes de série com temporadas/episódios + toggle assistido + progresso agregado.
3. **Fatia 3:** offline cache robusto + estados de erro/vazio refinados + polish visual.

## Definition of Done
- [x] Todos os critérios de aceite são verificáveis por teste (unit para lógica de progresso; widget para estados de tela).
- [x] Nenhuma ❓ bloqueante em aberto.
- [ ] QA revisou os critérios (próxima etapa do fluxo).
