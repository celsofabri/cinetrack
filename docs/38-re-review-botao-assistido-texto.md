# 38 - Re-review: botão de assistido com texto (fix/quick-watched-label)

Revisor: Code Reviewer. Escopo: `git diff` contra main (lib: favorites_section.dart, detail_actions.dart; testes; docs/30). docs/35, 36 e adr-004 ignorados. Código não alterado.

## Resultados reais (rodados por mim)
- `flutter analyze`: No issues found.
- `flutter test`: 502/502 passaram.
- `flutter build web`: ok.

## Status dos itens do docs/37
1. 🟡1 (altura fixa estoura em fonte grande): FECHADO. `mainAxisExtent` e o clamp de escala foram removidos; a grade é uma coluna de linhas `IntrinsicHeight` e o número de colunas sai de `LayoutBuilder` com `ceil(inner / (460 + 12))`, equivalente ao delegate anterior (1 coluna em 320/360, 2 em 768, 3 em 1024/1440; largura do cartão nunca passa de 460). Teste cobre 1x/2x/3x x 320/360/768/1024/1440 x claro/escuro (30 casos), sem exceção e com alvo >= 48. Passa pelo motivo certo: o 3x falhava com overflow no código antigo.
2. 🟡2 (chip na base): FECHADO. `Spacer()` antes do chip, cartão com `CrossAxisAlignment.stretch` dentro da linha esticada. Teste compara `bottomLeft.dy` dos chips vizinhos (filme sem selo ao lado de série com selo) a partir de 768 px; sem o Spacer eles divergiriam, então o teste pode falhar.
3. 🟡3 (nome acessível contém o texto visível): FECHADO. "Marcar como assistido: Filme M", "Assistido: desmarcar Filme M", série "Marcar como assistido: todos os episódios de X" / "Assistido: desmarcar todos os episódios de X". Começam pelo texto visível. Testes de semântica checam o label exato e o estado selecionado.

## Falhas novas procuradas
- Custo de IntrinsicHeight: medido em cópia fora do repo (flutter test, 1024 px). 54 itens: pump 876 ms, 5 rolagens 123 ms, toggle 8 ms. 500 itens: pump 1757 ms, rolagem 230 ms, toggle 34 ms. A main, com o mesmo teste: 54 itens 1101 ms / 500 itens 1860 ms de pump, rolagem 124 / 181 ms. Ou seja, paridade com a main; não é regressão. A intrinsic é um nível só (sem aninhamento exponencial) e o Chip implementa intrinsics.
- Rolagem preguiçosa: a grade nunca foi preguiçosa (antes `GridView shrinkWrap` + `NeverScrollable` dentro de um `ListView` com um único filho; agora Column dentro do mesmo ListView). Mesmo comportamento, construção total em ambos; 500 itens a 1,7 s no teste (VM de teste, não dispositivo) é igual ao baseline. Fora do escopo desta correção; se virar necessidade, entra na frente de Biblioteca (docs/35-36).
- LayoutBuilder dentro de ListView (viewport com largura limitada, altura ilimitada): sem erro; só usa maxWidth.
- Alturas desiguais na linha: cartões esticam à altura do mais alto (título de 1 vs 2 linhas, com e sem selo); chip na base. Coberto pelo teste de alinhamento.
- Foco/teclado/ordem: ordem de leitura linha a linha, cada cartão com InkWell e depois o chip; é a mesma ordem estrutural de antes (chip estava dentro do cartão). FilterChip ativa com Enter/Espaço. Rolagem e restauração: mesmo ListView, sem controller novo, estado do Riverpod intacto.
- Favoritos (abas Em andamento/Concluídos, filtros, ordenação), Desfazer, "salvando…" (pending vira spinner no chip, `onSelected` nulo), diálogo da série: lógica de `onToggleWatched` e do pai intocada; suíte inteira passa (502).
- `ValueKey(storageKey)` mantida por cartão: estado preservado quando a linha muda de composição.

## 🔴 Bloqueantes
Nenhum.

## 🟡 Importantes
Nenhum.

## 🟢 Cosméticos (irrelevantes, não bloqueiam)
- Tooltip só aparece em hover/long press; inofensivo.
- Linha de `pending: busy.contains(...)` passa de 100 colunas no formatter; analyze não reclama.

## Não verificado
Captura visual em navegador/dispositivo real, leitor de tela real, e desempenho em dispositivo físico (medido só no ambiente de teste).

## Veredito: APROVADO
