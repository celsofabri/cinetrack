# 19 - Especificação: Elenco nos detalhes e página de pessoa (ator/atriz)

> Autor: Product Analyst (squad). Evolução de feature existente. Depende de [`docs/15-detalhes-antes-de-favoritar.md`](./15-detalhes-antes-de-favoritar.md) (detalhe funciona sem favoritar) e [`docs/13-design-mobile-tabbar.md`](./13-design-mobile-tabbar.md) (detalhe fora do shell, sem tab bar).
> Pedido do Manager: "adicionar na tela de detalhes o elenco do filme ou série, e uma tela/página de detalhe por ator/atriz com descrição, informações e os filmes e séries em que atuou."
> Este documento define o *quê* e o *porquê*. Não decide arquitetura (ver "Referência de endpoints" apenas como pista).

## Problema
Na tela de detalhes (`/movie/:id`, `/tv/:id`) o usuário vê sinopse, nota, gêneros e temporadas, mas **não sabe quem atua**. A pergunta natural "de onde conheço esse ator?" ou "o que mais essa pessoa fez?" obriga a sair do app e buscar em outro site. Isso interrompe o ciclo de descoberta (ver título, achar pessoa, achar outro título, favoritar) que o app já suporta para Início/Explorar/Busca.

Persona afetada: qualquer usuário do catálogo, logado ou não (o catálogo é livre).

## Resultado esperado
1. Detalhes de filme e série mostram uma seção **"Elenco"** (carrossel horizontal com foto, nome e personagem).
2. Tocar em uma pessoa abre uma tela **`/person/:id`** com foto, nome, biografia, dados pessoais públicos e a **filmografia** (filmes e séries) com pôster, ano e personagem.
3. Tocar em um título da filmografia abre o detalhe daquele título (que já funciona sem favoritar), permitindo navegar título -> pessoa -> título indefinidamente.

## Métrica de sucesso
Sem telemetria remota (ADR-001), a métrica é comportamental/observável pelo Manager:
> A partir de qualquer detalhe, o usuário chega à filmografia de um ator em **2 toques** (cartão do ator, e a filmografia já está visível ao rolar) e chega ao detalhe de outro título dele em **3 toques**, sem usar a busca.

Sinal de qualidade: nenhuma regressão no detalhe atual (favoritar, assistido, temporadas) e erro/lentidão do elenco nunca bloqueia o resto da tela.

## Escopo

### Inclui
- Seção "Elenco" nos detalhes de **filme e série**.
- Nova rota `/person/:id` (fora do shell, como os detalhes), acessível por deep link.
- Biografia (pt-BR com fallback), nascimento/falecimento/idade, local de nascimento, "conhecido por", filmografia separada em Filmes e Séries.
- Estados de carregando / erro com "Tentar novamente" / vazio / sem foto em todas as telas novas.
- Marcadores de "já favoritado" na filmografia (ver default em ❓).
- Atribuição ao TMDB na tela de pessoa.
- Acessibilidade (rótulos semânticos, alvos de toque, texto escalável).

### Não inclui
- **Mudança no modelo salvo (`FavoriteDoc`) e nas regras do Firestore.** Elenco e pessoa vêm só do TMDB, somente leitura, nunca persistidos (mesmo princípio do `TitleDetails`). Cache apenas em memória/sessão e/ou cache HTTP; nada no Firestore.
- Seguir/favoritar atores, listas de atores, notificações.
- Busca de pessoas na tela de Busca (hoje `/search/multi` já pode devolver `media_type=person`; o app filtra. Continua assim nesta versão; vira iteração futura).
- Equipe técnica (diretor, roteirista, produtor) como seção própria. Ver ❓ 3 (diretor é o candidato mais óbvio).
- Elenco por episódio ou por temporada; "elenco da série" usa o elenco agregado da série.
- Galeria de fotos, vídeos, redes sociais (`external_ids`), prêmios.
- Telemetria/analytics.
- Tradução própria de biografia (só o que o TMDB entrega).

## Critérios de aceite

### A. Seção "Elenco" nos detalhes

