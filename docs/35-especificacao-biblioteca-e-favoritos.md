# 35 - Especificação: Biblioteca e Favoritos (com recomendações)

> **ATENÇÃO (2026-10-03): este documento foi REVISADO.** A direção mudou: Favoritos NÃO vira Biblioteca e entra o conceito "Minhas recomendações". A seção "REVISÃO" abaixo é o contrato vigente; no que conflitar, ela vence. As seções antigas (1 a 5, escopo, Gherkin e fatiamento originais) estão marcadas **CANCELADA / ADIADA** e ficam só como histórico (e como base da iteração futura "Sugestões para você").

---

## REVISÃO 2026-10-03: mudança de direção

Autor: Product Analyst. Status: contrato vigente para o Arquiteto (design em [docs/36, seção REVISÃO](./36-design-biblioteca-e-favoritos.md)) e para o Dev. Nada foi verificado rodando o app; leitura de `app_shell.dart`, `router.dart`, `home_screen.dart`, `favorites_screen.dart`, `favorites_section.dart`, `detail_actions.dart`, `discovery_section.dart` e `firestore.rules` (somente leitura). `.env` não lido.

### R.1 Decisão do Manager (literal) e o que muda

> "Mantenha o favoritos, mas crie o 'minhas recomendações'." / "Minhas recomendações são os filmes e séries que eu quero marcar como realmente os filmes e séries que os usuários gostaram, para recomendar pra outros usuários no futuro." Navegação: **aba própria**. Restrição absoluta: **os usuários não podem perder seus dados atuais**.

| Item do contrato anterior | Situação |
|---|---|
| Renomear Favoritos para "Biblioteca" (textos, ícone bookmark, tab, menu, rota `/library`, Perfil "Na biblioteca", diálogos, política, README) | **CANCELADO.** Textos, rota `/favorites`, ícone de coração e o comportamento de favoritar ficam exatamente como hoje |
| Novo estado "Favorito" (coração = amo) como subconjunto da Biblioteca, campo `loved`, chip "Favoritos" | **CANCELADO.** Favoritar continua sendo "adicionar à minha lista" |
| Banner "Agora sua lista se chama Biblioteca" | **CANCELADO** |
| "Recomendados para você" automático (TMDB) no Início | **ADIADO** (iteração futura). Para não colidir com o novo nome, passa a se chamar **"Sugestões para você"** |
| Fatia 0 "Exportar meus dados (JSON)" no Perfil | **MANTIDA** (rede de segurança e portabilidade LGPD) |
| Restrição de zero perda de dados, regras antes do app, regra nunca volta atrás, escrita idempotente | **MANTIDAS** (agora para o campo `recommended`) |
| **NOVO:** estado "Recomendo" + aba "Minhas recomendações" | **NO ESCOPO** (abaixo) |

### R.2 Problema, resultado e métrica

**Problema:** hoje tudo que está em Favoritos pesa igual (54 itens): obras amadas, toleradas e abandonadas. O produto não tem como saber quais títulos o usuário realmente indica. Sem esse sinal, a ideia de, no futuro, recomendar filmes e séries a outros usuários não tem base.
**Resultado esperado:** o usuário marca, com um toque, "Recomendo" nos títulos que realmente curtiu e os vê numa aba própria, "Minhas recomendações". Nesta entrega a marcação é **privada** (só o próprio usuário vê); nada é compartilhado, publicado nem enviado a ninguém.
**Métrica de sucesso (sem telemetria; verificável na conta):**

| Métrica | Alvo | Como verificar |
|---|---|---|
| Zero perda | Perfil antes = depois (itens, filmes assistidos, episódios, séries concluídas) e o arquivo exportado na Fatia 0 bate com o Perfil | Manager anota os números; teste automatizado de compatibilidade |
| Adoção | Manager marca >= 5 títulos como "Recomendo" na primeira semana | Contador no Perfil |
| Privacidade | Nenhuma leitura de `recommended` por outro usuário; texto da política/Perfil diz "privado por enquanto" | Teste de regras; revisão de texto |
| Custo | 0 leituras novas; 1 escrita por marcar/desmarcar | Revisão do Arquiteto |

### R.3 Conceito e vocabulário (contrato)

- **Favoritos** (inalterado): lista pessoal de acompanhamento, com progresso. Coração, rota `/favorites`, textos de hoje.
- **Recomendo:** marca booleana sobre um item **que está em Favoritos**. Significa "eu realmente gostei, indicaria". Todo título "Recomendo" está em Favoritos; nem todo favorito é "Recomendo".
- **Minhas recomendações:** a visão (aba) dos itens marcados "Recomendo". **Privada** nesta entrega.
- **Sugestões para você** (futuro, ADIADO): sugestões automáticas via TMDB. Nunca chamar de "recomendações" na interface para não confundir.
- Ícone/rótulo: **polegar para cima** (`thumb_up_outlined` / `thumb_up`), rótulo "Recomendo" (estado marcado: "Recomendado"). **Não usar coração** (é "adicionar") **nem estrela** (confunde com nota do TMDB). Nunca só o ícone: rótulo, tooltip e semântica dizem o estado.
- Microcopy de privacidade, visível no topo da aba e no estado vazio: "Só você vê esta lista, por enquanto."

### R.4 Navegação

- **Aba própria "Minhas recomendações"**. Mobile (largura <= 768 px): tab bar inferior. Desktop: item no menu do topo do Início (`_NavAction`), com rótulo completo.
- A tab bar já tem 5 itens (Início, Explorar, Busca, Favoritos, Perfil/Entrar); o máximo do Material 3 é 5. **Solução proposta (detalhe e alternativas no docs/36 R.5):** **Perfil/Entrar passa para um ícone (avatar ou "Entrar") no canto direito da barra superior** no mobile, liberando o slot; Busca, Favoritos e todos os demais ficam onde estão. Alternativa pedida como default pelo Manager (Busca vira lupa no topo) é equivalente em custo; fica como plano B, escolha do Manager. Nenhuma função some; rotas `/search`, `/profile`, `/favorites`, `/catalog`, `/movie/:id`, `/tv/:id`, `/person/:id` não mudam; nova rota `/recommendations`.
- Rótulo curto na tab bar (cabe em 320 px): "Recomendo"; tooltip, semântica e título da tela: "Minhas recomendações". Desktop: "Minhas recomendações".

### R.5 Fluxos

| Ação | Onde | Efeito |
|---|---|---|
| Marcar "Recomendo" (título **em** Favoritos) | detalhe; cartão da tela Favoritos | liga a marca; progresso, ordem e datas intactos |
| Marcar "Recomendo" (título **fora** de Favoritos) | detalhe (a partir de Início/Explorar/Busca) | **adiciona a Favoritos e recomenda numa só escrita** (default); feedback "Adicionado aos favoritos e às suas recomendações." |
| Desmarcar "Recomendo" | detalhe; cartão de Favoritos; cartão da aba | tira só a marca; **continua em Favoritos**, sem diálogo (reversível), aviso discreto "Removido das suas recomendações" |
| Remover de Favoritos (coração/botão atual) um título "Recomendo" | detalhe; cartões | **remove também a recomendação** (o item some), **com confirmação**, ainda que sem progresso: "Remover dos favoritos? Isso apaga seu progresso neste título{, e ele deixa de estar nas suas recomendações}." (cláusulas condicionais). Cancelar em foco inicial |
| Marcar assistido rápido / episódios / série inteira / Desfazer | como hoje | **não** altera "Recomendo"; "Recomendo" **não** marca assistido |
| Favoritar um título (coração) | como hoje | **não** recomenda |
| Cartões de Início/Explorar/Busca | como hoje | sem botão "Recomendo" (só o coração de hoje); recomendar é no detalhe ou na tela Favoritos |

- **Ordenação da aba:** mesma regra de Favoritos (`byRecentActivity`: atividade de assistir, depois adição). Marcar "Recomendo" **não reordena**. (❓ Q4 abaixo: ordenar por "recomendado em" exigiria um timestamp; default: não.)
- **Filtros:** Todos / Filmes / Séries (mesmo segmentado de Favoritos). Sem Em andamento/Concluídos (não se aplica a uma lista de indicações). Contador "(n)" no cabeçalho da aba respeita o filtro.
- **Estado vazio (ensina):** ícone de polegar, título "Você ainda não recomendou nada", texto "Abra um filme ou série que você curtiu e toque em Recomendo. Só você vê esta lista, por enquanto." + botão "Ver meus favoritos" (se houver favoritos) ou "Buscar um título" (se não houver). Se Favoritos está carregando ou não confirmado, mostra carregando/erro, **nunca** o vazio (erro ≠ vazio, padrão de `FavoritesGate`).
- **Deslogado:** a aba existe e mostra o convite "Entre para guardar suas recomendações" com o botão de login; o botão "Recomendo" no detalhe leva ao login e, após logar, executa a mesma intenção (adicionar + recomendar); cancelar login não grava nada.
- **Perfil:** novo contador "Recomendo" (n) ao lado dos atuais, que não mudam. O Perfil ganha também (Fatia 0) "Exportar meus dados (JSON)".

### R.6 Escopo

**Inclui:** Fatia 0 (exportar JSON); campo `recommended` + regras; botão "Recomendo" no detalhe e no cartão de Favoritos; aba/rota/tela "Minhas recomendações" (mobile e desktop); reorganização da tab bar mobile; contador no Perfil; confirmação ao remover de Favoritos item recomendado; política de privacidade, resumo no app e diálogo de exclusão atualizados; testes.
**Não inclui:** renomear Favoritos; qualquer compartilhamento, perfil público, ranking ou envio das recomendações a outros usuários (roadmap no docs/36 R.9); "Sugestões para você" automáticas; nota/justificativa por título; ordenação manual; importação de JSON; notificações.

### R.7 Critérios de aceite (Gherkin)

