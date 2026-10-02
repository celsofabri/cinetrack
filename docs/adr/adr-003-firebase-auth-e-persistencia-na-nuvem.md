# ADR-003: Firebase Auth (Google) + Cloud Firestore (plano Spark) para identidade e dados por usuário

Status: Aceita (Manager, 2026-10-02)

> **Revisa a premissa "persistência somente local, sem backend, sem múltiplos usuários" do [ADR-001](./adr-001-stack.md).** As demais decisões do ADR-001 (Flutter, Riverpod, go_router, `http`, TMDB) permanecem. O Hive deixa de ser a fonte da verdade dos dados do usuário e passa a servir cache de catálogo e leitura do legado para migração. Design completo: [`docs/08-design-login-perfil.md`](../08-design-login-perfil.md).

## Contexto
O Manager pediu login com Google, tela de Perfil e dados acessíveis de qualquer dispositivo (web no GitHub Pages, Android, iOS), a custo zero. Hoje tudo vive no Hive local. Requisitos que pesam: sem servidor próprio, sem cartão, offline com sincronização e merge multi-dispositivo sem perder marcações, isolamento por usuário imposto no servidor, exclusão de conta (LGPD), migração sem perda dos dados reais existentes.

Alternativas avaliadas: Supabase Free (pausa após 1 semana de inatividade; sem offline pronto), Google Sign-In + Drive appData (sem consulta/merge; token web de 1 h sem refresh), Realtime Database, backend próprio. Verificado na documentação em 2026-10-02: Spark oferece Auth gratuito até 50 mil MAU e Firestore com 1 GiB, 50 mil leituras, 20 mil escritas e 20 mil deletes por dia; chaves de API do Firebase são públicas por design e a proteção é feita por Security Rules.

## Decisão
1. **Autenticação:** Firebase Auth com provedor Google. Web: `signInWithPopup`; Android/iOS: `google_sign_in` + `signInWithCredential`.
2. **Dados:** Cloud Firestore, um documento por favorito em `users/{uid}/favorites/{storageKey}`; progresso de episódios no mapa `eps` do próprio documento (`"{season}_{episode}": true`), atualizado por caminho de campo para merge nativo. Catálogo TMDB (temporadas/episódios) **não** vai para a nuvem; fica em cache local.
3. **Isolamento:** Security Rules com `request.auth.uid == uid`, validação de schema/tamanho e negação padrão. Nenhum código de servidor (Cloud Functions/Storage/backups exigem Blaze e ficam fora).
4. **Offline/sync:** persistência nativa do Firestore (habilitada explicitamente na web) como cache e fila de escrita; Hive não guarda dados do usuário.
5. **Acoplamento:** `FavoritesRepository` passa a depender de uma interface `FavoritesDataSource` (impls: Firestore e Hive legado), o que mantém o backend substituível.
6. **Sem migração (decisão do Manager):** os dados locais atuais (box Hive `favorites`) são abandonados; não são lidos, migrados nem apagados. `LocalStore` permanece apenas para o cache de descoberta (ADR-002) e o novo cache de catálogo de temporadas.
6b. **Logout não limpa nada local (decisão do Manager).** O isolamento entre contas vem de: rules no servidor, leitura sempre escopada ao uid logado (data source recriado por uid; deslogado = vazio) e fila de escritas pendentes do SDK separada por usuário (premissa a validar no spike). iOS na App Store e Sign in with Apple são débitos futuros.
7. **Configuração:** `firebase_options.dart`, `google-services.json` e `GoogleService-Info.plist` versionados (públicos por design); API keys restritas por referrer/pacote/bundle; domínio `celsofabri.github.io` autorizado; plano Spark mantido, sem Blaze.
8. **Exclusão de conta:** orquestrada no cliente, com reautenticação e marcador `deleting` para ser retomável.

Versões consultadas no pub.dev em 2026-10-02 (a confirmar pelo resolver do projeto antes de fixar): `firebase_core 4.15.0`, `firebase_auth 6.7.0`, `cloud_firestore 6.10.0`, `google_sign_in 7.2.0`.

## Consequências

**Positivas**
- Multi-dispositivo e recuperação após limpar dados locais, objetivo central do Manager.
- Fila offline, retry e merge por campo prontos no SDK, evitando um motor de sync caseiro.
- Custo zero sem cartão, com folga de cerca de 20x nas cotas diárias para o uso esperado.
- Isolamento no servidor e config pública segura (sem segredos novos no CI).
- Backend trocável via `FavoritesDataSource`; exportação JSON planejada reduz lock-in.

**Negativas / riscos**
- Dependência do Google/Firebase e de o plano Spark continuar gratuito (sem garantia contratual); mitigação: abstração + exportação.
- Sem backups gerenciados nem código de servidor: exclusão e validações dependem de cliente + rules; recuperação de erro humano depende de exportação manual.
- Estouro de cota (ou abuso por conta Google qualquer) deixa o app em modo offline até o reset diário.
- Conflito no mesmo episódio é "último a chegar ao servidor vence" (variação do spec "último a alterar"); o cache do Firestore permanece no disco após logout (exposição em aparelho compartilhado, aceita pelo Manager); se a fila de pendências do SDK não for separada por uid (premissa não verificada), escritas offline podem se perder ao trocar de conta, e o fallback é uma outbox própria por uid.
- Favoritos locais antigos deixam de aparecer ao atualizar (abandono decidido); box não é apagado, rollback os reexibe.
- Mais configuração por plataforma (SHA-1, plist, domínio autorizado) e novas dependências nativas que aumentam o tamanho do app.
- Não verificados: separação por uid da fila de pendências do SDK, compatibilidade das versões com o SDK/CI atual, regiões com cota gratuita, retenção de backups técnicos do provedor após exclusão, comportamento exato de estouro de cota na Spark.
- Premissa "sem backend/ sem usuários" do ADR-001 deixa de valer: o app passa a tratar dados pessoais (LGPD): política de privacidade e exclusão obrigatórias.
