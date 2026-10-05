# 54 - Conferência final das regras sociais (Code Reviewer)

> Data: 2026-10-05 · Branch `feat/social-friends` (não commitada sobre `main` c60a393) · Entradas: [docs/51](./51-regras-sociais-fatia-0.md), [docs/53](./53-re-review-regras-sociais.md). Somente leitura: `git status` idêntico antes e depois (só este arquivo é novo).

## Veredito: REPROVADO (1 pendência 🟡, só de texto do docs/51 §7; nenhum 🔴; regras e testes OK)

As regras estão como revisei e os 5 itens de contrato do docs/53 foram fechados. Resta uma ambiguidade no passo a passo do Manager (smoke que depende de um app que ainda não existe no momento em que o texto manda fazê-lo). Corrigir é editar 3 frases, sem tocar em `firestore.rules`; depois disso o veredito vira APROVADO.

## (1) `firestore.rules` é o mesmo que revisei
- `git diff HEAD -- firestore.rules`: **+284/−0**, 348 linhas; mtime 10:26:04, anterior ao meu docs/53 (10:42). Nenhuma remoção, nenhuma mudança escondida. Reconferi os pontos de risco no texto: `isGoogle()` só em `create` (linhas 159, 200, 254, 291, 330), `validName` com `\p{Cc}`, ZW, bidi, U+2028/9, FEFF; `validPhoto` `^https://lh[0-9]+[.]googleusercontent[.]com/.*$` e ≤ 512; 31 reservados (contados: 11 originais + 20 novos, lista idêntica no docs/50 §4).
- Também alterados e coerentes: `firestore.indexes.json` (+2 compostos `to`/`from` + `createdAt` DESC, `COLLECTION`) e `package.json` (script `test:mutations`).
- Ressalva honesta: não tenho o arquivo do docs/53 byte a byte guardado; a conclusão vem do mtime anterior ao meu parecer, do diff aditivo e da releitura dos blocos críticos.

## (3) Execução real
| Execução | Resultado |
|---|---|
| `npm test` | **219/219 passam**, 0 falhas (64 existentes + 133 `social` + 13 `rules_budget` + 9 `social_compat`) |
| `npm run test:mutations` | **22/22 mortas** (M21 = foto sem âncora, M22 = `admin` liberado; fecham a R9 e a lacuna de reservados do docs/53) |

## (2) Itens do docs/53
| Item | Estado |
|---|---|
| 🟡-1 docs/50 desatualizado | **Resolvido.** docs/50 §2 (nickname UTF-16 e `photoURL` `lh<n>`), §4 (trecho com `validName`, `validPhoto`, 31 reservados, `isGoogle`, nota "texto de referência = firestore.rules + docs/51"), D10, riscos. Requisitos de cliente em docs/49 (linhas 308-311) e docs/50 (517-520): mensagem genérica única, `Random.secure()` ≥ 22 base62, `photoURL` só se casar com o padrão e ≤ 512 senão `null`, normalização do apelido (trim, NFC, invisíveis, NBSP/U+3000/tags). |
| 🟢-1 números | Resolvido (+284, 31 reservados, 219, 22). |
| 🟢-2 teste de prefixo antes de `lh` | Resolvido (testes `https://evil.com/?https://lh3...` e `evil.com?lh3...`, mutação M21 morta). |
| 🟢-3 apelido invisível | Aceito e registrado como limitação (docs/51 §8, docs/49/50), com teste `KNOWN LIMIT`. |
| 🟢-4 40 CJK / 20 emoji | Resolvido (aceitos, +1 negado) e o requisito de UTF-16 está nos requisitos de cliente da Fatia 1 (docs/49 linha 311, docs/50 linha 520, tabela do docs/50 linha 39: "igual a `String.length` do Dart"). Atende a observação pedida. |
| R2/R3 | Documentados como redundância de desenho (docs/51 §6); M15 prova que sem as duas não funciona. |

ADR-005: D10 (`lh<n>.googleusercontent.com`) coerente. Regras, docs/49, 50, 51 e ADR concordam em reservados (31), regex da foto, `validName`, limites, 219/22/+284 e na ordem regras, índices, app.

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes
**🟡-1. docs/51 §7 (lido como se eu fosse o Manager) tem uma ambiguidade que afeta a publicação única.**
1. **Smoke impossível no ponto em que está.** O passo 5 diz "Smoke com 2 contas Google **logo após publicar**: criar o perfil social, enviar pedido, aceitar". Mas o passo 4 manda fazer o deploy do app só depois e, hoje, **não existe UI/código social** (Fatia 0 = só regras). O Manager não tem como criar "José 🎬" nem enviar pedido logo após o passo 2. Corrigir: dizer em que momento o smoke roda (por exemplo "com o primeiro build da Fatia 1, ainda sem divulgar; até lá o RE2 de produção fica não verificado além do aceite do editor") ou fornecer um roteiro sem app (ex.: o Rules Playground do console só simula e não cobre `matches` em runtime com segurança, então declarar a limitação).
2. **Falta o que fazer se o smoke falhar.** O texto diz "nunca voltar as regras" e "correções só para frente", mas não diz a ação: **republicar uma versão corrigida (p.ex. sem a linha `matches` do `validName`) é permitido e é o conserto**; "não voltar" significa não republicar versão **sem** as invariantes/Fatia 0. Sem essa frase, o Manager pode achar que não há saída. Também falta "avisar o Orquestrador/Dev BE antes de republicar".
3. **Pequenos pontos de clareza**: o parágrafo "Depois de publicar: conferir data/hora..." está colado ao passo 3 (índices) mas pertence ao passo 2; falta dizer onde ver "Enabled" (console > Firestore > Índices > Compostos, coluna Status; passa de Building para Enabled); não diz que a ordem regras antes de índices é indiferente para o app atual (só importa os dois antes do app).

## 🟢 Sugestões
- docs/50 (§14 passo 2, "76 testes") e ADR-005 (linha 60, "47 novos + 76 existentes") ainda citam 76; o repositório tem 64 existentes e 219 no total. Ajustar ou apontar para o docs/51 §5.
- docs/50 §11 (linha 420) fala "foto fora de `googleusercontent.com`": está correto, mas pode citar `lh<n>`.
- Passo 1 do §7 ("exportar a conta") não diz para quê; acrescentar "linha de base para comparar depois".

## (4) O que continua não verificado (declarado em docs/51 §8, confere)
Nada em Firebase real (limite de chamadas em `in`, cobrança das leituras de regra, `existsAfter`), índices e tempo até Enabled, **RE2 `\p{Cc}`/`\x{...}` e contagem de `size()` em produção** (agora com teste no emulador de 40 CJK/20 emoji, mas produção é inferência), entropia do convite, Dart/UI, relógio. Também não verificado por mim: texto literal da doc oficial sobre o claim `sign_in_provider`. Declarado também: limitação de apelido invisível, resíduo de bloqueio e desativar/reativar contornando os 30 dias.

## (5) Pronto para o Manager?
Quase: os passos 0 (somente Google), 2 (publicar, conferir data/hora e ausência de erro, ~1 min), 3 (criar os 2 índices por CLI ou console, campos e ordem corretos, esperar Enabled) e a regra "não publicar parcial se o console recusar" estão corretos e completos. Como reverter sem voltar as regras: está dito só "rollback seguro = só do app"; falta a frase de correção para frente (🟡-1.2). Resolvido o 🟡-1, o Manager pode seguir sem dúvida.

## Segurança
Sem 🔴 nem 🟡 de segurança. A pendência é de documentação operacional.
