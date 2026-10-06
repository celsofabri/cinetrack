# 69 - Code review: amizades, fatia 5 (convite por link, refresh de apelido/foto, fechamento do desativar)

> Revisor: Code Reviewer (gate). Escopo: working tree NAO commitado sobre 5f39d73. Somente leitura; mutacoes extras em copias no scratchpad. `git status` identico antes e depois.

**Veredito: REPROVADO** (1 bloqueante de ferramenta e 1 importante; o Manager exige APROVADO limpo). Nenhum problema de seguranca ou de perda de dados; os dois itens sao correcoes pequenas.

## Numeros que eu mesmo rodei
| Verificacao | Resultado |
|---|---|
| `flutter analyze` | 0 problemas |
| `flutter test` | **1485 passaram**, 0 falhas |
| `flutter build web --release --base-href /cinetrack/` e sem base-href | ok nos dois |
| `npm test` (emulador, copia em porta 8191, pois a 8080 estava ocupada por outro processo) | **364/364** |
| `npm run test:mutations` **no repositorio** | **FALHA: SyntaxError em `mutations.mjs:142`** (ver F1) |
| `test:mutations` com a aspa corrigida so na copia | **48/48 mortas** |
| 4 mutacoes minhas (em copia, rodando dart_payloads + social) | todas mortas: codigo curto (`{22,40}`->`{4,40}`, 2 falhas), expiracao 90 dias (3), ponteiro nao movido no revogar (4), metade do outro no friendships (2) |
| `firestore.rules`, `firestore.indexes.json`, pubspec | sem diff |
| Chrome (`/#/invite/<codigo>`) | **nao verifiquei** (nao abri o navegador; confio so no relato do dev) |

## 🔴 Bloqueantes
**F1. `npm run test:mutations` nao executa: `firestore_rules_test/mutations.mjs:142`.**
`['F10 invite document written with somebody else's uid',` tem apostrofo dentro de string entre aspas simples: `node --check` da `SyntaxError: Unexpected identifier 's'`. O "48/48" declarado nao e reproduzivel no estado entregue; todo o gate de mutacoes (regras e payloads) fica inoperante. Corrigido apenas na minha copia, aí 48/48 mortas (as 11 novas M34-M38, F5-F10 funcionam). Correcao: trocar por `somebody else uid` (ou escapar) e rodar `npm run test:mutations` antes de entregar.

## 🟡 Importantes
**F2. A recuperacao "par removido durante o refresh" nunca dispara no SDK real: `lib/repositories/social_repository.dart` (laco de `refreshFriendHalves`, `e.code != 'not-found'`).**
Atualizar `friendships/{par}` inexistente faz as regras avaliarem `resource.data.members` com `resource == null`: o resultado e `permission-denied`, nao `not-found`. O proprio teste de regras confirma (`dart_payloads.test.mjs` ~1540: "a pair that no longer exists makes the batch fail whole" usa `assertFails`). `SocialFailure.fromFirestoreCode` mapeia isso para `denied`, que o laco relanca. So o fake (`not-found`) exercita a releitura.
Cenario: Ana muda o apelido; durante a passada o amigo remove (ou bloqueia) Ana entre a leitura da pagina e o batch; o batch falha inteiro, a UI mostra "Seu novo nome ou foto ainda nao chegou a todos os amigos" + "Tentar de novo" e o marcador fica; as metades dos outros 99 amigos da pagina ficam velhas ate a pessoa tocar em tentar (a releitura depois funciona). Nao ha perda de dados, nem ressurreicao da amizade (as regras negam; confirmado), mas viola "ninguem precisa fazer nada" numa corrida plausivel.
Correcao: tratar `denied` (alem de `not-found`) como "reler a pagina" ate 3 tentativas, e adicionar teste com o fake lancando `permission-denied`.

