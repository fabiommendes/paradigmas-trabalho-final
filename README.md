# Ocaso

Jogo de lógica sobre torres, lagos e sombras ao entardecer, feito para o
trabalho final de Paradigmas de Programação. O Prolog cria, resolve e
explica os puzzles; o Elm desenha a interface; o Python só faz a ponte.

O relatório de entrega está em [`RELATORIO.md`](RELATORIO.md).

![Captura de tela](docs/captura.jpg)

## Regras

O tabuleiro tem 5×5, 6×6 ou 7×7 casas. Cada casa é um **lago** (fixo) ou um
terreno, que pode estar vazio ou ter uma **torre** de altura 1, 2 ou 3.

Em cada linha o sol vem de um lado (☀). Uma torre de altura H faz sombra
nas H casas seguintes, no sentido oposto ao do sol; a sombra para na borda.

1. **Sol:** nenhuma torre pode ficar na sombra de outra.
2. **Lagos:** todo lago precisa estar na sombra.
3. **Linhas:** o número no fim da linha diz quantas casas dela estão na
   sombra (lagos inclusive).
4. **Colunas:** o número no alto da coluna é a soma das alturas das torres.

Algumas casas já vêm reveladas, para que a solução seja única.

**Controles:** clique numa casa para alternar entre torre 1, 2, 3 e chão.
Teclado: setas movem, `1`–`3` colocam torre, `0` ou `.` marcam chão, `⌫`
apaga, `Z` desfaz. "Pedir dica" mostra uma dedução do Prolog e quais regras
excluem os outros valores (ou aponta uma casa errada).

```
┌──────────────────────┐   HTTP/JSON   ┌───────────────────┐  janus  ┌──────────────────┐
│ Navegador            │ ────────────▶ │ FastAPI (Python)  │ ──────▶ │ SWI-Prolog       │
│ Elm + daisyUI (Vite) │ ◀──────────── │ backend/app/      │ ◀────── │ backend/prolog/  │
└──────────────────────┘               └───────────────────┘         └──────────────────┘
```

## Requisitos

- [SWI-Prolog](https://www.swi-prolog.org/Download.html) 9.2 ou mais novo
  (`swipl` no PATH);
- [uv](https://docs.astral.sh/uv/) para o Python;
- [Node.js](https://nodejs.org) 20 ou mais novo, com `npm`.

## Como rodar

```sh
make install    # instala as dependências (uma vez só)
make dev        # sobe backend e frontend
```

Abra http://localhost:5173. A documentação interativa da API fica em
http://localhost:8000/docs.

Sem `make`, em dois terminais:

```sh
cd backend && uv sync && uv run fastapi dev app/main.py
cd frontend && npm install && npm run dev
```

## Testes

```sh
make test           # tudo
make test-prolog    # testes plunit do Prolog
make test-backend   # testes da API (pytest)
make validar        # confere a forma do RELATORIO.md
```

Para o Elm: `cd frontend && npx elm-format --validate src/ && npx elm make src/Main.elm --output=/dev/null`.

## Testando o Prolog no terminal

```
$ swipl backend/prolog/ocaso.pl
?- example_puzzle(P), print_puzzle(P).
?- example_puzzle(P), solve(P, T), print_solution(P, T).
?- generate(hard, P), print_puzzle(P).
?- example_puzzle(P), hint(P, [], Dica).
```

## API

Posições contam a partir de 0; altura 0 é chão.

| Rota | Corpo enviado | Resposta |
|------|---------------|----------|
| `POST /api/generate` | `{"difficulty": "medium"}` | `{"size", "suns", "rows", "cols", "lakes", "givens"}` |
| `POST /api/solve` | o puzzle | `{"towers": [[...], ...]}` |
| `POST /api/hint` | `{"puzzle": ..., "placed": [[l, c, h], ...]}` | dica `cell`, `wrong` ou `complete` |

Formato inválido ou puzzle sem solução respondem 422 com `{"detail": ...}`.

## Problemas comuns

**`ImportError: libswipl...` ao subir o backend.** O pacote `janus-swi` é
compilado contra uma versão específica do SWI-Prolog. Recompile-o ignorando
o cache:

```sh
cd backend
uv sync --reinstall-package janus-swi --no-binary-package janus-swi --no-cache
```

## Estrutura

```
backend/
  prolog/ocaso.pl         regras, resolvedor, gerador e dicas (CLP(FD))
  prolog/test_ocaso.pl    testes plunit
  app/prolog.py           ponte Python → Prolog (janus)
  app/main.py             rotas HTTP e validação (FastAPI + Pydantic)
  tests/test_api.py       testes da API
frontend/
  src/Ocaso.elm           tipos e regras puras: sombras, pistas, edições
  src/Hint.elm            tipos e textos das dicas
  src/Api.elm             HTTP e JSON (decoders e encoders)
  src/Main.elm            Arquitetura Elm: estado, eventos, tela
  src/style.css           visual
docs/captura.jpg          captura de tela
RELATORIO.md              relatório de entrega
AVALIACAO.md              critérios de avaliação
scripts/                  validador da entrega e ferramentas do professor
```
