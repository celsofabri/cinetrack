# ADR-002: Cache de descoberta com TTL persistido em Hive (não estado só-em-memória do Riverpod)

Status: Aceita

## Contexto
A home passa a depender de múltiplas seções de catálogo TMDB (Em Alta, Novidades, Por categoria) buscadas na abertura do app (`docs/06-design-home-descoberta.md`). Sem alguma forma de cache, isso significa uma rajada de N chamadas TMDB toda vez que o usuário abre o app — risco de rate limit (429) e sensação de lentidão sem ganho real (o catálogo trending/novidades não muda minuto a minuto).

Recentemente corrigimos um bug em produção causado por `seasonProvider` (`FutureProvider.family`), que cacheava dado no Riverpod sem nenhum mecanismo de expiração: a validade do dado vivia implicitamente em "o provider nunca foi invalidado", desalinhando-se do repositório/Hive por baixo e exigindo invalidação manual espalhada pelo código. Precisamos de uma estratégia de cache para descoberta que não repita essa classe de bug.

## Decisão
O cache de seções de descoberta (Em Alta, Novidades, Por categoria) é persistido em um box Hive dedicado (`discovery_cache`, separado do box `favorites`), guardando por seção: os itens (`List<SearchResult>` serializado) e um timestamp `fetchedAt`.

A validade ("esse dado ainda é válido ou preciso buscar de novo?") é decidida em um único lugar — `DiscoveryRepository._cached()` — comparando `DateTime.now().difference(fetchedAt)` contra um TTL fixo por tipo de seção (Em Alta: 3h · Novidades: 6h · Categoria: 12h) **a cada chamada**, nunca por um timer ou estado guardado em memória no provider.

Os providers Riverpod (`trendingProvider`, `noveltiesProvider`, `categoryProvider`) são funções finas que apenas chamam o repositório — nunca guardam por conta própria se o dado "ainda é bom". Não há `ref.invalidate` manual necessário para manter o dado correto: cada leitura já revalida contra o Hive.

Em caso de erro de rede/API ao buscar dado expirado, a exceção é propagada (a seção mostra erro + retry) em vez de cair silenciosamente para o cache antigo — evita mostrar dado obsoleto como se fosse válido sem sinalização ao usuário.

## Consequências

**Positivas**
- Fonte única de verdade sobre validade do cache (timestamp no Hive), eliminando a classe de bug do `seasonProvider` (estado de cache implícito, desalinhado, exigindo invalidação manual espalhada).
- Sobrevive a restart do app (cache não se perde ao fechar o app, ao contrário de um cache só-em-memória do Riverpod).
- Reduz drasticamente a frequência de chamadas TMDB na abertura da home (rajada só ocorre quando o TTL expira, não a cada abertura) — mitiga risco de rate limit sem exigir lógica de retry/backoff sofisticada.

**Negativas**
- Mais um box Hive para gerenciar (mesma ressalva já registrada em ADR-001: sem schema versionado, mudanças futuras no formato de `DiscoveryCacheEntry` exigem migração manual escrita à mão).
- Dado de descoberta pode ficar até TTL (3h–12h, conforme seção) desatualizado em relação ao catálogo real do TMDB — trade-off aceito conscientemente: para "Em Alta"/"Novidades"/"Categoria", frescor ao minuto não é um requisito de produto.
- Sem stale-while-revalidate: em caso de erro ao tentar atualizar cache expirado, a seção mostra erro em vez de continuar mostrando o dado antigo — decisão deliberada (ver `docs/06-design-home-descoberta.md`), pode ser revisitada se o comportamento incomodar na prática.
