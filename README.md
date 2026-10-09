# Sudoku em Prolog + Elm

Projeto de exemplo para o trabalho final de Paradigmas de Programação. É um
site onde se joga Sudoku. O Prolog cria e resolve os puzzles, e o Elm desenha
a interface. O Python só faz a ponte entre os dois.

Use este repositório como ponto de partida se quiser. Você pode trocar o
Sudoku por outro problema e aproveitar toda a estrutura (servidor, integração
com Prolog, frontend com hot reload).

```
┌──────────────────────┐   HTTP/JSON   ┌───────────────────┐  janus  ┌──────────────────┐
│ Navegador            │ ────────────▶ │ FastAPI (Python)  │ ──────▶ │ SWI-Prolog       │
│ Elm + daisyUI (Vite) │ ◀──────────── │ backend/app/      │ ◀────── │ backend/prolog/  │
└──────────────────────┘               └───────────────────┘         └──────────────────┘
    avaliado                              NÃO avaliado                  avaliado
```

## O que cada parte faz

**Prolog** (`backend/prolog/sudoku.pl`). Descreve as regras do Sudoku como
restrições com a biblioteca CLP(FD) e deixa o resolvedor de restrições achar
as respostas. Tem três predicados principais:

- `solve/2` resolve um tabuleiro;
- `generate/2` cria um puzzle novo com solução única, no nível `easy`,
  `medium` ou `hard`;
- `hint/2` escolhe uma casa vazia e diz o número que vai nela, ou avisa
  que o tabuleiro já está completo ou não tem solução.

