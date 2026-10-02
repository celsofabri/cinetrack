# Especificação — Login com Google, Perfil e dados por usuário na nuvem

> Autor: Product Analyst (squad) · Evolução de feature existente (fluxo 2). O Arquiteto entra em seguida: há mudança de fronteira de dados (local -> nuvem), autenticação e dados pessoais (LGPD).
> Depende de / evolui: [`docs/01-especificacao.md`](./01-especificacao.md), [`docs/05-especificacao-home-descoberta.md`](./05-especificacao-home-descoberta.md), [`docs/adr/adr-001-stack.md`](./adr/adr-001-stack.md).
> **Esta especificação não escolhe tecnologia.** Restrição de negócio dada pelo Manager: **custo zero (plano gratuito)**. O Manager citou Firebase "ou outra abordagem 100% gratuita"; a escolha é do Arquiteto (ADR).

## Problema
Hoje favoritos, progresso de episódios e "filme assistido" vivem **somente no Hive local** (`LocalStore`, box `favorites`), sem conta (README: "sem conta e sem sincronização entre dispositivos"). Consequências para o usuário (hoje, o próprio Manager):
- Trocar de aparelho, limpar dados do navegador (web/GitHub Pages) ou reinstalar o app **apaga tudo** (anos de histórico de séries).
- Web, Android e iOS são três "ilhas": o que se marca no celular não aparece no navegador.
- Não existe noção de "quem sou eu" no app: nenhuma tela de perfil, nenhum isolamento entre pessoas que usem o mesmo aparelho/navegador.

O ADR-001 assumiu "app pessoal, sem infra própria"; o pedido do Manager muda essa premissa (precisa de identidade e armazenamento remoto). Isso deve ser refletido em novo ADR pelo Arquiteto.

## Resultado esperado
1. O usuário entra com a conta Google e, em **qualquer dispositivo/plataforma**, vê os mesmos favoritos, progresso de episódios e filmes assistidos.
2. Existe uma **tela de Perfil** com dados vindos do Google, estatísticas simples e ações de conta (sair, excluir dados/conta).
3. Quem já usa o app **não perde nada**: os dados locais atuais são importados para a conta no primeiro login, com confirmação e verificação.
4. O app continua utilizável sem rede para quem já está logado (leitura e marcação), sincronizando depois.
5. Cada usuário só enxerga e altera os próprios dados.

## Métrica de sucesso
Sem telemetria remota (ADR-001), a métrica é comportamental/verificável por teste e por uso real do Manager:
- **Zero perda na migração:** após o primeiro login com dados locais, nº de favoritos, de episódios assistidos e de filmes assistidos na conta == nº existente localmente (antes da migração). Verificável por teste automatizado e conferido pelo Manager no próprio acervo.
- **Multi-dispositivo:** marcar um episódio no dispositivo A e abrir o app logado no dispositivo B mostra o episódio marcado (após sincronizar, com rede) sem ação manual além de abrir/atualizar o app.
- **Fricção de login:** do app aberto e deslogado até logado: no máximo 3 toques (ex.: "Entrar" -> escolher conta Google -> pronto).
- **Dependência de persistência local zerada em termos de risco:** limpar o armazenamento local do aparelho e logar de novo restaura 100% dos dados.

## Escopo

### Inclui
- **Login e logout com Google** em web, Android e iOS.
- **Estado deslogado** (ver default em Perguntas): navegar catálogo (Home/descoberta, Explorar, Busca, Detalhes) sem login; ações que gravam dados do usuário (favoritar, marcar assistido/episódio) exigem login e levam ao fluxo de entrar.
- **Persistência por usuário na nuvem** de: favoritos (incluindo os dados do item já mantidos hoje), `watchedMovie`, episódios assistidos por temporada, `addedAt`, `lastWatchedAt`.
- **Tela de Perfil** (nova rota, acessível pelo menu/topo da home): nome, foto, e-mail (do Google); data de entrada na conta; estatísticas; ações Sair e Excluir conta/dados.
- **Migração dos dados locais existentes** no primeiro login (importar, mesclar sem duplicar, verificar, não apagar sem confirmação).
- **Offline/falha de rede** para usuário já logado: leitura do cache, escritas enfileiradas e sincronizadas ao reconectar; indicador de estado de sincronização.
- **Troca de conta** (sair e entrar com outra conta Google) sem vazamento de dados entre contas.
- **Exclusão de dados e da conta** (direito de apagar, LGPD), com confirmação.
- **Isolamento entre usuários** (um usuário nunca lê/escreve dado de outro).
- **Tratamento de erros de login:** cancelado pelo usuário, sem rede, popup bloqueado (web), conta/serviço indisponível, falha genérica.
- Privacidade: texto curto na tela de login/perfil dizendo quais dados são guardados e para quê; link para política de privacidade (conteúdo mínimo, ver Perguntas).

