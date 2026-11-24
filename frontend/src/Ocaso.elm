module Ocaso exposing
    ( Analysis
    , Board
    , Cell(..)
    , ClueStatus(..)
    , Content(..)
    , Height(..)
    , Position
    , Puzzle
    , RowClue
    , Source(..)
    , Sun(..)
    , analyze
    , boardFromPuzzle
    , clearCell
    , contentValue
    , cycleCell
    , decisions
    , heightFromInt
    , heightValue
    , placeContent
    , revealCell
    , revealSolution
    , rowShadows
    , rows
    )

{-| Tipos e regras do Ocaso, do lado do Elm

este módulo é PURO, ou seja, não faz HTTP e não conhece HTML. ele responde às
perguntas que a tela precisa responder a cada clique (onde há sombra, quais
pistas já fecham, se o puzzle está resolvido) sem chamar o Prolog. O Prolog
só é chamado para o que exige busca: gerar, resolver e explicar dicas

-}

import Array exposing (Array)
import Set exposing (Set)



-- TIPOS


type Sun
    = West
    | East


{-| uma torre só pode ter altura 1, 2 ou 3. com um `Int` seria possível
representar uma torre de altura 0 ou 7, já com este tipo, não
-}
type Height
    = Low
    | Mid
    | High


{-| o que há num terreno decidido: chão (sem torre) ou uma torre
-}
type Content
    = Ground
    | Tower Height


{-| quem decidiu a casa. a origem define o que o jogador pode mudar: casas
reveladas pelo puzzle (`Given`) e pelo Prolog (`Prolog`) ficam travadas
-}
type Source
    = Given
    | Player
    | Prolog


{-| uma casa é um lago, um terreno ainda não decidido, ou um terreno
decidido, com conteúdo e origem

separar `Undecided` de `Decided _ Ground` permite ao jogador marcar "aqui
não tem torre" sem confundir isso com "ainda não pensei nesta casa". e como
o lago é um construtor próprio, não existe "lago com torre": o tipo não
deixa escrever esse estado

-}
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


{-| o lado do sol e a pista de sombra de uma linha andam sempre juntos, então
ficam no mesmo registro. duas listas paralelas (sóis e pistas) poderiam ter
tamanhos diferentes, uma lista de `RowClue` não
-}
type alias RowClue =
    { sun : Sun
    , shade : Int
    }


type alias Puzzle =
    { size : Int
    , rowClues : List RowClue
    , colClues : List Int
    , lakes : List Position
    , givens : List ( Position, Content )
    }


{-| O tabuleiro guarda o próprio tamanho junto com as casas

o tipo é OPACO: o módulo exporta `Board`, mas não o construtor. de fora não
dá para montar um tabuleiro com um tamanho e um número de casas que não
batem; só `boardFromPuzzle` cria tabuleiros, e só as funções daqui os
alteram

-}
type Board
    = Board Int (Array Cell)



-- CONSTRUÇÃO E LEITURA


boardFromPuzzle : Puzzle -> Board
boardFromPuzzle puzzle =
    let
        start =
            Board puzzle.size (Array.repeat (puzzle.size * puzzle.size) Undecided)

        withLakes =
            List.foldl (\position -> updateCell position (always Lake)) start puzzle.lakes
    in
    List.foldl
        (\( position, content ) -> updateCell position (always (Decided Given content)))
        withLakes
        puzzle.givens


