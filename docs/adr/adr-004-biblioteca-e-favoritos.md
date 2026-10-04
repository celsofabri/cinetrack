# ADR-004: "Minhas recomendações" como campo `recommended` no documento do item de Favoritos; sugestões automáticas e compartilhamento adiados

Status: Aceita, **revisada em 2026-10-03** (substitui a versão do mesmo dia que renomeava Favoritos para Biblioteca e criava o campo `loved`). Decisão do Manager: "mantenha o favoritos, mas crie o 'minhas recomendações'"; restrição absoluta: nenhum usuário pode perder dados atuais. Proposta por: Arquiteto. Design: [`docs/36`, seção REVISÃO](../36-design-biblioteca-e-favoritos.md); produto: [`docs/35`, REVISÃO](../35-especificacao-biblioteca-e-favoritos.md). Complementa o [ADR-003](./adr-003-firebase-auth-e-persistencia-na-nuvem.md) (Firestore por usuário) e o [ADR-002](./adr-002-cache-descoberta-ttl.md).

## Contexto
Cada título adicionado é um documento `users/{uid}/favorites/{id-tipo}` (Favoritos, com progresso). O Manager quer manter Favoritos como está e criar um segundo estado, **"Minhas recomendações"**: os títulos que o usuário realmente curtiu e quer marcar, para, **no futuro**, recomendá-los a outros usuários. Nesta entrega a marcação é só coletada e é **privada**. Restrições: Firestore Spark sem Cloud Functions, um usuário real com ~54 itens, app em produção e abas antigas convivendo com a nova versão, regras que validam o documento resultante com `hasOnly`, política de privacidade sem telemetria, tab bar mobile já com 5 destinos (máximo do Material 3).

## Decisão
1. **Dado:** campo opcional `recommended: bool` no próprio documento do item. Marcado = `true`; não marcado = campo **ausente**; desmarcar = `FieldValue.delete()`. Migração preguiçosa: nenhuma escrita em massa; nada vira recomendado sozinho. Alternativas rejeitadas: coleção separada (leituras extras, órfãos, escrita "adicionar+recomendar" não atômica) e documento de preferências (documento quente, sem integridade).
2. **Regras:** `validFavorite` aceita `recommended` no `hasOnly` e exige `recommended is bool` quando presente (duas linhas lógicas). Nada mais muda, inclusive "`addedAt` só diminui". Sem regra de leitura nova: continua só o dono.
3. **Escrita:** marcar/desmarcar sempre por `update` com field path; "adicionar e recomendar" (título fora de Favoritos) é um único `set` com `recommended:true`. O mapper não emite o campo quando falso, então o `add` comum é igual ao de hoje. Marcar não toca `addedAt`/`lastWatchedAt` e não reordena.
4. **Semântica:** todo título recomendado está em Favoritos. Remover de Favoritos apaga o documento e, portanto, a recomendação, **com confirmação** quando houver progresso ou recomendação. Desmarcar mantém em Favoritos. Assistido rápido, bulk e Desfazer não tocam o campo.
5. **Vocabulário/UI:** Favoritos mantém nome, rota `/favorites` e coração. Recomendação usa polegar para cima, rótulo "Recomendo"/"Recomendado"; aba "Minhas recomendações" (rota `/recommendations`, rótulo curto "Recomendo" na tab bar). Sugestões automáticas futuras se chamam "Sugestões para você".
6. **Tab bar:** **Perfil/Entrar vai para um ícone na barra superior** no mobile, e a nova aba ocupa o slot (Início, Explorar, Busca, Favoritos, Recomendo). `/profile` passa a ser rota fora do shell (com voltar). Nenhuma rota é renomeada nem removida. Alternativa (Busca vira lupa no topo) é equivalente em custo e fica como plano B por escolha do Manager. Seis abas, fundir Busca em Explorar e drawer foram rejeitados.
7. **Ordem de rollout (obrigatória):** Fatia 0 (Exportar meus dados em JSON, só app, antes de tudo); Fatia 1 (Minhas recomendações): **o Manager publica as regras antes do app**; Fatia 2 (futuro): sugestões TMDB e compartilhamento, cada uma com seu ADR.
8. **Regras nunca são revertidas depois da primeira marcação.** Rollback é sempre do app. Correções só "para frente" (superconjunto que continua aceitando `recommended`).
9. **Privacidade:** dado novo = um booleano de gosto pessoal, privado, no documento existente; nada vai a terceiros; política, resumo no app e diálogo de exclusão passam a citá-lo e a dizer que, por ora, é privado e não é compartilhado. A exportação (Fatia 0) cobre a portabilidade.
10. **Compartilhamento (roadmap, não implementar):** exigirá consentimento explícito e revogável, perfil público opt-in, coleção pública separada (nunca abrir a leitura de `users/{uid}/favorites`), flag de compartilhamento distinto de `recommended`, tratamento LGPD (inclusive menores), moderação e, para agregação confiável, provavelmente backend (fora da premissa Spark atual). Exigirá ADR próprio e aprovação do Manager.

