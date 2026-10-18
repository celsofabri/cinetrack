# 88 - Perfil social (Fase 2), Fatia 4: Recomendados

> Autor: Dev (Backend + Frontend) · Data: 2026-10-18 · Branch: `feat/social-profile` (base 159dd28)
> Entradas: [docs/81](./81-especificacao-perfil-social.md) (RF-P2–P5, RF-R1–R3, RF-F5, RF-F9, D2, D9, D16, textos literais, cenários "Recomendados"), [docs/82](./82-design-perfil-social.md) §4.1, §4.4, §5.4, §15 item 4, [docs/83](./83-testabilidade-perfil-social.md) (Fatia 4: opt-in, 50/51 com "e mais 1", ordem, texto do diálogo), [docs/84](./84-fatia0-regras-perfil-social.md), [docs/85](./85-fatia1-fundacao-perfil-social.md), [docs/86](./86-fatia2-meu-perfil-social.md), [docs/87](./87-fatia3-perfil-de-amigo.md), [ADR-006](./adr/adr-006-snapshot-perfil-social.md).
> **`firestore.rules` não foi alterado** (sha256 `6135322e…e612`, o publicado). Nenhuma mudança de regra foi necessária: `validRecs` e a amarração seção ⇔ consentimento já existem desde a Fatia 0. **Payloads e golden inalterados** (`turnOn_recs_create`, `turnOn_recs_update`, `turnOff_last_section_deletes`, `recalc_all_sections` já cobriam `recs` e já eram reproduzidos contra as regras): `npm test` não precisou rodar. Nada publicado: sem push, sem deploy.

## HANDOFF
De: Dev (Backend + Frontend) → Para: Code Reviewer e QA, depois Orquestrador
Demanda: Fase 2 (perfil social), Fatia 4: Recomendados
Fluxo: feature | Etapa: Fatia 4
Prioridade: P1 (recomendações tinham promessa explícita de consentimento na política)

### O que foi feito
**Interruptor "Recomendados"** (`lib/providers/sharing_providers.dart`, `lib/widgets/sharing_section.dart`)
- Terceiro interruptor em "O que seus amigos veem", depois de Estatísticas e Atividades recentes (ordem do RF-P2), **desligado por padrão** (D2). Leitor de tela: "Compartilhar recomendados com amigos", ligado/desligado.
- **Ligar**: diálogo com os **textos literais** do docs/81 (o teste compara com a linha da tabela do próprio docs/81, como o QA-13) e **prévia**: "Recomendações: N", até 50 títulos na ordem da aba e "e mais N" (o mesmo componente que o amigo vê); sem nenhum recomendado: "Recomendações: 0" + "Você ainda não marcou nenhum título com Recomendo." (pode ligar mesmo assim). "Calculando…" enquanto os dados não são confiáveis (mesma condição do motor). "Compartilhar" = 1 transação (`sharing.recs = true` + `recs` + `tz`/`calc`/`updatedAt`), mais a releitura que já existia; se a releitura falha, a visão local inclui os `recs` gravados.
- **Desligar**: sem confirmação, transação que apaga `sharing.recs` e `recs`; se era a última seção, apaga o documento; mensagem "Seus amigos não veem mais seus recomendados.". O campo `recommended` dos favoritos **não muda** (RF-R3, teste compara todos os favoritos antes/depois).
- Incerto / offline / cota / "Aguarde a operação anterior terminar." / regras antigas: **o mesmo código** da Fatia 2 (nada específico de seção); testes repetidos para `recs` (ligar incerto confirmado depois, desligar incerto que não aconteceu e que aconteceu, offline, um por vez).

**`recs` no builder/motor** (já existiam desde a Fatia 1; esta fatia liga o caminho)
- `SharedProfileBuilder.recs`: favoritos com `recommended`, ordem `FavoriteItem.byRecentActivity` (a de `recommendedListProvider`, conferida contra o provider num conjunto com séries, filmes assistidos depois de favoritados e empates por `addedAt` e por título), primeiros 50, `count` = total. Cada item é **projeção** `{id, mediaType, title, poster}` (teste: nenhuma outra chave, nem sinopse, datas ou progresso); passa pelo `clamp` do validador (pôster fora do formato TMDB some, título cortado em 300).
- Motor `SharedProfileSync`: nenhuma linha nova. Marcar/desmarcar "Recomendo" ou remover o título dos favoritos chega pelo listener, coalesce (W = 5 s) e grava **só `recs`** (+ `tz`, `calc`, `updatedAt`) quando muda; mudança que não toca `recs` (assistir um título não recomendado) = 0 escritas; com só Estatísticas ligado, recomendar = 0 tentativas e nenhum `recs`; sem nada ligado = 0 escritas (testes com relógio falso).
- **Recomendar não cria atividade** (RF-A5): com Atividades ligado, recomendar/desrecomendar = lista inalterada, 0 escritas.

