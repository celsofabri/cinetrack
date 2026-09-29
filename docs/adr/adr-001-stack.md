# ADR-001: Stack do CineTrack (Flutter, Riverpod, Hive, TMDB, go_router)

Status: Aceita

## Contexto
Novo app mobile pessoal para favoritar filmes/séries e acompanhar progresso de episódios. Sem backend próprio, sem múltiplos usuários, sem requisito de escala. Decisões aprovadas pelo Manager em 2026-09-23: dados de catálogo via TMDB API; persistência somente local no aparelho.

## Decisão
- **Framework:** Flutter (pedido explícito do Manager).
- **Gerenciamento de estado:** Riverpod. Motivo: testável sem `BuildContext`, bom suporte nativo a estado assíncrono (buscas TMDB) combinando cache local, sem boilerplate de `Bloc` desnecessário para 1 dev/app pequeno.
- **Persistência:** Hive. Motivo: modelo de dados é uma árvore (show → season → episode), não relacional; Hive evita `build_runner`/SQL para um volume de dados pequeno (1 usuário, algumas dezenas de séries no máximo).
- **HTTP:** pacote `http` (evita dependência extra do `dio` para as poucas chamadas GET que o app faz).
- **Navegação:** `go_router`.
- **Catálogo:** TMDB API v3, chave fornecida pelo usuário via `.env` (não versionado).

## Consequências

**Positivas**
- Setup rápido, sem servidor, sem custo de infra.
- Fácil de testar (repositório isolado de UI e de fonte de dados).
- Funciona 100% offline para qualquer item já favoritado.

**Negativas**
- Sem sincronização entre aparelhos (aceito conscientemente — fora de escopo do MVP).
- Hive não tem migração de schema automática: mudança de modelo de dados no futuro exige migração manual escrita à mão.
- Dependência da disponibilidade/rate-limit da TMDB para descobrir catálogo novo (não afeta itens já favoritados).
