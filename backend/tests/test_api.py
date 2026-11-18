"""Testes HTTP da integração Ocaso."""

import pytest
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

PUZZLE = {
    "size": 5,
    "suns": ["west", "west", "east", "east", "west"],
    "rows": [3, 2, 1, 2, 3],
    "cols": [7, 0, 0, 3, 3],
    "lakes": [[0, 1], [3, 2], [3, 3], [4, 3]],
    "givens": [[3, 0, 0], [4, 0, 3], [3, 4, 2], [2, 4, 1], [1, 3, 0]],
}

SOLUTION = [
    [2, 0, 0, 3, 0],
    [2, 0, 0, 0, 0],
    [0, 0, 0, 0, 1],
    [0, 0, 0, 0, 2],
    [3, 0, 0, 0, 0],
]


@pytest.mark.parametrize(
    ("difficulty", "size"),
    [("easy", 5), ("medium", 6), ("hard", 7)],
)
def test_generate_returns_puzzle_for_each_level(difficulty: str, size: int):
    response = client.post("/api/generate", json={"difficulty": difficulty})
    assert response.status_code == 200
    puzzle = response.json()
    assert puzzle["size"] == size
    assert len(puzzle["suns"]) == len(puzzle["rows"]) == len(puzzle["cols"]) == size
    assert set(puzzle) == {"size", "suns", "rows", "cols", "lakes", "givens"}


def test_generate_rejects_unknown_difficulty():
    response = client.post("/api/generate", json={"difficulty": "expert"})
    assert response.status_code == 422


def test_solve_returns_towers_for_valid_puzzle():
    response = client.post("/api/solve", json=PUZZLE)
    assert response.status_code == 200
    assert response.json() == {"towers": SOLUTION}


def test_solve_returns_422_when_a_lake_cannot_be_shadowed():
    unsolvable = {**PUZZLE, "lakes": [*PUZZLE["lakes"], [0, 0]]}
    response = client.post("/api/solve", json=unsolvable)
    assert response.status_code == 422
    assert "não tem solução" in response.json()["detail"]


def test_solve_rejects_wrong_puzzle_dimensions():
    malformed = {**PUZZLE, "suns": ["west"]}
    response = client.post("/api/solve", json=malformed)
    assert response.status_code == 422


def test_hint_returns_tagged_cell_and_explanations():
    response = client.post(
        "/api/hint",
        json={"puzzle": PUZZLE, "placed": []},
    )
    assert response.status_code == 200
    hint = response.json()
    assert hint["kind"] == "cell"
    assert 0 <= hint["row"] < PUZZLE["size"]
    assert 0 <= hint["col"] < PUZZLE["size"]
    assert hint["value"] in range(4)
    assert hint["method"] in {"propagation", "search"}
    assert all("value" in item and "rules" in item for item in hint["excluded"])


def test_hint_reports_a_wrong_player_decision():
    response = client.post(
        "/api/hint",
        json={"puzzle": PUZZLE, "placed": [[0, 0, 1]]},
    )
    assert response.status_code == 200
    assert response.json()["kind"] == "wrong"
    assert response.json()["row"] == 0
    assert response.json()["col"] == 0


def test_hint_reports_complete_board():
    fixed = {tuple(given[:2]) for given in PUZZLE["givens"]}
    lakes = {tuple(position) for position in PUZZLE["lakes"]}
    placed = [
        [row, col, height]
        for row, values in enumerate(SOLUTION)
        for col, height in enumerate(values)
        if (row, col) not in fixed | lakes
    ]
    response = client.post(
        "/api/hint",
        json={"puzzle": PUZZLE, "placed": placed},
    )
    assert response.status_code == 200
    assert response.json() == {"kind": "complete"}


def test_hint_returns_422_for_an_unsolvable_puzzle():
    unsolvable = {**PUZZLE, "lakes": [*PUZZLE["lakes"], [0, 0]]}
    response = client.post(
        "/api/hint",
        json={"puzzle": unsolvable, "placed": []},
    )
    assert response.status_code == 422


def test_hint_rejects_decision_outside_puzzle():
    response = client.post(
        "/api/hint",
        json={"puzzle": PUZZLE, "placed": [[5, 0, 1]]},
    )
    assert response.status_code == 422