### Não inclui
- Outros provedores de login (e-mail/senha, Apple, Facebook etc.) — ver ❓ sobre Apple no iOS.
- Compartilhamento de listas, perfil público, seguir outros usuários, recomendações sociais.
- Edição de foto/e-mail (vêm do Google; somente leitura).
- Mesclar duas contas Google distintas do mesmo usuário.
- Sincronização em tempo real com push entre dispositivos abertos simultaneamente (basta atualizar ao abrir o app/reconectar; tempo real é evolução futura).
- Exportação dos dados em arquivo (portabilidade) — fatia futura; ver Fatiamento.
- Notificações, telemetria/analytics, painel administrativo.
- Cache de catálogo TMDB (descoberta) por usuário — continua global e local, não vai para a conta.
- Qualquer mudança nas regras de negócio de progresso (`ProgressCalculator`) — são o contrato atual.

## Critérios de aceite

```gherkin
# --- Login / logout ---
Cenário: Login com Google bem-sucedido (primeira vez, sem dados locais)
  Dado que estou deslogado e não tenho dados locais antigos
  Quando toco em "Entrar com Google" e escolho minha conta
  Então fico logado
  E o app mostra meu nome e foto na área de perfil
  E meus favoritos aparecem vazios (estado vazio normal da home)

Cenário: Sessão persiste ao reabrir o app
  Dado que estou logado
  Quando fecho e reabro o app (ou recarrego a página na web)
  Então continuo logado sem escolher conta de novo

Cenário: Logout
  Dado que estou logado
  Quando toco em "Sair" no Perfil e confirmo
  Então volto ao estado deslogado
  E a tela inicial NÃO mostra nenhum favorito/progresso da conta que saiu
  E os dados da conta permanecem intactos na nuvem

Cenário: Login cancelado pelo usuário
  Dado que abri o seletor de conta do Google
  Quando fecho/cancelo o seletor
  Então continuo deslogado
  E NÃO vejo mensagem de erro assustadora (no máximo aviso neutro "Login cancelado")
  E posso tentar de novo

Cenário: Login sem rede
  Dado que estou deslogado e sem internet
  Quando toco em "Entrar com Google"
  Então vejo "Sem conexão. Conecte-se à internet para entrar."
  E continuo deslogado, sem travar

Cenário: Popup bloqueado na web
  Dado que estou na versão web e o navegador bloqueia o popup de login
  Quando toco em "Entrar com Google"
  Então vejo mensagem explicando que o popup foi bloqueado e como permitir
  E existe a opção de tentar novamente (ou alternativa de login sem popup, se o Arquiteto optar por isso)
  E o app não fica em estado de "carregando" infinito

Cenário: Falha genérica/serviço indisponível no login
  Dado que o serviço de autenticação retorna erro
  Quando tento entrar
  Então vejo mensagem de erro clara com "Tentar novamente"
  E nenhum dado local é alterado

Cenário: Duplo toque em "Entrar com Google"
  Dado que o login está em andamento
  Quando toco de novo no botão
  Então não é aberta uma segunda tentativa (botão desabilitado/indicador de progresso)

# --- Estado deslogado ---
Cenário: Deslogado navega o catálogo
  Dado que estou deslogado
  Quando abro o app
  Então vejo a Home com as seções de descoberta, e posso usar Explorar, Busca e Detalhes
  E vejo um convite claro para entrar ("Entre para salvar seus favoritos")

Cenário: Deslogado tenta favoritar
  Dado que estou deslogado
  Quando toco no coração de um item (em carrossel, busca ou detalhes)
  Então sou levado ao fluxo de login
  E, após logar com sucesso, o item que eu queria favoritar é favoritado (a intenção não se perde)
  E, se cancelar o login, nada é favoritado

Cenário: Deslogado tenta marcar episódio ou filme como assistido
  Dado que estou deslogado e vejo os detalhes de um título
  Quando tento marcar episódio/filme como assistido
  Então sou levado ao fluxo de login e nada é gravado antes de logar

# --- Perfil ---
Cenário: Ver dados do perfil
  Dado que estou logado com a conta "Ana Souza <ana@exemplo.com>"
  Quando abro a tela de Perfil
  Então vejo nome, foto e e-mail dessa conta
  E vejo estatísticas: total de favoritos, filmes favoritos, séries favoritas, filmes assistidos, episódios assistidos e séries concluídas

Cenário: Estatísticas refletem os dados reais
  Dado que tenho 3 filmes favoritos (1 assistido) e 2 séries com 5 episódios assistidos no total
  Quando abro o Perfil
  Então vejo 5 favoritos (3 filmes + 2 séries), 1 filme assistido e 5 episódios assistidos
  E os números mudam após eu marcar mais um episódio e voltar ao Perfil

Cenário: Perfil sem foto
  Dado que a conta Google não tem foto, ou a foto falha ao carregar
  Quando abro o Perfil
  Então vejo um avatar placeholder (iniciais ou ícone) e o layout não quebra

Cenário: Editar nome de exibição (se aprovado, ver ❓)
  Dado que estou no Perfil
  Quando altero o nome de exibição para "Ana" e salvo
  Então o novo nome aparece no app em todos os meus dispositivos
  E o nome vindo do Google não é sobrescrito na conta Google
  E nome vazio ou só com espaços é rejeitado com mensagem

# --- Persistência por usuário / multi-dispositivo ---
Cenário: Dados acessíveis em outro dispositivo
  Dado que estou logado no dispositivo A e favoritei "Breaking Bad" e marquei S1E1 como assistido
  Quando entro com a mesma conta no dispositivo B (ou na web)
  Então vejo "Breaking Bad" nos favoritos com S1E1 assistido

Cenário: Restaurar após limpar armazenamento local
  Dado que estou logado e tenho dados
  Quando limpo os dados locais do app/navegador e entro de novo
  Então todos os meus favoritos e progresso voltam

Cenário: Persistência das ações sem depender do cache local
  Dado que estou logado e com rede
  Quando favorito um item, marco um filme como assistido e marco um episódio
  Então as três ações são gravadas na conta do usuário
  E continuam lá após logout e novo login

Cenário: Marcações conflitantes em dois dispositivos
  Dado que no dispositivo A (offline) marquei S1E2 e no dispositivo B marquei S1E3
  Quando ambos sincronizam
  Então a conta fica com S1E2 e S1E3 marcados (nenhuma marcação some por causa da outra)

Cenário: Desmarcar em um dispositivo vence marcação mais antiga em outro
  Dado que S1E1 estava marcado em A e B
  Quando desmarco em A (mais recente) e B sincroniza depois sem alterar S1E1
  Então S1E1 fica desmarcado nos dois (a regra de resolução de conflito é determinística: último a alterar vence por item)

# --- Migração dos dados locais ---
Cenário: Primeiro login com dados locais existentes (caminho feliz)
  Dado que tenho 40 favoritos e progresso salvos localmente (Hive) e nunca fiz login neste aparelho
  Quando faço login com Google pela primeira vez
  Então o app mostra "Encontramos N favoritos neste aparelho. Importar para sua conta?" com "Importar" e "Agora não"
  E ao escolher "Importar" os 40 favoritos, seus episódios assistidos e filmes assistidos passam a existir na conta
  E vejo confirmação "Importados N itens"
  E a contagem na conta é igual à contagem local de antes

Cenário: Migração é verificada antes de qualquer limpeza local
  Dado que a importação terminou
  Quando o app confere que todos os itens existem na conta
  Então os dados locais legados NÃO são apagados automaticamente nessa operação
  E só deixam de ser usados após a verificação bem-sucedida

Cenário: Migração falha no meio (rede cai)
  Dado que a importação está em andamento
  Quando a conexão cai
  Então nenhum dado local é perdido ou alterado
  E vejo "Importação não concluída. Tentaremos de novo." com opção de tentar novamente
  E ao retomar, itens já importados não são duplicados (idempotente)

Cenário: Usuário escolhe "Agora não"
  Dado que o app ofereceu a importação
  Quando escolho "Agora não"
  Então os dados locais permanecem intactos no aparelho
  E posso importar depois a partir do Perfil ("Importar dados deste aparelho")

Cenário: Conta já tem dados na nuvem e o aparelho também tem dados locais
  Dado que minha conta já tem 10 favoritos e o aparelho tem 40 locais, 6 deles em comum
  Quando importo
  Então a conta fica com a união (44 itens), sem duplicatas
  E para itens em comum, episódios assistidos são a união dos dois lados e filme assistido = verdadeiro se qualquer lado marcou
  E nenhum item da nuvem é removido pela importação

Cenário: Dados locais são do usuário A e quem loga é o usuário B no mesmo aparelho
  Dado que existem dados locais legados e entro com uma conta que não é a do dono
  Quando o app oferece a importação
  Então é necessário confirmar explicitamente "Importar" (nunca automático)
  E "Agora não" mantém o legado fora da conta B

Cenário: Importação repetida
  Dado que já importei os dados locais para esta conta
  Quando faço logout/login de novo
  Então o app não oferece importar de novo os mesmos dados nem cria duplicatas

Cenário: Registro local corrompido ou antigo
  Dado que existe um registro local sem campos novos (ex.: sem lastWatchedAt) ou corrompido
  Quando importo
  Então registros válidos são importados (usando os mesmos defaults de FavoriteItem.fromJson)
  E registros ilegíveis são ignorados, contados e informados ("1 item não pôde ser importado") sem abortar o resto

# --- Offline / falha de rede ---
Cenário: Abrir o app offline estando logado
  Dado que estou logado e já sincronizei antes
  Quando abro o app sem internet
  Então vejo meus favoritos e progresso (do cache) normalmente
  E vejo indicador discreto de "offline/sem sincronizar"

Cenário: Marcar episódio offline e sincronizar depois
  Dado que estou logado e offline
  Quando marco um episódio como assistido
  Então a marcação aparece imediatamente na tela
  E, ao voltar a rede, ela é gravada na conta sem eu fazer nada
  E vejo o indicador mudar para "sincronizado"

Cenário: Falha de gravação na nuvem com rede ativa (erro do serviço)
  Dado que estou logado e o serviço de dados retorna erro
  Quando favorito um item
  Então o item aparece como favorito localmente e fica pendente de sincronização
  E vejo aviso discreto "Não foi possível sincronizar. Tentaremos de novo."
  E o app não perde a ação nem trava

Cenário: Primeiro login sem cache e sem rede após autenticar
  Dado que acabei de logar e a leitura dos meus dados na nuvem falhou
  Quando abro a home
  Então vejo estado de erro específico com "Tentar novamente" (não um estado vazio enganoso "você não tem favoritos")

Cenário: Sessão expirada/revogada
  Dado que minha sessão não é mais válida
  Quando o app tenta sincronizar
  Então sou avisado "Sessão expirada, entre novamente"
  E as alterações pendentes não são descartadas; são sincronizadas após novo login na mesma conta

# --- Troca de conta e isolamento ---
Cenário: Troca de conta
  Dado que estou logado como Ana
  Quando faço logout e entro como Bruno
  Então vejo apenas os dados do Bruno
  E nenhum favorito, progresso ou estatística da Ana aparece em nenhuma tela

Cenário: Alterações pendentes de Ana não vão para a conta do Bruno
  Dado que Ana tinha alterações offline ainda não sincronizadas e fez logout
  Quando Bruno entra no mesmo aparelho
  Então as alterações pendentes da Ana não são gravadas na conta do Bruno
  E ao Ana voltar a logar, ficam disponíveis para sincronizar (ou o app avisa que serão descartadas se o logout apagar o cache; ver ❓)

Cenário: Isolamento no servidor
  Dado que sou o usuário A autenticado
  Quando uma requisição tenta ler ou escrever dados do usuário B (identificador de B)
  Então a operação é negada
  E uma requisição sem autenticação para dados de usuário também é negada

# --- Exclusão (LGPD) ---
Cenário: Excluir conta e dados
  Dado que estou no Perfil logado
  Quando toco em "Excluir minha conta e dados" e confirmo (confirmação explícita, com texto de que é irreversível)
  Então todos os meus dados na nuvem (favoritos, progresso, dados de perfil) são apagados
  E a conta de login do app é removida
  E os dados locais dessa conta no aparelho são apagados
  E volto ao estado deslogado vendo mensagem "Conta excluída"

Cenário: Cancelar a exclusão
  Dado que abri a confirmação de exclusão
  Quando toco em "Cancelar"
  Então nada é apagado

Cenário: Exclusão exige login recente
  Dado que minha última autenticação foi há muito tempo e o serviço exige reautenticação
  Quando confirmo a exclusão
  Então sou pedido a entrar com Google novamente
  E a exclusão só ocorre após a reautenticação bem-sucedida da MESMA conta

Cenário: Exclusão falha (rede/erro)
  Dado que confirmei a exclusão e a operação falhou
  Quando o erro ocorre
  Então vejo "Não foi possível excluir. Tente novamente."
  E meus dados NÃO ficam parcialmente apagados de forma silenciosa (o estado é consistente ou a operação pode ser repetida até completar)

Cenário: Exclusão offline
  Dado que estou offline
  Quando tento excluir a conta
  Então vejo que preciso estar online e nada é apagado

Cenário: Recriar conta após excluir
  Dado que excluí minha conta
  Quando entro novamente com o mesmo Google
  Então começo como usuário novo, sem nenhum dado antigo

Cenário: Sair não apaga dados
  Dado que escolho "Sair" (e não "Excluir")
  Então nenhum dado da nuvem é removido
```