{-| as casas linha por linha, cada uma com a sua posição. a tela percorre
esta lista em vez de pedir casa por casa, então nunca precisa tratar uma
posição inexistente
-}
rows : Board -> List (List ( Position, Cell ))
rows (Board size array) =
    array
        |> Array.toList
        |> List.indexedMap (\index cell -> ( ( index // size, modBy size index ), cell ))
        |> chunksOf size


chunksOf : Int -> List a -> List (List a)
chunksOf size list =
    if size <= 0 || List.isEmpty list then
        []

    else
        List.take size list :: chunksOf size (List.drop size list)


{-| as casas decididas pelo jogador ou pelo Prolog. é o que o Prolog precisa
receber para dar uma dica (as reveladas pelo puzzle ele já conhece)
-}
decisions : Board -> List ( Position, Content )
decisions board =
    board
        |> rows
        |> List.concat
        |> List.filterMap
            (\( position, cell ) ->
                case cell of
                    Decided Given _ ->
                        Nothing

                    Decided _ content ->
                        Just ( position, content )

                    _ ->
                        Nothing
            )


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


{-| a altura no formato da API: 0 para chão
-}
contentValue : Content -> Int
contentValue content =
    case content of
        Ground ->
            0

        Tower height ->
            heightValue height


towerHeight : Cell -> Int
towerHeight cell =
    case cell of
        Decided _ (Tower height) ->
            heightValue height

        _ ->
            0



-- SOMBRAS E PISTAS


{-| Quais casas de uma linha estão na sombra

uma casa está na sombra se alguma torre antes dela (no sentido em que a
sombra anda) a alcança, isto é, se a posição da torre mais a sua altura
chega até a casa. percorremos a linha uma vez guardando o alcance máximo
até ali (`reach`)

com o sol a leste a sombra anda para oeste. em vez de uma segunda versão,
invertemos a linha, como faz o `row_shadows/3` do Prolog

-}
rowShadows : Sun -> List Cell -> List Bool
rowShadows sun line =
    case sun of
        West ->
            castShadows line

        East ->
            line
                |> List.reverse
                |> castShadows
                |> List.reverse


castShadows : List Cell -> List Bool
castShadows line =
    let
        step cell ( index, reach, shaded ) =
            ( index + 1
            , max reach (index + towerHeight cell)
            , (index <= reach) :: shaded
            )

        ( _, _, reversed ) =
            List.foldl step ( 0, -1, [] ) line
    in
    List.reverse reversed


{-| Tudo o que a tela precisa saber sobre o tabuleiro atual

é calculado uma única vez por desenho da tela (em vez de cada casa
recalcular as sombras do tabuleiro inteiro) e reúne as quatro regras do
jogo num só lugar.

-}
type alias Analysis =
    { shaded : Set Position
    , rowStatuses : List ClueStatus
    , colStatuses : List ClueStatus
    , towersInShadow : Set Position
    , lakesInSun : Set Position
    , solved : Bool
    }


analyze : Puzzle -> Board -> Analysis
analyze puzzle board =
    let
        boardRows =
            rows board

        shadeRows =
            List.map2 (\clue line -> rowShadows clue.sun (List.map Tuple.second line))
                puzzle.rowClues
                boardRows

        shaded =
            List.map2 (List.map2 (\( position, _ ) inShade -> ( position, inShade )))
                boardRows
                shadeRows
                |> List.concat
                |> List.filter Tuple.second
                |> List.map Tuple.first
                |> Set.fromList

        rowStatuses =
            List.map2
                (\clue line -> clueStatus (List.length (List.filter identity line)) clue.shade)
                puzzle.rowClues
                shadeRows

        -- Soma as alturas coluna a coluna: cada linha vira uma lista de
        -- alturas, e `List.map2 (+)` soma essas listas posição a posição.
        columnSums =
            boardRows
                |> List.map (List.map (Tuple.second >> towerHeight))
                |> List.foldl (List.map2 (+)) (List.repeat puzzle.size 0)

        colStatuses =
            List.map2 clueStatus columnSums puzzle.colClues

        towersInShadow =
            boardRows
                |> List.concat
                |> List.filter (\( position, cell ) -> towerHeight cell > 0 && Set.member position shaded)
                |> List.map Tuple.first
                |> Set.fromList

        lakesInSun =
            puzzle.lakes
                |> List.filter (\position -> not (Set.member position shaded))
                |> Set.fromList
    in
    { shaded = shaded
    , rowStatuses = rowStatuses
    , colStatuses = colStatuses
    , towersInShadow = towersInShadow
    , lakesInSun = lakesInSun

    -- Casas não decididas contam como "sem torre". Como o puzzle tem
    -- solução única, cumprir as quatro regras já é estar na solução.
    , solved =
        Set.isEmpty towersInShadow
            && Set.isEmpty lakesInSun
            && List.all ((==) Exact) rowStatuses
            && List.all ((==) Exact) colStatuses
    }


clueStatus : Int -> Int -> ClueStatus
clueStatus actual clue =
    if actual < clue then
        Below

    else if actual > clue then
        Above

    else
        Exact


updateCell : Position -> (Cell -> Cell) -> Board -> Board
updateCell ( row, col ) change ((Board size array) as board) =
    let
        index =
            row * size + col
    in
    if row < 0 || col < 0 || row >= size || col >= size then
        board

    else
        case Array.get index array of
            Just cell ->
                Board size (Array.set index (change cell) array)

            Nothing ->
                board


{-| o clique numa casa: não decidida -> torre 1 -> 2 -> 3 -> chão -> torre 1.
Só casas do jogador mudam
-}
cycleCell : Position -> Board -> Board
cycleCell position =
    updateCell position
        (\cell ->
            case cell of
                Undecided ->
                    Decided Player (Tower Low)

                Decided Player content ->
                    Decided Player (nextContent content)

                _ ->
                    cell
        )


nextContent : Content -> Content
nextContent content =
    case content of
        Ground ->
            Tower Low

        Tower Low ->
            Tower Mid

        Tower Mid ->
            Tower High

        Tower High ->
            Ground


placeContent : Position -> Content -> Board -> Board
placeContent position content =
    updateCell position
        (\cell ->
            case cell of
                Undecided ->
                    Decided Player content

                Decided Player _ ->
                    Decided Player content

                _ ->
                    cell
        )


clearCell : Position -> Board -> Board
clearCell position =
    updateCell position
        (\cell ->
            case cell of
                Decided Player _ ->
                    Undecided

                _ ->
                    cell
        )


{-| uma casa revelada pelo Prolog (dica ou solução). ela pode substituir uma
decisão do jogador, mas nunca um lago ou uma casa revelada pelo puzzle
-}
revealCell : Position -> Content -> Board -> Board
revealCell position content =
    updateCell position
        (\cell ->
            case cell of
                Lake ->
                    cell

                Decided Given _ ->
                    cell

                _ ->
                    Decided Prolog content
        )


revealSolution : List (List Content) -> Board -> Board
revealSolution solution board =
    solution
        |> List.indexedMap
            (\row line -> List.indexedMap (\col content -> ( ( row, col ), content )) line)
        |> List.concat
        |> List.foldl (\( position, content ) -> revealCell position content) board
