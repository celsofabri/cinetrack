# 49 - Especificação: Amizades (feature 1 de 5 do conjunto social)

> Autores: Product Analyst + Arquiteto · Data: 2026-10-05 · Design: [docs/50](./50-design-amizades.md) · Decisão: [ADR-005](./adr/adr-005-modelo-social-amizades.md) (Proposta).
> **Esta rodada só documenta.** Nenhum código foi escrito, nenhum arquivo existente foi alterado. Base: `main` em `9b5220c`.
> Próximas features que dependem desta base: F2 perfil de amigo (snapshot de estatísticas/atividades/recomendados com opt-in), F3 ranking entre amigos (montado no cliente), F4 avaliações 1–5 com meia estrela e média dos amigos, F5 comentários com visibilidade Amigos/Privado.

---

## Etapa 1 - Análise do código atual

### Como as peças funcionam hoje (lido em `main`)
- **Dados e regras.** `firestore.rules` tem só `users/{uid}` (leitura/exclusão do dono; escrita do dono com `validProfile()`: `hasOnly(['displayName','schemaVersion','updatedAt','deleting'])`, apelido 1–40) e `users/{uid}/favorites/{key}` (`validFavorite`, incl. `recommended`). Todo o resto cai em `match /{document=**} { allow read, write: if false; }`. Não há nenhuma noção de "outro usuário": `isOwner(uid)` é a única função. `firestore.indexes.json` está vazio.
- **Perfil.** `ProfileDataSource` (`lib/data/profile_data_source.dart`) observa `users/{uid}` e expõe `UserProfile{nickname, deleting}`; `setNickname` faz `set(merge)` com `displayName` (ou `FieldValue.delete()`), `schemaVersion: 1`, `updatedAt`. Nome, e-mail e foto vêm do Google em tempo de execução e **não são copiados para o banco** (afirmado em `PrivacySummary`, na política `web/privacidade.html` e no ADR-003). `ProfileScreen` mostra avatar, apelido, estatísticas, privacidade, exportar, sair e excluir.
- **Exclusão de conta.** `AccountDeleter.run`: reautentica o mesmo uid → `ensureOnline()` (leitura `Source.server`) → `markDeleting()` (`users/{uid}.deleting = true`) → `deleteAllFavorites()` (páginas de 400 lidas do servidor, `wipeInPages`, teto de 500 páginas) → `deleteProfile()` → `deleteCurrentUser`. Cada passo é idempotente e retomável; `guardDeletionStep` traduz timeout/erros em `AccountDeletionFailure` (escrita com timeout = "incerto"). Depois da exclusão marca a limpeza do cache do Firestore no navegador (`markFirestoreCachePurge`). **Nada disso conhece dados fora de `users/{uid}`.**
- **Exportação.** `ExportDataSource` lê `users/{uid}/favorites` paginado por id e `users/{uid}`; `ExportSerializer` escreve o JSON (`kExportSchemaId = 'cinetrack-export'`, `kExportSchemaVersion = 1`). Os documentos são exportados "brutos", então campos novos em `favorites` entram sozinhos; **coleções novas não entram.**
- **Navegação.** `routerProvider` (go_router): `ShellRoute` com `/`, `/favorites`, `/recommendations`, `/catalog`, `/search`, `/profile`; detalhes fora do shell. O `redirect` só protege `/profile` (deslogado vai a `/`; durante o carregamento da sessão não redireciona). `AppShell` (≤768 px, `kMobileBreakpoint`): `MobileTopBar` (logo, lupa `/search`, `SyncIndicator`) + `NavigationBar` com **5 destinos**: Início, Explorar, Recomendo, Favoritos, Perfil/Entrar. Em `/search` o destino Explorar é o selecionado. Desktop (≥769 px): cada tela tem seu AppBar/menu do topo (`_NavAction` em `home_screen.dart`: ícone+rótulo a partir de 960 px × fator de fonte, só ícone abaixo).
- **Cache offline.** `persistenceEnabled: true` (`firebase_bootstrap.dart`). O cache do Firestore é por dispositivo, não por uid: o isolamento atual vem de **todas as consultas serem parametrizadas pelo uid** (caminho `users/{uid}/...`). As consultas sociais precisam manter essa propriedade (sempre filtrar pelo uid atual).
- **Testes.** Fakes (`FavoritesDataSource`, `ProfileDataSource`) sem Firebase no `flutter test`; regras no emulador em `firestore_rules_test/` (`npm test`, `--test-concurrency=1`).