### Casos de borda
- **Dois dispositivos editando a mesma série ao mesmo tempo:** regra de merge determinística é requisito (união de episódios assistidos; para desmarcações, ver cenário de conflito). Não pode haver "perda silenciosa" de marcação. Mecanismo é do Arquiteto.
- **Mesmo `id` de TMDB para filme e série:** a chave composta atual (`'$id-${mediaType}'`, `FavoriteItem.storageKey`) deve ser preservada na nuvem.
- **Volume de dados:** séries com muitas temporadas/episódios (cache de `seasons`) podem ser grandes. Requisito de produto: nenhum limite do plano gratuito pode ser atingido sem aviso por uso normal de um usuário pessoal; o Arquiteto deve estimar tamanho por usuário vs. cotas gratuitas e dizer o que é guardado (ex.: só flags assistidas + referências, em vez de todo o catálogo cacheado, que pode ser rebaixado do TMDB).
- **Cota gratuita esgotada / serviço fora do ar:** o app não pode ficar inutilizável; cai no comportamento offline (leitura do cache, escritas pendentes) com mensagem honesta.
- **Relógio do dispositivo errado:** se a resolução de conflito usar timestamps, o Arquiteto deve considerar o risco (ex.: dispositivo com data no futuro "vencendo" sempre).
- **Troca de rede/instabilidade durante a gravação:** idempotência; sem duplicar favoritos em reenvio.
- **Aba duplicada na web / vários dispositivos logados:** logout em um dispositivo não desloga os outros; ações em ambos continuam válidas.
- **Cookies de terceiros/modo anônimo/privado no navegador:** login ou persistência de sessão pode falhar; mostrar mensagem, não tela vazia.
- **Conta Google sem nome/foto/e-mail visível:** campos opcionais; usar fallback (e-mail ou "Usuário").
- **Nome/foto mudaram no Google:** perfil reflete a versão mais recente a cada login (ou periodicamente); nome de exibição editado no app (se aprovado) não é sobrescrito.
- **Migração em aparelho com muitos dados e rede lenta:** progresso visível, cancelável, retomável; sem bloquear o uso do app inteiro.
- **App atualizado com Hive de versão anterior:** o esquema local existente continua legível (contrato atual); campos ausentes seguem os defaults de `FavoriteItem.fromJson`.
- **Acessibilidade:** botão de login, avatar, estatísticas e confirmações de exclusão com rótulos para leitor de tela; foto com texto alternativo; alvos de toque adequados; diálogo de exclusão operável por teclado na web.
- **Privacidade em logs/testes:** nenhum e-mail, nome ou token em log, handoff ou fixture de teste (TEAM.md/LGPD); testes usam contas/dados fictícios.
- **Segredos:** configuração de projeto do provedor escolhido não é segredo por si só, mas qualquer chave privada/secret nunca entra no repositório; GitHub Pages é público (o Arquiteto avalia o que pode ser exposto no cliente e como proteger por regras de acesso).
- **Domínio autorizado (web):** o login só funciona em domínios autorizados (GitHub Pages e localhost de dev); falha deve ter mensagem compreensível.
- **iOS:** ver ❓ sobre exigência de Sign in with Apple em app com login de terceiros publicado na App Store.
- **Estado de "carregando sessão" na abertura:** evitar piscar a tela de deslogado antes de saber se há sessão (splash existente).

