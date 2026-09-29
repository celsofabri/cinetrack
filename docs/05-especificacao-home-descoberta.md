# Especificação — Home com descoberta visual (Em Alta, Novidades, Categorias)

> Autor: Product Analyst (squad) · Evolução de feature existente (fluxo 2 — sem gate de arquitetura obrigatório, mas o Arquiteto entra porque há mudança de dados/contrato: novos endpoints TMDB, possível novo campo de modelo local).
> Depende de / evolui: [`docs/01-especificacao.md`](./01-especificacao.md), [`docs/02-design.md`](./02-design.md), [`docs/adr/adr-001-stack.md`](./adr/adr-001-stack.md).

## Problema
Hoje a tela inicial (`lib/screens/home_screen.dart`) só renderiza a lista de favoritos do usuário (`ListView` simples, texto + pôster pequeno de 46x69), com um filtro Todos/Filmes/Séries. Não existe nenhuma forma de descobrir conteúdo novo a partir da home: a única porta de entrada para algo que o usuário ainda não conhece é apertar a lupa (`FloatingActionButton` → `SearchScreen`) e **já saber o título que quer buscar**.

Isso quebra o caso de uso "abri o app sem saber o que assistir": o usuário de um app de streaming/descoberta espera ver "o que está em alta", "lançamentos recentes" e "categorias" assim que abre — o CineTrack hoje se comporta só como uma lista de favoritos com busca por nome exato.

Além disso, a experiência visual atual (lista de texto com pôster pequeno) não comunica "app de filmes/séries" — não há destaque visual para pôsteres, não há hierarquia entre "o que estou assistindo agora" e "o resto dos favoritos".

## Resultado esperado
A tela inicial passa a ter duas frentes que convivem na mesma tela:
1. **O que é meu** — favoritos, com destaque para quem está "assistindo agora" (progresso parcial), sem perder nenhuma funcionalidade existente (marcar assistido, ver progresso, filtro Todos/Filmes/Séries).
2. **Descoberta** — conteúdo do catálogo TMDB que o usuário ainda não tem, organizado em seções visuais (carrosséis horizontais de pôsteres maiores): "Em Alta", "Novidades" e "Por categoria" (gênero).

O usuário consegue, ao abrir o app, encontrar algo para assistir e favoritar **sem digitar nada** — a busca continua existindo, mas vira caminho alternativo, não o único.

## Métrica de sucesso
O CineTrack não tem telemetria remota (decisão registrada em `adr-001-stack.md` — "app pessoal, sem infra própria"), então a métrica de sucesso é **comportamental/subjetiva**, no mesmo espírito da métrica original do produto:

> Ao abrir o app, o usuário consegue identificar e favoritar algo que não tinha em mente antes de abrir — em no máximo 2 toques a partir da home (tocar no card + tocar em favoritar) — **sem precisar usar a busca**.

Sinal indireto observável pelo próprio usuário/Manager ao longo do uso: a busca (lupa) passa a ser usada só quando ele já sabe o que quer, não como "vitrine" default do app.

## Escopo

### Inclui
- Reestruturação da `HomeScreen` em seções, na tela inicial (sem nova tela/rota):
  - **Continue assistindo**: séries com progresso parcial (algum episódio assistido, mas não todos), em destaque visual (não misturada dentro da lista genérica de favoritos).
  - **Meus favoritos**: a lista/grade atual de favoritos (com o filtro Todos/Filmes/Séries existente), agora abaixo do destaque de "continue assistindo" — sem perder nenhum comportamento de hoje.
  - **Em Alta**: carrossel horizontal de conteúdo popular/em tendência no TMDB (filmes e séries), não-personalizado (não usa histórico do usuário — mantém o "sem recomendação personalizada" já definido como fora de escopo em `01-especificacao.md`).
  - **Novidades**: carrossel horizontal de lançamentos recentes (filmes em cartaz / séries em exibição).
  - **Por categoria**: um ou mais carrosséis horizontais organizados por gênero (ex. Ação, Comédia, Terror...).
