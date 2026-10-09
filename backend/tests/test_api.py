"""Testes da API HTTP (pytest).

Usamos o TestClient do FastAPI: ele chama a aplicação diretamente, sem subir
um servidor nem abrir porta. Cada função `test_*` é um teste; o pytest as
encontra sozinho.

Rodar: `uv run pytest` (na pasta backend) ou `make test-backend` (na raiz).

As regras do Sudoku são testadas em Prolog (prolog/test_sudoku.pl). Aqui
conferimos só a "cola": rotas, formato do JSON e códigos de status.
"""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)

# O mesmo puzzle de example_puzzle/1 em sudoku.pl.
EXAMPLE = [
    [5, 3, 0, 0, 7, 0, 0, 0, 0],
    [6, 0, 0, 1, 9, 5, 0, 0, 0],
    [0, 9, 8, 0, 0, 0, 0, 6, 0],
    [8, 0, 0, 0, 6, 0, 0, 0, 3],
    [4, 0, 0, 8, 0, 3, 0, 0, 1],
    [7, 0, 0, 0, 2, 0, 0, 0, 6],
    [0, 6, 0, 0, 0, 0, 2, 8, 0],
    [0, 0, 0, 4, 1, 9, 0, 0, 5],
    [0, 0, 0, 0, 8, 0, 0, 7, 9],
]


def solved_example() -> list[list[int]]:
    """A solução do puzzle de exemplo, obtida pela própria API."""
    return client.post("/api/solve", json={"board": EXAMPLE}).json()["board"]


def test_solve():
    response = client.post("/api/solve", json={"board": EXAMPLE})
    assert response.status_code == 200
    assert response.json()["board"][0] == [5, 3, 4, 6, 7, 8, 9, 1, 2]


def test_solve_without_solution():
    board = [row[:] for row in EXAMPLE]  # cópia, para não alterar EXAMPLE
    board[0][2] = 5  # dois 5 na primeira linha
    response = client.post("/api/solve", json={"board": board})
    assert response.status_code == 422


def test_solve_rejects_malformed_board():
    # Quem rejeita aqui é o Pydantic, antes de o Prolog ser chamado.
    response = client.post("/api/solve", json={"board": [[1, 2, 3]]})
    assert response.status_code == 422


def test_generate():
    response = client.post("/api/generate", json={"difficulty": "easy"})
    assert response.status_code == 200
    board = response.json()["board"]
    assert len(board) == 9 and all(len(row) == 9 for row in board)
    assert 0 in sum(board, [])  # sum(..., []) concatena as linhas: há casa vazia


def test_hint():
    response = client.post("/api/hint", json={"board": EXAMPLE})
    assert response.status_code == 200
    hint = response.json()
    assert EXAMPLE[hint["row"]][hint["col"]] == 0  # a dica é para uma casa vazia


def test_hint_on_complete_board():
    response = client.post("/api/hint", json={"board": solved_example()})
    assert response.status_code == 422
    assert response.json()["detail"] == "O tabuleiro já está completo."


def test_hint_on_full_board_with_errors():
    board = solved_example()
    board[0][0], board[0][1] = board[0][1], board[0][0]  # troca dois números
    response = client.post("/api/hint", json={"board": board})
    assert response.status_code == 422
    assert "não tem solução" in response.json()["detail"]
