# 39 - Exportar meus dados (JSON) - Fatia 0

Contexto: rede de segurança antes de mudar regras do Firestore (ADR-004, docs/35 R.6, docs/36 R.6) e portabilidade da LGPD (art. 18). Só leitura: nenhuma escrita, nenhuma mudança de regras.

## O que o usuário vê
Perfil, seção "Seus dados" (logo antes de "Sair" e "Excluir minha conta e dados"): botão "Exportar meus dados (JSON)" (alvo >= 48 px, semântica de botão). Toque abre um diálogo (foco em Cancelar): arquivo com dados pessoais, guardar em lugar seguro, nada enviado a terceiros, o app não guarda cópia. Confirmando:

| Estado | Comportamento |
|---|---|
| Carregando | spinner + "Lendo seus dados… N itens até agora" (leitores de tela ouvem só "Exportando seus dados"), botão desabilitado (sem duplo toque), "Cancelar" |
| Sucesso | "Pronto: N itens no arquivo cinetrack-export-AAAA-MM-DD.json. O download foi iniciado…" + avisos condicionais (dados do aparelho, alterações não enviadas, itens não interpretados) |
| Servidor inacessível | cartão: "Tentar de novo" / "Exportar dados deste aparelho" / "Cancelar". Nada é entregue antes da escolha |
| Erro | mensagem por causa (recusado, sem dados no aparelho, download bloqueado, genérico), "Tentar novamente" / "Fechar" |
| Plataforma sem entrega (Android/iOS) | texto explicando que está na versão web; sem botão |

## Decisões (e justificativas)
- **Offline: oferecer, não bloquear.** Bloquear deixaria o usuário sem cópia justamente quando ele mais pode precisar; gerar em silêncio seria enganoso. Então: tenta o servidor (`Source.server`, timeout de 30 s por página); se não confirmar, pergunta; o arquivo do aparelho sai com `source: "device-cache"`, `complete: false` e aviso na tela. Cache vazio nunca vira arquivo ("não há dados neste aparelho").
- **Sem e-mail, foto, nem uid no arquivo.** Mínimo necessário: e-mail e foto vêm do Google e não estão no Firestore (a política diz isso); o arquivo tende a ficar solto em Downloads. O uid não é necessário para o titular (restauração é feita para a conta logada). Incluído: apelido (`profile.displayName` + documento bruto `users/{uid}`) e os favoritos.
- **Documento bruto, não o modelo do app.** `data` é o mapa do documento como está no Firestore: `eps`, `seasonSummaries`, `watchedMovie`, `addedAt`, `lastWatchedAt`, `updatedAt` e qualquer campo futuro (`recommended`) entram sem mudar o exportador. Timestamps viram ISO 8601 UTC; `timestampFields` lista quais campos de topo eram timestamps (para restaurar).
- **Documentos que o app não entende (corrompidos ou de versão nova) não derrubam nada:** entram crus e são listados em `issues` (`not-recognized-by-app`); valores não representáveis em JSON viram marcador tipado (`unsupported-value`); falha ao serializar um documento (`encode-failed`, não deve ocorrer) marca `complete: false`.
- **Paginação:** 300 documentos por leitura, ordem por id (`orderBy(documentId)` + `startAfter`), sem teto de total; trava de segurança se o cursor não avançar. A UI cede o frame entre páginas. O JSON é montado por documento (uma linha por favorito).
- **Troca de conta:** o uid é conferido após cada leitura e imediatamente antes de entregar; mudou (ou o usuário cancelou) = resultado descartado, nada é entregue, estado reiniciado.
- **Entrega web:** Blob + âncora `download`, nome `cinetrack-export-AAAA-MM-DD.json` (data local). O Blob só existe na memória e a URL é revogada depois; nada vai para Hive/IndexedDB do app, nada é enviado, nada vai para log (só o código de erro do Firestore).
- **Mobile:** import condicional (`dart.library.js_interop`): a versão não-web compila com um stub "não suportado". Compartilhar/salvar em Android/iOS exigiria plugin nativo; fica fora até haver uso (nova dependência pesada sem benefício hoje).
- **Dependência:** `web: ^1.1.1` passa de transitiva para direta (já estava no `pubspec.lock` na 1.1.1; nenhum pacote novo baixado). É o pacote oficial do Dart para `dart:js_interop` no navegador.
- **Versão do app:** `kAppVersion` (sem `package_info_plus`, que é plugin nativo); um teste garante que bate com o `version:` do pubspec.