- Pôsteres maiores nos carrosséis de descoberta (mais visual que a `ListView` atual) — dimensão exata é decisão de design/implementação.
- Ação de favoritar **direto no card do carrossel** (ícone de coração), sem precisar abrir a tela de detalhes nem a busca.
- Indicação visual em itens de descoberta que **já são favoritos** (ex. coração preenchido/selo), para o usuário não achar que está duplicando.
- Toque em qualquer card de descoberta abre a tela de detalhes já existente (`/movie/:id` ou `/tv/:id`), reaproveitando o fluxo atual.
- Estados de carregamento, vazio e erro **por seção** (uma seção com erro não derruba a home inteira nem as demais seções).
- Primeira abertura do app (zero favoritos): a home ainda mostra as seções de descoberta normalmente (ver Critérios de aceite) — o estado vazio deixa de ser "tela inteira em branco".
- Busca (lupa) continua acessível a partir da home, como hoje.

### Não inclui
- Recomendações **personalizadas** (baseadas em histórico/comportamento do usuário) — já estava fora de escopo em `01-especificacao.md` e continua fora. "Em Alta"/"Novidades"/"Categorias" são conteúdo de catálogo global do TMDB, iguais para qualquer usuário — não são "recomendação" no sentido de ML/algoritmo próprio.
- Telas dedicadas de "ver mais" por categoria com paginação/scroll infinito (fica como fatia futura, ver Fatiamento).
- Editorial curado manualmente (ex. "Selecionado pela equipe CineTrack") — categorias vêm do catálogo TMDB (trending/gênero), não de curadoria manual.
- Personalização de quais categorias/gêneros aparecem (favoritar um gênero, esconder uma seção) — fica fixo/definido pelo app nesta versão.
- Notificações de lançamento (já fora de escopo).
- Mudança na tela de busca (`SearchScreen`) — continua como está, só deixa de ser o único caminho.
- Telemetria/analytics para medir uso das novas seções (sem infra, conforme ADR-001).

## Critérios de aceite

