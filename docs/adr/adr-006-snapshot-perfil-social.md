# ADR-006: Perfil compartilhado com amigos como documento derivado ("snapshot") recalculável, sem Cloud Functions

Status: **Aceita (Manager, 2026-10-10)** · Autor: Arquiteto · Data: 2026-10-10
Relacionados: [ADR-003](./adr-003-firebase-auth-e-persistencia-na-nuvem.md) (Firestore Spark, regras como único guarda), [ADR-004](./adr-004-biblioteca-e-favoritos.md) (item 10: compartilhar recomendações exige consentimento e coleção separada), [ADR-005](./adr-005-modelo-social-amizades.md) (`isFriend`, invariante "amigo ⇒ não bloqueado"), [docs/81](../81-especificacao-perfil-social.md) (especificação), [docs/82](../82-design-perfil-social.md) (design), [docs/83](../83-testabilidade-perfil-social.md) (QA).

> **Revê a decisão "estatísticas calculadas sem contadores armazenados"** ([docs/08](../08-design-login-perfil.md) decisões 2 e 8; README "Perfil"). Para o **dono**, ela continua valendo: o Meu perfil segue calculando tudo ao vivo. O que muda é que, **só para quem consentir**, passa a existir uma **cópia derivada** gravada para os amigos lerem.

## Contexto
Amigos não podem ler `users/{uid}/favorites` (restrição do Manager; ADR-004 item 10). Para mostrar estatísticas, atividades e recomendados a um amigo, alguma coisa precisa ser gravada num documento legível por ele. Sem Cloud Functions (Spark), só o **cliente do dono** pode produzir esse documento, e as regras só conseguem validar forma, não a verdade dos números.

Fatos que moldam a decisão (lidos no código em `main` 9c57327 e medidos no emulador, ver "Evidência"):
1. Duas estatísticas mudam **sem escrita do dono**: "Séries concluídas" (episódio novo vai ao ar) e "Tempo assistido" (durações chegam depois pelo reconciliador). Um snapshot só "a cada escrita" fica errado nesses casos.
2. Escritas de favoritos são `update`/`set` isolados, não aguardados, enfileirados offline (`SyncFailureSink.fire`). Se a parte do snapshot de um **batch** for recusada, o SDK reverte o batch inteiro e **a marcação do usuário some** (viola "ninguém perde dados").
3. Não existe data por episódio (`eps` é `"{s}_{e}": true`); `lastWatchedAt` é por título. "Este mês/ano" de episódios não é derivável do que existe.
4. **Limite medido das regras: 1000 expressões avaliadas por requisição.** Validar campo a campo 10 atividades + 50 recomendados + 3 recortes de estatísticas estoura o limite (o emulador nega a escrita com "maximum of 1000 expressions"); uma validação enxuta cabe com ~38% de folga.
5. Firestore documenta no máximo 500 transformações de campo (ex.: `serverTimestamp`) por documento numa escrita; a marcação de série inteira grava até 5000 episódios num único `update`. (O emulador **não** impõe esse limite; não verificado em produção.)
6. O prompt da fase pede atualizar "a cada escrita de favorito/progresso, em batch". O PA propôs divergir (D4).

## Opções consideradas

Eixo 1: como manter o snapshot.

| Opção | Prós | Contras | Custo (Spark) | Risco |
|---|---|---|---|---|
| A. Mesmo batch da escrita de favorito, com contadores incrementais (`increment`) | Atômico com a ação | Recusa do snapshot **desfaz a marcação** (perda de dados); `increment` duplica com Desfazer/repetição e não se corrige; não cobre episódio novo nem duração tardia; dois aparelhos divergem para sempre | +1 escrita por marcação | **Alto** |
| B. Mesmo batch, mas com o snapshot recalculado inteiro | Corrige-se a cada ação | Mesma perda de dados de A; o recálculo usa a visão local (com escritas pendentes), sem ganho real de consistência; contenção (1 escrita/s por documento) numa maratona | +1 escrita por marcação | Alto |
| **C. Projeção derivada: função pura dos favoritos + catálogo local, gravada em escrita própria, coalescida, só com dados confirmados pelo servidor** | Nunca toca a escrita do usuário; idempotente; corrige-se sozinha (episódio novo, duração, outro aparelho, app antigo); mesma filosofia "derivado dos dados" | Amigo vê com alguns segundos de atraso; números ficam velhos enquanto o dono não abre o app | ≤ 1 escrita por janela de 5 s de atividade; 0 se nada mudou | Baixo |
| D. Log de eventos (`users/{uid}/events`) e agregação no leitor | Histórico rico | Leitor precisaria ler N eventos por amigo (cota); eventos não se corrigem; exigiria regras de leitura em coleção do dono | N leituras por perfil | Médio |