```gherkin
# --- Fatia 0: exportar ---
Cenário: Exportar meus dados
  Dado que estou logado e tenho 54 itens em Favoritos
  Quando toco em "Exportar meus dados (JSON)" no Perfil
  Então recebo um arquivo .json com os 54 itens, com todos os campos de cada documento (progresso, assistido, datas)
  E o arquivo não contém e-mail nem identificador interno da conta
  E o app não escreve nada no Firestore

Cenário: Exportar sem conexão confiável
  Dado que não consigo confirmar os dados no servidor
  Quando toco em exportar
  Então o app avisa que o arquivo pode estar incompleto antes de gerá-lo, ou permite tentar de novo
  E nunca gera um arquivo vazio como se fosse completo

# --- Marcar / desmarcar ---
Cenário: Marcar Recomendo no detalhe (título já em Favoritos)
  Dado um título em Favoritos, não recomendado
  Quando toco em "Recomendo" no detalhe
  Então o botão passa a "Recomendado" (selecionado, polegar preenchido, semântica "selecionado")
  E o título aparece na aba Minhas recomendações
  E progresso, assistido, datas e posição na ordem de Favoritos não mudam

Cenário: Marcar Recomendo num título fora de Favoritos
  Dado um título que não está em Favoritos
  Quando toco em "Recomendo" no detalhe
  Então o título entra em Favoritos e em Minhas recomendações numa única operação
  E vejo "Adicionado aos favoritos e às suas recomendações."
  E, se a operação falhar, o título não fica em nenhuma das duas listas

Cenário: Marcar Recomendo no cartão de Favoritos
  Dado a tela Favoritos com um título não recomendado
  Quando toco no polegar do cartão
  Então o polegar fica preenchido, o toque não abre o detalhe e o botão de assistido rápido continua funcionando

Cenário: Desmarcar Recomendo
  Dado um título recomendado, com progresso
  Quando toco em "Recomendado" para desmarcar
  Então ele sai de Minhas recomendações, continua em Favoritos com o mesmo progresso e não há diálogo

Cenário: Duplo toque
  Quando toco duas vezes rápido em "Recomendo"
  Então ocorre uma única escrita e o botão mostra estado pendente até concluir

Cenário: Recomendar não marca assistido nem favorita sozinho o que não pediu
  Dado um título fora de Favoritos
  Quando marco um episódio como assistido
  Então ele entra em Favoritos e NÃO é recomendado

# --- Aba ---
Cenário: Nova aba no mobile
  Dado que estou no mobile (largura <= 768 px)
  Então a tab bar tem exatamente 5 destinos: Início, Explorar, Busca, Favoritos e Recomendo
  E o acesso ao Perfil (ou Entrar, se deslogado) está na barra superior, com alvo de toque >= 48 px
  E tooltip e semântica da aba dizem "Minhas recomendações"

Cenário: Nova aba no desktop
  Dado que estou em largura > 768 px
  Então o menu do topo do Início tem "Minhas recomendações" e leva a /recommendations

Cenário: Nenhuma função perdida e links antigos funcionam
  Quando abro /favorites, /search, /catalog, /profile, /movie/603, /tv/1396 e /person/1 por link direto
  Então cada um abre a tela de hoje sem erro, e /recommendations abre a nova aba

Cenário: Listagem da aba
  Dado 54 itens em Favoritos, 5 recomendados (3 filmes, 2 séries)
  Quando abro Minhas recomendações
  Então vejo os 5, com "(5)" no cabeçalho, ordenados como em Favoritos
  Quando escolho Filmes
  Então vejo 3 e o contador reflete o filtro

Cenário: Estado vazio ensina
  Dado nenhum título recomendado
  Quando abro a aba
  Então vejo "Você ainda não recomendou nada", a instrução de tocar em Recomendo e "Só você vê esta lista, por enquanto."

Cenário: Vazio nunca enquanto carrega ou com erro
  Dado que Favoritos ainda carrega ou não foi confirmado pelo servidor
  Quando abro a aba
  Então vejo carregando ou a mensagem de erro de carga, nunca o estado vazio

# --- Remover de Favoritos ---
Cenário: Remover de Favoritos um título recomendado
  Dado um título recomendado
  Quando toco para remover dos favoritos
  Então o diálogo avisa que ele também deixa de estar nas suas recomendações, com Cancelar em foco inicial
  Quando confirmo
  Então o título sai de Favoritos e de Minhas recomendações e o contador do Perfil diminui

Cenário: Cancelar a remoção
  Quando cancelo, toco fora ou pressiono Esc
  Então nada muda

# --- Offline, erro, login ---
Cenário: Offline
  Dado que estou offline
  Quando marco ou desmarco Recomendo
  Então a interface atualiza na hora e sincroniza ao reconectar sem perder a marcação

Cenário: Falha ao salvar
  Dado que a escrita é recusada (permissão/cota) ou falha
  Quando marco Recomendo
  Então o botão volta ao estado anterior, vejo mensagem clara de erro e nada fica pela metade

Cenário: Login obrigatório
  Dado que estou deslogado
  Quando toco em "Recomendo"
  Então vejo o convite de login e, após logar, a marcação é executada; se cancelo, nada é gravado

Cenário: Item removido em outro aparelho
  Dado que o título foi removido de Favoritos em outro aparelho
  Quando marco Recomendo aqui, em tela desatualizada, num item que a UI achava existente
  Então vejo "Este título não está mais nos favoritos." e nenhum documento vazio é recriado

# --- Não perda de dados ---
Cenário: Dados atuais intactos após a atualização
  Dado minha conta com 54 itens, 20 filmes assistidos, N episódios e M séries concluídas
  Quando abro o app atualizado
  Então Favoritos tem os mesmos 54 itens com o mesmo progresso, ordem e datas
  E o Perfil mostra os mesmos números e "Recomendo" = 0
  E nenhum documento foi escrito (sem migração em massa)

Cenário: Operações existentes não apagam a marca
  Dado um título recomendado com progresso
  Quando marco a série inteira como assistida e depois toco em Desfazer, ou marco episódios, ou abro com sincronização atrasada
  Então o título continua recomendado e o progresso volta como hoje

Cenário: Excluir conta
  Dado uma conta com recomendações
  Quando concluo "Excluir minha conta e dados"
  Então favoritos, progresso, recomendações e apelido são apagados e o diálogo cita as recomendações

# --- Compatibilidade com app antigo ---
Cenário: App antigo lê documento recomendado
  Dado que marquei Recomendo na versão nova
  Quando outro aparelho com a versão antiga abre o app
  Então o título aparece normalmente em Favoritos, sem erro

Cenário: App antigo grava progresso em título recomendado
  Quando a versão antiga marca um episódio desse título
  Então a gravação é aceita e o título continua recomendado na versão nova

Cenário: App novo com regras antigas (esquecimento do passo do Manager)
  Dado que as regras novas ainda não foram publicadas
  Quando marco Recomendo
  Então a ação falha de forma visível (banner/mensagem), o botão volta ao estado anterior e nenhum outro dado é afetado

# --- Privacidade e regras ---
Cenário: Marcação é privada
  Dado que sou o usuário A com recomendações
  Então o usuário B não consegue ler nem gravar os meus documentos
  E nenhuma tela, link ou requisição expõe minhas recomendações a terceiros

Cenário: Regras
  Dado o campo `recommended` publicado nas regras
  Então o dono grava true ou remove o campo; gravar texto, número, null, mapa ou lista é negado; campo desconhecido é negado; documentos sem o campo continuam atualizáveis

Cenário: Política atualizada
  Quando abro a política de privacidade
  Então ela cita as recomendações marcadas, diz que por enquanto são privadas e não são compartilhadas, e prevê consentimento antes de qualquer compartilhamento futuro, com nova data
```

### R.8 Casos de borda

- **E1. Mesmo id como filme e série:** chave composta `{id}-{tipo}` em tudo.
- **E2. Relógio/`addedAt`:** marcar não toca `addedAt`, `lastWatchedAt` nem a ordem.
- **E3. Troca de conta durante a operação:** nada é escrito na conta nova (padrão atual).
- **E4. Duas marcações concorrentes em aparelhos diferentes:** a última a chegar ao servidor vence (convergem; mesma política do ADR-003).
- **E5. Perfil virou tela empilhada no mobile:** voltar leva de volta à tela anterior; deep link sem histórico oferece "Ir para o início" (padrão `detailAppBar`).
- **E6. Barra superior estreita (320 px, fonte 2x):** logo + indicador de sincronização + ícone de Perfil sem overflow.
- **E7. Cartão de Favoritos com o novo botão (320 px, fonte 2x):** sem overflow; fallback: o polegar vai para a linha do título.
- **E8. PWA/service worker antigo:** vê o app antigo por um tempo; seguro, desde que as regras tenham sido publicadas antes.
- **E9. Exportação com documento muito grande (`eps` de 5000 entradas) ou muitos itens:** continua válida; gerar em memória é aceitável para o volume atual.
- **E10. Acessibilidade:** alvo >= 48 px; estado `selected`/toggle na semântica; foco visível por teclado; contraste nos temas claro/escuro; anúncio do resultado por snackbar.
- **E11. Texto longo:** título de 300 caracteres truncado com reticências, completo na semântica.

### R.9 Perguntas em aberto (todas com default; nenhuma bloqueia)

| # | Pergunta | Default |
|---|---|---|
| Q1 | Tab bar: **Perfil/Entrar vai para a barra superior** (default do PA) ou Busca vira lupa no topo (sugestão original do Manager) | Perfil no topo; Busca permanece tab |
| Q2 | Rótulo curto na tab: "Recomendo" | "Recomendo" (título completo na tela) |
| Q3 | Remover de Favoritos remove a recomendação | Sim, com confirmação |
| Q4 | Ordenar a aba por "recomendado em" (exige campo timestamp) | Não: ordem de atividade, como Favoritos. Dá para acrescentar depois sem perder nada |
| Q5 | Marcar automaticamente algum dos ~54 itens | Não; tudo começa em 0 |
| Q6 | Mostrar "Só você vê esta lista, por enquanto." | Sim |
| Q7 | Recomendar título fora de Favoritos adiciona a Favoritos | Sim, numa escrita |