```gherkin
Cenário: Usuário novo, sem nenhum favorito, abre o app pela primeira vez
  Dado que não tenho nenhum favorito
  E tenho conexão com a internet e uma chave TMDB configurada
  Quando abro a tela inicial
  Então NÃO vejo uma tela totalmente vazia
  E vejo as seções "Em Alta", "Novidades" e "Por categoria" preenchidas com conteúdo do TMDB
  E vejo uma indicação de que ainda não tenho favoritos (mensagem curta, não a tela inteira)

Cenário: Favoritar um item direto do carrossel de descoberta
  Dado que estou na tela inicial vendo a seção "Em Alta"
  Quando toco no ícone de favoritar em um card que ainda não é meu favorito
  Então o item é adicionado aos meus favoritos
  E o ícone do card muda para o estado "favoritado" imediatamente
  E o item passa a aparecer também na seção "Meus favoritos"

Cenário: Item de descoberta que já é favorito é indicado visualmente
  Dado que "Breaking Bad" já está nos meus favoritos
  Quando "Breaking Bad" aparece em qualquer carrossel de descoberta (Em Alta, Novidades ou Categoria)
  Então o card mostra o ícone de favorito já preenchido/marcado
  E tocar no ícone não duplica o favorito

Cenário: Continue assistindo em destaque
  Dado que tenho uma série favoritada com progresso parcial (ex. 12/24 episódios assistidos)
  E tenho um filme favoritado marcado como assistido (progresso não se aplica)
  Quando abro a tela inicial
  Então a série com progresso parcial aparece na seção "Continue assistindo"
  E o filme já assistido NÃO aparece nessa seção (aparece só na lista geral de favoritos)

Cenário: Navegar da descoberta para os detalhes
  Dado que estou vendo a seção "Novidades" na home
  Quando toco no pôster de um item (fora do ícone de favoritar)
  Então sou levado para a tela de detalhes desse filme/série
  E essa tela funciona exatamente como quando aberta a partir da busca

Cenário: Filtro Todos/Filmes/Séries continua funcionando nos favoritos
  Dado que tenho filmes e séries favoritados
  Quando aplico o filtro "Filmes" na home
  Então a seção "Meus favoritos" mostra só filmes
  E a seção "Continue assistindo" e as seções de descoberta não são afetadas pelo filtro

Cenário: Sem internet ao abrir a home
  Dado que estou offline
  E já tenho favoritos carregados anteriormente (cache local)
  Quando abro a tela inicial
  Então a seção "Meus favoritos" (e "Continue assistindo") aparece normalmente, com dados do cache
  E as seções de descoberta (Em Alta, Novidades, Categorias) mostram individualmente uma mensagem de "sem conexão" com opção de tentar novamente
  E a tela inicial não trava nem quebra

Cenário: Sem chave TMDB configurada
  Dado que o app não tem uma chave TMDB válida configurada
  Quando abro a tela inicial
  Então a seção "Meus favoritos" funciona normalmente (dado local, sem depender da API)
  E as seções de descoberta mostram uma mensagem de erro de configuração (mesmo padrão já usado na busca)

Cenário: TMDB retorna erro ou rate limit (429) em uma seção de descoberta
  Dado que a seção "Novidades" falhou ao carregar (erro 429 ou 5xx do TMDB)
  Quando a home termina de carregar as outras seções
  Então "Em Alta", "Por categoria" e os favoritos continuam funcionando normalmente
  E só a seção "Novidades" mostra o estado de erro específico com opção de tentar novamente

Cenário: Usuário sem favoritos remove seu último item favoritado
  Dado que tinha 1 favorito e removo esse favorito
  Quando volto para a tela inicial
  Então a seção "Meus favoritos" volta ao estado vazio (mensagem + CTA, como hoje)
  E as seções de descoberta continuam visíveis normalmente (não desaparecem)

Cenário: Busca continua acessível
  Dado que estou na tela inicial, agora com seções de descoberta
  Quando quero buscar um título específico
  Então ainda encontro e uso a busca (lupa) em no máximo 1 toque a partir da home
```

### Casos de borda
- **Item sem pôster no TMDB** dentro de um carrossel de descoberta → mesmo tratamento já existente (placeholder), não pode quebrar o layout horizontal do carrossel.
- **Seção de descoberta vazia** (TMDB retorna lista vazia para uma categoria, ex. gênero sem lançamentos recentes) → a seção some ou mostra estado vazio próprio, mas não trava as demais.
- **Duplo toque no ícone de favoritar dentro do carrossel** (delay de rede + toque duplo) → idempotente, mesmo comportamento já garantido hoje na busca (não duplica).
- **Item de descoberta favoritado e removido em seguida, rapidamente** → estado do ícone precisa refletir a fonte da verdade local (repositório de favoritos), não um estado otimista desalinhado.
- **Filme assistido parcialmente não existe** (filme é boolean assistido/não assistido) → "Continue assistindo" é uma seção exclusiva de séries com progresso parcial; filme assistido ou não não entra nela.
- **Série favoritada mas com 0 episódios marcados como assistidos** → não é "continue assistindo" (ainda não começou); também não deveria contar como "concluído". Ela aparece normalmente na lista geral de favoritos, não no destaque.
- **Série 100% assistida** → sai da seção "Continue assistindo" (não tem mais o que continuar), mas continua em "Meus favoritos".
- **Rotação de tela / orientação landscape** → carrosséis horizontais precisam continuar navegáveis e não quebrar em telas menores/maiores (mesmo princípio de "nunca travar a tela" do MVP original).
- **Acessibilidade**: pôsteres em carrosséis precisam ter texto alternativo (nome do filme/série) para leitor de tela; navegação horizontal por carrossel precisa ser operável via leitor de tela/teclado, não só gesto de arrastar.
- **Idioma/região do conteúdo**: a API já busca em `pt-BR` (`tmdb_api_client.dart`); "Novidades" deve refletir lançamentos relevantes para o usuário brasileiro — se o endpoint escolhido pelo Arquiteto precisar de parâmetro de região, a sugestão de produto é manter consistência com o idioma já fixado (BR), mas a decisão técnica final é do Arquiteto.
- **Muitas chamadas TMDB simultâneas na abertura da home** (favoritos + em alta + novidades + N categorias) → risco de rate limit mais cedo; é um risco técnico a avaliar pelo Arquiteto (ex. cache local com TTL para as seções de descoberta), mas o requisito de produto é: uma seção lenta/com erro não pode atrasar ou quebrar as demais.