## Perguntas em aberto ❓

Cada uma com default recomendado (adotado nesta spec se o Manager não responder).

**Precisam do Manager (impactam escopo/negócio):**
- ❓ **O app exige login para ser usado?** Default recomendado: **NÃO exige para navegar** o catálogo (Home/descoberta, Explorar, Busca, Detalhes); **exige para gravar** (favoritar, marcar assistido). Motivo: reduz fricção e preserva o valor de descoberta recém-entregue; consistente com "ter seus filmes e séries trackeados corretamente sem depender de persistência local". Alternativa: login obrigatório já na abertura (mais simples, pior primeira impressão).
- ❓ **Usuário deslogado pode favoritar "localmente" (modo convidado)?** Default: **não**; sem login nada é gravado, para não recriar a dependência de persistência local que o Manager quer eliminar. Os dados locais legados continuam no aparelho, intactos, esperando a migração. Consequência assumida: quem não logar deixa de ver seus favoritos antigos até logar (a home deslogada mostra convite para entrar e menciona que há dados no aparelho).
- ❓ **O que fazer com os dados locais depois da migração bem-sucedida?** Default: **manter uma cópia local legada (não apagar automaticamente)** e oferecer no Perfil "Remover cópia local deste aparelho" com confirmação. Segurança primeiro, dado o fato de que são dados reais do Manager.
- ❓ **Logout apaga o cache local da conta no aparelho?** Default: **sim, apaga o cache local dos dados do usuário no logout** (privacidade em aparelho compartilhado/web pública), **desde que não haja alterações pendentes de sincronização**; se houver pendências, avisar e pedir "Sincronizar e sair" / "Sair e descartar". 
- ❓ **iOS na App Store:** o app será publicado na App Store? Se sim, a Apple costuma exigir Sign in with Apple quando se oferece login de terceiros (e há custo de conta de desenvolvedor, fora do "100% gratuito"). Default: tratar iOS como build pessoal/sideload nesta versão e **não** incluir Sign in with Apple; se for publicar, abrir nova demanda.
- ❓ **Política de privacidade / aviso LGPD:** default: texto curto no app (dados guardados: identificador da conta, nome, e-mail, foto e suas listas; finalidade: sincronizar; como excluir) + página simples hospedada no próprio GitHub Pages. O Manager valida o texto (sem assessoria jurídica formal prevista).

