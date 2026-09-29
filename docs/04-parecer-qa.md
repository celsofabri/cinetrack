## Plano de testes: CineTrack MVP
Escopo: lógica de progresso/próximo episódio, parsing e tratamento de erro do cliente TMDB, estados da lista de favoritos (vazio/filme/série).
Fora de escopo (nesta rodada): testes e2e reais em device/emulador (Xcode não instalado no ambiente — ver Riscos residuais), testes de acessibilidade automatizados.

| Caso | Tipo | Nível | Automatizado? | Critério de aceite ligado |
|------|------|-------|----------------|---------------------------|
| Contagem watched/total agregada por série | Unit | unit | ✅ | "Progresso agregado na lista de favoritos" |
| Cálculo do próximo episódio (ordem temporada/episódio) | Unit | unit | ✅ | "Marcar episódio como assistido" |
| Episódio com `air_date` futura não vira "próximo" | Unit | unit | ✅ | Caso de borda: série ainda em exibição |
| Temporada 0 (especiais) ordenada por último | Unit | unit | ✅ | Caso de borda: "specials" |
| Lista de seasons vazia não quebra o cálculo | Unit | unit | ✅ | Robustez / edge case |
| Parsing de `/search/multi` (ignora tipo "person") | Unit | unit | ✅ | "Buscar e favoritar uma série" |
| Busca com string vazia não dispara chamada de rede | Unit | unit | ✅ | Eficiência / robustez |
| Erro 401 do TMDB → mensagem de configuração | Unit | unit | ✅ | "Chave de API ausente/inválida" |
| Erro 429 do TMDB → mensagem de rate limit | Unit | unit | ✅ | Caso de borda: rate limit |
| Lista de favoritos vazia mostra estado vazio | Widget | widget | ✅ | "Lista de favoritos vazia" |
| Filme favoritado mostra status assistido/não assistido | Widget | widget | ✅ | Tela de detalhes do filme |
| Série favoritada mostra progresso agregado (ex. "1/2") | Widget | widget | ✅ | "Progresso agregado na lista de favoritos" |
| Fluxo completo em device/emulador real (busca online, favoritar, marcar episódio, matar app e reabrir offline) | E2E manual | e2e | ❌ (pendente) | Todos os cenários do Gherkin |

## Parecer QA: CineTrack MVP — ⚠️ APROVADO COM RESSALVAS
- Critérios de aceite: 8/9 verificados por teste automatizado (unit/widget). O 9º ("abrir série favoritada offline" e o fluxo ponta-a-ponta) depende de execução em device/emulador real.
- Regressão: não aplicável (primeira entrega).
- `flutter analyze`: 0 problemas. `flutter test`: 13/13 passando.
- Bugs abertos: S1: 0 | S2: 0 | S3: 0 | S4: 0
- Riscos residuais:
  - **Sem evidência de execução em device/emulador real** — este ambiente não tem Xcode completo nem emulador Android configurado, então não foi possível rodar `flutter run` num simulador/aparelho de verdade nem validar visualmente TMDB real (precisa de chave de API, que é do usuário).
  - Cache de temporada sem expiração (ver review de código) — risco baixo, documentado.
- Ressalvas (exigem aceite do Manager 🧑‍💼):
  - Rodar `flutter run` num dispositivo/emulador Android ou iOS real (com Xcode/Android Studio instalados) antes de considerar o MVP "pronto para uso diário", cobrindo pelo menos o cenário completo: buscar → favoritar → marcar episódios → fechar app → reabrir offline.