```gherkin
Cenário: Elenco exibido no detalhe de um filme
  Dado que abro /movie/:id de um filme com elenco no TMDB
  Quando o elenco termina de carregar
  Então vejo a seção "Elenco" abaixo da sinopse/gêneros
  E ela é um carrossel horizontal de cartões
  E cada cartão mostra foto, nome e personagem
  E a ordem é a mesma devolvida pelo TMDB (campo order, relevância de elenco)
  E vejo no máximo 15 pessoas (default, ver ❓ 1)

Cenário: Elenco exibido no detalhe de uma série
  Dado que abro /tv/:id de uma série com elenco no TMDB
  Quando o elenco carrega
  Então vejo a seção "Elenco" com o elenco agregado da série
  E o "personagem" mostra o papel principal da pessoa na série
  E, se houver mais de um papel, mostra o primeiro (ou os dois primeiros separados por " / ") truncado em 1-2 linhas

Cenário: Detalhe sem favoritar e sem login
  Dado que não estou logado e o título não é favorito
  Quando abro o detalhe do título
  Então a seção "Elenco" aparece normalmente
  E nenhum pedido de login é feito

Cenário: Elenco carregando
  Dado que o detalhe do título já está visível
  Quando o elenco ainda está sendo buscado
  Então vejo placeholders (esqueleto) da seção "Elenco"
  E o restante da tela (sinopse, favoritar, temporadas) continua utilizável

Cenário: Falha ao carregar o elenco (erro de rede ou TMDB)
  Dado que a busca do elenco falha
  Quando a seção deveria aparecer
  Então a seção "Elenco" mostra a mensagem de erro (offline: "Sem conexão com a internet.") e o botão "Tentar novamente"
  E o resto da tela NÃO é substituído por erro
  E tocar em "Tentar novamente" busca só o elenco de novo

Cenário: Título sem elenco cadastrado
  Dado que o TMDB devolve elenco vazio
  Quando o detalhe é exibido
  Então a seção "Elenco" é ocultada por completo (sem título de seção vazio)
  (alternativa em ❓ 2: mostrar "Elenco não disponível")

Cenário: Pessoa do elenco sem foto
  Dado que uma pessoa do elenco não tem profile_path
  Quando o cartão é exibido
  Então vejo um avatar placeholder (ícone de pessoa ou iniciais) do mesmo tamanho
  E nome e personagem aparecem normalmente
  E o cartão continua tocável

Cenário: Personagem não informado
  Dado que uma pessoa do elenco tem character vazio
  Quando o cartão é exibido
  Então a linha do personagem não aparece (sem texto "null" nem linha em branco que quebre o layout)

Cenário: Tocar em uma pessoa do elenco
  Dado que vejo o cartão de uma pessoa no elenco
  Quando toco no cartão
  Então navego para /person/:id daquela pessoa
  E o botão voltar retorna ao detalhe do título, na mesma posição

Cenário: "Ver todos" (ver ❓ 1)
  Dado que o título tem mais pessoas no elenco do que o limite do carrossel
  Quando toco em "Ver todos"
  Então vejo a lista completa do elenco (lista vertical ou grade), na ordem do TMDB
  E cada item leva a /person/:id
```

### B. Tela de pessoa `/person/:id`