**Decisões de produto de baixo impacto (default adotado, Manager só se discordar):**
- ❓ **Dados "pessoais" editáveis:** default: **nome e foto vêm do Google e são somente leitura**; **nome de exibição (apelido) editável dentro do app** (opcional, 1 a 40 caracteres). Mínimo necessário: não coletar telefone, data de nascimento, endereço etc. Se o Manager quiser mais campos (ex.: idioma, gêneros favoritos), vira fatia futura.
- ❓ **Estatísticas do perfil:** default: favoritos (total/filmes/séries), filmes assistidos, episódios assistidos, séries concluídas, "membro desde". Calculadas a partir dos dados (sem armazenar contadores duplicados, a critério do Arquiteto).
- ❓ **Local do Perfil na navegação:** default: ícone/avatar no topo da home (junto ao menu atual), que abre `/profile`; deslogado mostra botão "Entrar".
- ❓ **Resolução de conflito:** default: união de episódios assistidos; para desmarcar, o último a alterar por episódio vence; `addedAt` mantém o mais antigo; `lastWatchedAt` o mais recente. Arquiteto confirma viabilidade.
- ❓ **Retenção após exclusão:** default: **nenhuma** (apagar de fato, sem retenção de backup do app); o Arquiteto informa se o provedor mantém backups técnicos por prazo e isso é comunicado ao Manager.