Eixo 2: como obter "este mês/ano" (D5 do PA).

| Opção | Prós | Contras |
|---|---|---|
| Contadores por período incrementados | Barato | Desmarcar desconta do mês errado; nunca se corrige; viola a filosofia derivada |
| **Data de cada marcação de episódio no próprio favorito (`epsAt`), dali em diante; filmes usam `lastWatchedAt` (já é a data da marcação atual)** | Tudo continua derivável e recalculável; desmarcar desconta do período certo; serve à F3 (períodos) e às atividades | Campo novo em `validFavorite` (aditivo); histórico anterior sem data conta só no Total |
| Períodos a partir de "ligou o compartilhamento" | Sem campo novo | Ainda exige data por item para desmarcar corretamente |

Eixo 3: layout (A1 do PA). Um documento por usuário com as seções consentidas **vs.** um documento por seção **vs.** subcoleção. Um documento: perfil de amigo = 1 `get` + 1 `exists` = **2 leituras cobradas**; por seção: 3 `get` = até 6; subcoleção com `list`: 3. O ranking (F3) lê o mesmo documento (mesmo custo por amigo; bytes maiores, aceitável: ≤ ~30 KB no pior caso).

## Decisão
1. **Um documento por usuário, `shared_profiles/{uid}`**, que só existe se pelo menos uma seção estiver ligada. Seções: `stats`, `activity` (+ `actSince`), `recs`. **Seção desligada = campo ausente no servidor** (desligar apaga). Leitura: `isOwner(uid) || isFriend(uid, eu)` (1 `exists`). Escrita: só o dono.
2. **Consentimento gravado junto do conteúdo** (`sharing: {stats|activity|recs: true}`), e as regras exigem **seção presente ⇔ consentimento presente**. Ligar/desligar é uma **transação** (exige servidor; nada fica na fila) que muda `sharing` e a seção juntos. O motor de recálculo **nunca** escreve `sharing`: se outro aparelho desligou uma seção, a escrita atrasada deste é **negada pelas regras** em vez de republicar sem consentimento.
3. **O snapshot é uma projeção pura** `SharedProfileBuilder.build(favoritos, catálogo local, durações, consentimentos, actSince, relógio, fuso)`. Atividades também são **derivadas dos dados** (datas de favoritar, marcar filme, marcar episódio, concluir), não registradas como eventos: desmarcar, Desfazer e remover dos favoritos as removem sozinhos; nada anterior a `actSince` é publicado (as regras também exigem `at >= actSince`).
4. **Quando é gravado** (decisão sobre "a cada escrita, em batch"): o gatilho é **toda mudança da lista de favoritos** observada pelo listener que já existe (cobre todas as escritas do app, marcação em massa, Desfazer, `addAndRecommend`, `favoriteThen`, replay pós-login, outro aparelho e aba antiga), mais o fim do sync de catálogo/durações, a virada de mês e ligar uma seção. A escrita é **própria, nunca no batch do favorito**, coalescida: **W = 5 s** depois da última mudança (no máximo 30 s desde a primeira), mais uma tentativa ao ocultar a página. **Diverge conscientemente do "em batch" do prompt**: o batch não dá consistência real (o cálculo usa a visão local), arrisca desfazer a marcação do usuário e não cobre o que muda sem escrita.
5. **Só grava com dados confiáveis**: lista de favoritos confirmada pelo servidor nesta sessão (`fromCache == false`), sem escritas pendentes (`hasPendingWrites == false`), sync de catálogo ocioso (ou 60 s de espera), conta sem `deleting`, uid inalterado. **Só grava se mudou** (comparação canônica); não regride completude (não troca um tempo assistido mais completo por um menos completo com as mesmas contagens). **Pulso de 24 h**: se nada mudou mas `updatedAt` tem mais de 24 h, grava só `updatedAt` (sinal de "confirmado recentemente").
6. **Datas de marcação**: campo `epsAt` (`{"s_e": Timestamp}`) no favorito, gravado **no mesmo `update`** do episódio (é parte da própria ação, como `lastWatchedAt`), com a **hora do aparelho corrigida pelo desvio do servidor** (estimado quando um `serverTimestamp` próprio é confirmado) e **um único instante por escrita** (a marcação em massa inteira tem a mesma data). Não usa `serverTimestamp` por episódio (limite de 500 transformações). Desmarcar apaga a data; Desfazer restaura as datas anteriores; datas órfãs (deixadas por app antigo) não contam e são limpas na próxima escrita do documento. Para não arriscar a marcação com regras antigas, o app só envia `epsAt` depois de **constatar as regras novas** (sonda de 1 leitura, guardada no aparelho; regras nunca voltam).
7. **Períodos**: o snapshot guarda `month.key` ("AAAA-MM"), `year.key` ("AAAA") e `tz` (deslocamento do dono em minutos) do momento do cálculo. O leitor mostra "este mês" só se `month.key` = mês atual **no fuso do dono** (agora UTC + `tz`); senão 0 com "Atualizado há…". Todos os leitores veem o mesmo número (F3 compara amigos). Histórico sem data entra só no Total, com `undatedEpisodes`/`undatedMovies` e `datedFrom` para a nota "contamos a partir de…".
8. **Desatualizado é sinalizado**, não escondido: `updatedAt` (hora do servidor, exigida pelas regras) + pulso de 24 h + `calc` (versão da fórmula) + `v` (versão do schema). Regra para a F3 (recomendação): desatualizado se `agora - updatedAt > 7 dias` ou `calc` menor que o exigido; a UI desta fase sempre mostra "Atualizado há X", sem alarme.
9. **Regras enxutas por limite da plataforma**: forma fechada (`hasOnly`) do documento e das seções; `updatedAt == request.time`; `tz` em faixa; consentimento ⇔ conteúdo; as 5 métricas do ranking (filmes, episódios, séries assistidas, séries concluídas, minutos) numéricas e ≥ 0 nos três recortes; formato de `month.key`/`year.key` e coerência entre eles; atividades ≤ 10 com `at >= actSince`; recomendados ≤ 50 e `count >= itens`; seções só revalidadas quando mudam; criar/mudar consentimento exige `social/{uid}` (amizades ativas) e conta Google. **Tipos e faixas de cada item e os tetos numéricos ficam no validador Dart** (idêntico ao contrato da tabela de tetos do docs/82 §4.4), com golden de payloads reproduzido contra as regras. Custo: leitura 1 chamada; recálculo 0; criar/mudar consentimento 1; pior escrita medida ≈ 62% do limite de expressões.
10. **Números falsos (D12)**: risco **aceito formalmente** (assinatura do Manager). As regras não conseguem provar que os números correspondem aos favoritos nem impedir números plausíveis inventados por um cliente modificado do próprio dono. Mitigações: só amigos mútuos veem; remover/bloquear; F3 decide se sinaliza; validador Dart limita o app oficial.
11. **Revogação**: desfazer amizade/bloquear revoga pela regra (`isFriend`) na próxima leitura, sem reescrever o documento. Desativar amizades e excluir a conta **apagam** o documento antes **e depois** de fechar a porta (`social/{uid}`), então não sobra documento sem finalidade e não existe "amigo residual lendo conteúdo" (A8: sem `exists(social)` extra na leitura).
12. **Forward-compat**: F3 lê `stats` (mesmo documento, sem migração; `list` continua negado até a F3 decidir entre `get` por id e `documentId in [≤10]`); F4 acrescenta o tipo `rated` às atividades derivadas (a partir das avaliações do dono) e publica regras que aceitam `v` novo; F5 não depende deste documento. O leitor ignora tipos e campos desconhecidos; campo ausente aparece "—", nunca 0.

