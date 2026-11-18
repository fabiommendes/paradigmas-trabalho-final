"""Ponte entre Python e Prolog usando a biblioteca janus."""

from pathlib import Path
from typing import Any

import janus_swi as janus

PROLOG_FILE = Path(__file__).parent.parent / "prolog" / "ocaso.pl"
janus.consult(str(PROLOG_FILE))


class NoSolution(Exception):
    """O puzzle não tem solução compatível com as regras."""


def generate(difficulty: str) -> dict[str, Any]:
    result = janus.query_once(
        "ocaso:api_generate(Name, Puzzle)",
        {"Name": difficulty},
    )
    return result["Puzzle"]


def solve(puzzle: dict[str, Any]) -> list[list[int]]:
    result = janus.query_once(
        "ocaso:api_solve(Puzzle, Towers)",
        {"Puzzle": puzzle},
    )
    if not result["truth"]:
        raise NoSolution
    return result["Towers"]


def hint(puzzle: dict[str, Any], placed: list[list[int]]) -> dict[str, Any]:
    result = janus.query_once(
        "ocaso:api_hint(Puzzle, Placed, Hint)",
        {
            "Puzzle": puzzle,
            "Placed": placed,
        },
    )
    return result["Hint"]