### O que a feature muda (impacto)
| Área | Hoje | Preciso |
|---|---|---|
| Regras | só dono | funções `isFriend/isBlocked`, 5 coleções novas, nenhuma alteração em `users/{uid}` nem `validProfile` |
| Perfil | apelido, estatísticas | seção "Amigos e privacidade" (ativar, handle, aparecer na busca, foto) |
| AccountDeleter | favoritos + perfil | novo passo "dados sociais" (social+handle, pedidos, pares, bloqueios) antes dos favoritos |
| Exportação | favoritos + perfil | seção `social` no JSON (schema 2) |
| Rotas | `/profile` protegida | `/friends` e `/friends/add` protegidas (mesmo redirect) |
| Navegação | 5 abas cheias | **sem 6ª aba**: entrada Amigos na barra superior (mobile) e no menu do topo (desktop) + indicador de pedidos |
| Privacidade | "foto não vai para o banco" | a foto do Google passa a ser copiada **se o usuário ativar e aceitar** (texto + política mudam) |

### Riscos principais
1. **Privacidade por construção.** Qualquer regra frouxa expõe dados a não amigos. Mitigação: cartão público mínimo e separado; suíte de regras de negação.
2. **Limite de 10/20 chamadas `get/exists` por requisição** e cobrança de cada uma como leitura: obriga `isFriend` de 1 chamada e snapshots dentro dos documentos lidos (docs/50 §7).
3. **Cota Spark é do projeto** (50 mil leituras/dia): lista de amigos = N leituras; precisa de cache e de não manter listeners amplos.
4. **Consistência sem servidor**: depende de batches do cliente e de invariantes nas regras (bloqueio ⇒ sem amizade; amizade ⇒ pedido consumido).
5. **Spam de pedidos** (regras não contam documentos) e handle ofensivo (sem moderação).
6. **Exclusão/exportação**: se o primeiro dado social for gravado antes do `AccountDeleter`/exportação cobri-lo, há violação de LGPD. Por isso a Fatia 1 inclui os dois.
7. **Rollout**: regras sem volta; índices precisam estar "Enabled" antes do app consultar.
8. **Emulador ≠ produção**: limite de chamadas medido no emulador; cobrança de leituras de regra só pela documentação.

### Perguntas em aberto da etapa 1
Ver ❓ abaixo e "Decisões a validar com o Manager" (D1–D11).

---

## Amizades entre usuários do CineTrack

**Problema:** Hoje o CineTrack é uma ilha: ninguém vê o que o outro assiste ou recomenda. Para quem quer comparar gostos com pessoas que conhece (primeiro o próprio Manager e seus amigos), falta o vínculo básico e seguro entre duas pessoas, sem expor a ninguém mais os favoritos privados.
**Resultado esperado:** Duas pessoas conseguem se encontrar, pedir, aceitar, desfazer e bloquear amizade dentro do app, com revogação imediata nos dois sentidos, sem mudar nenhum dado existente e sem que usuários atuais precisem fazer nada.
**Métrica de sucesso** (o app não tem telemetria, então é verificável por teste e uso real):
- Do Perfil ao pedido enviado: ≤ 6 toques (Amigos → Adicionar → digitar @ → buscar → Adicionar → confirmar).
- **Zero vazamento**: suíte de regras prova que não amigo/bloqueado/anônimo não lê nenhum dado do outro (100% dos casos negativos passam).
- **Zero perda**: favoritos, progresso e apelido de qualquer conta existente idênticos antes/depois (regras antigas + novas passam a suíte existente de 76 testes).
- Abrir a lista de amigos custa ≤ N+3 leituras (N = amigos) e é servida do cache quando offline.

