# Conferência final: social fatia 5 (Code Reviewer)

**Veredito: APROVADO** (nenhum 🔴, nenhum 🟡).

## Números (rodados por mim)
- `flutter analyze`: 0 problemas. `flutter test`: 1490 passam. `flutter build web` e `--base-href /cinetrack/`: ok.
- `node --check` em todos os .mjs: ok. `npm test`: 364/364. `npm run test:mutations`: 48/48 mortas.
- `firestore.rules`, `firestore.indexes.json`, `pubspec.yaml`: sem diff. `git status` igual antes/depois.

## Achados anteriores
- 🔴 F1 (SyntaxError em `mutations.mjs`): fechado; o arquivo carrega e as 48 mutações rodam.
- 🟡 F2 (retomada só tratava `not-found`): fechado. `refreshFriendHalves` trata `not-found` e `denied` como "par pode ter sumido": relê a página do mesmo cursor (do servidor) e só segue se algum par do lote realmente sumiu; usa a página relida (não recria o par). Se todos os pares do lote ainda existem, a negação é relançada e aparece. Se a página relida vier do cache, relança.
  - Mutação própria (cópia em scratchpad): (M1) só `not-found` => "um par removido entre a leitura e a escrita..." falha; (M2) engolir toda negação (sem checar se algum par sumiu) => "uma negação com todos os pares existentes é REAL" falha. Ambas mortas; base passa.
  - Sem laço infinito: no máximo 3 tentativas por página e `maxPages` páginas; pior caso 3 leituras + 3 escritas por página. Cancelamento é checado a cada passo. Desativar/troca de conta: geração do controller cancela a corrida; negação legítima (par todo ainda presente) vira falha visível; se o usuário desativou, a página relida vem vazia e termina sem escrever nada (nada é ressuscitado).
- 🟢a marcador só apagado após o desligamento (`cancelAndClear` só em `off`; falha antes de fechar mantém e retoma): testes de controller cobrem os dois casos.
- 🟢b erro de leitura do convite: "Não foi possível ler o seu convite agora." + "Tentar de novo", sem "Criar link"/"Novo link", convite intocado; teste de widget.
- 🟢c relógio: "Verifique a data e a hora do aparelho e tente de novo" (teste de widget, convite não criado, pode tentar de novo).
- 🟢d política "Perfil → Amizades"; data da política (06/10/2026) intacta e comentário ATUALIZAR preservado (sem diff nessas linhas).

## Itens da primeira revisão
Contrato Dart x regras (golden + replay 364), `Random.secure()` por padrão (campo `random` só para testes), mensagem única, link com `#`, exportação do convite, AccountDeleter/deactivate com convite e refresh, README/política/PrivacySummary consistentes; 1343 testes antigos seguem passando (total 1490). Diff sem churn (26 arquivos modificados + novos da fatia).

## Observação (não bloqueante)
O fake de `updateFriendHalves` imita `permission-denied` para par inexistente; o comportamento real depende das regras publicadas (já validado pelas regras de update).
