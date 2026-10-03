# 25 - Conferência: elenco e atores (correções do docs/24)

Branch `feat/cast-and-people` (não commitada). Revisão só de leitura; nada de código alterado. Chrome **não verificado** (conferência por código, build e testes).

## Resultados reais (rodados por mim)
- `flutter analyze`: No issues found.
- `flutter test`: 405 testes, todos passam.
- `flutter build web --release`: OK (só o aviso conhecido de tree-shake/fonte).
- `firestore.rules`: sem diff. `lib/models/favorite_doc.dart`: sem diff. `pubspec.yaml`: único diff é `- assets/tmdb_logo.png` (nenhuma dependência nova).

## Status por item
| # | Item | Status | Observação |
|---|---|---|---|
| 1 | Atribuição TMDB | ✅ | Ver detalhes abaixo |
| 2 | Fallback de biografia | ✅ | Só `notFound` na chamada en-US vira "sem biografia" (cacheada); demais `TmdbException` (rede, 429, 5xx/unknown) são relançadas, `_cacheOnSuccess` fecha o keepAlive, nada é cacheado |
| 3 | `ClientException` -> offline | 🟡 (aceito, ver 🟢-1) | Compila no web (build OK), sem `dart:io` novo; teste dedicado |
| 4 | Paralelismo perfil + filmografia | ✅ | `PersonScreen` faz `ref.watch` dos dois providers; erros continuam isolados (perfil -> tela de erro/não encontrada; filmografia -> `ErrorState` só na seção) |
| 5 | Desempate, id, adulto | ✅ | Desempate (popularidade, depois id) em `knownFor`, em `_byDateDesc` com e sem data; `{...json, 'id': id}` usa o id da rota; `adult: true` -> `TmdbException.notFound()` -> "Pessoa não encontrada" |
| 6 | Regressões | ✅ | 405 testes verdes, analyze limpo, build OK |

### (1) Atribuição em detalhe
- Logo: `assets/tmdb_logo.png` e `web/tmdb_logo.png` idênticos (820x107, 10275 bytes), declarado no pubspec; o build contém `build/web/tmdb_logo.png` e `build/web/assets/assets/tmdb_logo.png`.
- Aviso: `kTmdbNotice` confere caractere a caractere com o texto exigido ("This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."). Também presente em `web/privacidade.html`.
- Presença: rodapé da tela de pessoa (`_Attribution`), Perfil (`profile_screen.dart`) e `privacidade.html`.
- HTML: `<img src="tmdb_logo.png">` é relativo e a página não tem `<base>`; a página é servida em `/cinetrack/privacidade.html` (o app a abre com `Uri.base.resolve('privacidade.html')`), logo resolve para `/cinetrack/tmdb_logo.png`, que o build copia da pasta `web/`. Funciona sob o base-href do GitHub Pages. Tem `alt` e fundo branco próprio (pílula) para o modo escuro, se o sistema escurecer a página.
- Proeminência: 110 px de largura, dentro de pílula branca com borda; bem menor que o logo do CineTrack na AppBar. Pílula branca garante contraste do gradiente no escuro.
- Semântica: `semanticLabel: 'Logo do TMDB'`; texto em `bodySmall`/`onSurfaceVariant` (cor padrão do tema). `errorBuilder` evita quebra se o asset faltar.
- Não verificado visualmente (Chrome): alinhamento no Perfil, que centraliza o resto do conteúdo, enquanto `TmdbAttribution` é `Column` com `crossAxisAlignment.start`.

## Novos findings
### 🔴 Nenhum.
### 🟡 Nenhum.
### 🟢
1. **`ClientException` = offline é uma aproximação.** No navegador, "Failed to fetch" cobre offline, CORS, bloqueio por extensão e URL inválida; o app só chama `api.themoviedb.org` com URL fixa e o TMDB envia CORS, então na prática o caso real é rede/bloqueio, e a mensagem "Sem conexão com a internet." é razoável. Alternativa futura: mensagem mais neutra ("Não foi possível falar com o TMDB. Verifique sua conexão."). Não bloqueia.
2. **Chamada desperdiçada em pessoa inexistente.** Como a filmografia agora é observada em paralelo, um id 404 dispara também `combined_credits` (que também dá 404). Custo desprezível; ignorar.
3. **Alinhamento visual do bloco de atribuição no Perfil** não conferido no navegador (ver acima); conferir de relance antes/depois do push.
4. Herdado do docs/22 e continua válido: formato real de `aggregate_credits`/`combined_credits` e imagens reais do TMDB não foram verificados contra a API (testes usam dublê). Um smoke test manual com um ator real é recomendado.

## Veredito: APROVADO
Todas as correções pedidas (🟡1, 🟡2, 🟡3, 🟡5 e os 🟢) estão implementadas e conferidas; analyze, 405 testes e build web passam; regras do Firestore, `FavoriteDoc` e dependências intactos. **Nada bloqueia o push.** Recomendações não bloqueantes: smoke test manual com ator real (390/1024 px, claro/escuro) e olhar o bloco de atribuição no Perfil.