## Perguntas em aberto ❓

Nenhuma bloqueante para o Arquiteto começar o desenho técnico. Marcadas como não-bloqueantes (decisão pode ficar com Arquiteto/Manager durante o design, sem travar esta especificação):

- ❓ **Quais categorias/gêneros exibir e em que ordem?** Sugestão de produto: um conjunto pequeno e fixo de gêneros populares (ex. Ação, Comédia, Terror, Romance, Animação) comuns a filme e série, mas a lista final e a fonte (fixa no app vs. dinâmica via `/genre/movie/list` e `/genre/tv/list`) fica a critério do Arquiteto/Design. Não bloqueia — se não decidido, a Fatia 1 e 2 (Em Alta, Novidades, Continue assistindo) já entregam valor sem depender disso.
- ❓ **Critério de ordenação de "Continue assistindo"** quando há mais de uma série em progresso: por data do último episódio marcado como assistido (requer novo campo de "última atividade" no modelo local, hoje só existe `addedAt`) ou por data de adição aos favoritos. Recomendação de produto: usar última atividade (mais alinhado à expectativa de "continue de onde parei"), mas isso é uma decisão técnica sobre o modelo de dados — repasso ao Arquiteto.
- ❓ **Categorias por gênero: filme e série usam taxonomias de gênero diferentes no TMDB.** Produto quer "por categoria" apresentada de forma unificada para o usuário (ex. "Terror" mostrando filme e série juntos, se fizer sentido) — a viabilidade técnica de unificar ou a necessidade de separar por tipo de mídia é decisão do Arquiteto.
- ❓ **Cache/TTL das seções de descoberta** (para não bater na TMDB toda vez que a home abre, e reduzir risco de rate limit) — decisão técnica do Arquiteto, mas produto espera que a home não pareça "lenta" a cada abertura.

Nenhuma destas pontos exige escalonamento ao Manager — são decisões técnicas normais de design, não ambiguidade de escopo/negócio.

## Fatiamento sugerido

1. **Fatia 1 — "Em Alta" simples:** adicionar carrossel "Em Alta" (trending, misto filme/série) acima da lista de favoritos atual, com favoritar direto no card e indicação de já-favoritado. Cobre os casos de borda de offline/sem chave/erro só para essa seção. É o menor incremento que já resolve o problema central ("abrir o app e achar algo sem buscar").
2. **Fatia 2 — Reestruturação visual + Continue assistindo:** separar "Continue assistindo" (só dado local, sem nova chamada TMDB) da lista geral de favoritos, e aumentar o tamanho dos pôsteres/trocar `ListView` por layout mais visual nos favoritos também.
3. **Fatia 3 — "Novidades":** carrossel de lançamentos recentes (filmes em cartaz / séries em exibição), com os mesmos estados de erro/offline por seção.
4. **Fatia 4 — "Por categoria":** carrosséis por gênero (depende da decisão de quais gêneros — ver ❓).
5. **Fatia 5 (opcional/futuro):** tela dedicada "ver mais" por categoria com paginação, para quem quer explorar além do carrossel inicial.

## Definition of Done
- [x] Todos os critérios de aceite são verificáveis por teste (unit para regras de "continue assistindo"/já-favoritado; widget para estados de cada seção — loading, vazio, erro, sucesso).
- [x] Nenhuma ❓ bloqueante em aberto (todas as marcadas são decisões técnicas não-bloqueantes, repassadas ao Arquiteto).
- [ ] QA revisa os critérios (próxima etapa do fluxo).