## Consequências

**Positivas**
- **Nenhuma ação do usuário depende do snapshot**: recusa, cota ou bug no compartilhado nunca desfaz uma marcação (testável: "nunca no mesmo batch").
- Idempotente e autocorretivo: dois aparelhos, fila offline, app antigo, episódio novo, duração tardia e virada de mês convergem no próximo recálculo; "só grava se mudou" = 0 escritas sem mudança.
- Revogação imediata pelas regras; consentimento à prova de aparelho atrasado; nada anterior ao consentimento é publicado.
- Cota baixa: perfil de amigo 2 leituras a frio e 0 no TTL; quem não liga nada não grava nada novo; F3 reaproveita o mesmo documento.
- Períodos e atividades vêm dos dados (não de contadores): desmarcar desconta do mês certo; Desfazer volta exatamente ao estado anterior.

**Negativas / custos**
- **Snapshot pode estar velho**: até o dono abrir o app (pulso de 24 h só ocorre com o app aberto). Sinalizado por "Atualizado há X".
- **Validação nas regras é mais fraca que a do PA (D12)**: itens de atividades e recomendados têm só a forma validada; tetos por métrica e coerência mês ≤ ano ≤ total ficam no Dart. Um cliente modificado do dono pode publicar texto arbitrário nos títulos (mesma classe de risco do apelido livre) e inflar o documento até 1 MiB para os amigos dele.
- **Dado novo privado para todos que usam a versão nova**: data de cada marcação de episódio (`epsAt`), no próprio documento do dono, exportada e apagada como o resto; política atualizada antes.
- `epsAt` aumenta o documento de séries longas (≈ +20 B por episódio; 5000 episódios ≈ +100 KB, longe de 1 MiB) e a sonda custa 1 leitura por aparelho, uma única vez.
- Hora da marcação de episódio vem do aparelho corrigida por estimativa (não do servidor): relógio muito errado antes da primeira correção pode deslocar o mês de uma marcação.
- Dados do amigo lidos ficam no cache persistente do SDK do leitor (nunca exibidos dali; leitura sempre `Source.server`).
- Mais um documento a cobrir em exclusão, desativação e exportação (schema 3).