### R.10 Fatiamento revisado

0. **Fatia 0 - Exportar meus dados (JSON).** Só app, sem regras. Manager exporta a própria conta antes da Fatia 1.
1. **Fatia 1 - Minhas recomendações.** Regras (Manager publica **antes** do app), campo `recommended`, botão, aba, tab bar, Perfil, privacidade, testes.
2. **Fatia 2 - Futuro (não implementar):** "Sugestões para você" (desenho do doc 36 antigo, seções 9) e compartilhamento com consentimento (roadmap no doc 36 R.9).

---

*As seções abaixo são o contrato anterior (Biblioteca/Favorito/Recomendados). Mantidas só como histórico e base da iteração futura.*

Autor: Product Analyst. Data: 2026-10-03. Status: para decisão do Manager (❓) e depois handoff ao Arquiteto.
Base lida (somente leitura): docs/07, 08, 15, 18, 19, 30; `lib/models/favorite_item.dart`, `favorite_doc.dart`; `favorites_screen.dart`, `favorites_section.dart`, `detail_actions.dart`, `discovery_section.dart`, `home_screen.dart`, `profile_stats_card.dart`, `tmdb_api_client.dart`, `app_shell.dart`, `firestore.rules`, README, `web/privacidade.html`. Não li `.env`. Nada foi verificado rodando o app.

> Pedido do Manager (literal): "O favoritos precisa mudar de termo: ao invés de favoritar, precisamos fazer com que seja 'adicionar à biblioteca' ou 'acervo'... e ter favoritos como uma forma de recomendação de filmes/séries que realmente o usuário goste."

---

## Problema

**Para quem:** usuário logado do CineTrack (hoje, o Manager, com ~54 itens em produção) e futuros usuários.

1. **O termo está errado para o que o app faz.** Hoje "favoritar" = colocar um título na lista pessoal de acompanhamento, com progresso, assistido e "concluído". Um usuário que adiciona um filme só para lembrar de assistir (ou uma série que acompanha sem adorar) o "favorita". Favorito deveria significar "amo isso".
2. **O app perde o sinal de gosto.** Como tudo é "favorito", nenhum item diz o que o usuário realmente ama. Não há como recomendar bem: uma lista de 54 itens mistura obras amadas, obras toleradas e obras abandonadas.
3. **Descoberta fraca.** Início só tem carrosséis genéricos (Em Alta, Novidades, por gênero). Nada é personalizado.
4. **Ícone enganoso.** O coração hoje significa "adicionar ao acervo". Ao reservar o coração para o favorito de verdade, o ícone atual precisa mudar, e o usuário já treinado precisa ser avisado.

## Resultado esperado

- O usuário entende dois conceitos distintos, com palavras e ícones distintos:
  - **Biblioteca** = tudo que adicionei/acompanho (o que hoje é "favorito", com progresso).
  - **Favoritos** = subconjunto que eu amo (coração), usado como semente de **recomendações**.
- Tudo que existe hoje continua existindo, sem perda e sem mudar a semântica de progresso/assistido/concluído.
- O Início passa a ter "Recomendados para você", baseado nos Favoritos, com explicação ("Porque você favoritou X"), sem backend próprio, sem custo extra e sem ML próprio.

## Métrica de sucesso

O app não tem telemetria (a política de privacidade promete "sem análise nem telemetria") e há um único usuário real. Portanto as métricas são verificáveis por dados da própria conta e por conferência do Manager, sem instrumentar nada novo:

| Métrica | Alvo | Como verificar |
|---|---|---|
| Zero perda na mudança | 100% dos itens, do progresso e das datas atuais presentes na Biblioteca depois do update (contagem antes = depois: itens, filmes assistidos, episódios assistidos, séries concluídas) | Manager anota os números do Perfil antes; conferência depois; teste automatizado de compatibilidade |
| Entendimento do termo | Nenhuma tela, tooltip, diálogo, erro ou doc de usuário ainda usa "favoritar/favorito" com o sentido antigo | Busca textual de strings (checklist da seção "Textos a renomear") |
| Adoção de Favoritos | Manager marca ≥ 3 favoritos em até 1 semana; Perfil mostra o contador | Perfil |
| Qualidade das recomendações | 0 itens já na Biblioteca; 0 adultos; 100% com pôster e motivo; ≥ 12 itens distintos com 3 favoritos de gêneros diferentes; avaliação do Manager "faz sentido" em ≥ 6 de 10 itens | Testes automatizados + avaliação do Manager |
| Custo | 0 leituras novas no Firestore; escritas = 1 por marcação; chamadas ao TMDB ≤ 1 por semente por 24 h | Revisão do Arquiteto/QA |

---

## 1. Conceito, vocabulário, ícones e navegação

> **CANCELADA (2026-10-03):** renomear Favoritos para Biblioteca, trocar ícones e rota `/library` não serão feitos. Vale a REVISÃO no topo.

### 1.1 Nome: **Biblioteca** (default) x Acervo
Recomendo **Biblioteca**.
- Curto (10 letras): cabe no rótulo da tab bar mobile (5 destinos) sem cortar em 320 px com fonte grande; "Acervo" também cabe, mas é menos comum no uso diário.
- Verbo natural e curto para botões: "Adicionar à biblioteca" / "Na biblioteca" / "Remover da biblioteca". "Acervo" soa institucional ("acervo do museu") e pede "Adicionar ao acervo", mais estranho.
- Padrão conhecido em apps de mídia (biblioteca de jogos, de músicas, de filmes).
- Risco: "biblioteca" pode sugerir "tenho o arquivo/posse". Mitigação: subtítulo do estado vazio e do convite: "Sua biblioteca de filmes e séries para acompanhar."

❓ **P1** Nome final: **Biblioteca** (default) ou Acervo?

### 1.2 Definições (contrato de produto)
- **Biblioteca:** conjunto de títulos (filme/série) que o usuário adicionou. Cada item tem progresso, assistido, concluído, `lastWatchedAt`. É exatamente o conjunto de documentos que existe hoje em `users/{uid}/favorites`.
- **Favorito:** marca booleana extra, sobre um item **que está na Biblioteca**. Significa "amo". Todo Favorito está na Biblioteca; nem todo item da Biblioteca é Favorito.
- **Recomendado:** título sugerido a partir dos Favoritos; **nunca** está na Biblioteca.

### 1.3 Ícones (reservar coração para o favorito de verdade)
| Ação | Ícone hoje | Ícone novo (default) |
|---|---|---|
| Adicionar/estar na Biblioteca (cartões, busca, detalhe) | coração (`favorite_border`/`favorite`) | `bookmark_add_outlined` (não está) / `bookmark_added` (está) |
| Tab bar | `favorite_border`/`favorite` | `video_library_outlined`/`video_library` (ou `bookmarks`) |
| Favorito (amo) | não existe | coração `favorite_border`/`favorite`, cor de destaque; selecionado = preenchido |
| Menu do topo do Início ("Meus favoritos") | `favorite` | `video_library` com rótulo "Minha biblioteca" |

Regras: ícone nunca é o único portador do estado (rótulo/tooltip/semântica sempre dizem o estado); contraste e alvo de toque ≥ 48 px no mobile (padrão atual); estado "adicionando…" com spinner como hoje.
Não usar estrela (confunde com nota/avaliação do TMDB, que o app já exibe nos detalhes).

### 1.4 Textos a renomear (checklist; QA usa como lista de busca)
Lista a partir de busca no código; o Arquiteto/Dev deve repetir a busca por "favorit" em `lib/`, `web/`, `README.md`, `test/`.