```gherkin
Cenário: Tela de pessoa completa
  Dado que abro /person/:id de uma pessoa com todos os dados
  Quando a tela carrega
  Então vejo foto, nome, biografia, data de nascimento, local de nascimento e "Conhecido por"
  E vejo a filmografia separada em duas seções: "Filmes" e "Séries"
  E o logo e o botão voltar estão visíveis

Cenário: Idade e datas
  Dado que a pessoa tem data de nascimento e não tem data de falecimento
  Então vejo "Nascimento: dd/mm/aaaa (N anos)" com N calculado pela data atual
  Dado que a pessoa tem data de falecimento
  Então vejo "Nascimento: dd/mm/aaaa" e "Falecimento: dd/mm/aaaa (N anos)" com N = idade ao falecer
  E não vejo a idade atual

Cenário: Biografia em pt-BR
  Dado que o TMDB tem biografia em pt-BR para a pessoa
  Então ela é exibida em português

Cenário: Biografia sem tradução pt-BR (fallback)
  Dado que a biografia em pt-BR está vazia
  Quando a tela carrega
  Então o app tenta a biografia em inglês (en-US) e a exibe com a indicação "Biografia em inglês"
  (decisão de ❓ 4: indicar o idioma)

Cenário: Pessoa sem biografia em nenhum idioma
  Dado que não há biografia em pt-BR nem em inglês
  Então a seção de biografia mostra "Biografia não disponível" (ou é ocultada, ver ❓ 5)
  E o restante da tela funciona normalmente

Cenário: Biografia longa
  Dado que a biografia tem mais de 5 linhas
  Então ela aparece recolhida em até 5 linhas (default) com "Ler mais"
  Quando toco em "Ler mais"
  Então o texto completo é exibido e o controle vira "Mostrar menos"
  E o estado expandido/recolhido é anunciado a leitores de tela
  Dado que a biografia cabe em 5 linhas
  Então não aparece o controle "Ler mais"

Cenário: Pessoa sem foto
  Dado que a pessoa não tem profile_path
  Então vejo um avatar placeholder e o restante dos dados normalmente

Cenário: Pessoa sem data de nascimento / sem local
  Dado que birthday ou place_of_birth são nulos ou vazios
  Então a linha correspondente é omitida (nunca "null", "—" solto ou idade calculada de data inexistente)

Cenário: Data de nascimento parcial ou inválida
  Dado que o TMDB devolve data fora do formato aaaa-mm-dd
  Então o app não quebra e omite data e idade

Cenário: Filmografia - filmes
  Dado que a pessoa tem créditos de filmes
  Quando a tela carrega
  Então a seção "Filmes" lista cada título com pôster, título, ano e personagem
  E a ordenação padrão é por data de lançamento, do mais recente para o mais antigo (ver ❓ 6)
  E títulos sem data de lançamento aparecem no fim da lista

Cenário: Filmografia - séries
  Dado que a pessoa tem créditos de séries
  Então a seção "Séries" lista cada título com pôster, nome, ano da primeira exibição e personagem
  E segue a mesma ordenação dos filmes

Cenário: Alternar ordenação (se aprovado em ❓ 6)
  Dado que vejo a filmografia
  Quando escolho ordenar por "Popularidade"
  Então as listas são reordenadas por popularidade decrescente
  E a escolha vale apenas para a visita atual

Cenário: Sem créditos de filmes ou de séries
  Dado que a pessoa só tem filmes (ou só séries)
  Então só a seção existente aparece (sem título de seção vazio)
  Dado que não tem nenhum crédito de atuação
  Então vejo "Nenhum filme ou série encontrado" no lugar da filmografia

Cenário: Tocar em um título da filmografia
  Dado que vejo um título na filmografia
  Quando toco no item
  Então abro /movie/:id ou /tv/:id correspondente
  E o detalhe funciona mesmo que o título não seja favorito e eu esteja deslogado

Cenário: Crédito sem pôster
  Dado que o título da filmografia não tem poster_path
  Então vejo placeholder de pôster e o item continua tocável

Cenário: Créditos duplicados (mesma pessoa, várias funções no mesmo título)
  Dado que a pessoa tem 2 ou mais créditos de atuação no mesmo título
  Então o título aparece uma única vez na lista
  E o campo personagem junta os papéis distintos separados por " / "

Cenário: Falha ao carregar a pessoa
  Dado que a busca principal da pessoa falha
  Então vejo estado de erro em tela cheia com "Tentar novamente" (offline: "Sem conexão com a internet.")
  E o logo e o botão voltar continuam disponíveis

Cenário: Falha só na filmografia
  Dado que os dados da pessoa carregam mas os créditos falham
  Então foto, nome e biografia aparecem
  E a área da filmografia mostra erro com "Tentar novamente" independente

Cenário: Pessoa inexistente (id inválido ou 404)
  Dado que abro /person/999999999 ou /person/abc
  Então vejo "Pessoa não encontrada" com ação de voltar/ir ao início
  E o app não trava nem mostra stack trace

Cenário: Filtro de conteúdo adulto
  Dado que a pessoa tem créditos marcados como adult
  Então esses créditos não são exibidos (ver ❓ 7)
```

### C. Navegação