## Evidência (spike no emulador, cópia descartável no scratchpad; projeto intocado)
- Regras propostas (docs/82 §4) + suítes existentes do repositório: **376/376** passam (compatibilidade com documentos e app atuais).
- Spike novo (13 testes): criação com 50 recomendados; pior atualização (estatísticas + 10 atividades + 50 recomendados) aceita; 11 atividades, 51 recomendados, `updatedAt` do cliente, número negativo, chave de mês incoerente, campo extra, atividade anterior a `actSince` negados; aparelho atrasado não republica seção desligada; mudar consentimento sem `social` negado, recálculo permitido; leitura: dono e amigo sim, estranho, anônimo e ex-amigo não; amigo lendo documento inexistente recebe "não existe"; favoritos com `epsAt` de 5000 entradas aceitos, `epsAt` não-mapa negado, payload antigo aceito.
- Limite de 1000 expressões **confirmado**; versão com validação item a item **negada** até para só as estatísticas. Pior caso da versão final ≈ 62% do limite.
- O emulador **não** impõe o limite de 500 transformações; **produção pode divergir** em tudo acima.

## Não verificado
- Cobrança real de leituras de regra em produção; comportamento real do SDK web (Source.server offline, timeout de transação, ocultar página); limite de transformações em produção; parecer jurídico (LGPD) sobre `epsAt` e os textos de consentimento.