| Onde | Texto atual | Texto novo (default) |
|---|---|---|
| Tab bar (`app_shell.dart`) | "Favoritos" / tooltip "Meus favoritos" | "Biblioteca" / tooltip "Minha biblioteca" |
| Menu do Início (`home_screen.dart`) | "Meus favoritos" | "Minha biblioteca" |
| Título da tela (`favorites_screen.dart`) | "Meus favoritos" | "Minha biblioteca" |
| Botão do detalhe (`detail_actions.dart`) | "Favoritar" / "Remover dos favoritos" | "Adicionar à biblioteca" / "Remover da biblioteca" (estado: "Na biblioteca") |
| Semântica do botão do detalhe | "Favoritar {t}" / "Remover {t} dos favoritos" | "Adicionar {t} à biblioteca" / "Remover {t} da biblioteca" |
| Diálogo de remoção | "Remover dos favoritos?" | "Remover da biblioteca?" + texto novo (ver 3.3) |
| Erro parcial (`kPartialWriteMessage`) | "O título foi favoritado, mas não foi possível salvar o 'assistido'…" | "O título foi adicionado à biblioteca, mas não foi possível salvar o 'assistido'. Tente marcar de novo." |
| `kGoneMessage` | "Este título não está mais nos favoritos." | "Este título não está mais na sua biblioteca." |
| Busca: estado vazio (`search_screen.dart`) | "Busque algo para favoritar" | "Busque algo para adicionar à biblioteca" |
| Busca: tooltips/semântica da linha | "Favoritar {t}" / "Remover {t} dos favoritos" | "Adicionar {t} à biblioteca" / "Remover {t} da biblioteca" |
| Carrosséis (`discovery_section.dart`) tooltips | "Adicionar {t} aos favoritos" / "Remover {t} dos favoritos" | "Adicionar {t} à biblioteca" / "Remover {t} da biblioteca" |
| Estado vazio da lista (`favorites_section.dart`) | "Nenhum favorito ainda" / "…buscar um filme ou série e favoritar." | "Sua biblioteca está vazia" / "Toque na lupa para buscar um filme ou série e adicionar à biblioteca." |
| Grupo "Concluídos" vazio | "Tudo o que você favoritou já foi concluído…" | "Tudo o que está na sua biblioteca já foi concluído. Veja a aba Concluídos…" |
| Perfil (`profile_stats_card.dart`) | "Favoritos" (total), "Filmes favoritos", "Séries favoritas" | "Na biblioteca" (total), "Filmes na biblioteca", "Séries na biblioteca" **e** novo "Favoritos" (contagem do novo conceito) |
| Erro de sync/carga (`sync_widgets.dart`, `auth_gate.dart`) | "Não foi possível carregar/acessar seus favoritos agora…" | "…sua biblioteca agora…" |
| Convite de login (`account_widgets.dart`, docs/07) | "Entre para salvar seus favoritos e seu progresso…" | "Entre para salvar sua biblioteca e seu progresso em qualquer aparelho." |
| Convite de login ao tentar adicionar | "Entre para salvar seus favoritos" | "Entre para salvar na sua biblioteca" |
| Exclusão de conta (`delete_account_dialog.dart`) | "apaga para sempre seus favoritos, seu progresso e seu apelido" | "apaga para sempre sua biblioteca, seus favoritos, seu progresso e seu apelido" |
| Resumo de privacidade (`privacy_summary.dart`) | "listas (favoritos e progresso)" | "listas (biblioteca, favoritos e progresso)" |
| Política (`web/privacidade.html`) | "favoritar filmes e séries", "favoritos, filmes assistidos…", "apagamos seus favoritos…" | ver seção 4.6 |
| `web/index.html` e `web/manifest.json` (descrição) | "Favorite movies and TV shows…" | "Keep a library of movies and TV shows and track episode-by-episode progress." |
| README (descrição, nota de versão, "Excluir conta", lista de testes, estrutura) | "favoritar…", "Meus favoritos" | "adicionar à biblioteca…", "Minha biblioteca"; nota de versão do release (ver 2.5) |
| Rótulo de snackbars e Desfazer do assistido rápido (docs/30) | "Este título não está mais nos favoritos." | idem `kGoneMessage` |
| Rota | `/favorites` | `/library` (ver 1.5) |
| Documentos históricos docs/07–34 | usam "favoritos" | **não reescrever** (histórico). Este doc 35 passa a ser a fonte do vocabulário; nota de topo opcional |

Textos que **mantêm** a palavra "favorito" porque agora significam o conceito novo: botão/ação de coração, filtro "Favoritos", contador "Favoritos" no Perfil, seção de recomendações ("Porque você favoritou X"), estados vazios das recomendações.

Testes existentes que fixam strings antigas (`favorites_screen_test`, `home_screen_composition_test`, `favorite_heart_edge_test`, `details_before_favorite_test`, `quick_watched_test`, etc.) precisam ser atualizados; é parte do escopo, não regressão.

### 1.5 Navegação
- **Tab bar mobile (limite de 5):** hoje são 5 destinos: Início, Explorar, Busca, Favoritos, Perfil/Entrar. **A aba "Favoritos" vira "Biblioteca" na mesma posição.** Nenhuma aba nova. Os Favoritos **não** ganham aba própria (estouraria o limite de 5 e a tab bar tem folga zero).
- **Onde ficam os Favoritos (default):** dentro da Biblioteca, como terceiro filtro. O seletor atual (Todos/Filmes/Séries e Em andamento|Concluídos) ganha um chip alternável **"♥ Favoritos (n)"**, independente dos demais (combina com tipo e com grupo; contadores respeitam os filtros ativos, como hoje).
- Alternativas descartadas: (a) seção/carrossel "Seus favoritos" no topo da Biblioteca: ocupa espaço fixo e duplica itens; (b) aba própria: sem espaço; (c) só no Perfil: esconde o recurso que alimenta as recomendações.
- **Desktop/largura > breakpoint:** sem tab bar; o menu do topo do Início aponta para "Minha biblioteca"; o filtro funciona igual.
- **Rota:** nova `/library`; `/favorites` antiga **redireciona** para `/library` (PWA instalado, links e favoritos do navegador do usuário continuam funcionando; ninguém cai em "não encontrado").
- **Perfil:** o contador "Favoritos" abre a Biblioteca com o filtro Favoritos ligado (nice-to-have; não bloqueia).

❓ **P2** Onde ficam os Favoritos: **filtro/chip dentro da Biblioteca (default)** ou seção própria?
❓ **P3** Mostrar o coração (favoritar) também nos cartões das listagens (Início/Explorar/Busca)? **Default: não.** Nas listagens só o botão de Biblioteca (um botão por cartão, sem poluição); o coração fica no Detalhe e nos cartões da Biblioteca, onde o usuário já sabe se gosta. Se o Manager quiser coração em tudo, vira iteração 4.

---

## 2. Migração dos dados existentes (usuário real, ~54 itens)

> **CANCELADA:** não há renomeação nem estado Favorito/`loved`. Permanece válido o princípio (migração preguiçosa, campo ausente = não, sem escrita em massa), agora para `recommended`.

### 2.1 O que vira o quê
| Hoje | Depois |
|---|---|
| Documento em `users/{uid}/favorites/{id-tipo}` (qualquer um, assistido ou não) | Item da **Biblioteca**, idêntico. Progresso, assistido, concluído, `addedAt`, `lastWatchedAt`, `seasonSummaries`, `eps` inalterados |
| (nada) | Favorito = **falso** para todos |

- **Default: todos permanecem na Biblioteca; nenhum vira Favorito automaticamente.**
- **Não deduzir favoritos de "assistido/concluído".** Ter assistido não é amar (inclui obras que o usuário detestou; séries "em dia" ficam em Concluídos por regra técnica, não por gosto). Deduzir poluiria as recomendações, que é justamente o objetivo do pedido ("realmente o usuário goste").
- **Ajuda sem automatismo (default):** banner único e dispensável na primeira abertura da Biblioteca após o update: "Agora sua lista se chama Biblioteca. Toque no ♥ nos títulos que você ama para receber recomendações." com "Entendi". Estado "visto" guardado localmente (por aparelho, é só um aviso; reaparecer em outro aparelho é aceitável).
- **Iteração posterior (opcional):** assistente "Escolha seus favoritos" (lista da Biblioteca para marcar vários de uma vez, ordenada por concluídos/recentes). Seleção sempre manual.

❓ **P4** Migração de favoritos: **nenhum vira favorito automaticamente (default)** x sugerir marcação em lote (iteração 3) x deduzir de concluídos (não recomendo).

### 2.2 Nada pode ser perdido
- A migração é **preguiçosa e sem escrita em massa**: ausência do campo de favorito = "não favorito". Nenhum script, nenhum batch de 54 escritas, nenhuma janela de inconsistência.
- Ordem obrigatória de publicação (Manager): **primeiro regras do Firestore, depois o app** (ver seção 5). A fatia 1 (só renomear) não exige regras.
- Os contadores do Perfil antes/depois são o checklist de conferência do Manager.

### 2.3 Compatibilidade para trás
Cenários reais: aba do PWA aberta com versão antiga, segundo aparelho ainda não atualizado, service worker servindo build antigo por algum tempo.
- Versão antiga **lê** os documentos novos sem erro, ignorando o campo extra (o mapper atual lê só os campos conhecidos; confirmar com teste). Mostra tudo como "favoritos" (terminologia antiga); aceitável e temporário.
- Versão antiga **escreve** progresso por caminho de campo (`update` com `eps.x`, `watchedMovie`, `lastWatchedAt`): preserva o campo de favorito (update não mexe em outros campos). OK.
- **Risco real 1:** a adição inicial (`add`) usa `set(data)` completo no documento (`firestore_favorites_data_source.dart`). Se uma versão antiga "re-adicionar" um item existente (ex.: tela desatualizada), sobrescreve o documento e **apaga a marca de favorito**. Impacto baixo (o usuário remarca), mas o Arquiteto deve garantir que a versão nova nunca use `set` completo em item existente (ver caso de borda B6).
- **Risco real 2 (alto, para o Arquiteto):** as regras validam o documento resultante com `hasOnly([...])`. Depois que existir um documento com o campo novo, **qualquer `update` feito sob as regras antigas seria negado**. Logo, **não é permitido fazer rollback das regras** para a versão anterior depois que algum favorito tiver sido marcado, e a nova regra tem de ser publicada antes do app novo. Rollback do app, sim, é seguro (ele só ignora o campo).
- Semântica de progresso/assistido/concluído: **nenhuma mudança**. Marcar assistido continua adicionando à Biblioteca se o título não estiver (docs/15 e 30), e **não** marca favorito.

### 2.4 Revisão ao desfazer o release
Voltar ao app anterior reexibe tudo como "favoritos" antigos, com os dados íntegros. Documentar em README (nota de versão).

### 2.5 Comunicação ao usuário
Nota de versão no README e banner único (2.1): "Favoritos agora se chama Biblioteca. Favoritos passou a ser a sua seleção do que você ama."

---

## 3. Fluxos

> **CANCELADA** (fluxos Biblioteca/Favorito). Substituída por R.5. Reaproveitáveis: 3.7 (offline/concorrência/login).

### 3.1 Estados possíveis de um título para o usuário logado
1. Fora da Biblioteca
2. Na Biblioteca (não favorito)
3. Na Biblioteca e Favorito
(Não existe "Favorito fora da Biblioteca".)

### 3.2 Matriz de ações
| Ação | Origem | Efeito |
|---|---|---|
| Adicionar à Biblioteca | cartão de Início/Explorar/Busca/Recomendados, detalhe | cria o item (como o antigo "favoritar"); não favorito |
| Remover da Biblioteca | detalhe, cartão da Biblioteca, busca/carrossel | apaga o item e o progresso (**e o Favorito junto**, ver abaixo), com confirmação se houver progresso ou favorito |
| Favoritar (♥) | detalhe, cartão da Biblioteca | se já na Biblioteca: marca favorito; se não: **adiciona à Biblioteca e marca favorito numa única escrita** |
| Desfavoritar | detalhe, cartão da Biblioteca | só tira a marca; **o item permanece na Biblioteca**, com progresso |
| Marcar assistido rápido (check) | cartão da Biblioteca | inalterado; não altera favorito |
| Marcar assistido/episódio estando fora da Biblioteca | detalhe | inalterado: adiciona à Biblioteca e marca; não favorita |

