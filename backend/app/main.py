"""API HTTP do Ocaso; as regras e buscas ficam no Prolog."""

from typing import Annotated, Literal, Union

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from app import prolog

app = FastAPI(title="Ocaso (Prolog + Elm)")

Coordinate = Annotated[int, Field(ge=0)]
HeightValue = Annotated[int, Field(ge=0, le=3)]
ClueValue = Annotated[int, Field(ge=0)]
Position = Annotated[list[int], Field(min_length=2, max_length=2)]
Given = Annotated[list[int], Field(min_length=3, max_length=3)]


class PuzzleData(BaseModel):
    size: Literal[5, 6, 7]
    suns: list[Literal["west", "east"]]
    rows: list[ClueValue]
    cols: list[ClueValue]
    lakes: list[Position]
    givens: list[Given]

    @classmethod
    def _coordinate_is_valid(cls, row: int, col: int, size: int) -> bool:
        return 0 <= row < size and 0 <= col < size

    def model_post_init(self, __context: object) -> None:
        if not (
            len(self.suns) == len(self.rows) == len(self.cols) == self.size
        ):
            raise ValueError("suns, rows e cols devem ter o mesmo tamanho de size")
        if any(clue > self.size for clue in self.rows):
            raise ValueError("cada pista de linha deve estar entre 0 e size")
        if any(clue > 3 * self.size for clue in self.cols):
            raise ValueError("cada pista de coluna deve estar entre 0 e 3 * size")

        lake_positions = [tuple(position) for position in self.lakes]
        given_positions = [tuple(given[:2]) for given in self.givens]
        for row, col in lake_positions + given_positions:
            if not self._coordinate_is_valid(row, col, self.size):
                raise ValueError("há uma coordenada fora do tabuleiro")
        if len(set(lake_positions)) != len(lake_positions):
            raise ValueError("há coordenadas de lago repetidas")
        if len(set(given_positions)) != len(given_positions):
            raise ValueError("há revelações repetidas")
        if set(lake_positions) & set(given_positions):
            raise ValueError("uma casa não pode ser lago e revelação")
        if any(given[2] < 0 or given[2] > 3 for given in self.givens):
            raise ValueError("a altura revelada deve estar entre 0 e 3")


class GenerateRequest(BaseModel):
    difficulty: Literal["easy", "medium", "hard"] = "medium"


class HintRequest(BaseModel):
    puzzle: PuzzleData
    placed: list[Given]

    def model_post_init(self, __context: object) -> None:
        size = self.puzzle.size
        placed_positions = [tuple(cell[:2]) for cell in self.placed]
        fixed_positions = {
            tuple(position) for position in self.puzzle.lakes
        } | {tuple(given[:2]) for given in self.puzzle.givens}
        for cell in self.placed:
            row, col, value = cell
            if not PuzzleData._coordinate_is_valid(row, col, size):
                raise ValueError("há uma decisão fora do tabuleiro")
            if value < 0 or value > 3:
                raise ValueError("a altura decidida deve estar entre 0 e 3")
        if len(set(placed_positions)) != len(placed_positions):
            raise ValueError("há decisões repetidas")
        if set(placed_positions) & fixed_positions:
            raise ValueError("não se pode decidir uma casa fixa")


class RuleData(BaseModel):
    rule: Literal["sun", "lakes", "row", "col"]
    index: int | None = None


class ExcludedValue(BaseModel):
    value: HeightValue
    rules: list[RuleData]


class CellHint(BaseModel):
    kind: Literal["cell"]
    row: Coordinate
    col: Coordinate
    value: HeightValue
    method: Literal["propagation", "search"]
    excluded: list[ExcludedValue]


class WrongHint(BaseModel):
    kind: Literal["wrong"]
    row: Coordinate
    col: Coordinate
    value: HeightValue
    rules: list[RuleData]


class CompleteHint(BaseModel):
    kind: Literal["complete"]


class UnsolvableHint(BaseModel):
    kind: Literal["unsolvable"]


HintResponse = Annotated[
    Union[CellHint, WrongHint, CompleteHint, UnsolvableHint],
    Field(discriminator="kind"),
]

NO_SOLUTION = "Este puzzle não tem solução. Confira as casas decididas."


@app.post("/api/generate", response_model=PuzzleData)
def generate(request: GenerateRequest) -> dict:
    return prolog.generate(request.difficulty)


@app.post("/api/solve")
def solve(puzzle: PuzzleData) -> dict[str, list[list[int]]]:
    try:
        towers = prolog.solve(puzzle.model_dump(mode="python"))
    except prolog.NoSolution:
        raise HTTPException(status_code=422, detail=NO_SOLUTION) from None
    return {"towers": towers}


@app.post("/api/hint", response_model=HintResponse)
def hint(request: HintRequest) -> dict:
    placed = [list(cell) for cell in request.placed]
    result = prolog.hint(request.puzzle.model_dump(mode="python"), placed)
    if result["kind"] == "unsolvable":
        raise HTTPException(status_code=422, detail=NO_SOLUTION)
    return result