### Escopo
- Inclui:
  - **Ativação opt-in** do social no Perfil: escolher handle único (`@maria_silva`), confirmar apelido, mostrar ou não a foto, e a opção **"Aparecer na busca"** (ligada/desligada).
  - **Busca por handle exato** (sem busca por nome/prefixo) com resultado mínimo: handle, apelido e avatar.
  - **Pedido de amizade**: enviar, cancelar (remetente), aceitar, recusar (destinatário); sem duplicados; **pedido cruzado vira amizade**.
  - **Lista de amigos** e **pedidos pendentes** (recebidos e enviados), com **indicação visível de recebidos** (contador).
  - **Remover amigo**: sem notificar; some dos dois lados.
  - **Bloquear** (desfaz amizade e cancela pedidos; o bloqueado não encontra, não pede, não vê nada e não é avisado) e **tela de bloqueados** com desbloquear (não restaura a amizade).
  - Trocar de handle (1 vez a cada 30 dias, default) e desativar o social.
  - Funções de regra reutilizáveis `isFriend(a, b)` e `isBlocked(a, b)` para F2–F5.
  - Cobertura em **exclusão de conta** (usuário some da lista dos outros), **exportação**, **política/resumo de privacidade** e README.
- Não inclui:
  - Perfil de amigo, estatísticas, atividades, recomendados (F2); ranking (F3); avaliações (F4); comentários (F5).
  - Notificações push/e-mail (a indicação de pedidos é dentro do app).
  - Busca por nome/prefixo, sugestão de amigos, importar contatos, grupos, amigos de amigos.
  - Denúncia/moderação de handle ou apelido (sem servidor).
  - Limites **impostos no servidor** (contagem de amigos/pedidos): só no app.
  - Tempo real além do contador de pedidos recebidos.
  - Convite por link com código (recomendado como Fatia 5; regras do convite **não** foram validadas nesta rodada).

