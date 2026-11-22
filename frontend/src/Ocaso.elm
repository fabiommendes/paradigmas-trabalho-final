module Ocaso exposing
    ( Board
    , Cell(..)
    , ClueStatus(..)
    , Content(..)
    , Height(..)
    , Position
    , Puzzle
    , Source(..)
    , Sun(..)
    , boardFromPuzzle
    , cellAt
    , clearPlayerCell
    , colStatus
    , contentValue
    , cycleCell
    , empty
    , heightFromInt
    , heightValue
    , isSolved
    , lakesInSun
    , revealHint
    , revealSolution
    , rowShadows
    , rowStatus
    , setPlayerContent
    , shadowAt
    , shadows
    , toTowerRows
    , towersInShadow
    )

{-| Tipos e regras puras do Ocaso. O tabuleiro não conhece HTTP nem HTML.
-}

import Array exposing (Array)
import Set exposing (Set)


type Sun
    = West
    | East


type Height
    = Low
    | Mid
    | High


type Content
    = Ground
    | Tower Height


type Source
    = Given
    | Player
    | Prolog


type Cell
    = Lake
    | Undecided
    | Decided Source Content


type ClueStatus
    = Below
    | Exact
    | Above


type alias Position =
    ( Int, Int )


type alias Board =
    Array Cell


type alias Puzzle =
    { size : Int
    , suns : List Sun
    , rows : List Int
    , cols : List Int
    , lakes : List Position
    , givens : List ( Position, Content )
    }


empty : Int -> Board
empty size =
    Array.repeat (size * size) Undecided


boardFromPuzzle : Puzzle -> Board
boardFromPuzzle puzzle =
    let
        withLakes =
            List.foldl (\position board -> setCell puzzle.size position Lake board)
                (empty puzzle.size)
                puzzle.lakes
    in
    List.foldl
        (\( position, content ) board ->
            setCell puzzle.size position (Decided Given content) board
        )
        withLakes
        puzzle.givens


cellAt : Position -> Int -> Board -> Cell
cellAt ( row, col ) size board =
    Array.get (row * size + col) board
        |> Maybe.withDefault Undecided


setCell : Int -> Position -> Cell -> Board -> Board
setCell size ( row, col ) cell board =
    Array.set (row * size + col) cell board


heightValue : Height -> Int
heightValue height =
    case height of
        Low ->
            1

        Mid ->
            2

        High ->
            3


heightFromInt : Int -> Maybe Height
heightFromInt value =
    case value of
        1 ->
            Just Low

        2 ->
            Just Mid

        3 ->
            Just High

        _ ->
            Nothing


contentValue : Content -> Int
contentValue content =
    case content of
        Ground ->
            0

        Tower height ->
            heightValue height


contentFromInt : Int -> Content
contentFromInt value =
    heightFromInt value
        |> Maybe.map Tower
        |> Maybe.withDefault Ground


toTowerRows : Int -> Board -> List (List Int)
toTowerRows size board =
    List.range 0 (size - 1)
        |> List.map
            (\row ->
                List.range 0 (size - 1)
                    |> List.map
                        (\col ->
                            case cellAt ( row, col ) size board of
                                Decided _ content ->
                                    contentValue content

                                Lake ->
                                    0

                                Undecided ->
                                    0
                        )
            )


rowCells : Int -> Int -> Board -> List Cell
rowCells size row board =
    List.range 0 (size - 1)
        |> List.map (\col -> cellAt ( row, col ) size board)


rowShadows : Sun -> List Cell -> List Bool
rowShadows sun cells =
    let
        westward =
            cells
                |> List.indexedMap
                    (\index _ ->
                        cells
                            |> List.indexedMap
                                (\sourceIndex sourceCell ->
                                    sourceIndex
                                        < index
                                        && (towerHeight sourceCell
                                                |> Maybe.map (\height -> sourceIndex + height >= index)
                                                |> Maybe.withDefault False
                                           )
                                )
                            |> List.any identity
                    )
    in
    case sun of
        West ->
            westward

        East ->
            List.reverse cells
                |> rowShadows West
                |> List.reverse


towerHeight : Cell -> Maybe Int
towerHeight cell =
    case cell of
        Decided _ (Tower height) ->
            Just (heightValue height)

        _ ->
            Nothing


shadows : Puzzle -> Board -> List (List Bool)
shadows puzzle board =
    List.range 0 (puzzle.size - 1)
        |> List.map
            (\row ->
                let
                    sun =
                        puzzle.suns
                            |> List.drop row
                            |> List.head
                            |> Maybe.withDefault West
                in
                rowShadows sun (rowCells puzzle.size row board)
            )