### 3.3 Remover da Biblioteca remove o Favorito? **Sim (default).**
Favorito é subconjunto da Biblioteca; manter "favorito órfão" quebraria a invariante e as recomendações (a semente precisaria de dados de título que o documento carrega). Para não surpreender:
- Confirmação aparece se houver **progresso OU favorito**. Texto: "Remover da biblioteca? Isso apaga seu progresso neste título{, e ele deixa de ser um dos seus favoritos}." (a cláusula só aparece se for favorito). Botões Cancelar (foco inicial)/Remover.
- Sem progresso e sem favorito: remove direto (como hoje).
- Confirmação ao remover item favorito sem progresso: **sim** (default), porque perde o sinal de gosto, que é o ativo novo.

❓ **P5** Remover da Biblioteca também remove o Favorito: **sim, com confirmação (default)**. Alternativa: manter um registro separado de "favoritos" mesmo fora da Biblioteca (não recomendo: dobra dados e complica privacidade/exclusão).

### 3.4 Cartões nas listagens (Início, Explorar, Busca, Recomendados)
- Um único botão por cartão: **bookmark** (adicionar/na biblioteca). Mesma mecânica do coração atual (pendente com spinner, anti-duplo-toque, o toque no botão nunca navega, tocar no cartão abre o detalhe, igual docs/15).
- Remover a partir do cartão: segundo toque no botão, com a mesma confirmação da 3.3 (comportamento atual, apenas com texto novo).
- Item que é Favorito mostra no cartão apenas o bookmark "adicionado"; o coração não aparece aqui (P3). Opcional: um selo de coração pequeno e não interativo no pôster; **default: não**, para manter consistência.

### 3.5 Detalhe do título
Dois controles, lado a lado (empilhados em largura estreita), cada um com altura ≥ 48 px mobile:
1. **Biblioteca:** "Adicionar à biblioteca" (primário) → "Na biblioteca" (tonal, com check; toque remove, com a confirmação da 3.3). É o botão atual com novo rótulo.
2. **Favorito:** botão com coração: "Favoritar" → "Favorito" (preenchido). `toggle` com `selected` na semântica.
- Favoritar sem estar na Biblioteca adiciona à Biblioteca (3.2). Feedback em snackbar: "Adicionado à biblioteca e aos favoritos."
- Desfavoritar mantém o item; snackbar discreto "Removido dos favoritos" (sem diálogo; é reversível com um toque).
- Deslogado: tocar em qualquer um leva ao fluxo de login e, após logar, executa **a mesma intenção** (`PendingIntent`); cancelar login não faz nada (como hoje).
- O coração tem anti-duplo-toque e spinner próprios, independentes do botão da Biblioteca.

### 3.6 Cartão na Biblioteca (`FavoriteCard`)
Ordem na linha de ações: [check assistido rápido] [♥]. Ambos 48 px, tooltips/semântica próprios:
- ♥: "Favoritar {t}" / "Remover {t} dos favoritos" (aqui o termo antigo volta com sentido novo e correto: "dos favoritos" = desmarcar).
- Verificar a matriz já usada pelos testes de layout (320/360/768/1024/1440 px, fonte 1,5x e 2x, claro/escuro) sem overflow. Se a linha estourar, o coração vai para a linha de título e o check mantém a posição atual (decisão de design com o Arquiteto/UX; critério de aceite abaixo é o limite).
- Filtro "♥ Favoritos (n)": lista vazia com filtro ligado → estado vazio que ensina: "Você ainda não marcou favoritos. Toque no ♥ nos títulos que você ama para receber recomendações." Se o filtro de grupo (Em andamento/Concluídos) esconder todos os favoritos, a mensagem aponta para a outra aba (padrão já existente).

### 3.7 Offline, concorrência e login
- Todas as escritas seguem o padrão atual (`runWrite`/`runDetailWrite`): otimista com fila do SDK; deslogado → login → reexecuta; falha → snackbar de erro genérico/rejeição, como no docs/30.
- Offline: marcar/desmarcar favorito funciona localmente e sincroniza depois; **Recomendados** mostram o cache (ver 4.5) ou escondem a seção; nunca erro bloqueante.
- Dois aparelhos: favoritar no A e remover da Biblioteca no B → vence a ordem do servidor. Favoritar um item que sumiu não pode **recriar o documento sem progresso por acidente** quando o usuário só queria marcar (B7).

---

## 4. Recomendações

> **ADIADA (iteração futura):** passa a se chamar "Sugestões para você". Fora do escopo imediato; o desenho (TMDB, cache, privacidade) fica como referência.

### 4.1 O que são
Uma lista curta de filmes e séries que o usuário **ainda não tem na Biblioteca**, derivada dos seus **Favoritos**, com o motivo visível.

### 4.2 Onde aparecem
- **MVP:** seção **"Recomendados para você"** no Início (carrossel horizontal igual ao dos demais), posicionada logo abaixo de "Continue assistindo" (acima dos carrosséis genéricos).
- Cada cartão: pôster, título, ano/nota se disponíveis, **linha de motivo** ("Porque você favoritou {X}") e o botão bookmark (adicionar à biblioteca). Tocar abre o detalhe (que já funciona para título fora da Biblioteca, docs/15).
- **Página própria** "Para você" (grade completa, mais itens, filtro Filmes/Séries): iteração posterior; o MVP é só o carrossel. A seção tem "Ver tudo" apenas quando a página existir.
- Deslogado: a seção não aparece (não há Favoritos). O convite de login já existente passa a mencionar a biblioteca; opcional: um cartão "Entre e marque seus favoritos para receber recomendações" (default: não, para não poluir o catálogo livre).

### 4.3 Sinal e ativação
- **Semente (MVP): somente Favoritos.** Opcional futuro: concluídos recentes como sinal fraco (iteração 4). Não usar "assistido" como sinal no MVP (4.4 explica).
- **Mínimo para ativar:** **3 favoritos** (default). Com 0–2 favoritos, a seção mostra um cartão de estado vazio que ensina: "Marque 3 favoritos para receber recomendações" com progresso "1 de 3" e botão "Escolher favoritos" (abre a Biblioteca com o filtro ligado ou, se não houver favoritos, a Biblioteca normal). Com Biblioteca vazia: leva à busca.
- Por que 3 e não 1: com uma só semente a lista vira "mais do mesmo" de um título e a explicação "porque você favoritou X" fica monótona; 3 dá diversidade mínima. Custo do default: o usuário precisa de 3 toques para ver valor.

❓ **P6** Mínimo de favoritos para ativar a seção: **3 (default)** ou 1? (Com 1–2 poderíamos mostrar recomendações com aviso "Poucas informações ainda".)
❓ **P7** Sinal secundário no MVP: **somente Favoritos (default)**. Incluir concluídos como semente de peso menor na iteração 4?

### 4.4 De onde vêm (sem backend próprio, sem custo)
- **TMDB**, endpoints por título semente: `/movie/{id}/recommendations` e `/tv/{id}/recommendations`; se vierem poucos resultados, `/similar` como complemento. Mesma chave e mesmo cliente (`TmdbApiClient`) já usados, `language=pt-BR`, `include_adult=false`. **Não verifiquei** a resposta real desses endpoints nem a cota atual da chave: o Arquiteto/QA deve validar com chamadas reais (nunca imprimir a chave).
- **Regras de combinação (determinísticas, sem ML):**
  1. Sementes: até **8** favoritos por vez (se houver mais, rotacionar entre as últimas visitas para variar a cada dia, mantendo estáveis durante o dia).
  2. Juntar os resultados; remover duplicados; **título que aparece nas recomendações de mais de uma semente sobe** (sinal de afinidade com múltiplos favoritos).
  3. Excluir tudo que já esteja na Biblioteca (checagem na renderização, contra o stream ao vivo, para sumir na hora em que o usuário adiciona).
  4. Excluir adultos; exigir pôster; exigir mínimo de qualidade para evitar itens obscuros (ex.: `vote_count` ≥ 50 e `vote_average` ≥ 6; limites exatos a validar com dados reais).
  5. **Diversidade:** intercalar por semente (round-robin) e no máximo 3 itens por semente na lista final de ~20; misturar filmes e séries na proporção das sementes.
  6. Motivo: o título da semente que originou o item (se várias: "Porque você favoritou {X} e mais {n}").
  7. Tipo: recomendação de filme para semente de série é permitida (TMDB já faz por tipo; o app não força cruzamento).
- **Estável:** a lista não deve "pular" a cada abertura do app (cache, 4.5). Pull-to-refresh/“Atualizar” opcional na página própria (iteração futura).

### 4.5 Cache, cotas e desempenho
- Cache por semente (`discovery_cache` / Hive, local, TTL 24 h; chave por `{id}-{tipo}`), igual ao padrão de descoberta (ADR-002). Não grava recomendações no Firestore (zero escritas/leituras novas; Spark inalterado).
- Chamadas: ≤ 8 por 24 h por usuário em uso normal; concorrência limitada (como o catálogo, 3) e backoff existentes. TMDB gratuito para uso não comercial; manter a atribuição ao TMDB já exibida.
- Offline ou TMDB fora: usar cache expirado (marcar como "salvo no aparelho", sem destaque); sem cache: esconder a seção (falha de recomendação **nunca** vira erro de tela cheia nem toast; opcional estado discreto "Não foi possível carregar recomendações" com "Tentar novamente").
- Mudar os favoritos invalida só as sementes afetadas (nova semente = nova chamada; semente removida = some do resultado e do motivo).

