# 0002 — Alternador de janelas no ⌥Tab, com CGEventTap e o Ronic MacToWindows

Status: aceito (2026-11-25)
Decisores: mantenedores do Ronic DockPane

## Contexto

O ⌘Tab do macOS troca de **app**, não de janela. Para chegar a uma janela específica é preciso
trocar de app e depois procurar a janela. A versão 0.4.0 traz um alternador de **janelas** com
miniaturas, como o Alt+Tab do Windows, reaproveitando os cartões do painel do Dock.

Ele precisa de três coisas que a API pública do AppKit não dá juntas:

1. **Capturar** o ⌥Tab, para que o Tab não chegue ao app da frente.
2. Saber quando o **⌥ é solto**, que é o momento de trocar.
3. Engolir as setas, o Esc e o Enter enquanto o alternador está aberto.

Há outro detalhe: o **Ronic MacToWindows**, da mesma família, já usa ⌥Tab (Alt+Tab) para trocar de
app. O tap de teclado dele fica no nível HID, à frente de todos os outros, e consome o atalho.

## Decisão

1. **CGEventTap de sessão** (`.cgSessionEventTap`, `.defaultTap`) para `keyDown`, `keyUp` e
   `flagsChanged`, na run loop principal:
   - ⌥Tab abre o alternador ou avança; ⌥⇧Tab volta.
   - Com o alternador aberto, as teclas são engolidas: setas, Esc (cancela) e Enter (confirma).
   - Soltar o ⌥ (`flagsChanged` sem `maskAlternate`) troca para a janela escolhida.
   - Qualquer outra tecla passa intacta, e nenhuma tecla é gravada nem registrada em log.
2. **Rede de segurança:** um timer de 250 ms, ativo só enquanto o alternador está aberto, lê
   `CGEventSource.flagsState`. Se o ⌥ não estiver mais pressionado (um key-up perdido por entrada
   segura ou timeout do tap), o alternador fecha. Ele nunca fica preso engolindo o teclado.
3. **Ordem das janelas** = ordem de empilhamento na tela (`CGWindowListCopyWindowInfo`, só limites
   e dono, sem precisar de Gravação de Tela), casada com as janelas da Acessibilidade pelo frame.
   Minimizadas e de apps ocultos vão para o fim. Como no ⌘Tab, um toque rápido vai para a janela
   anterior sem mostrar o painel (ele só aparece após 120 ms com o ⌥ seguro).
4. **Convivência com o MacToWindows** por notificação distribuída:
   - O DockPane posta `io.github.jhowmael.ronicdockpane.switcher` com `"on"` ou `"off"` quando o
     alternador liga ou desliga (menu, saída do app).
   - Quem chega depois posta `io.github.jhowmael.ronicdockpane.switcher.query`, e o DockPane
     responde com o estado atual.
   - O MacToWindows cede o ⌥Tab enquanto o estado for `"on"`. Se o DockPane sair ou travar, ele volta
     a usar o Alt+Tab de apps (também observa o término do processo).
   - Tudo com `deliverImmediately`, porque apps de barra de menus nunca ficam "ativos".
5. Para outra combinação, `defaults write io.github.jhowmael.ronicdockpane switcherKeyCode -int <código>`
   troca a tecla usada com o ⌥ (50 = a tecla à esquerda do 1).

## Alternativas consideradas

- **`RegisterEventHotKey` (Carbon):** captura o ⌥Tab, mas não avisa quando o ⌥ é solto nem deixa
  engolir as setas. Seria preciso um monitor de teclado à parte, ou seja, outro mecanismo de qualquer jeito.
- **`NSEvent.addGlobalMonitorForEvents`:** só observa, não consome. O Tab chegaria ao app da frente.
- **Tap no nível HID, à frente do MacToWindows:** dependeria da ordem em que os apps abrem (o último
  tap inserido na frente ganha). Frágil.
- **APIs privadas de foco** (`_SLPSSetFrontProcessWithOptions`): mais confiáveis para trazer a janela,
  mas podem quebrar a cada versão do macOS. Em vez delas, além de `activate()`, o app marca
  `AXMain` na janela e `AXFrontmost` no app pela Acessibilidade, que já é permitida.

## Consequências

- O tap enxerga todas as teclas. O código só reage ao ⌥Tab e, com o alternador aberto, às teclas de
  navegação. Isso está documentado no README, na seção de privacidade.
- Usa a mesma permissão de Acessibilidade que o app já pede; sem ela, o tap não é criado e o app
  tenta de novo a cada 3 s até a permissão ser dada.
- Janelas de outros Spaces continuam de fora (mesma limitação do painel do Dock).
- O cache de miniaturas por janela (na memória, podado às janelas que ainda existem) faz o
  alternador e o painel abrirem já com imagens. Cada miniatura tem algumas centenas de KB.