### Critérios de aceite
```gherkin
# --- Ativação e privacidade ---
Cenário: Usuário atual não precisa fazer nada
  Dado que tenho conta com favoritos e não ativei amizades
  Quando abro o app depois da atualização
  Então vejo meus favoritos, progresso e apelido como antes
  E nenhum dado meu foi copiado para fora de "users/{uid}"
  E ninguém consegue me encontrar nem me enviar pedido

Cenário: Ativar amizades com handle livre
  Dado que estou logado e tenho apelido "Ana"
  Quando abro Perfil > Amigos e privacidade, escolho "@ana_9" e confirmo
  Então "@ana_9" fica reservado só para mim
  E meu cartão (handle, apelido, foto se eu permiti) fica pesquisável por handle exato

Cenário: Handle já em uso
  Dado que "@maria" pertence a outra pessoa
  Quando tento ativar com "@maria"
  Então vejo "Esse identificador não está disponível" e nada é criado

Cenário: Handle inválido
  Quando digito "Ab", "a b", "_ana", "ana_", "admin" ou mais de 20 caracteres
  Então o campo mostra o erro em português e o botão "Ativar" fica desabilitado

Cenário: Disputa simultânea pelo mesmo handle
  Dado que duas pessoas confirmam "@disputa" ao mesmo tempo
  Então exatamente uma conclui e a outra vê "não está disponível"

Cenário: Ficar fora da busca
  Dado que desliguei "Aparecer na busca"
  Quando outra pessoa (não amiga) busca meu handle exato
  Então ela vê "Nenhum usuário encontrado" (igual a handle inexistente)
  E eu continuo podendo buscar outras pessoas, enviar pedidos e aceitar pedidos que me enviarem

Cenário: Trocar handle
  Dado que troquei de handle há mais de 30 dias
  Quando escolho um novo livre
  Então o novo vale, o antigo fica livre para outras pessoas e meus amigos continuam amigos
Cenário: Trocar handle cedo demais
  Dado que troquei há 10 dias
  Quando tento trocar de novo
  Então vejo "Você poderá trocar de novo em <data>" e nada muda

Cenário: Remover o apelido com amizades ativas
  Quando tento apagar meu apelido
  Então o app pede para manter um apelido ou desativar amizades

# --- Busca e pedido ---
Cenário: Buscar e enviar pedido
  Dado que "@bruno" está visível na busca
  Quando busco "bruno" (maiúsculas e espaços são normalizados) e toco "Adicionar amigo"
  Então vejo o cartão (apelido, avatar, @bruno) e, depois do toque, "Pedido enviado"
  E "@bruno" aparece em Pedidos > Enviados

Cenário: Buscar quem me bloqueou, quem está oculto ou não existe
  Quando busco o handle
  Então a mensagem é a mesma nos três casos: "Nenhum usuário encontrado"

Cenário: Pedido duplicado
  Dado que já enviei pedido a Bruno
  Quando tento enviar de novo
  Então vejo "Você já enviou um pedido" e nenhum segundo documento é criado

Cenário: Já são amigos
  Quando busco um amigo atual
  Então o cartão mostra "Já são amigos" e não oferece "Adicionar"

Cenário: Pedido cruzado
  Dado que Ana enviou pedido a Bruno
  Quando Bruno busca Ana e toca "Adicionar amigo"
  Então viram amigos de imediato, o pedido de Ana é consumido e não sobra pendência

Cenário: Cancelar pedido enviado
  Quando cancelo o pedido
  Então ele some das duas listas e posso enviar outro depois

Cenário: Aceitar
  Dado que Ana tem pedido recebido de Bruno
  Quando toca "Aceitar"
  Então Bruno aparece em Amigos para Ana e Ana para Bruno, e o pedido some
Cenário: Recusar
  Quando Ana toca "Recusar"
  Então o pedido some e Bruno não recebe aviso

Cenário: Um lado não cria amizade sozinho (regras)
  Quando um cliente tenta gravar o documento de amizade sem pedido do outro lado
  Ou o remetente tenta "aceitar" o próprio pedido
  Ou um terceiro tenta usar o pedido alheio
  Então o Firestore nega (permission-denied) e nada é criado

# --- Lista, remover ---
Cenário: Lista de amigos
  Dado que tenho 3 amigos
  Quando abro Amigos
  Então vejo os 3 em ordem alfabética com apelido e avatar
Cenário: Indicação de pedidos recebidos
  Dado que tenho 2 pedidos pendentes recebidos
  Quando estou em qualquer tela logado
  Então vejo o contador "2" no ícone Amigos e ele é lido por leitores de tela ("2 pedidos de amizade recebidos")

Cenário: Remover amigo
  Quando removo Bruno e confirmo
  Então Bruno some da minha lista e eu da dele, sem aviso, e ele deixa de ver qualquer dado meu na hora
  E não preciso apagar nada nas outras features

# --- Bloquear ---
Cenário: Bloquear amigo
  Dado que Bruno é meu amigo e há pedidos pendentes entre nós
  Quando bloqueio Bruno e confirmo
  Então a amizade e os pedidos somem nos dois lados, no mesmo instante
  E Bruno não me encontra na busca, não me envia pedido, não vê nada meu e não é avisado
  E eu também não o encontro nem peço amizade enquanto ele estiver bloqueado

Cenário: Desbloquear
  Quando desbloqueio Bruno
  Então ele sai da lista de bloqueados e a amizade NÃO volta; qualquer um pode enviar novo pedido

Cenário: Bloqueio parcial é impossível (regras)
  Quando um cliente grava o bloqueio sem desfazer a amizade ou os pedidos no mesmo batch
  Então o Firestore nega

# --- Exclusão e exportação ---
Cenário: Excluir conta
  Dado que tenho amigos, pedidos, bloqueios e handle
  Quando excluo minha conta
  Então handle, cartão, pares, pedidos (enviados e recebidos) e bloqueios são apagados
  E meus ex-amigos deixam de me ver na lista
  E o handle fica livre
Cenário: Exclusão interrompida no meio e retomada
  Quando a exclusão falha após apagar os pares
  Então ao retomar o app conclui sem erro (passos idempotentes)

Cenário: Exportar meus dados
  Quando exporto
  Então o JSON traz a seção social (handle, preferências, amigos com uid e apelido, pedidos, bloqueios)

# --- Estados e erros ---
Cenário: Sem login
  Quando abro /friends deslogado
  Então vou para o início (como /profile) e o ícone Amigos não aparece
Cenário: Offline
  Dado que estou sem rede
  Quando abro Amigos
  Então vejo a última lista do cache com o aviso "Sem conexão"
  E enviar/aceitar/bloquear/remover ficam desabilitados com "Sem conexão. Tente de novo quando estiver online."
Cenário: Regras ainda não publicadas
  Quando o servidor responde permission-denied na ativação
  Então vejo "Amizades ainda não estão disponíveis. Tente mais tarde." e nada quebra no resto do app
Cenário: Cota diária esgotada
  Quando o servidor responde resource-exhausted
  Então vejo "Muitas operações hoje. Tente de novo amanhã." e favoritos continuam funcionando em cache
Cenário: Teclado e leitor de tela
  Então busca envia com Enter, diálogos de remover/bloquear iniciam o foco em "Cancelar", cada ação tem rótulo com o nome da pessoa e alvos ≥ 48 px de 320 a 1440 px
```

