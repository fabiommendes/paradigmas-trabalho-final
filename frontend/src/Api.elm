module Api exposing
    ( Difficulty(..)
    , difficultyLabel
    , generate
    , hint
    , solve
    )

{-| HTTP and JSON integration for the Ocaso API.
-}

import Array
import Hint exposing (Exclusion, Hint(..), Method(..), Rule(..))
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Ocaso exposing (Board, Cell(..), Content(..), Height(..), Position, Puzzle, Source(..), Sun(..))
import Set


type Difficulty
    = Easy
    | Medium
    | Hard


difficultyLabel : Difficulty -> String
difficultyLabel difficulty =
    case difficulty of
        Easy ->
            "Fácil"

        Medium ->
            "Médio"

        Hard ->
            "Difícil"


difficultyName : Difficulty -> String
difficultyName difficulty =
    case difficulty of
        Easy ->
            "easy"

        Medium ->
            "medium"

        Hard ->
            "hard"


generate : Difficulty -> (Result String Puzzle -> msg) -> Cmd msg
generate difficulty toMsg =
    Http.post
        { url = "/api/generate"
        , body =
            Http.jsonBody
                (Encode.object [ ( "difficulty", Encode.string (difficultyName difficulty) ) ])
        , expect = expectJson toMsg puzzleDecoder
        }


solve : Puzzle -> (Result String (List (List Int)) -> msg) -> Cmd msg
solve puzzle toMsg =
    Http.post
        { url = "/api/solve"
        , body = Http.jsonBody (encodePuzzle puzzle)
        , expect = expectJson toMsg (towerRowsDecoder puzzle.size)
        }


hint : Puzzle -> Board -> (Result String Hint -> msg) -> Cmd msg
hint puzzle board toMsg =
    Http.post
        { url = "/api/hint"
        , body =
            Http.jsonBody <|
                Encode.object
                    [ ( "puzzle", encodePuzzle puzzle )
                    , ( "placed", encodePlaced puzzle.size board )
                    ]
        , expect = expectJson toMsg hintDecoder
        }


encodePuzzle : Puzzle -> Encode.Value
encodePuzzle puzzle =
    Encode.object
        [ ( "size", Encode.int puzzle.size )
        , ( "suns", Encode.list (Encode.string << sunName) puzzle.suns )
        , ( "rows", Encode.list Encode.int puzzle.rows )
        , ( "cols", Encode.list Encode.int puzzle.cols )
        , ( "lakes", Encode.list encodePosition puzzle.lakes )
        , ( "givens"
          , Encode.list
                (\( ( row, col ), content ) ->
                    Encode.list identity
                        [ Encode.int row
                        , Encode.int col
                        , Encode.int (contentValue content)
                        ]
                )
                puzzle.givens
          )
        ]