```gherkin
Cenário: Tab bar escondida na tela de pessoa
  Dado que estou em largura <= 768 px
  Quando abro /person/:id
  Então a tab bar NÃO é exibida (mesmo padrão de /movie e /tv, doc 13)
  E o botão voltar e o logo estão visíveis no topo, sempre, e fora da área rolável
  E o SyncBanner aparece no rodapé como nas telas de detalhe

Cenário: Logo sempre visível em <= 768 px
  Dado que estou em /person/:id em qualquer largura <= 768 px
  Então o logo permanece visível mesmo com a biografia expandida e a lista rolada

Cenário: Desktop (> 768 px)
  Dado que estou em largura >= 769 px
  Então a tela de pessoa usa o mesmo cabeçalho/menu superior dos detalhes de título
  E o conteúdo tem largura máxima legível (não esticar a biografia na tela toda)

Cenário: Cadeia de navegação e voltar
  Dado que fui Início -> filme -> ator -> outro filme -> outro ator
  Quando toco em voltar repetidamente
  Então retorno passo a passo pela mesma cadeia até o Início
  E nenhum passo reinicia o carregamento sem necessidade (usa cache)

Cenário: Deep link direto para a pessoa
  Dado que abro a URL /person/:id diretamente (sem histórico anterior)
  Então a tela carrega normalmente, sem login
  E o botão voltar leva ao Início ("/") em vez de sair do app/ficar inerte

Cenário: Deep link para detalhe de título continua funcionando
  Dado que abro /movie/:id ou /tv/:id diretamente
  Então a seção "Elenco" aparece e funciona

Cenário: Loop de navegação
  Dado que estou num filme, abro um ator, e dele o mesmo filme
  Então abre uma nova entrada na pilha (comportamento de push), sem erro; voltar desfaz um passo por vez

Cenário: Redirect do /profile não é afetado
  Dado que não estou logado
  Quando abro /person/:id
  Então NÃO sou redirecionado (só /profile exige sessão)
```

### D. Marcadores de favorito/assistido na filmografia (opcional, ver ❓ 8)

```gherkin
Cenário: Título da filmografia que já é favorito
  Dado que estou logado e o título já está nos meus favoritos
  Quando vejo a filmografia
  Então o item mostra um selo de favorito (coração preenchido) discreto
  E se o título estiver assistido (filme) mostra o selo de assistido
  E o toque continua abrindo o detalhe

Cenário: Deslogado
  Dado que não estou logado
  Então nenhum selo é exibido e nenhuma leitura de favoritos é exigida

Cenário: Favoritos ainda carregando ou com erro
  Dado que a lista de favoritos não carregou
  Então a filmografia é exibida sem selos, sem bloquear nem mostrar erro por causa disso

Cenário: Favoritar não acontece na filmografia
  Então não há coração acionável na filmografia (somente indicador); favoritar é feito no detalhe
```

### E. Acessibilidade

```gherkin
Cenário: Leitor de tela no elenco
  Dado que o leitor de tela está ativo
  Então cada cartão é um único elemento com rótulo "<nome>, <personagem>, botão" (ou apenas "<nome>, botão" sem personagem)
  E a foto é decorativa (excluída da semântica, pois o nome já é anunciado)
  E a seção tem cabeçalho semântico "Elenco"

Cenário: Alvos de toque e teclado
  Então cada cartão de pessoa e cada item da filmografia tem alvo mínimo de 48 px
  E no desktop os itens são focáveis por teclado (Tab) e ativáveis por Enter/Espaço
  E o carrossel pode ser rolado por teclado/mouse (setas ou arrastar), não apenas por gesto de toque

Cenário: Texto ampliado e contraste
  Dado texto do sistema em 200%
  Então nomes e personagens quebram em até 2 linhas com reticências, sem sobrepor nem cortar o cartão
  E o contraste de texto sobre fundo atende WCAG AA

Cenário: Biografia expansível
  Então o controle "Ler mais" / "Mostrar menos" é um botão com rótulo e estado anunciados

Cenário: Imagens com falha
  Dado que a imagem da foto/pôster falha ao carregar
  Então o placeholder é exibido (sem ícone de erro quebrado nem espaço vazio)
```

### F. Rate limit, cache, privacidade e atribuição