### 4.6 Privacidade / LGPD
- Dados de gosto são pessoais. **Princípio:** mínimo necessário. Novo dado persistido: **um booleano por item da Biblioteca** (`favorito`), no mesmo documento já existente, na mesma região, com as mesmas regras de acesso (só o dono lê/escreve). Nenhum dado sensível novo, nenhum perfil de gosto derivado é armazenado.
- Nada de enviar dados do usuário a terceiros além do **id do título** (público) ao TMDB, que já recebe consultas de catálogo sem conta. Não enviar uid, e-mail, nome nem a lista inteira de favoritos de uma vez. O TMDB vê o IP da requisição do dispositivo (como já ocorre no catálogo).
- Sem telemetria nova. Sem compartilhar favoritos com outros usuários (não há social no escopo).
- **Política de privacidade** (`web/privacidade.html`, atualizar "Última atualização"): linha da tabela passa a "Sua biblioteca (títulos adicionados), quais deles você marcou como favoritos, filmes assistidos e episódios assistidos (com a data)"; acrescentar em "Quem processa": "Para sugerir títulos parecidos com os seus favoritos, o app consulta o TMDB enviando apenas o código público do título; não enviamos seu nome, e-mail nem sua conta"; "Como excluir": "apagamos sua biblioteca, seus favoritos, seu progresso e seu apelido". O resumo no app (`privacy_summary.dart`) acompanha.
- **Exclusão de conta:** o campo novo vive dentro do documento do item, então é apagado junto no fluxo atual de exclusão em lotes (sem nova coleção). Teste obrigatório: após excluir, nenhum documento nem cache de recomendação da conta permanece; o cache local de recomendações é apagado ao sair da conta ou, no mínimo, nunca mostrado para outra conta (mesmo cuidado de isolamento por uid do docs/08; o cache de catálogo é público, mas "motivo: porque você favoritou X" revela gosto, logo o cache de recomendações deve ser escopado por uid).
- Menor de idade: sem mudança de fluxo; adulto ocultado nas recomendações (e, hoje, na descoberta).

### 4.7 O que NÃO fazer
- Nada de ML/filtragem colaborativa própria, servidor, Cloud Functions, planos pagos ou coleta de comportamento.
- Sem recomendar o que já está na Biblioteca (inclusive o que o usuário abandonou: remover da Biblioteca é o caminho para "não quero ver isso", por ora).
- Sem "porque as pessoas parecidas com você…" (não temos dados de outros usuários).
- Sem compartilhar/exportar favoritos nesta entrega.
- Sem notificações push.

---

## Escopo

> **CANCELADO:** escopo vigente em R.6.

**Inclui**
- Renomeação completa de termos, ícones, rótulos, semântica, tooltips, diálogos, mensagens, Perfil, convite de login, política, README, descrição web.
- Aba/tela/rota Biblioteca (`/favorites` → `/library`).
- Novo estado Favorito (coração), no detalhe e na Biblioteca; filtro "Favoritos" na Biblioteca; contadores no Perfil.
- Seção "Recomendados para você" no Início com TMDB, regras de qualidade, cache, estados vazio/erro/offline.
- Ajuste de regras do Firestore e testes de regras; atualização dos testes automatizados.
- Compatibilidade com dados e versões atuais.

**Não inclui**
- Alterar progresso, assistido, concluído, Desfazer, ordenação por atividade (docs/18, 30).
- Pasta/coleção/"listas" múltiplas, tags, ordenação manual, notas pessoais, avaliação por estrelas.
- Recomendações por ML, social, compartilhamento, notificações.
- Renomear identificadores de código, coleção `favorites` do Firestore, nomes de arquivos (decisão do Arquiteto; não é visível ao usuário).
- Página "Para você" completa, "Não tenho interesse", assistente "Escolha seus favoritos", coração nas listagens (iterações, ver fatiamento).
- Reescrever docs históricos 07–34.

---

## Critérios de aceite (Gherkin)

> **CANCELADOS** (vocabulário Biblioteca/Favorito). Vigentes: R.7. Os de "Recomendações" voltam só na iteração das Sugestões.

```gherkin
# --- Vocabulário e navegação ---
Cenário: Tab bar mostra Biblioteca no lugar de Favoritos
  Dado que estou no mobile (largura <= breakpoint)
  Quando vejo a tab bar
  Então vejo exatamente 5 destinos: Início, Explorar, Busca, Biblioteca e Perfil (ou Entrar)
  E nenhum rótulo, tooltip ou semântica da tab bar contém "favorit"

Cenário: Nenhum texto antigo permanece
  Dado o app atualizado
  Quando percorro Início, Explorar, Busca, Detalhe (filme e série), Biblioteca, Perfil, diálogo de exclusão e login
  Então nenhum texto visível, tooltip, semântica ou mensagem de erro usa "favoritar"/"favoritos" com o sentido de adicionar à lista
  E "favorito/favoritos" só aparece no sentido do coração

Cenário: Link antigo continua funcionando
  Dado que tenho /favorites salvo nos favoritos do navegador ou o PWA instalado abrindo nessa rota
  Quando abro /favorites
  Então sou levado à Biblioteca (/library) sem tela de erro

# --- Migração ---
Cenário: Dados existentes preservados
  Dado que minha conta tem 54 itens, 20 filmes assistidos, N episódios assistidos e M séries concluídas
  Quando abro o app atualizado
  Então a Biblioteca tem os mesmos 54 itens com o mesmo progresso, ordem por atividade e datas
  E o Perfil mostra "Na biblioteca" = 54, o mesmo nº de filmes assistidos, episódios assistidos e séries concluídas
  E "Favoritos" = 0
  E nenhuma escrita em massa foi feita nos documentos

Cenário: Aviso de mudança aparece uma vez
  Dado que abro a Biblioteca pela primeira vez após o update neste aparelho
  Então vejo o aviso "Agora sua lista se chama Biblioteca. Toque no ♥ …" com "Entendi"
  Quando toco em "Entendi"
  Então ele não aparece mais neste aparelho

Cenário: Versão antiga aberta em outro aparelho
  Dado que marquei um favorito na versão nova
  E outro aparelho ainda roda a versão antiga
  Quando a versão antiga marca um episódio como assistido nesse mesmo título
  Então o título continua marcado como favorito na versão nova
  E a versão antiga não apresenta erro ao ler o documento com o campo novo

# --- Biblioteca: adicionar/remover ---
Cenário: Adicionar à Biblioteca a partir de um cartão
  Dado que estou logado e um título não está na minha Biblioteca
  Quando toco no botão bookmark do cartão
  Então o título entra na Biblioteca, o botão passa a "na biblioteca" e o tooltip/semântica dizem "Remover {título} da biblioteca"
  E o título não é favorito
  E o toque no botão não abre o detalhe

Cenário: Adicionar sem estar logado
  Dado que estou deslogado
  Quando toco em "Adicionar à biblioteca"
  Então vejo o convite "Entre para salvar na sua biblioteca"
  E, após logar com sucesso, o título é adicionado
  E, se cancelar o login, nada é adicionado

Cenário: Remover da Biblioteca item sem progresso e sem favorito
  Dado um título na Biblioteca sem progresso e que não é favorito
  Quando toco em "Remover da biblioteca"
  Então ele é removido sem diálogo

Cenário: Remover da Biblioteca item com progresso
  Dado um título com episódios assistidos
  Quando toco em "Remover da biblioteca"
  Então vejo o diálogo "Remover da biblioteca?" avisando que o progresso será apagado, com Cancelar em foco inicial
  Quando confirmo
  Então o item some da Biblioteca e do contador do Perfil

Cenário: Remover da Biblioteca item favorito
  Dado um título que é favorito, com ou sem progresso
  Quando toco em "Remover da biblioteca"
  Então o diálogo avisa que ele também deixa de ser favorito
  Quando confirmo
  Então o título sai da Biblioteca e dos Favoritos e o contador "Favoritos" diminui em 1

Cenário: Cancelar a remoção
  Dado o diálogo de remoção aberto
  Quando cancelo, toco fora ou pressiono Esc
  Então nada muda

Cenário: Falha ao salvar
  Dado que a escrita é recusada pelo servidor (permissão/cota) ou falha
  Quando adiciono ou removo um título
  Então vejo uma mensagem clara de erro e o estado volta ao anterior
  E nenhum item fica "meio-adicionado"

# --- Favoritos ---
Cenário: Favoritar item que já está na Biblioteca (detalhe)
  Dado um título na Biblioteca, não favorito
  Quando toco em "Favoritar"
  Então o botão passa a "Favorito" (selecionado) e o título aparece no filtro Favoritos
  E progresso e posição na ordem por atividade não mudam

Cenário: Favoritar item fora da Biblioteca
  Dado um título fora da Biblioteca
  Quando toco em "Favoritar" no detalhe
  Então o título é adicionado à Biblioteca e marcado como favorito numa única operação
  E vejo "Adicionado à biblioteca e aos favoritos"
  E, se a operação falhar, o título não fica na Biblioteca nem como favorito

Cenário: Desfavoritar mantém na Biblioteca
  Dado um título favorito com progresso
  Quando toco em "Favorito" para desmarcar
  Então ele deixa de ser favorito, continua na Biblioteca com o mesmo progresso e não há diálogo

Cenário: Favoritar a partir do cartão da Biblioteca
  Dado a Biblioteca com um título não favorito
  Quando toco no ♥ do cartão
  Então o ♥ fica preenchido, o toque não abre o detalhe e o botão de assistido rápido continua funcionando

Cenário: Filtro Favoritos
  Dado 54 itens na Biblioteca, 4 favoritos (2 filmes, 2 séries)
  Quando ativo o chip "Favoritos (4)"
  Então vejo só os 4, combinando com os filtros Filmes/Séries e Em andamento/Concluídos
  E os contadores dos grupos refletem o filtro

Cenário: Sem favoritos com filtro ligado
  Dado nenhum favorito
  Quando ativo o filtro Favoritos
  Então vejo "Você ainda não marcou favoritos…" e não um erro

Cenário: Deslogado tenta favoritar
  Dado que estou deslogado
  Quando toco em "Favoritar"
  Então sou levado ao login e, após logar, a intenção (adicionar e favoritar) é executada
  E cancelar o login não grava nada

Cenário: Offline
  Dado que estou offline
  Quando favorito, desfavorito ou adiciono um título
  Então a UI atualiza imediatamente e sincroniza ao reconectar, sem perder a marcação

Cenário: Interação com assistido rápido e Desfazer
  Dado um título favorito
  Quando marco a série inteira como assistida e depois toco em Desfazer
  Então o progresso volta como hoje (docs/30) e o título continua favorito
  E, se o título foi removido da Biblioteca nesse intervalo, o Desfazer informa "Este título não está mais na sua biblioteca."

Cenário: Assistido rápido não favorita
  Dado um título fora da Biblioteca
  Quando marco um episódio ou o filme como assistido
  Então ele entra na Biblioteca e não é favorito

# --- Perfil ---
Cenário: Estatísticas novas
  Dado 54 itens (30 filmes, 24 séries) e 4 favoritos
  Quando abro o Perfil
  Então vejo "Na biblioteca" 54, "Filmes na biblioteca" 30, "Séries na biblioteca" 24 e "Favoritos" 4
  E os demais contadores (assistidos, episódios, séries concluídas, tempo assistido) não mudam

# --- Recomendações ---
Cenário: Recomendações aparecem com favoritos suficientes
  Dado que estou logado com >= 3 favoritos
  Quando abro o Início
  Então vejo "Recomendados para você" abaixo de "Continue assistindo"
  E cada cartão mostra pôster, título e "Porque você favoritou {X}"

Cenário: Não recomendar o que já está na Biblioteca
  Dado uma recomendação visível
  Quando adiciono esse título à Biblioteca
  Então ele sai da seção imediatamente
  E nenhum título da Biblioteca aparece na seção em nenhum momento

Cenário: Qualidade e segurança do conteúdo
  Dado respostas do TMDB com itens adultos, sem pôster, duplicados e de baixa qualidade
  Quando a seção é montada
  Então esses itens não aparecem, não há repetidos e nenhuma semente contribui com mais de 3 itens

Cenário: Diversidade
  Dado 3 favoritos de gêneros diferentes
  Quando a seção é montada
  Então há itens ligados a cada semente (intercalados), não só da primeira

Cenário: Poucos favoritos
  Dado 1 ou 2 favoritos
  Quando abro o Início
  Então vejo o cartão "Marque 3 favoritos para receber recomendações" com "1 de 3" (ou "2 de 3") e o botão "Escolher favoritos"
  E nenhuma lista de recomendações

Cenário: Biblioteca vazia
  Dado nenhum item na Biblioteca
  Quando abro o Início
  Então o cartão de ativação leva à busca em vez da Biblioteca vazia

Cenário: Desfavoritar abaixo do mínimo
  Dado 3 favoritos e recomendações visíveis
  Quando desmarco um favorito
  Então a seção volta ao estado de ativação ("2 de 3")

Cenário: Remover a semente
  Dado uma recomendação com motivo "Porque você favoritou X"
  Quando X deixa de ser favorito
  Então nenhum cartão mostra X como motivo (itens que só vinham de X somem)

Cenário: Offline ou TMDB indisponível
  Dado que há cache de recomendações
  Quando estou offline
  Então vejo a seção com os itens salvos
  Dado que não há cache
  Quando estou offline ou o TMDB retorna erro/429
  Então a seção não aparece (ou mostra um aviso discreto com "Tentar novamente") e o resto do Início funciona normalmente
  E nenhuma tela de erro cheia

Cenário: Deslogado
  Dado que estou deslogado
  Então a seção "Recomendados para você" não aparece e os carrosséis genéricos continuam funcionando

Cenário: Troca de conta
  Dado que Ana tem recomendações em cache e sai da conta
  Quando Bruno entra
  Então nada da Ana (itens ou motivos) aparece para o Bruno

# --- Privacidade ---
Cenário: Dados enviados a terceiros
  Dado que a seção é carregada
  Então as requisições ao TMDB contêm apenas o id/tipo do título, a chave do app e o idioma
  E não contêm uid, e-mail, nome nem a lista de favoritos

Cenário: Excluir conta
  Dado uma conta com favoritos
  Quando concluo "Excluir minha conta e dados"
  Então biblioteca, favoritos, progresso e apelido são apagados
  E o cache de recomendações da conta é apagado ou inacessível
  E o diálogo de exclusão cita biblioteca e favoritos

Cenário: Política atualizada
  Dado o app atualizado
  Quando abro a política de privacidade
  Então ela descreve biblioteca, favoritos e a consulta ao TMDB por código de título, com nova data de atualização

# --- Segurança (regras) ---
Cenário: Regras aceitam o campo novo e rejeitam lixo
  Dado o campo de favorito publicado nas regras
  Então o dono consegue gravar favorito=true/false (booleano)
  E uma gravação com tipo errado (texto, número) ou campo desconhecido é negada
  E outro usuário não consegue ler nem gravar
  E documentos antigos sem o campo continuam atualizáveis
```