### Casos de borda
- **Pedido cruzado simultâneo** (os dois enviam no mesmo instante): podem coexistir `A→B` e `B→A`; qualquer lado "aceita" e o mesmo batch apaga os dois. O app, ao ver os dois pedidos, completa a amizade sozinho.
- **Usuário excluiu a conta** com pedido/bloqueio de outra pessoa pendente: pedidos e pares dele são apagados; o bloqueio que *outros* fizeram contra ele fica órfão (some quando o bloqueador desbloquear); a lista de bloqueados mostra nome do instantâneo.
- **Handle de conta excluída** vira livre imediatamente (sem quarentena; ver D2).
- **Nome mudou**: lista de amigos mostra o instantâneo; atualização é o fan-out raro (D8).
- **Foto do Google mudou**: cartão tem a URL antiga até o dono reabrir o app (verificação no início da sessão, 1 escrita se mudou).
- **Duas abas/dois aparelhos** do mesmo usuário aceitando o mesmo pedido: a segunda escrita é negada (pedido já consumido) e a UI recarrega.
- **uid com `_`**: a regra assume uid sem `_` (uids do Google/Firebase são alfanuméricos). Documentado em docs/50 §3.
- **Bloquear alguém que nunca interagiu** (a partir do cartão da busca): permitido.
- **Auto-pedido / auto-bloqueio**: negado.
- **Pedido para quem não ativou o social**: negado (sem cartão não há como ser achado; evita lixo em uids inexistentes).
- **Offline com escrita enfileirada**: ações sociais exigem servidor (confirmação) para evitar amizade "fantasma" aplicada horas depois.
- **Relógio do aparelho**: datas vêm do servidor (`request.time`); a regra de 30 dias não depende do relógio do cliente.
- **Consulta sem filtro de uid**: proibida por contrato (isolamento do cache entre contas).
- **Contas de teste da mesma pessoa**: nada impede; amizade consigo mesmo é negada.