**Perfil de amigo** (`lib/screens/friend_profile_screen.dart`, `lib/shared_profile/shared_stats_reading.dart`, `lib/widgets/shared_profile_widgets.dart`)
- Seção "Recomendados" depois de Atividades recentes: "Recomendações: N" (de `recs.count`; leitor "Recomendações: N"), a lista na ordem gravada, "e mais N" quando `count` > itens listados (50 → nada; 51 → "e mais 1"; 75 → "e mais 25").
- Cada item (`SharedRecTile`): pôster pequeno (ou o ícone do tipo quando não há pôster), título (2 linhas, reticências; leitor "Título, filme/série"), "Filme"/"Série"; toque ou Enter abre `/movie/:id` ou `/tv/:id`.
- Ausente: "Fulano não compartilha recomendados com amigos." (sem número). Ligado sem nenhum: "Recomendações: 0" + "Fulano ainda não tem recomendados.".
- **Leitura tolerante** (`SharedRecsReading.read`, RF-F9): `recs` que não é mapa = não compartilhado; `count` ausente/negativo/de outro tipo = "Recomendações: —" (leitor "sem informação") e sem "e mais"; item malformado (id não inteiro, tipo de mídia desconhecido, sem título, não mapa) ignorado e os demais mantidos na ordem; campos desconhecidos ignorados; pôster fora de `^/[A-Za-z0-9._-]+$` (≤ 200) descartado (título aparece sem pôster); no máximo 50 itens exibidos, qualquer que seja o documento.
- Ordem de Tab: Voltar → Atualizar → cada atividade → cada recomendado → Remover amizade → Bloquear (teste).

**Prévia do dono "Como seus amigos veem"**: agora aparece com Estatísticas **ou** Recomendados ligado (antes só com Estatísticas, decisão 5 do docs/86) e mostra o que está gravado: estatísticas (se ligadas) e "Recomendados" com o mesmo `SharedRecsView` do perfil de amigo; tocar num título abre o detalhe. Desligar Recomendados tira a lista da prévia na hora.

**Política** (`web/privacidade.html`, data 18/10/2026; `lib/widgets/privacy_summary.dart`)
- `PrivacySummary`: "…suas atividades recentes (…) e seus recomendados (até 50 títulos que marcou com Recomendo, na ordem da sua aba, e quantos são); para isso guardamos uma cópia só do que você ligou, e desligar apaga na hora." (teste literal atualizado em `test/sharing_section_test.dart`).
- `privacidade.html`: linha da tabela (cópia das seções ligadas inclui recomendados), "Quem vê o quê" (fora o que você ligar: … e, nos recomendados, os títulos que marcou com Recomendo), item "O que seus amigos veem" com **Recomendados** (até 50, ordem da aba, quantos são; nada muda nas suas recomendações; desligar não desmarca nenhuma), o parágrafo "Minhas recomendações é privada" reescrito (privada **a menos que** você ligue "Recomendados", com consentimento e prévia; o que os amigos mútuos veem: nome, pôster, filme/série, ordem, total; recomendar não vira atividade; desligar apaga a cópia e não muda as recomendações) e "Como excluir" (o que seus amigos viam: estatísticas, atividades e recomendados). A frase antiga "Pediremos seu consentimento antes de qualquer compartilhamento e atualizaremos esta política antes disso" saiu: é exatamente o que esta fatia cumpre.