## 🟢 Sugestoes
- **G1.** `SocialController.deactivate` chama `cancelAndClear()` antes de `_run(deactivate)`. Se o desativar falhar (offline, negado) com as amizades ainda ativas, o marcador de refresh pendente ja foi apagado e o apelido novo nao chega mais aos amigos ate a proxima troca. Limpar o marcador so depois do sucesso (cancelar a passada antes, sim; apagar o marcador depois).
- **G2.** `FirestoreSocialDataSource.read`: se a leitura do convite falha (rede), `invite` fica nulo e a UI mostra "Criar link" mesmo havendo ponteiro (`InviteInfo.missing`); criar entao troca o link antigo em silencio. Diferenciar "nao carregou" de "nao existe".
- **G3.** Relogio do aparelho atrasado mais que a validade (ex.: 2 dias para "1 dia") faz `expiresAt > request.time` falhar: falha visivel (mensagem de convite), sem dano. O docs/68 diz "relogio atrasado so encurta"; ajustar a frase.
- **G4.** Politica (`privacidade.html`) diz "Perfil -> Amigos" para criar o convite; o caminho e Perfil -> Amizades.
- **G5.** O dono que abre o proprio link ve "Este convite nao esta disponivel" (decisao consistente com a mensagem unica; so documentar).
- **G6.** A exportacao inclui o codigo do convite (segredo do proprio usuario): aceitavel, o comentario avisa; vale uma linha no texto da tela de exportacao.

## Verificacoes sem achado
1. **Contrato Dart x regras**: `createInvite` (transacao: delete antigo?, set convite, update ponteiro) casa campo a campo com `validInviteCard`/`inviteTransitionOk`/delete do convite; `photoURL` omitido sem foto, `null` no update; `createdAt` = `serverTimestamp`; revogar = delete + `deleteField` no ponteiro (a regra le `.get('inviteCode', null)`); refresh escreve so `aName/aPhoto` ou `bName/bPhoto`, `null` aceito por `validPhoto`. O `.mjs` traduz `$now+N` para `Timestamp.fromMillis(Date.now()+N)` e `$deleteField` para `deleteField()`, equivalentes a `Timestamp.fromDate(DateTime.now()+offset)` e `FieldValue.delete()` do SDK Dart. "30 dias" = 29,5 dias: margem de 12 h para relogio adiantado; adiantado >12 h nega com falha visivel. Golden + fixture + replay cobrem criar (valido, formato, >30 d, 2o convite, sem social, nao-Google), revogar (propria/alheia), usar, refresh (propria/alheia/invalidos/100 por batch) e cartao com convite. Limite honesto: `Transaction`/`FieldValue` do SDK Dart real continuam sem execucao contra o emulador (so fake + replay JS), como o dev declarou.
2. **Seguranca do convite**: `Random.secure()` por padrao; `random:` so e parametro de construtor, o provider de producao nao o passa; 24 base62 (~143 bits), sem `list`; codigo malformado nem chega ao servidor; expirado/bloqueado (negado) e inexistente (sem documento) viram a mesma mensagem, 1 `get` em todos; convite nunca cria amizade (pedido normal; teste de replay); bloqueio, limite de 50 e regras do pedido valem; desativar/excluir apagam o convite no batch (regra exige) e foram testados com convite real. Link usa `#`: fragmento nao vai ao servidor nem ao Referer; nao ha analytics/telemetria; nenhum `debugPrint` com codigo (so o codigo de erro).
3. **Refresh**: so a minha metade; pedidos/bloqueios intocados; lido do servidor (pagina de cache recusada); marcador por uid apagado so no fim; coalescencia e geracao corretas; troca de conta/desativar nao tocam a conta nova; amizade removida nao e ressuscitada (update em doc inexistente e negado). Custo N leituras + M escritas em lotes de 100 coerente com a cota do docs/68 (regra sem chamada extra).
4. **Rotas**: `/invite/:code` e publica, fora do redirect de `/friends*`; sem conflito; hash strategy nao alterada; nenhuma intencao pendente persistida (o endereco e a intencao); login por popup preserva a pagina.
5. **UI/a11y**: alvos >= 48 px, foco inicial em Cancelar nas confirmacoes, regioes vivas para feedback, indicador do refresh no fim do cartao (sem layout shift), Web Share so quando existe a API; testes cobrem 320-1440 px, fonte 3x e claro/escuro.
6. **Privacidade/LGPD**: politica, resumo no app e README coerentes com o comportamento; data "Ultima atualizacao" e comentario ATUALIZAR intactos; exportacao `social.invite` aditiva (schema 2).
7. **Regressoes**: 1343 testes anteriores passam; os ajustes em `social_section_test`/`profile_screen_test` (rolar ate o botao, escopo do `AlertDialog`) sao legitimos, sem enfraquecer asserções; hooks em `fake_social_cloud`/`favorites_harness` apenas adicionam metodos/marcador. Diff sem churn de formatacao.

## Para o re-review
Corrigir F1 (1 caractere) e F2 (+ teste), rodar `npm run test:mutations` no repositorio e reportar 48/48. G1 e G2 recomendados no mesmo ajuste.