**Python** (`backend/app/`). `prolog.py` carrega o arquivo `.pl` com a
biblioteca [janus](https://www.swi-prolog.org/pldoc/man?section=janus), que
roda o SWI-Prolog dentro do próprio processo Python. `main.py` expõe os
predicados como rotas HTTP com o FastAPI. Não há lógica de jogo aqui.

**Elm** (`frontend/src/`). Segue a Arquitetura Elm (Model, Msg, update, view).

- `Sudoku.elm` guarda o tipo do tabuleiro e as regras que precisam ser
  instantâneas, como marcar em vermelho os números repetidos. Não faz HTTP
  nem HTML.
- `Api.elm` faz as requisições e converte JSON em valores Elm.
- `Main.elm` cuida do estado, do teclado e da tela.

Para anotar candidatos, ligue o modo de marcação (botão "✎ Marcar" ou tecla
`N`) e digite os números. As marcações vão para os cantos da casa em ordem
crescente, como é costume entre quem resolve Sudoku. Quando você coloca um
número, essa marcação some sozinha das casas da mesma linha, coluna e bloco.

O visual fica todo em `frontend/src/style.css`. O Elm usa classes
semânticas (`board`, `cell--selected`, `number-key`), e o CSS as define com
o `@apply` do [Tailwind](https://tailwindcss.com) e os componentes do
[daisyUI](https://daisyui.com). O arquivo é comentado seção por seção e
mostra várias técnicas de CSS moderno, como variáveis, `color-mix()`,
container queries, `:has()`, `@property` e máscaras. O [Vite](https://vite.dev) serve o frontend e
recompila o Elm a cada vez que você salva um arquivo.

O código está cheio de comentários explicando construções de cada linguagem.
Vale ler os três arquivos Elm e o `sudoku.pl` do começo ao fim.

## Requisitos

- [SWI-Prolog](https://www.swi-prolog.org/Download.html) 9.2 ou mais novo
  (o comando `swipl` precisa estar no PATH);
- [uv](https://docs.astral.sh/uv/) para o Python (ele instala o Python certo
  sozinho);
- [Node.js](https://nodejs.org) 20 ou mais novo, com `npm`.

O compilador do Elm é instalado pelo `npm`, dentro de `frontend/node_modules`.
Não precisa instalar nada globalmente.

No Debian/Ubuntu, a versão do SWI-Prolog no `apt` pode ser antiga. O PPA
oficial resolve: `sudo add-apt-repository ppa:swi-prolog/stable`. Se o
`uv sync` falhar ao instalar o `janus-swi`, quase sempre é porque ele não
achou o `swipl`. Confira com `swipl --version`.

## Como rodar

```sh
make install    # instala as dependências (uma vez só)
make dev        # sobe backend e frontend
```

Abra http://localhost:5173. A documentação interativa da API fica em
http://localhost:8000/docs, e dá para testar as rotas por lá.

Sem `make`, abra dois terminais:

```sh
# terminal 1
cd backend
uv sync
uv run fastapi dev app/main.py

# terminal 2
cd frontend
npm install
npm run dev
```

Os dois servidores recarregam sozinhos quando você salva um arquivo. O Vite
repassa tudo que começa com `/api` para o backend na porta 8000 (veja
`frontend/vite.config.js`).

## Mudando o visual

O projeto traz dois arquivos de estilo, com as mesmas classes:

- `style.css` é o visual completo, com temas próprios, fontes, gradientes,
  animações e várias técnicas de CSS moderno;
- `style-simples.css` é uma versão minimalista, quase só com `@apply` do
  Tailwind e componentes do daisyUI. É mais fácil de entender e de
  modificar.

Para trocar de um para o outro, mude o `import` no início de
`frontend/src/main.js`. O Elm não muda.

No visual completo, abra `frontend/src/style.css` e procure a seção **4. VARIÁVEIS DE
PERSONALIZAÇÃO**. Dá para mudar muita coisa só trocando valores, sem
escrever CSS novo:

- a fonte do título, a fonte dos números e o peso de cada tipo de número;
- a cor e o fundo que indicam a origem do número (pista, jogador ou Prolog);
- o tamanho do tabuleiro e do painel, a espessura das linhas e o arredondamento;
- as cores de cada estado de casa (selecionada, em conflito, mesmo número);
- o gradiente do fundo, a intensidade do granulado e da grade de pontos;
- o efeito de vidro dos painéis e a velocidade das animações (`--speed`).

As cores principais vêm dos temas `light` e `dark` do daisyUI, com as cores
redefinidas na seção 2.
O botão sol/lua do cabeçalho troca entre eles com o `theme-controller` do
daisyUI, que funciona só com CSS. Na primeira visita vale a preferência do
sistema operacional; depois, o `main.js` guarda a escolha no `localStorage`
e a entrega ao Elm como *flag* na inicialização.
Para trocar uma fonte, instale outra do [Fontsource](https://fontsource.org)
(`npm install @fontsource-variable/NOME`) e troque o `@import`
correspondente na seção 1.

## Brincando com o Prolog direto no terminal

Não precisa do resto do sistema para testar o Prolog:

```
$ swipl backend/prolog/sudoku.pl
?- example_puzzle(P), solve(P, S), print_grid(S).
?- generate(hard, P), print_grid(P).
?- example_puzzle(P), count_solutions(P, 10, N).
```

Esse é o jeito mais rápido de desenvolver a parte lógica. Só depois de o
predicado funcionar no `swipl` vale a pena ligá-lo ao Python.

## Problemas comuns

**`ENOSPC: System limit for number of file watchers reached`** ao rodar o
Vite. O Linux limita quantos arquivos podem ser vigiados ao mesmo tempo, e
editores como o VS Code gastam boa parte desse limite. Dá para aumentar o
limite:

```sh
echo fs.inotify.max_user_watches=524288 | sudo tee /etc/sysctl.d/40-inotify.conf
sudo sysctl --system
```

Sem `sudo`, outra saída é fazer o Vite verificar os arquivos periodicamente
em vez de vigiá-los. Em `vite.config.js`, acrescente
`watch: { usePolling: true }` dentro de `server`.

**`ImportError: libswipl.so.9: cannot open shared object file`** ao subir o
backend ou rodar os testes. O pacote `janus-swi` é compilado contra uma
versão específica do SWI-Prolog. Se você atualizou o SWI-Prolog (por exemplo,
da 9 para a 10) depois de instalar o backend, o `uv` continua usando a versão
antiga, guardada em cache. Recompile o pacote a partir do código-fonte,
ignorando o cache:

```sh
cd backend
uv sync --reinstall-package janus-swi --no-binary-package janus-swi --no-cache
```

## Testes

```sh
make test           # tudo
make test-prolog    # só os testes em Prolog (plunit)
make test-backend   # só os testes da API (pytest)
```

## API

Todas as rotas recebem e devolvem JSON. Um tabuleiro é uma lista de 9 linhas
com 9 inteiros cada, e 0 é casa vazia.

| Rota                 | Corpo enviado              | Resposta                           |
| -------------------- | -------------------------- | ---------------------------------- |
| `POST /api/generate` | `{"difficulty": "medium"}` | `{"board": [[...], ...]}`          |
| `POST /api/solve`    | `{"board": [[...], ...]}`  | `{"board": [[...], ...]}`          |
| `POST /api/hint`     | `{"board": [[...], ...]}`  | `{"row": 0, "col": 4, "value": 7}` |

Quando o tabuleiro não tem solução, `solve` e `hint` respondem com status 422
e `{"detail": "mensagem"}`. `hint` também responde 422 quando o tabuleiro já
está completo. O Elm mostra essa mensagem na tela.

## Entrega

A entrega acontece pelo GitHub Classroom, em duas atividades:

1. **Repositório do grupo.** Um por grupo, com o código do projeto e o
   `RELATORIO.md` preenchido. Este arquivo é o template do relatório:
   preencha todas as seções (as instruções estão em comentários dentro do
   próprio arquivo e não aparecem quando ele é visualizado).
2. **Repositório individual.** Um por aluno, com a avaliação 360 graus dos
   colegas em `avaliacao-360/<sua-matricula>.md`, copiada de
   `avaliacao-360/TEMPLATE.md`. Esse repositório pode partir deste template
   ou do código final do grupo, tanto faz. Só você e o professor leem o que
   está nele.

Antes de entregar, confira a forma dos documentos com o validador:

```sh
make validar                                                # repositório do grupo
uv run scripts/validar_entrega.py avaliacao-360/<matricula>.md   # repositório individual
```

Ele aponta comentários de instrução que sobraram, campos entre colchetes não
preenchidos, tabelas malformadas, seções e subseções faltando, arquivos
citados que não existem, notas fora da escala, divisões de esforço que não
somam 100%, roteiro da apresentação acima de 15 minutos e integrantes que
aparecem numa tabela e não em outra. Também avisa quando um colega recebeu
nota 1, 2 ou 5 e ficou sem comentário. Erros impedem a entrega; avisos
merecem uma conferida.

Os critérios de avaliação, com a rubrica da nota do grupo, a fórmula da
nota individual e os prazos (18/11 sem desconto; 23/11 e 30/11 com
desconto), estão em `AVALIACAO.md`.

### Ferramentas do professor

Os scripts em `scripts/` cobrem a correção de ponta a ponta: baixar as
entregas do GitHub Classroom, fazer a triagem de código suspeito, medir,
preencher a rubrica e agregar as avaliações 360 em notas. Os alunos não
precisam deles. O fluxo e o uso de cada um estão em `scripts/README.md`.

## Estrutura

```
backend/
  prolog/sudoku.pl        regras, resolvedor, gerador e dica
  prolog/test_sudoku.pl   testes plunit
  app/prolog.py           ponte Python → Prolog (janus)
  app/main.py             rotas HTTP (FastAPI)
  tests/test_api.py       testes da API
frontend/
  src/Main.elm            Arquitetura Elm: estado, eventos, tela
  src/Sudoku.elm          tipos e regras do tabuleiro
  src/Api.elm             HTTP e JSON
  src/main.js             inicia o Elm e lembra o tema escolhido
  src/style.css           visual completo: temas, variáveis, componentes
  src/style-simples.css   visual minimalista (mesmas classes)
  vite.config.js          plugins e proxy para o backend
Makefile                  atalhos (install, dev, test, validar)
RELATORIO.md              template do relatório de entrega
AVALIACAO.md              critérios de avaliação (rubrica e nota individual)
avaliacao-360/TEMPLATE.md template da avaliação 360 graus (individual)
scripts/validar_entrega.py valida a forma dos documentos de entrega
scripts/                  (professor) baixar, auditar, medir, rubrica, agregar;
                          veja scripts/README.md
```

## Adaptando para o seu projeto

Para trocar o Sudoku por outro problema, o caminho costuma ser este:

1. Escreva e teste os predicados no `swipl`, num arquivo `.pl` novo.
2. Em `app/prolog.py`, carregue o arquivo com `janus.consult` e crie uma
   função Python para cada predicado, usando `janus.query_once`.
3. Em `app/main.py`, crie uma rota para cada função.
4. No Elm, crie os tipos do seu domínio, os decoders JSON em `Api.elm` e as
   telas em `Main.elm`.

Uma dica sobre o janus: o dicionário que `query_once` devolve tem uma chave
para cada variável da consulta e a chave `truth`, que diz se a consulta teve
sucesso. Strings do Python chegam no Prolog como strings, não como átomos.
Veja como `generate` usa `atom_string/2` em `prolog.py`. No sentido inverso,
átomos viram strings e listas viram listas, mas termos compostos como
`dica(1, 2, 3)` não passam: por isso `hint/2` devolve uma lista
`[Linha, Coluna, Valor]`.

## Ideias para estender este exemplo

- Marcações de centro, além das de canto (outro construtor em `InputMode`).
- Pedir ao Prolog todos os candidatos de cada casa e preencher as marcações
  automaticamente.
- Cronômetro e placar de melhores tempos.
- Um Prolog que explica a dica ("só o 7 cabe nesta linha") em vez de só
  revelar o número.
- Níveis de dificuldade medidos pelas técnicas necessárias para resolver,
  e não pela quantidade de pistas.
- Variantes: Sudoku com restrições de cavalo ou rei ou damas para os 9. Sudoku
  variantes com termômetros, restrições de vizinhos, operações matemáticas, etc.
  Sudoku 4x4 ou 16x16, Killer Sudoku, Sudoku diagonal. Em Prolog, quase sempre
  basta adicionar restrições.
- Outros quebra-cabeças que combinam bem com CLP(FD): N-rainhas, Hitori, KenKen,
  Kakuro, Nonogram, criptoaritmética (estilo SEND + MORE = MONEY). Melhor ainda:
  misture jogos conhecidos ou invente seu próprio jogo/quebra cabeça!