### Números
| Comando | Resultado |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` (2 rodadas, fuso da máquina) | **1980/1980** nas duas (antes: 1917; +63) |
| `TZ=UTC flutter test` | **1980/1980** |
| `flutter build web --base-href /cinetrack/` | ✓ Built build/web |
| `npm test` (regras) | **não rodado**: `firestore.rules`, fixtures e payloads (golden) inalterados |
| `python3 tool/dart_mutations.py` (lista completa, cópia em /tmp do HEAD final) | ver "Mutações" abaixo |

Testes novos: `test/fatia4_recs_test.dart` (controller, motor com relógio falso, builder/validador, leitor tolerante) e `test/fatia4_recs_widget_test.dart` (diálogo, prévia, desligar, perfil de amigo, 50/51/75, tolerância, foco, matriz 320/375/768/1024/1440 × 1×/2×/3× claro/escuro com 50 títulos longos, prévia do dono a 320/1440 × 1×/3×, diálogo de 51 títulos a 320 px 1×/3×). Ajustes: `test/sharing_section_test.dart` (3 interruptores, ordem de foco com Recomendados, frase da política) e `test/export_data_section_test.dart` (altura da superfície: o resumo de privacidade cresceu de novo).

### Mutações Dart (`tool/dart_mutations.py`, `K1–K22`)
K1 `recs` gravado sem consentimento (motor monta `recs` para todos); K2 `recs` fica no servidor depois de desligar; K3 visão do dono mantém `recs` depois de desligar; K4 "e mais 0" aos 50; K5 sem "e mais 1" aos 51; K6 ordem da aba invertida; K7 amigo lê "Recomendações" da lista e não de `recs.count`; K8 `recs.count` gravado como nº de itens listados; K9 "Recomendações" exibido da lista; K10 recomendar cria atividade; K11 prévia do dono sem a lista; K12 prévia do dono só com Estatísticas; K13 diálogo sem a prévia; K14 amigo vê recomendados quando ausente; K15 amigo ignora `recs`; K16 título recomendado não abre; K17 pôster fora do formato exibido; K18 item de tipo desconhecido exibido; K19 lista do amigo sem limite de 50; K20 sem o interruptor; K21 motor nunca vê mudança de `recs`; K22 visão local (releitura falhou) sem `recs`.
- Rodada isolada (K1–K22, cópia em /tmp): **22/22 KILLED**.
- Conferência extra: as **170** mutações da lista aplicam e **compilam** (nenhuma "morta" por erro de compilação; o script conta falha de compilação como "Some tests failed"). Achado nesta conferência e corrigido antes da rodada completa: o `SharedRecTile` repetia o trecho `'/movie/${item.id}' : '/tv/${item.id}'` da mutação `Q15` (Fatia 2), o que quebraria a unicidade exigida pelo script; a rota do item passou a `'/${movie ? 'movie' : 'tv'}/${item.id}'`. K11/K13 tinham erro de compilação na 1ª versão (promoção de nulo) e foram reescritas (`if (false && x != null)`), depois mortas.
- Rodada completa: **RESULTADO_MUTACOES**.

### Decisões tomadas (e por quem)
- Dev (sujeitas a review):
  1. **"e mais N" = `count` − itens exibidos** (não − itens gravados): se o leitor ignora um item malformado, o rodapé continua somando ao total ("Recomendações" e lista + rodapé batem). No app oficial os dois são iguais.
  2. Prévia "Como seus amigos veem" existe com Estatísticas **ou** Recomendados (revê a decisão 5 do docs/86, que valia só para Estatísticas/Atividades). Com só Atividades, continua sem prévia (a lista de atividades abaixo já é o que os amigos veem).
  3. Textos sem literal no docs/81 (todos neutros, em português): "Recomendações: N" (o docs/81 usa "Recomendações: 12" no cenário), "e mais N", "Fulano não compartilha recomendados com amigos." (padrão da tabela RF-F5), "Fulano ainda não tem recomendados.", "Você ainda não marcou nenhum título com Recomendo." (prévia do dono sem nenhum), "Filme"/"Série" no item (como a aba Minhas recomendações).
  4. Item do amigo **com pôster** pequeno (40×60, `contain`), sanitizado pelo mesmo formato do validador; sem pôster = ícone do tipo (filme/série). Atividades continuam só com ícone (Fatia 3).
  5. A prévia do diálogo mostra a lista inteira (até 50) e não um resumo: é o que os amigos verão (o diálogo rola; testado a 320 px 3×).
  6. O leitor tolerante descarta item com título vazio ou só espaços (não há o que mostrar nem o que anunciar).

### Desvios do docs/82
- Nenhum de dados ou regras. §8 (privacidade): o trecho de recomendações foi escrito como acima.

### Suposições (não verificadas)
- `CachedNetworkImage`/`Image.network` com pôster do TMDB em lista de até 50 itens no perfil de amigo não pesa (mesmo componente e tamanho pequeno da busca; não medido no navegador).
- Emulador = produção nas regras (risco 10 do docs/82): os payloads de `recs` executados são os do golden já reproduzido contra as regras publicadas.

### Riscos / atenção
- **Publicar a política junto com o app desta fatia** (a frase antiga dizia que as recomendações não eram compartilhadas). Data "Última atualização" = 18/10/2026; ajustar se o release for em outro dia.
- Cota: nada novo além do previsto (docs/82 §11): ligar = transação + releitura; cada mudança de "Recomendo" de quem compartilha = no máximo 1 escrita coalescida; quem não liga = 0 escritas; o perfil de amigo continua com 1 leitura (o documento já trazia `recs`).
- Orçamento das regras: inalterado (as regras não mudaram; o pior documento legal, com 50 recomendados, já foi medido na Fatia 0: ≈ 65%).
- D16 (risco aceito): um cliente modificado do dono pode publicar títulos arbitrários nos recomendados; o leitor exibe só texto (sem HTML), descarta pôster fora do formato e limita a 50.
- Rollback do app: como na Fatia 2, a versão anterior não sabe desligar "Recomendados" (nem mostra o interruptor); o `recs` gravado continua no documento, e amigos com a versão anterior não o veem (a tela da Fatia 3 ignora `recs`). Remédio: voltar para esta versão e desligar, desativar as amizades ou excluir a conta.

### Artefatos
- Código: `lib/providers/sharing_providers.dart`, `lib/widgets/{sharing_section,shared_profile_widgets,privacy_summary}.dart`, `lib/screens/friend_profile_screen.dart`, `lib/shared_profile/{shared_stats_reading,shared_profile_texts}.dart`, `web/privacidade.html`.
- Testes: `test/fatia4_recs_test.dart`, `test/fatia4_recs_widget_test.dart`; ajustados `test/sharing_section_test.dart`, `test/export_data_section_test.dart`; `tool/dart_mutations.py` (`K1–K22`).

### Critério de aceite deste handoff
- Code Review e QA aprovados; `flutter analyze` limpo; `flutter test` e a suíte Dart de mutações verdes no ambiente do revisor. Depois, merge e publicação do app **junto com a política**.