### Perguntas em aberto ❓
Todas com default recomendado; nenhuma bloqueia a Fatia 0. Detalhes em "Decisões a validar".
- ❓ D1 a D11 (abaixo). As mais sensíveis: **D3/D10** (copiar a foto do Google para o banco muda a promessa de privacidade) e **D1** (handle × convite).
- ❓ Texto jurídico/LGPD do novo tratamento (apelido+foto visíveis a não amigos): **não verificado** por advogado.

### Fatiamento sugerido
0. **Regras + índices + testes de regras** (funções `isFriend/isBlocked`, 5 coleções). Publicáveis antes de qualquer UI; app atual não é afetado.
1. **Ativação no Perfil** (handle, apelido, foto, "Aparecer na busca") **+ AccountDeleter + exportação + texto/política de privacidade + README**. (Sai junto: ninguém grava dado social sem que exclusão e exportação o cubram.)
2. **Busca por handle + enviar/cancelar pedido** + aba "Enviados".
3. **Receber/aceitar/recusar + lista de amigos + indicador de pedidos + remover amigo.**
4. **Bloquear + tela de bloqueados + desbloquear.**
5. **Convite por link (código revogável), desativar social, refresh de foto/apelido nos pares.**

---

## Decisões a validar com o Manager

Cada decisão: opções, **recomendação (default)** e consequências.

**D1. Forma de descoberta.**
(a) Busca por apelido: ambígua, exige listar perfis (raspagem), regras não checam bloqueio em lista. Não recomendado.
(b) Só handle único: sem ambiguidade, busca exata, sem raspagem.
(c) Só link/código de convite: máxima privacidade, atrito para quem não tem o link.
(d) **Handle exato agora + convite por link na Fatia 5 (default).** Consequência: quem desliga "Aparecer na busca" só é achado depois que o convite existir (até lá, ele ainda pode buscar e aceitar pedidos).

**D2. Formato e unicidade do handle.**
Default: `^[a-z0-9_]{3,20}$` (minúsculo ASCII, sem `_` no início/fim, lista de 31 reservados: admin, cinetrack, suporte, ajuda, staff, oficial, moderador, sistema, security, null, anonymous, cine...), exibido como `@handle`. Unicidade pela reserva `handles/{handle}` gravada no mesmo batch/transação do ponteiro `social/{uid}`; a regra nega criar sobre um handle alheio. **Troca: 1 vez a cada 30 dias**, handle antigo liberado na hora. Opções: permitir maiúsculas (risco de homógrafos), 7 dias de intervalo, quarentena do handle antigo (exigiria regra de tempo extra). Consequência: um handle liberado pode ser reivindicado por outra pessoa: como amizade é por uid, ninguém "herda" amigos, mas pode haver confusão visual.

**D3. O que um não amigo vê na busca.**
Default: **handle, apelido e avatar**, nada mais (sem estatísticas, sem número de amigos, sem amigos em comum). Opção: só handle+apelido, sem foto (menos dado). Consequência da foto: o app passa a **copiar a URL da foto do Google** para o banco (hoje não copia); exige texto novo e consentimento (D10).

**D4. Pedido cruzado.**
Default: **vira amizade** automaticamente (os dois já consentiram). Opção: manter dois pedidos pendentes até alguém aceitar (pior UX). Consequência: implementado no cliente como "enviar = aceitar se existir o inverso" e coberto pelas regras (qualquer lado completa).

**D5. Limite de amigos/pedidos.**
Default: **300 amigos, 50 pedidos enviados pendentes, 50 recebidos exibidos (com "ver mais")**, só no app. Opção: contadores no servidor (documento `social/{uid}` com `friendCount` verificado por `getAfter`): +1 leitura de regra por escrita e mais complexidade. Consequência: um cliente modificado ignora os limites; o dano é lixo no próprio usuário/destinatários (que podem bloquear).