```gherkin
Cenário: Cache evita chamadas repetidas
  Dado que já abri o elenco de um título ou a página de uma pessoa nesta sessão
  Quando volto a essa tela (voltar na pilha, reabrir)
  Então os dados são reaproveitados sem nova chamada ao TMDB e sem piscar estado de carregando
  (política de tempo de vida: decisão do Arquiteto; sugestão de produto: pelo menos a sessão)

Cenário: Rate limit do TMDB (HTTP 429)
  Dado que o TMDB responde 429
  Então o app mostra a mensagem de erro padrão com "Tentar novamente" (sem laço automático agressivo)
  E o restante do app (favoritos, detalhes do título) segue funcionando

Cenário: Número de chamadas por tela é pequeno
  Então abrir um detalhe de título adiciona no máximo 1 chamada para o elenco
  E abrir uma pessoa gera no máximo 2 chamadas (dados + créditos), idealmente 1 combinada (ver Referência)
  E navegar por um carrossel de elenco NÃO dispara chamadas por pessoa (só ao tocar)

Cenário: Sem login obrigatório
  Dado que não estou logado
  Então elenco e pessoa funcionam integralmente (catálogo livre)

Cenário: Nada é salvo
  Quando navego por elenco e pessoas
  Então nenhum documento é criado ou alterado no Firestore
  E o modelo FavoriteDoc e as regras do Firestore permanecem inalterados

Cenário: Atribuição ao TMDB
  Dado que estou na tela de pessoa
  Então vejo no rodapé "Dados fornecidos pelo TMDB" (texto; logo conforme termos de uso do TMDB, ver ❓ 9)
```

## Casos de borda
- **Ordem do elenco:** o TMDB já devolve `order` por relevância; não reordenar. Séries podem devolver centenas de pessoas: limitar o carrossel e evitar renderizar tudo (desempenho).
- **Série: elenco agregado vs. elenco recorrente:** convidados pontuais podem aparecer com poucos episódios; ordem do TMDB é a verdade (não filtrar por nº de episódios nesta versão).
- **Mesma pessoa em várias funções:** no elenco do título, deduplicar por `id` da pessoa (um cartão só, personagens unidos). Na filmografia, deduplicar por `id` do título.
- **Elenco só com créditos "como si mesmo"** (documentários, talk shows, premiações): a filmografia pode ficar poluída com "Self" / "Si mesmo". Default: manter, mas ver ❓ 10.
- **Personagem em inglês ("Self", "Himself", "Narrator"):** exibir como vier; sem tradução própria.
- **Créditos sem data** ou **com data futura (anunciado)**: sem data vão ao fim; futuros aparecem com o ano normalmente (opcional rótulo "Em breve"). Ordenar por data decrescente deixa os futuros no topo (aceitável, ver ❓ 6).
- **Créditos de talk shows com centenas de episódios** (pessoa convidada): lista de séries muito longa; paginar/limitar visualmente com "ver mais" (ver ❓ 11).
- **Nomes longos / alfabetos não latinos:** quebra e reticências sem estourar layout; fontes com suporte a CJK/árabe/cirílico.
- **Falecimento:** não exibir idade atual; mostrar idade ao falecer. Data de falecimento anterior à de nascimento (dado ruim): omitir idade.
- **Fuso/data:** datas são só dia (sem hora); calcular idade pela data local sem erro de fuso (aniversário hoje conta como já completou).
- **Formato de data:** pt-BR dd/mm/aaaa; ano de lançamento em 4 dígitos.
- **ID de rota inválido:** `/person/abc` não pode lançar exceção não tratada (hoje `int.parse` nas rotas de detalhe estouraria); tratar como "não encontrado". Vale conferir o mesmo para `/movie` e `/tv`.
- **Rotação/redimensionamento:** cruzar 768 px com a tela aberta mantém dados e posição de rolagem; sem tab bar nas duas larguras.
- **Troca rápida de tela:** voltar enquanto carrega não deve causar erro nem aplicar resposta antiga em tela nova.
- **Conexão cai no meio:** o que já carregou permanece; só a parte pendente mostra erro.
- **Biografia com texto formatado:** pode vir com quebras de linha e, às vezes, créditos de fonte ("Description above from the Wikipedia article..."). Preservar parágrafos; não interpretar HTML.
- **Idioma:** todo texto fixo da UI em pt-BR; conteúdo vem do TMDB conforme disponível.
- **Conteúdo adulto:** ver ❓ 7.

## Impacto em outros lados do produto
- **Tela de detalhe de filme e série:** nova seção; não pode regredir favoritar/assistido/temporadas nem a regra de "funcionar offline para favoritos" (doc 15): sem rede, o elenco mostra erro local, o resto segue.
- **Router:** nova rota fora do shell; redirect só afeta `/profile`.
- **Mobile tab bar (doc 13):** sem alteração; pessoa se comporta como detalhe.
- **Firestore, `FavoriteDoc`, regras, repositório de favoritos:** inalterados.
- **Busca:** inalterada nesta versão.
- **Testes existentes** (`test/details_before_favorite_test.dart` etc.) precisam continuar passando; o elenco no detalhe precisa de dublê no cliente TMDB nos testes para não exigir rede.

