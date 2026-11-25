# 0001 — Prévia das janelas com ScreenCaptureKit e Gravação de Tela opcional

Status: aceito (2026-11-24)
Decisores: mantenedores do Ronic DockPane

## Contexto

A primeira versão (0.1.x) só listava os títulos das janelas, lidos pela API de Acessibilidade.
Isso era uma escolha deliberada: sem captura de imagem, o app não pedia **Gravação de Tela**, tinha
uma única permissão e consumia pouca memória.

O comportamento esperado, porém, é o da barra de tarefas do Windows: ao passar o mouse no ícone,
ver uma **miniatura do conteúdo** de cada janela. Isso não é possível só com Acessibilidade; o
conteúdo da janela de outro app só pode ser lido com captura de tela, que no macOS exige a
permissão de Gravação de Tela.

## Decisão

1. O painel passa a exibir uma miniatura por janela, em cartões (até 4 colunas com o Dock embaixo,
   uma coluna com o Dock nas laterais), com o título acima.
2. A captura usa **ScreenCaptureKit** (`SCScreenshotManager`, uma imagem por janela, sob demanda).
   Nada de stream contínuo, nada em disco: as imagens vivem na memória enquanto o painel está aberto.
3. A permissão de Gravação de Tela é **opcional**. Sem ela, o painel continua funcionando com a
   lista de títulos da versão anterior. A Acessibilidade segue obrigatória.
4. O app pergunta pela permissão **uma única vez** (alerta amigável) e deixa um item no menu para
   ativar depois. O menu mostra o estado das prévias.
5. O painel abre imediatamente, com cartões do tamanho final e o ícone do app como substituto; as
   miniaturas entram quando a captura termina (cerca de 0,5 s para 4 janelas nos testes).
6. As prévias exigem macOS 14 (`SCScreenshotManager`). O app continua rodando no macOS 13, só sem
   miniaturas.
7. A captura de demonstração do README usa miniaturas **desenhadas**, nunca janelas reais.

## Alternativas consideradas

- **Manter só a lista de títulos** — preserva a permissão única, mas não entrega o comportamento
  pedido.
- **`CGWindowListCreateImage`** — API antiga, obsoleta a partir do macOS 14 e indisponível nos SDKs
  novos; também exigiria a mesma permissão.
- **`SCStream` (captura contínua, ao vivo)** — dá prévia animada, mas mantém a captura ativa, usa
  mais CPU/memória e dispara o indicador de gravação do sistema por mais tempo. Fica como possível
  evolução.
- **Exigir macOS 14 em tudo** — simplificaria o código, mas deixaria o macOS 13 sem o app.

## Consequências

- O README deixa de afirmar que o app nunca captura a tela; a seção de privacidade descreve o que
  é capturado, onde fica e que a permissão é opcional.
- A meta original de baixo consumo de memória fica mais difícil: cada miniatura (cerca de
  440×276 px) ocupa algumas centenas de KB enquanto o painel está aberto, e é descartada ao fechar.
- Com assinatura ad-hoc, o macOS pode pedir de novo a Gravação de Tela a cada versão baixada. O
  `scripts/dev-signing.sh` mantém a permissão nas builds locais.
- Janelas minimizadas podem não ter captura; nesse caso o cartão mostra o ícone do app, esmaecido.
