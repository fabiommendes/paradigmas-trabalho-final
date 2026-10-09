"""Ponte entre Python e Prolog usando a biblioteca janus.

janus (pacote `janus-swi`) embute o SWI-Prolog dentro do processo Python.
Não há servidor Prolog separado nem troca de mensagens: chamamos predicados
diretamente e recebemos as respostas como dicionários Python.

Conversão automática de tipos (Python -> Prolog):
    int          -> inteiro
    str          -> string  (use janus.Term / átomos com cuidado, veja abaixo)
    list         -> lista
    dict         -> dict do SWI-Prolog

Para mais detalhes: https://www.swi-prolog.org/pldoc/man?section=janus

Este é o ÚNICO arquivo do projeto que conhece o janus. O resto do backend
só chama as funções abaixo.
"""

from pathlib import Path

import janus_swi as janus

Grid = list[list[int]]

PROLOG_FILE = Path(__file__).parent.parent / "prolog" / "sudoku.pl"

# consult/1 carrega o arquivo .pl, como `?- [sudoku].` no terminal do swipl.
janus.consult(str(PROLOG_FILE))


class NoSolution(Exception):
    """O tabuleiro enviado não tem solução."""


class BoardComplete(Exception):
    """O tabuleiro não tem casas vazias: não há dica para dar."""


def solve(puzzle: Grid) -> Grid:
    # query_once executa a consulta e devolve um dict com as variáveis da
    # consulta (em maiúsculas, como no Prolog) e a chave 'truth', que diz se
    # a consulta teve sucesso.
    result = janus.query_once("sudoku:solve(Puzzle, Solution)", {"Puzzle": puzzle})
    if not result["truth"]:
        raise NoSolution
    return result["Solution"]


def generate(difficulty: str) -> Grid:
    # Strings do Python viram strings do Prolog, mas generate/2 espera um
    # ÁTOMO (easy, medium, hard). atom_string/2 faz a conversão do lado Prolog.
    result = janus.query_once(
        "atom_string(D, Name), sudoku:generate(D, Puzzle)", {"Name": difficulty}
    )
    return result["Puzzle"]


def hint(board: Grid) -> tuple[int, int, int]:
    result = janus.query_once("sudoku:hint(Board, Result)", {"Board": board})["Result"]
    # hint/2 sempre tem sucesso e devolve, em Result, uma lista [Linha,
    # Coluna, Valor] ou um dos átomos `complete` e `unsolvable` (átomos
    # chegam ao Python como strings). Quem decidiu o que aconteceu foi o
    # Prolog; aqui só traduzimos cada caso. O `match` do Python escolhe o
    # ramo pela FORMA do valor, parecido com o casamento de padrões do
    # Prolog e do Elm.
    match result:
        case "complete":
            raise BoardComplete
        case "unsolvable":
            raise NoSolution
        case [row, col, value]:
            return row, col, value
    raise ValueError(f"resultado inesperado de hint/2: {result!r}")
