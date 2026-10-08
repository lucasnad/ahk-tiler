# ahk-tiler

Gerenciador de janelas em mosaico (tiling) + barra de status para Windows, em **um único
script AutoHotkey v1.1** (`tiler.ahk`) e um arquivo de configuração (`tiler.ini`).
Pensado para máquinas onde só o AHK v1 está liberado: não precisa de admin, instalação
nem biblioteca externa.

## Requisitos

- Windows 10 ou 11.
- AutoHotkey **v1.1** Unicode (32 ou 64 bits; testado com 1.1.37.02 nas duas). Não roda no v2.
- Para saber a versão, dê dois cliques em `versao.ahk`. Precisa mostrar `1.1.x` e `unicode=1`
  (`ptr=8` é 64 bits, `ptr=4` é 32 bits; os dois funcionam).

## Como usar

1. Baixe a pasta (ou só `tiler.ahk` + `tiler.ini`).
2. Dê dois cliques em `tiler.ahk` (ou abra com o AutoHotkey v1).
3. A barra aparece no topo de cada monitor e as janelas passam a ser organizadas.
4. **Tecla de pânico: `Ctrl+Alt+Shift+Esc`** devolve todas as janelas escondidas e fecha o script.

Para iniciar com o Windows, coloque um atalho do `tiler.ahk` em `shell:startup`.

## Atalhos padrão (editáveis em `tiler.ini`, seção `[hotkeys]`)

| Atalho | Ação |
|---|---|
| `Alt+H/J/K/L` ou setas | foco esquerda/baixo/cima/direita (atravessa monitores) |
| `Alt+Shift+H/J/K/L` ou setas | move a janela (troca de lugar; no limite, vai pro outro monitor) |
| `Alt+U / P` | diminui / aumenta a largura da janela em foco |
| `Alt+O / I` | aumenta / diminui a altura |
| `Alt+R` | promove a janela para o primeiro tile |
| `Alt+T` ou `Alt+Shift+Space` | alterna flutuante |
| `Alt+F` | monocle (uma janela por vez, tela cheia) |
| `Alt+Shift+V` | alterna layout: BSP, colunas, linhas |
| `Alt+X` | espelha o layout horizontalmente |
| `Alt+Y` | próximo foco dentro do workspace |
| `Alt+1..9` / `Alt+Shift+1..9` | vai para / manda a janela para o workspace |
| `Alt+S / A / D` | workspace seguinte / anterior / último |
| `Alt+Shift+A / F` | manda a janela para o monitor anterior / seguinte |
| `Alt+M` | minimiza |
| `Alt+Shift+Q` | fecha |
| `Alt+Shift+X` | refaz o layout |
| `Alt+Shift+P` | pausa/retoma o tiling |
| `Alt+Shift+R` | recarrega o `tiler.ini` |
| `Alt+Shift+E` | sai (restaura tudo) |

Clique numa pílula de workspace da barra para ir até ele; clique no chip do layout para alternar.

## Configuração (`tiler.ini`)

- `[general]`: espaçamentos, número de workspaces, cor da borda do foco (Windows 11).
- `[bar]`: posição (`top`/`bottom`), altura, fonte, widgets da direita (`cpu,ram,battery,date,time`), cores.
- `[ignore]`: janelas que nunca são gerenciadas. Formato `tipo:padrão=1`; tipos: `exe`, `class`,
  `title` (contém), `titlere` e `classre` (regex).
- `[float]`: janelas gerenciadas que já nascem flutuantes.
- `[rules]`: novas janelas de um programa abrem em determinado workspace (`exe:Code.exe=1`).
- `[hotkeys]` e `[launch]`: atalhos (sintaxe do AHK: `!` Alt, `+` Shift, `^` Ctrl, `#` Win).

**Se algum programa se comportar mal** (janela que fica "pulando", que não deve entrar no
mosaico, etc.), o jeito é acrescentar uma regra em `[ignore]` ou `[float]`. Para descobrir
exe/classe/título das janelas abertas, veja "Diagnóstico" abaixo.

## Segurança e recuperação

- Janelas de workspaces inativos são **escondidas** (não minimizadas). Os handles ficam em
  `hidden.txt`. Se o script morrer à força, abra o `tiler.ahk` de novo: ele reexibe tudo na partida.
- Ao sair normalmente (ou recarregar), tudo é restaurado e as barras são removidas.
- Janelas de programas **elevados** (rodando como admin) não podem ser movidas por um script sem
  elevação. O tiler detecta a falha, marca a janela como flutuante e segue em frente.
- Os atalhos globais são os do próprio AutoHotkey (`Hotkey`), então teclas `Alt+letra` ficam
  reservadas para o tiler e deixam de chegar aos programas (menus com Alt, por exemplo).
  Se algum atalho atrapalhar um programa, troque-o em `[hotkeys]`.

## Diagnóstico

Em `tiler.ini` use `debug=1`. O script passa a escrever `tiler.log` e a ler comandos de `tiler.cmd`
(uma linha por comando; o arquivo é apagado após a leitura):

| Comando | Efeito |
|---|---|
| `dump` | grava `tiler.state` (monitores, workspaces, cada janela com retângulo real, exe e título) |
| `classify` | grava `tiler.classify`: **todas** as janelas abertas e por que cada uma entra ou não no mosaico (não move nada) |
| `bardump <prefixo>` | salva a imagem da barra de cada monitor |
| `<ação>` | executa uma ação como se fosse o atalho, por exemplo `goto_2`, `focus_left`, `toggle_float` |
| `fakeunplug \\.\DISPLAY1` / `fakereplug` | simula tirar/recolocar um monitor |

`test_title_prefix=TT` faz o tiler gerenciar **apenas** janelas cujo título começa com `TT`,
útil para testar sem mexer nas janelas reais. `tools/testwin.ahk` cria janelas coloridas para isso.

## Notas para quem for mexer no código (armadilhas do AHK v1)

- `global S := {}` fora de função torna `S` **super-global** e variáveis não diferenciam
  maiúsculas de minúsculas: **nunca use uma variável chamada `s`** (sobrescreve o estado todo).
- `SetTimer, % S.fn, ...` com a propriedade direto não funciona; use o helper `Arm()`.
- `("0x" str) + 0` não converte hexadecimal; passe por uma variável (`HexToInt`).
- `Reload` perde os argumentos de linha de comando; o `reload` daqui relança com `--ini`.
- `--selftest` abre outra instância do mesmo script, então **encerra a que estiver rodando**
  (`#SingleInstance Force`).

## Estado dos testes

Testado em Windows 11, com AHK 1.1.37.02 (U64 e U32), dois monitores a 100% de escala:
layout (BSP/colunas/linhas, sem sobreposição), foco, mover, redimensionar, workspaces, flutuar,
monocle, mover entre monitores, fechar, pausar, atalhos reais, clique na barra, recuperação após
kill, remoção/readição de monitor (simulada) e `reload`.

Não testado: Windows 10, escalas de DPI diferentes de 100%, hot-plug físico de monitor,
programas elevados, e o conjunto de aplicativos de um ambiente corporativo.