**Para o Arquiteto (técnicas, não decidir aqui):** provedor de auth e armazenamento gratuito; modelo de dados na nuvem; regras de segurança/isolamento; estratégia offline e fila de sincronização; cota gratuita vs. volume esperado; login com popup vs. redirect na web; estratégia de testes sem depender de conta Google real (fakes/emuladores).

## Fatiamento sugerido

1. **Fatia 1 — Identidade:** login/logout com Google nas 3 plataformas, sessão persistente, estado deslogado (navegar catálogo; gravar exige login), tratamento dos erros de login. Perfil mínimo (nome, foto, e-mail, Sair). *Sem mexer ainda na persistência: valida identidade e a configuração por plataforma (incluindo domínio do GitHub Pages).*
2. **Fatia 2 — Dados por usuário na nuvem + isolamento:** favoritos, `watchedMovie` e episódios assistidos gravados/lidos por usuário, com cache local por usuário e regras de acesso restritas ao dono; logout limpa/isola cache; troca de conta.
3. **Fatia 3 — Migração dos dados locais:** detecção no primeiro login, importação idempotente com merge e verificação, relatório de itens importados/ignorados, importação adiada a partir do Perfil. **Deve ser entregue junto ou imediatamente após a Fatia 2, antes de o Manager passar a usar o app logado como fonte principal.** *Recomendação de rollout: backup manual do Hive (cópia do acervo) antes de liberar, já que são dados reais.*
4. **Fatia 4 — Offline e sincronização robusta:** fila de pendências, indicador de estado, resolução de conflito multi-dispositivo, sessão expirada, quota/serviço indisponível.
5. **Fatia 5 — Perfil completo e conta:** estatísticas, nome de exibição editável, "Remover cópia local", **exclusão de conta/dados** (obrigatória antes de abrir o app a terceiros; se só o Manager usar, ainda assim é requisito desta versão).
6. **Fatia 6 (futura):** exportação dos dados (portabilidade), sincronização em tempo real entre dispositivos abertos, outros provedores de login.

> Observação de ordem: a Fatia 5 (exclusão) deve estar pronta antes de qualquer pessoa além do Manager ter acesso ao app em produção.

## Definition of Done
- [x] Critérios de aceite escritos em Gherkin, com caminhos de erro, verificáveis por teste (unit: merge/migração/estatísticas/regra de conflito; widget: estados de login, perfil, deslogado, diálogos; integração/regras: isolamento entre usuários e exclusão, via emulador ou fake a critério do Arquiteto).
- [x] Cada ❓ tem default recomendado.
- [ ] ❓ marcadas "Precisam do Manager" respondidas ou defaults aprovados (as bloqueantes de verdade: modo deslogado/exigência de login, destino dos dados locais após migração, iOS na App Store).
- [ ] QA revisa a testabilidade dos critérios (próxima etapa).
- [ ] Arquiteto produz ADR (auth + armazenamento gratuito + segurança + offline + migração) antes de qualquer implementação.