shadowAt : Puzzle -> Board -> Position -> Bool
shadowAt puzzle board ( row, col ) =
    shadows puzzle board
        |> List.drop row
        |> List.head
        |> Maybe.andThen (List.drop col >> List.head)
        |> Maybe.withDefault False


rowStatus : Puzzle -> Board -> Int -> ClueStatus
rowStatus puzzle board row =
    let
        shadowCount =
            shadows puzzle board
                |> List.drop row
                |> List.head
                |> Maybe.withDefault []
                |> List.filter identity
                |> List.length

        clue =
            puzzle.rows
                |> List.drop row
                |> List.head
                |> Maybe.withDefault 0
    in
    clueStatus shadowCount clue


colStatus : Puzzle -> Board -> Int -> ClueStatus
colStatus puzzle board col =
    let
        total =
            List.range 0 (puzzle.size - 1)
                |> List.map
                    (\row ->
                        cellAt ( row, col ) puzzle.size board
                            |> towerHeight
                            |> Maybe.withDefault 0
                    )
                |> List.sum

        clue =
            puzzle.cols
                |> List.drop col
                |> List.head
                |> Maybe.withDefault 0
    in
    clueStatus total clue


clueStatus : Int -> Int -> ClueStatus
clueStatus actual clue =
    if actual < clue then
        Below

    else if actual > clue then
        Above

    else
        Exact


towersInShadow : Puzzle -> Board -> Set Position
towersInShadow puzzle board =
    List.range 0 (puzzle.size - 1)
        |> List.concatMap
            (\row ->
                List.range 0 (puzzle.size - 1)
                    |> List.filterMap
                        (\col ->
                            let
                                position =
                                    ( row, col )
                            in
                            case cellAt position puzzle.size board of
                                Decided _ (Tower _) ->
                                    if shadowAt puzzle board position then
                                        Just position

                                    else
                                        Nothing

                                _ ->
                                    Nothing
                        )
            )
        |> Set.fromList


lakesInSun : Puzzle -> Board -> Set Position
lakesInSun puzzle board =
    puzzle.lakes
        |> List.filter (\position -> not (shadowAt puzzle board position))
        |> Set.fromList


isSolved : Puzzle -> Board -> Bool
isSolved puzzle board =
    let
        rowsExact =
            List.range 0 (puzzle.size - 1)
                |> List.all (\row -> rowStatus puzzle board row == Exact)

        columnsExact =
            List.range 0 (puzzle.size - 1)
                |> List.all (\col -> colStatus puzzle board col == Exact)
    in
    Set.isEmpty (towersInShadow puzzle board)
        && Set.isEmpty (lakesInSun puzzle board)
        && rowsExact
        && columnsExact


cycleCell : Position -> Int -> Board -> Board
cycleCell position size board =
    case cellAt position size board of
        Undecided ->
            setCell size position (Decided Player (Tower Low)) board

        Decided Player content ->
            let
                next =
                    case content of
                        Ground ->
                            Tower Low

                        Tower Low ->
                            Tower Mid

                        Tower Mid ->
                            Tower High

                        Tower High ->
                            Ground
            in
            setCell size position (Decided Player next) board

        _ ->
            board


setPlayerContent : Position -> Int -> Content -> Board -> Board
setPlayerContent position size content board =
    case cellAt position size board of
        Undecided ->
            setCell size position (Decided Player content) board

        Decided Player _ ->
            setCell size position (Decided Player content) board

        _ ->
            board


clearPlayerCell : Position -> Int -> Board -> Board
clearPlayerCell position size board =
    case cellAt position size board of
        Decided Player _ ->
            setCell size position Undecided board

        _ ->
            board


revealHint : Position -> Content -> Int -> Board -> Board
revealHint position content size board =
    case cellAt position size board of
        Lake ->
            board

        Decided Given _ ->
            board

        _ ->
            setCell size position (Decided Prolog content) board


revealSolution : List (List Int) -> Puzzle -> Board -> Board
revealSolution towers puzzle board =
    List.range 0 (puzzle.size - 1)
        |> List.concatMap
            (\row ->
                List.range 0 (puzzle.size - 1)
                    |> List.map (\col -> ( row, col ))
            )
        |> List.foldl
            (\(( row, col ) as position) current ->
                let
                    value =
                        towers
                            |> List.drop row
                            |> List.head
                            |> Maybe.andThen (List.drop col >> List.head)
                            |> Maybe.withDefault 0
                in
                case cellAt position puzzle.size current of
                    Lake ->
                        current

                    Decided Given _ ->
                        current

                    _ ->
                        setCell puzzle.size position (Decided Prolog (contentFromInt value)) current
            )
            board