**D6. Ativação.**
Default: **opt-in no Perfil** (exige apelido e handle; sem ativar, ninguém é exposto, nem pode enviar/receber pedido). Opção: ativar automaticamente com handle gerado. Consequência: respeita "nenhum usuário precisa fazer nada" e LGPD (consentimento por ação). Quem ainda não ativou não aparece em nada.

**D7. Recusar.**
Default: **apaga o pedido em silêncio**. Opção: marcar "recusado" e impedir novo pedido por 30 dias (anti-assédio, mais regras). Consequência (default): o remetente pode reenviar; a defesa é bloquear.

**D8. Atualização de apelido/foto nos amigos.**
Default: **fan-out raro**: ao mudar apelido/foto, o dono atualiza a própria "metade" em cada par (≤ 300 escritas em lotes de 400, sem leitura de regra), em segundo plano e retomável. Opção: nunca propagar (instantâneo da hora da amizade) ou ler o cartão fresco ao abrir o perfil do amigo (F2). Consequência: mudar apelido custa N escritas uma vez; sem isso, amigos veem o nome antigo.

**D9. Exportação inclui apelido/foto dos amigos?**
Default: **sim, uid + apelido** (a foto não). É dado pessoal de terceiros, mas faz parte do vínculo do titular. Opção: só uids. Consequência: revisar texto de privacidade.

**D10. Foto/avatar.**
Default: aceitar **apenas URLs `https://lh<n>.googleusercontent.com/` (ex.: `lh3`)** (anti-rastreamento por URL arbitrária) e dar ao usuário a escolha "Mostrar minha foto" (ligada por padrão na ativação, destacada). Sem foto, o avatar usa iniciais. Consequência: o cartão pode ficar com foto desatualizada até a próxima sessão do dono.

**D11. Cota e plano.**
Default: **não ativar Blaze**; cache + TTL de 5 min na lista, listener estreito só no contador de pedidos, mensagens de "tente amanhã". Consequência: a cota de 50 mil leituras/dia é do projeto inteiro (docs/50 §9 estima); com milhares de usuários ativos ela aperta e será preciso rever.

**D12. (adicional, do Product Analyst) Pedido para quem está oculto.**
Default: só é possível quando o remetente já tem o uid (por pedido do outro lado ou convite). Consequência: oculto = invisível na busca, mas não "mudo".


## Requisitos acrescentados na revisão das regras (docs/51)
- **Mensagem genérica única**: ao criar pedido, ler cartão (`handles`) ou usar convite, qualquer negação (inexistente, oculto, bloqueado, expirado, `permission-denied`) mostra a mesma mensagem ("Não foi possível enviar"/"Nenhum usuário encontrado"). Criar pedido para quem me bloqueou é negado pelas regras e isso não pode ser distinguível na tela. Vale para as Fatias 2 e 5.
- **Código do convite (Fatia 5)**: `Random.secure()`, ≥ 22 caracteres base62, nunca derivado de uid, hora ou contador.
- **Foto (cliente)**: enviar `photoURL` só se casar com `^https://lh[0-9]+[.]googleusercontent[.]com/` e tiver ≤ 512 caracteres; senão enviar `null` (as regras negam o resto e a gravação inteira falharia).
- **Apelido (cliente)**: na entrada e na exibição, `trim`, normalizar para NFC e remover caracteres invisíveis/bidi (controle, U+200B/C, U+200E/F, U+202A–E, U+2066–9, U+2060, U+061C, U+FEFF, U+2028/9) e também NBSP, U+3000 e caracteres de tag (U+E0000–E007F), que as regras **não** barram. O limite de 40 conta unidades UTF-16 (igual a `String.length` do Dart): 40 CJK ou 20 emoji.
- Só contas Google criam `social`, handle, pedido, par e convite (regra `isGoogle()`).