## Segurança, LGPD e atribuição
- Os dados de elenco e pessoa são **públicos do TMDB** (nome, foto, biografia, datas e local de nascimento de figuras públicas). **Nenhum dado pessoal do usuário** é coletado, enviado ou armazenado por esta feature; as requisições ao TMDB não carregam identificação do usuário (além do que o cliente já envia hoje).
- A chave TMDB continua só onde já está; nada novo em log, handoff ou exemplo.
- Dados de pessoas **não são persistidos** pelo CineTrack (somente cache de sessão), o que também evita ficar com dado desatualizado (ex.: falecimento, correção de biografia).
- Exibir atribuição ao TMDB conforme os termos de uso (ver ❓ 9).
- Falecidos ou pessoas que pedem correção: a fonte é o TMDB; o CineTrack não edita nem modera esse conteúdo.

## Referência de endpoints TMDB (apenas pista, sem decidir arquitetura)
Sujeito à confirmação do Arquiteto/dev; não verificado contra a documentação atual do TMDB nesta análise.
- Elenco de filme: `GET /movie/{id}/credits` (campo `cast`, com `id`, `name`, `character`, `profile_path`, `order`).
- Elenco de série: `GET /tv/{id}/aggregate_credits` (elenco agregado, com `roles[]`) ou `GET /tv/{id}/credits` (só temporada mais recente/regular). Escolha impacta o critério "personagem" da seção A.
- Alternativa para economizar chamadas: `append_to_response=credits` em `/movie/{id}` e `/tv/{id}` (já usados por `getMovieDetails`/`getTvDetails`). Decisão do Arquiteto.
- Pessoa: `GET /person/{id}` (name, biography, birthday, deathday, place_of_birth, profile_path, known_for_department, popularity).
- Filmografia: `GET /person/{id}/combined_credits` (cast com `media_type`, `character`, `release_date`/`first_air_date`, `popularity`, `poster_path`, `adult`), ou `append_to_response=combined_credits` em `/person/{id}`.
- Fallback de biografia: repetir `GET /person/{id}` com `language=en-US` quando `biography` vier vazia (o cliente atual força `language=pt-BR` em toda chamada, `_uri`; precisará aceitar sobrescrita).
- Imagens: `https://image.tmdb.org/t/p/{tamanho}{profile_path}` (mesma base `imageBaseUrl`).
- "Conhecido por": o TMDB entrega `known_for_department` (ex. "Acting") e, em busca, `known_for`. Para a tela, derivar dos créditos mais populares. Regra exata em ❓ 12.

## Perguntas em aberto ❓
Todas têm default recomendado; **o dev pode seguir os defaults se o Manager não responder**. Marcadas com (!) as que mais mudam esforço ou comportamento.