## Formato (`schemaVersion: 1`; a versão atual é a 2, abaixo)
```json
{
  "schema": "cinetrack-export",
  "schemaVersion": 1,
  "exportedAt": "2026-10-03T12:00:00.000Z",
  "app": {"name": "CineTrack", "version": "0.1.0"},
  "source": "server",            // ou "device-cache"
  "complete": true,              // false se veio do aparelho ou houve encode-failed
  "profile": {"displayName": "Ana", "data": {...}},   // null se não há documento
  "counts": {"documents": 54, "movies": 30, "series": 24, "watchedMovies": 12, "watchedEpisodes": 480, "notRecognized": 0},
  "issues": [{"key": "...", "reason": "not-recognized-by-app"}],
  "favorites": [
    {"key": "1396-tv", "timestampFields": ["addedAt", "lastWatchedAt", "updatedAt"], "data": {"id": 1396, "eps": {"1_1": true}, "recommended": true, "...": "..."}}
  ]
}
```
### `schemaVersion: 2` (amizades, fase 1; documentado no fechamento, docs/71 G3)
O app atual gera a versão **2**. Ela só **acrescenta** a chave `social` entre `profile` e `counts`; todo o resto é igual à versão 1 (um arquivo v1 continua sendo um subconjunto válido; teste `social_export_test.dart`).
```json
{
  "schema": "cinetrack-export",
  "schemaVersion": 2,
  "...": "header, profile como na v1",
  "social": null,                 // nunca ativou as amizades (e não há resíduo)
  "social": {
    "handle": "ana_9",            // null se só há resíduos (sem ponteiro)
    "discoverable": true,
    "photoVisible": true,
    "pointer": {"timestampFields": ["handleChangedAt"], "data": {"handle": "ana_9", "handleChangedAt": "...", "schemaVersion": 1, "inviteCode": "..."}},
    "card":    {"timestampFields": ["createdAt", "updatedAt"], "data": {"uid": "<seu uid>", "nickname": "Ana", "photoURL": "https://lh3...", "discoverable": true, "...": "..."}},
    "invite":  {"code": "...", "createdAt": "...", "expiresAt": "...", "exists": true},   // null sem convite
    "counts":  {"friends": 2, "requestsSent": 1, "requestsReceived": 0, "blocks": 1},
    "friends":          [{"key": "uidA_uidB", "uid": "<uid do amigo>", "nickname": "Bia", "since": "..."}],
    "requestsSent":     [{"key": "<seu uid>_<uid>", "uid": "<uid>", "nickname": "Caio", "createdAt": "..."}],
    "requestsReceived": [{"key": "<uid>_<seu uid>", "uid": "<uid>", "nickname": "Dora", "createdAt": "..."}],
    "blocks":           [{"key": "<uid>", "uid": "<uid>", "nickname": "Zeca", "createdAt": "..."}]
  },
  "counts": {"...": "como na v1"},
  "issues": [{"key": "friendships/<id>", "reason": "not-recognized-by-app"}],
  "favorites": ["como na v1"]
}
```
- `pointer` e `card` são os documentos `social/{uid}` e `handles/{handle}` **crus** (todos os campos, inclusive futuros), no mesmo formato dos favoritos (`timestampFields` + `data`).
- Das outras pessoas vão **só uid e apelido** (instantâneos), nunca fotos (D9). Um documento que o app não entende entra em `issues` e na lista com os nomes e tipos dos campos, sem valores.
- O **seu uid** aparece em `card.data.uid` e nas chaves compostas (`key`) de pedidos e amizades (docs/71 G4). O e-mail nunca entra.
- O código do convite é um segredo (quem o tem vê o seu cartão): trate o arquivo como o próprio link.
- **Resíduos sem ponteiro** (desativação cuja última varredura falhou, exclusão interrompida): as 4 listas são lidas mesmo sem `social/{uid}` (4 leituras a mais para quem nunca ativou; com as regras antigas a leitura é negada e significa "nada"). Se houver resíduo, a seção sai com `handle: null`, `pointer: null` e as listas (docs/73).

Restaurar (fora do escopo; sem importação no app): para cada entrada, trocar os `timestampFields` de `data` por Timestamp e gravar em `users/{uid}/favorites/{key}`. O teste de round-trip faz isso e passa o resultado pelo `FavoriteMapper`.

## Arquivos
`lib/export/` (serializador, `runExport`, `file_saver*`), `lib/data/export_data_source.dart` (interface), `lib/data/firestore_export_data_source.dart`, `lib/providers/export_providers.dart`, `lib/widgets/export_data_section.dart`; testes `test/export_serializer_test.dart`, `test/export_data_section_test.dart`, fake `test/support/fake_export_data_source.dart`.

## Custo
1 leitura por documento (54 hoje) + 1 do perfil por exportação; a leitura final de página curta evita consulta vazia extra; a cada múltiplo exato de 300 há uma consulta vazia (custo mínimo de 1 leitura). Anti-duplo-toque na UI.

## Revisão (docs/41) - correções
- `FirestoreExportDataSource`: conversão (`convert`/`convertValue`), mapeamento de erros (`mapError`) e `guard` (timeout) agora são estáticos `@visibleForTesting` e testados em `test/firestore_export_data_source_test.dart` com `Timestamp` reais (topo, Map, List, nanos, null, NaN/Infinity, int grande) e `FirebaseException`/timeout. Mutação: remover `Timestamp() => toDate()` ou o mapeamento `permission-denied` quebra os testes. A query em si (`orderBy`/`startAfter`/`Source`) continua sem teste automatizado (não há fake de Firestore no projeto): fica no roteiro manual do QA.
- Botões da seção com alvo >= 48 px também em desktop (`visualDensity: standard`, pois a densidade compacta reduzia 48 para 40), incluindo "Cancelar" do carregamento; teste de 320 px com fonte 3x, claro/escuro, estados carregando/offline/sucesso/erro.
- `profile.timestampFields` marca timestamps do perfil. Política: frase de contato para cópia fora da web.
- Limites conhecidos: `Timestamp.toDate()` na web perde sub-milissegundo (só diminui o valor); `hadPendingWrites` é lido só no início do export (escritas feitas durante a leitura não geram aviso; o arquivo é uma foto do servidor).

## Não verificado
- `FirestoreExportDataSource` contra Firestore real/emulador (sem credenciais no ambiente): `Source.server`/`Source.cache`, `startAfter([id])` com `documentId()` e o comportamento de erro offline na web seguem a documentação do SDK. Roteiro para o QA/Manager: exportar com a conta real, conferir `counts` com o Perfil; repetir em modo avião (deve oferecer a escolha); conferir leituras no console.
- Download real no navegador (Chrome/Safari/Firefox), bloqueio de download, aparência visual (só testes de widget e overflow).
- Se leituras `Source.server` incluem escritas locais ainda não confirmadas: assumido que não; por isso o aviso "havia alterações ainda não enviadas".
- Android/iOS: só compilação do stub por análise estática; não foi gerado build nativo.