## Consequências

**Positivas**
- 0 leituras novas e 1 escrita por marcação no Spark; o contador do Perfil e a aba derivam do stream já assinado.
- Favoritos não muda para o usuário atual: nenhum texto, rota ou hábito quebra; zero migração; os ~54 itens ficam intactos; Fatia 0 dá uma cópia antes de qualquer mudança de regras.
- Invariante estrutural (recomendado está em Favoritos); escrita "adicionar+recomendar" atômica; exclusão de conta e remoção já apagam o campo.
- Compatibilidade nos dois sentidos analisada no emulador (com o nome `loved`, em cópia descartável): app atual + regras novas funciona, inclusive em documentos marcados; app novo + regras antigas só falha ao marcar (visível); a trava `addedAt` impede que o `set` completo de um app antigo apague progresso ou marca existente.
- A tab bar fica dentro do limite do Material 3 sem perder funções nem quebrar deep links.

**Negativas / riscos**
- **Acoplamento de rollout:** regras antes do app; esquecer quebra só a ação de marcar (com mensagem), não o restante.
- **Irreversibilidade das regras** após a primeira marcação (negariam qualquer `update` em documento marcado); mitigação: nunca reverter; se inevitável, desmarcar tudo antes (aceito até pelas regras antigas).
- Resíduo conhecido: `set` completo com `addedAt` menor ou igual ao do servidor (cache frio + relógio atrasado) apagaria progresso/marca; muito improvável, já existe hoje.
- Perfil sai da tab bar: menos descoberta de "Entrar" e das estatísticas; mitigado por convite no Início e login sob demanda. `/profile` fora do shell exige ajuste e testes (voltar, banner, deep link).
- O dado de gosto, mesmo privado, é pessoal: a política precisa ser atualizada antes do deploy; a frase de consentimento futuro é compromisso de produto a aprovar.
- O campo booleano não guarda quando foi marcado; a ordem da aba é por atividade. Um `recommendedAt` opcional pode ser acrescentado depois (aditivo), mas exigirá nova publicação de regras.
- Divida de vocabulário permanente: coleção `favorites` e classes legadas continuam; o campo novo tem nome distinto.

## Não verificado
- Reexecução do emulador de regras com o campo `recommended` (a prova foi feita com `loved`); comportamento do SDK em produção para `update` em documento removido e reversão otimista; rótulos do console e propagação das regras.
- Leitura de `profile_screen.dart`, `account_widgets.dart` e a lista exata de testes que usam a aba Perfil/Entrar; layout em 320 px com fonte 2x; pacote de compartilhamento de arquivo no mobile.
- Parecer jurídico (LGPD) sobre o dado de gosto e sobre o compartilhamento futuro.
- Nenhum teste Flutter/Dart foi executado e nenhum código foi alterado.