---

## Casos de borda

- **B1. Item favorito removido em outro aparelho enquanto o diálogo está aberto:** reler o estado após o diálogo (padrão docs/30, parte A); nada a remover → informar "não está mais na biblioteca".
- **B2. Mesmo título como filme e série (mesmo id numérico):** a chave composta `{id}-{tipo}` já resolve; favorito e recomendação devem usar a chave composta, e "já está na Biblioteca" compara id **e** tipo.
- **B3. Favorito com título removido do catálogo do TMDB (404) ou sem recomendações:** semente é ignorada em silêncio; se todas falharem, a seção some.
- **B4. Título recomendado que é continuação/mesma franquia do que o usuário já tem:** permitido (é o ponto de "gosto"); só não repetir o que já está na Biblioteca.
- **B5. Duplo toque no ♥ ou no bookmark:** anti-duplo-toque por chave (padrão atual); dois toques rápidos geram uma só escrita.
- **B6. Escrita que recria o documento sem progresso:** favoritar item que a UI acha que não está na Biblioteca, mas que existe em outro aparelho (cache desatualizado). A criação não pode sobrescrever progresso existente (o `add` atual é `set` completo). Exigir comportamento "criar só se não existir/preservar campos existentes" (Arquiteto).
- **B7. Favoritar item removido em outro aparelho (documento inexistente):** não ressuscitar silenciosamente com dados vazios se o usuário estava na Biblioteca (caso A) e sim informar; se estava fora da Biblioteca (caso de criação), adiciona normalmente.
- **B8. Troca de conta durante a operação:** nada é escrito na conta nova (padrão atual do docs/30: comparar uid).
- **B9. Dispositivos com relógio errado / `addedAt`:** a regra de `addedAt` só diminuir permanece; favoritar não mexe em `addedAt`, nem em `lastWatchedAt`. **Favoritar não deve reordenar a Biblioteca** (ordem por atividade = assistir, não gostar). Default: sem efeito na ordem.
- **B10. Muitos favoritos (ex.: 200):** só 8 sementes; rotação diária; sem custo adicional por favorito.
- **B11. Todas as recomendações já estão na Biblioteca:** seção escondida ou estado "Por enquanto não há novas sugestões"; nunca carrossel vazio.
- **B12. Primeira carga sem rede / documentos ainda carregando:** não mostrar "marque 3 favoritos" enquanto a Biblioteca está carregando ou falhou (evitar o falso estado vazio; mesmo princípio do docs/07: erro ≠ vazio).
- **B13. Acessibilidade:** coração e bookmark com rótulo, estado (`selected`/`toggled`) e alvo 48 px; anunciar resultado por região ao vivo (snackbar); foco visível por teclado; ícone nunca é o único indicador; contraste do coração nos temas claro e escuro; fonte 2x sem overflow; leitor de tela lê o motivo da recomendação ("Recomendado porque você favoritou X").
- **B14. Idioma:** títulos e sinopses em pt-BR via TMDB; se vier sem tradução, aceitar o título original (como já ocorre).
- **B15. Textos longos:** nome de semente com 300 caracteres (limite do título nas regras) truncado com reticências no motivo, completo na semântica.
- **B16. Cache local antigo ("Hive") de recomendações após logout:** não reutilizar entre contas (ver 4.6).
- **B17. PWA com service worker antigo:** usuário pode ver a UI antiga por um tempo; funciona (seção 2.3).
- **B18. Perfil durante a transição:** os rótulos novos nunca podem reaproveitar o rótulo "Favoritos" para o total antigo (por isso o total virou "Na biblioteca").

---

## 5. Impactos técnicos para o Arquiteto avaliar (sem decidir)

> **SUBSTITUÍDO** pelo docs/36, seção REVISÃO. Itens 1 a 4 (campo no documento, regras, compatibilidade, custo) continuam válidos com o campo `recommended`.

1. **Onde guardar a marca de favorito**
   - (a) Novo campo booleano no documento existente `users/{uid}/favorites/{key}` (zero leituras extras; mesmo ciclo de vida; exclusão de conta já cobre; atualização por campo é natural; sem coleção nova).
   - (b) Coleção separada (ex.: `users/{uid}/loved/{key}`): exige duas leituras/stream, risco de órfãos e duas escritas para "favoritar e adicionar" (não atômico sem batch), exclusão de conta precisa cobrir a nova coleção.
   - Inclinação do PA: (a), por menor custo e menos casos de borda; decisão do Arquiteto.
   - Em qualquer caso: leitura ausente = `false`; marcar não toca `addedAt`/`lastWatchedAt`; "favoritar + adicionar" atômico (B6/B7).