1. (!) **Quantos nomes no carrossel e "Ver todos"?** Default: **15** no carrossel (ordem TMDB), **sem** tela "Ver todos" no MVP; "Ver todos" entra na iteração 3 (lista completa). Para séries com centenas de pessoas o corte é essencial.
2. **Elenco vazio:** ocultar a seção (default) ou mostrar "Elenco não disponível"?
3. **Incluir diretor/criador?** Default: **fora** do MVP; só atores. Candidato a iteração futura (uma linha "Direção: X" tocável).
4. **Fallback de biografia:** default: tentar en-US e mostrar a nota "Biografia em inglês". Alternativa: não mostrar nada em inglês.
5. **Pessoa sem biografia:** default: mostrar "Biografia não disponível" (evita parecer bug); alternativa: ocultar.
6. (!) **Ordenação da filmografia:** default: **data de lançamento, mais recente primeiro**, sem alternador no MVP; iteração 2 adiciona o alternador "Recentes / Populares". Registrar que "popularidade" põe os títulos mais conhecidos no topo e é melhor para atores com muitos créditos.
7. **Conteúdo adulto:** default: **ocultar** créditos com `adult=true` (consistente com `include_adult=false` do Explorar).
8. (!) **Selos de favorito/assistido na filmografia:** default: **fora do MVP**, entra na iteração 2 (favorito) e só leitura, sem ação. Assistido de série (progresso) fica de fora; exibir só "favorito" para todos e "assistido" apenas para filmes.
9. **Atribuição ao TMDB:** default: texto "Dados fornecidos pelo TMDB" no rodapé da tela de pessoa. Os termos do TMDB pedem normalmente o logo e aviso de que o produto "usa a API do TMDB mas não é endossado por ele"; o Manager/jurídico confirma se o app já exibe isso em outro lugar (Perfil/Sobre). Não verifiquei os termos atuais.
10. **Créditos "como si mesmo" (Self) em talk shows/prêmios:** default: **manter** no MVP; iteração futura pode agrupar ou ocultar créditos cujo personagem contém "Self"/"Himself"/"Herself".
11. **Filmografia muito longa:** default: mostrar os **primeiros 20** de cada seção com "Mostrar mais" que expande a lista, evitando renderizar centenas de itens de uma vez.
12. **"Conhecido por":** default: os **3 títulos mais populares** (campo `popularity` dos créditos) em um carrossel/linha de pôsteres no topo, acima da filmografia; além de exibir o departamento (ex. "Atuação").
13. **Tab bar na tela de pessoa:** default: **escondida**, igual aos detalhes (doc 13). Confirmar, pois o usuário perde o acesso às abas durante uma cadeia longa de navegação (voltar é o caminho).
14. **Deep link sem histórico:** default: voltar leva a `/`. Confirmar.
15. **Cache:** default de produto: cache em memória durante a sessão (elenco e pessoa), sem persistência em disco/Firestore. TTL e mecanismo são do Arquiteto.
16. **Estado do carrossel nas séries:** exibir o papel principal ou todos? Default: primeiro papel; ao tocar na pessoa o detalhe completo mostra os demais.

## Fatiamento sugerido (MVP -> iterações)
Cada fatia é entregável e reversível sozinha; a 1 não depende da 2 para ser útil.

1. **MVP - Fatia 1: Elenco nos detalhes (somente leitura).** Seção "Elenco" em filme e série (15 nomes, ordem TMDB, foto, nome, personagem, scroll horizontal, carregando/erro/vazio/sem foto, acessibilidade básica). Cartão ainda *sem* navegação, ou levando à Fatia 2 quando pronta. Valor imediato e baixo risco; erro isolado da tela.
2. **MVP - Fatia 2: Tela de pessoa `/person/:id`.** Rota fora do shell, foto, nome, biografia (pt-BR + fallback, expandir/recolher), nascimento/falecimento/idade, local, filmografia com Filmes e Séries (pôster, ano, personagem, ordem por data), toque abre o detalhe do título, voltar e logo, deep link, id inválido, estados, atribuição TMDB, cache de sessão. O cartão do elenco passa a navegar.
3. **Iteração 3: "Conhecido por" + "Mostrar mais"/"Ver todos".** Destaque dos 3 mais populares, paginação visual da filmografia, tela/lista completa do elenco.
4. **Iteração 4: Alternador de ordenação (Recentes/Populares) e selos de favorito** na filmografia (logado, somente leitura).
5. **Iteração 5 (futuro, fora deste pedido):** diretor/criador, busca de pessoas em `/search`, filtros por "Self", cache persistente.

## Definition of Done (checagem do analista)
- [ ] Todos os critérios acima são verificáveis por teste (cliente TMDB com dublê; widget tests para elenco e pessoa; teste de rota com id inválido e deep link)
- [ ] Nenhuma ❓ bloqueante em aberto (todas têm default; as marcadas (!) merecem resposta do Manager)
- [ ] QA revisou os critérios e concordou que são testáveis
- [ ] Confirmado que `FavoriteDoc` e regras do Firestore ficaram intactos

## Decisões do Manager (2026-10-03)
1. Filmografia ordenada por **data, do mais recente para o mais antigo** (❓6).
2. Selos de favorito/assistido na filmografia: **depois do MVP** (❓8, iteração 4).
3. Elenco: o carrossel nas telas de detalhe segue como previsto, mas o Manager quer o **elenco completo acessível** ("Ver todos" entra no MVP, ao contrário do default da spec). Definir: tela/lista com todos os nomes do TMDB (foto, nome, personagem), com botão voltar e logo sempre visíveis no mobile (❓1).
4. Atribuição ao TMDB: aprovada; o Orquestrador confere os termos atuais de texto/logo antes de publicar (❓9).