encodePlaced : Int -> Board -> Encode.Value
encodePlaced size board =
    List.range 0 (size * size - 1)
        |> List.filterMap
            (\index ->
                case Array.get index board of
                    Just (Decided Given _) ->
                        Nothing

                    Just (Decided _ content) ->
                        Just
                            (Encode.list identity
                                [ Encode.int (index // size)
                                , Encode.int (modBy size index)
                                , Encode.int (contentValue content)
                                ]
                            )

                    _ ->
                        Nothing
            )
        |> Encode.list identity


encodePosition : Position -> Encode.Value
encodePosition ( row, col ) =
    Encode.list identity [ Encode.int row, Encode.int col ]


sunName : Sun -> String
sunName sun =
    case sun of
        West ->
            "west"

        East ->
            "east"


contentValue : Content -> Int
contentValue content =
    case content of
        Ground ->
            0

        Tower height ->
            case height of
                Low ->
                    1

                Mid ->
                    2

                High ->
                    3


puzzleDecoder : Decoder Puzzle
puzzleDecoder =
    Decode.map6 Puzzle
        (Decode.field "size" Decode.int)
        (Decode.field "suns" (Decode.list sunDecoder))
        (Decode.field "rows" (Decode.list Decode.int))
        (Decode.field "cols" (Decode.list Decode.int))
        (Decode.field "lakes" (Decode.list positionDecoder))
        (Decode.field "givens" (Decode.list givenDecoder))
        |> Decode.andThen validatePuzzle


sunDecoder : Decoder Sun
sunDecoder =
    Decode.string
        |> Decode.andThen
            (\name ->
                case name of
                    "west" ->
                        Decode.succeed West

                    "east" ->
                        Decode.succeed East

                    _ ->
                        Decode.fail "orientação do Sol inválida"
            )


positionDecoder : Decoder Position
positionDecoder =
    Decode.list Decode.int
        |> Decode.andThen
            (\values ->
                case values of
                    [ row, col ] ->
                        Decode.succeed ( row, col )

                    _ ->
                        Decode.fail "uma posição deve conter linha e coluna"
            )


givenDecoder : Decoder ( Position, Content )
givenDecoder =
    Decode.list Decode.int
        |> Decode.andThen
            (\values ->
                case values of
                    [ row, col, value ] ->
                        contentDecoder value
                            |> Decode.map (\content -> ( ( row, col ), content ))

                    _ ->
                        Decode.fail "uma revelação deve conter linha, coluna e altura"
            )


validatePuzzle : Puzzle -> Decoder Puzzle
validatePuzzle puzzle =
    let
        positions =
            puzzle.lakes ++ List.map Tuple.first puzzle.givens

        inBounds ( row, col ) =
            row
                >= 0
                && col
                >= 0
                && row
                < puzzle.size
                && col
                < puzzle.size

        uniquePositions =
            Set.size (Set.fromList positions) == List.length positions

        validClues =
            List.all (\clue -> clue >= 0 && clue <= puzzle.size) puzzle.rows
                && List.all (\clue -> clue >= 0 && clue <= 3 * puzzle.size) puzzle.cols

        validSize =
            List.member puzzle.size [ 5, 6, 7 ]

        validLengths =
            List.length puzzle.suns
                == puzzle.size
                && List.length puzzle.rows
                == puzzle.size
                && List.length puzzle.cols
                == puzzle.size
    in
    if not validSize then
        Decode.fail "tamanho de tabuleiro inválido"

    else if not validLengths then
        Decode.fail "o puzzle não tem uma pista por linha e coluna"

    else if not validClues then
        Decode.fail "há uma pista fora do intervalo permitido"

    else if not (List.all inBounds positions) then
        Decode.fail "há uma casa fora do tabuleiro"

    else if not uniquePositions then
        Decode.fail "há casas fixas repetidas ou sobrepostas"

    else
        Decode.succeed puzzle


towerRowsDecoder : Int -> Decoder (List (List Int))
towerRowsDecoder size =
    Decode.field "towers" (Decode.list (Decode.list towerValueDecoder))
        |> Decode.andThen
            (\rows ->
                if List.length rows == size && List.all (\row -> List.length row == size) rows then
                    Decode.succeed rows

                else
                    Decode.fail "a solução tem dimensões inválidas"
            )


towerValueDecoder : Decoder Int
towerValueDecoder =
    Decode.int
        |> Decode.andThen
            (\value ->
                if value >= 0 && value <= 3 then
                    Decode.succeed value

                else
                    Decode.fail "altura de torre inválida"
            )


hintDecoder : Decoder Hint
hintDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "cell" ->
                        Decode.map5
                            (\row col value method excluded ->
                                Deduce
                                    { row = row
                                    , col = col
                                    , value = value
                                    , method = method
                                    , excluded = excluded
                                    }
                            )
                            (Decode.field "row" Decode.int)
                            (Decode.field "col" Decode.int)
                            (Decode.field "value" Decode.int |> Decode.andThen contentDecoder)
                            (Decode.field "method" methodDecoder)
                            (Decode.field "excluded" (Decode.list exclusionDecoder))

                    "wrong" ->
                        Decode.map4
                            (\row col value rules ->
                                Mistake { row = row, col = col, value = value, rules = rules }
                            )
                            (Decode.field "row" Decode.int)
                            (Decode.field "col" Decode.int)
                            (Decode.field "value" Decode.int |> Decode.andThen contentDecoder)
                            (Decode.field "rules" (Decode.list ruleDecoder))

                    "complete" ->
                        Decode.succeed AllDone

                    "unsolvable" ->
                        Decode.fail "Este puzzle não tem solução."

                    _ ->
                        Decode.fail "tipo de dica desconhecido"
            )


exclusionDecoder : Decoder Exclusion
exclusionDecoder =
    Decode.map2 Exclusion
        (Decode.field "value" Decode.int |> Decode.andThen contentDecoder)
        (Decode.field "rules" (Decode.list ruleDecoder))


ruleDecoder : Decoder Rule
ruleDecoder =
    Decode.field "rule" Decode.string
        |> Decode.andThen
            (\name ->
                case name of
                    "sun" ->
                        Decode.succeed SunRule

                    "lakes" ->
                        Decode.succeed LakeRule

                    "row" ->
                        Decode.map RowRule (Decode.field "index" Decode.int)

                    "col" ->
                        Decode.map ColRule (Decode.field "index" Decode.int)

                    _ ->
                        Decode.fail "regra de dica desconhecida"
            )


methodDecoder : Decoder Method
methodDecoder =
    Decode.string
        |> Decode.andThen
            (\method ->
                case method of
                    "propagation" ->
                        Decode.succeed Propagation

                    "search" ->
                        Decode.succeed Search

                    _ ->
                        Decode.fail "método de dica desconhecido"
            )


contentDecoder : Int -> Decoder Content
contentDecoder value =
    if value == 0 then
        Decode.succeed Ground

    else
        Ocaso.heightFromInt value
            |> Maybe.map (Tower >> Decode.succeed)
            |> Maybe.withDefault (Decode.fail "valor de casa inválido")


expectJson : (Result String value -> msg) -> Decoder value -> Http.Expect msg
expectJson toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ body ->
                    Decode.decodeString decoder body
                        |> Result.mapError (\_ -> "Resposta inesperada do servidor.")

                Http.BadStatus_ metadata body ->
                    Err (errorDetail metadata.statusCode body)

                Http.BadUrl_ url ->
                    Err ("URL inválida: " ++ url)

                Http.Timeout_ ->
                    Err "O servidor demorou demais para responder."

                Http.NetworkError_ ->
                    Err "Não foi possível falar com o servidor. O backend está rodando?"


errorDetail : Int -> String -> String
errorDetail status body =
    case Decode.decodeString (Decode.field "detail" Decode.string) body of
        Ok detail ->
            detail

        Err _ ->
            "Erro no servidor (código " ++ String.fromInt status ++ ")."