2. **`firestore.rules`:** `validFavorite` usa `hasOnly([...])`; precisa incluir a nova chave e validar o tipo (`is bool`, opcional como os demais). Como a regra valida o documento resultante, atualizações de documentos que já tenham o campo serão negadas por regras antigas: **publicação das regras antes do app, e proibido reverter as regras** depois de uso. Novos casos em `firestore_rules_test` (campo bool aceito, tipo errado negado, doc antigo sem campo atualiza, doc com campo atualiza, `addedAt` continua só diminuindo). **O Manager precisa republicar `firestore.rules` no console/CLI do Firebase antes do deploy da fatia 2** (a fatia 1 não precisa).
3. **Migração/compat:** nenhuma migração de dados (default ausente = falso). `FavoriteDoc`/`FavoriteItem`/mapper: campo opcional com default; `toJson/fromJson` com ausência tolerada; data source de `add` não pode sobrescrever campo existente. Versão antiga lê sem erro (teste). Rollback do app seguro.
4. **Custo Spark:** zero leituras novas (filtro, contagem e recomendações derivam do stream já assinado); 1 escrita por marcação/desmarcação; nenhuma escrita para recomendações. TMDB: cache por semente 24 h em Hive; limites de concorrência e backoff reutilizáveis (`CatalogReconciler`/cliente atual); novo método no `TmdbApiClient` para recommendations/similar com `include_adult=false`.
5. **Estatísticas do Perfil:** `ProfileStats` ganha "na biblioteca" (hoje `favorites`/`movies`/`series`, só rótulo) e novo contador de favoritos, calculados dos documentos (sem contadores gravados, como hoje). Atualizar `profile_stats_card.dart` e testes; garantir que nada reaproveite o antigo nome `favorites` com semântica trocada.
6. **Ordenação e filtros:** `byRecentActivity` permanece; favoritar não altera a ordem (B9). Filtro Favoritos é um terceiro eixo no estado da seção (junto de Todos/Filmes/Séries e Em andamento/Concluídos); contadores respeitam filtros.
7. **Navegação/rotas:** `/library` + redirect de `/favorites`; `app_shell.dart` (tab, ícones, tooltip), `home_screen.dart`, `go_router`.
8. **Recomendações:** provider (derivado de favoritos + biblioteca ao vivo), cache em `discovery_cache` com escopo por uid, política de seleção das sementes e de intercalação; testável sem rede com fake do cliente. Atenção a `ref.watch` sobre o stream para sumir itens adicionados.
9. **Detalhe:** dois controles independentes com estados e anti-duplo-toque separados; `FavoriteToggleButton`/`runDetailWrite`/`PendingIntent` precisam carregar a *intenção* (adicionar, favoritar, adicionar+favoritar) para a reexecução pós-login ser explícita e não toggle (princípio do docs/15).
10. **Renomeação de código:** identificadores `favorites*` podem ficar (invisíveis); o Arquiteto decide se renomeia para evitar confusão futura. Coleção Firestore `favorites` **não deve** ser renomeada (exigiria migração e quebraria versões antigas).
11. **Testes:** atualizar strings dos testes existentes; novos testes para os cenários acima; rodar a suíte de regras no emulador.
12. **Web:** `index.html`/`manifest.json` descrição; `privacidade.html` e `privacy_summary.dart`; README.

---

## Perguntas em aberto ❓ (todas com default; nenhuma bloqueia a fatia 1)

| # | Pergunta | Default recomendado | Bloqueia |
|---|---|---|---|
| P1 | Nome: Biblioteca ou Acervo | **Biblioteca** | fatia 1 (só texto; trocar depois custa pouco) |
| P2 | Favoritos: chip/filtro dentro da Biblioteca ou seção própria | **Chip/filtro** | fatia 2 |
| P3 | Coração também nos cartões de Início/Explorar/Busca | **Não** (coração só no Detalhe e na Biblioteca) | fatia 2 |
| P4 | Migração: algum item vira favorito automaticamente | **Não**; aviso único + (iteração 3) assistente manual; não deduzir de concluídos | fatia 2 |
| P5 | Remover da Biblioteca remove também o Favorito | **Sim, com confirmação** | fatia 2 |
| P6 | Mínimo de favoritos para ativar recomendações | **3** | fatia 3 |
| P7 | Concluídos como semente secundária | **Não no MVP** | iteração 4 |
| P8 | "Não tenho interesse" em uma recomendação (exige guardar item dispensado, mais um dado pessoal) | **Fora do MVP**; se entrar, local por aparelho (sem nova coleção) | iteração 4 |

---

## Fatiamento sugerido (MVP → iterações)

> **CANCELADO:** fatiamento vigente em R.10.

1. **Fatia 1 - Renomear (MVP A, sem mudança de dados nem de regras).** Biblioteca na tab bar/menu/título, textos (tabela 1.4), ícone bookmark no lugar do coração, rota `/library` com redirect, Perfil ("Na biblioteca"), convite/erros/diálogos, política e README, descrição web, testes atualizados. Nesta versão o coração **não existe** na interface (evita o mesmo ícone com dois significados no mesmo release). Entregável e reversível sozinho; já corrige o termo pedido pelo Manager. Pode ir ao ar sem republicar regras.
2. **Fatia 2 - Favorito (MVP B).** Campo + regras (Manager republica **antes** do app) + testes de regras + coração no Detalhe e nos cartões da Biblioteca + chip "Favoritos" + contador no Perfil + banner único + comportamento de remoção (3.3) + compat com versão antiga.
3. **Fatia 3 - Recomendados para você (MVP C).** Cliente TMDB (recommendations/similar), regras de qualidade/diversidade, cache por uid, seção no Início, estados vazio/offline/erro, texto de privacidade final.
4. **Iteração 4+.** Página "Para você" com "Ver tudo"; assistente "Escolha seus favoritos"; coração nas listagens (se P3 mudar); concluídos como sinal secundário; "Não tenho interesse"; atalho do Perfil para o filtro de favoritos.

Dependências: 3 depende de 2; 2 pode ser lançada sem 3, mas o usuário só vê valor do favorito com 3; por isso 2 e 3 devem sair próximas. Cada fatia atrás de commit/deploy separado, com plano de rollback (fatia 2: rollback só do app, nunca das regras).

---

## Decisões do Manager (2026-10-03)

> **SUPERADAS** pela mudança de direção do mesmo dia (R.1). Permanecem: zero perda de dados, regras antes do app, regras nunca revertidas, Fatia 0 de exportação.

O Manager aprovou **todos os padrões recomendados** nas perguntas ❓ acima. Este documento é, a partir de agora, **contrato fechado** para o Arquiteto: não há ❓ bloqueante em aberto. Decisões, por extenso:

- **P1 Nome:** "Biblioteca" (rótulos: "Adicionar à biblioteca", "Na biblioteca", "Remover da biblioteca", "Minha biblioteca"). Não usar "Acervo".
- **Ícones:** bookmark (`bookmark_add_outlined`/`bookmark_added`) para adicionar/estar na Biblioteca; tab "Biblioteca" com `video_library`; o coração fica reservado ao Favorito de verdade. Sem estrela.
- **Navegação:** a aba "Favoritos" vira "Biblioteca" na mesma posição (continuam 5 destinos na tab bar mobile); rota `/library`, com `/favorites` redirecionando para ela.
- **P2 Local dos Favoritos:** chip/filtro "♥ Favoritos (n)" dentro da Biblioteca, combinável com Todos/Filmes/Séries e Em andamento/Concluídos. Sem aba nem seção própria.
- **P3 Coração nas listagens:** não. Nos cartões de Início/Explorar/Busca/Recomendados só o botão de Biblioteca; o coração fica no Detalhe e nos cartões da Biblioteca.
- **P4 Migração:** todos os itens atuais (~54) permanecem na Biblioteca, com progresso, assistido e datas intactos; **nenhum vira Favorito automaticamente**; nada é deduzido de assistidos/concluídos. Migração preguiçosa (campo ausente = não favorito), sem escrita em massa. Banner único e dispensável "Agora sua lista se chama Biblioteca. Toque no ♥…". Assistente manual "Escolha seus favoritos" fica para a iteração 4+.
- **Favoritar:** favoritar um título fora da Biblioteca o **adiciona à Biblioteca e marca favorito numa única escrita**. Desfavoritar mantém o item na Biblioteca. Assistido rápido não favorita. Favoritar não altera a ordem por atividade.
- **P5 Remoção:** remover da Biblioteca também remove o Favorito, com confirmação quando houver progresso **ou** favorito.
- **P6 Recomendações:** seção "Recomendados para você" no Início, abaixo de "Continue assistindo"; ativa com **no mínimo 3 favoritos** (abaixo disso, cartão que ensina a favoritar com "n de 3"); fonte TMDB recommendations/similar por até 8 sementes, cache de 24 h por semente, escopado por uid, sem backend próprio nem escritas no Firestore; nunca recomenda o que está na Biblioteca; oculta adulto; exige pôster; diversidade (máx. 3 por semente); motivo "Porque você favoritou X"; sem ML próprio.
- **P7 Sinal secundário:** somente Favoritos no MVP; concluídos como semente ficam para a iteração 4+.
- **P8 "Não tenho interesse":** fora do MVP (iteração 4+; se entrar, local por aparelho).
- **Privacidade:** só um booleano novo por item, no documento existente; ao TMDB vai apenas o id/tipo do título; política de privacidade, resumo no app e diálogo de exclusão atualizados; exclusão de conta apaga tudo, inclusive o cache de recomendações da conta.
- **Publicação:** fatia 1 (renomear) sem mudar regras; na fatia 2 o Manager republica `firestore.rules` **antes** do app, e as regras **não podem ser revertidas** depois do primeiro favorito marcado.
- **Fatiamento aprovado:** 1 Renomear, 2 Favorito, 3 Recomendados, 4+ iterações.
