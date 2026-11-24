module Api exposing
    ( Difficulty(..)
    , difficultyLabel
    , generate
    , hint
    , solve
    )

{-| aqui acontece a comunicação com o backend (FastAPI + Prolog) e conversão de JSON.
aqui as funções devolvem `Cmd msg`: que é a DESCRIÇÃO de uma requisição. quem a
executa é o runtime do Elm, que entrega a resposta ao `update` como uma
mensagem com um `Result`

este é o único módulo que conhece o formato do JSON. o resto do programa só
vê os tipos de `Ocaso` e `Hint`. os decoders não aceitam qualquer coisa, tipo: um
puzzle com pistas faltando ou uma altura 7 viram um `Err`, nunca um valor
inválido dentro do programa

-}

import Hint exposing (Exclusion, Hint(..), Method(..), Rule(..))
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Ocaso exposing (Board, Content(..), Position, Puzzle, Sun(..))
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


{-| o nome usado pela API (e pelo Prolog: são os átomos easy, medium, hard)
-}
difficultyName : Difficulty -> String
difficultyName difficulty =
    case difficulty of
        Easy ->
            "easy"

        Medium ->
            "medium"

        Hard ->
            "hard"



-- REQUISIÇÕES


generate : Difficulty -> (Result String Puzzle -> msg) -> Cmd msg
generate difficulty toMsg =
    Http.post
        { url = "/api/generate"
        , body =
            Http.jsonBody
                (Encode.object [ ( "difficulty", Encode.string (difficultyName difficulty) ) ])
        , expect = expectJson toMsg puzzleDecoder
        }


solve : Puzzle -> (Result String (List (List Content)) -> msg) -> Cmd msg
solve puzzle toMsg =
    Http.post
        { url = "/api/solve"
        , body = Http.jsonBody (encodePuzzle puzzle)
        , expect = expectJson toMsg (solutionDecoder puzzle.size)
        }


hint : Puzzle -> Board -> (Result String Hint -> msg) -> Cmd msg
hint puzzle board toMsg =
    Http.post
        { url = "/api/hint"
        , body =
            Http.jsonBody <|
                Encode.object
                    [ ( "puzzle", encodePuzzle puzzle )
                    , ( "placed", Encode.list encodeDecision (Ocaso.decisions board) )
                    ]
        , expect = expectJson toMsg hintDecoder
        }



-- JSON: ENVIO


{-| no JSON, sóis e pistas de linha são duas listas separadas, que é o formato
que o Prolog recebe. no domínio eles andam juntos em `RowClue`.
-}
encodePuzzle : Puzzle -> Encode.Value
encodePuzzle puzzle =
    Encode.object
        [ ( "size", Encode.int puzzle.size )
        , ( "suns", Encode.list (.sun >> sunName >> Encode.string) puzzle.rowClues )
        , ( "rows", Encode.list (.shade >> Encode.int) puzzle.rowClues )
        , ( "cols", Encode.list Encode.int puzzle.colClues )
        , ( "lakes", Encode.list encodePosition puzzle.lakes )
        , ( "givens", Encode.list encodeDecision puzzle.givens )
        ]


{-| `[linha, coluna, altura]`, com altura 0 para chão
-}
encodeDecision : ( Position, Content ) -> Encode.Value
encodeDecision ( ( row, col ), content ) =
    Encode.list Encode.int [ row, col, Ocaso.contentValue content ]


encodePosition : Position -> Encode.Value
encodePosition ( row, col ) =
    Encode.list Encode.int [ row, col ]


sunName : Sun -> String
sunName sun =
    case sun of
        West ->
            "west"

        East ->
            "east"



-- JSON: RECEBIMENTO


{-| o puzzle exatamente como vem no JSON, antes de ser conferido. ele só
existe dentro deste módulo; `toPuzzle` o transforma no `Puzzle` do domínio
ou falha com uma mensagem
-}
type alias WirePuzzle =
    { size : Int
    , suns : List Sun
    , rows : List Int
    , cols : List Int
    , lakes : List Position
    , givens : List ( Position, Content )
    }


puzzleDecoder : Decoder Puzzle
puzzleDecoder =
    Decode.map6 WirePuzzle
        (Decode.field "size" Decode.int)
        (Decode.field "suns" (Decode.list sunDecoder))
        (Decode.field "rows" (Decode.list Decode.int))
        (Decode.field "cols" (Decode.list Decode.int))
        (Decode.field "lakes" (Decode.list positionDecoder))
        (Decode.field "givens" (Decode.list givenDecoder))
        |> Decode.andThen toPuzzle


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


{-| confere o puzzle recebido e monta o `Puzzle` do domínio. as listas de
sóis e de pistas só são juntadas depois de conferido que têm o mesmo
tamanho (`List.map2` descartaria em silêncio o que sobrasse)
-}
toPuzzle : WirePuzzle -> Decoder Puzzle
toPuzzle wire =
    let
        positions =
            wire.lakes ++ List.map Tuple.first wire.givens

        inBounds ( row, col ) =
            row >= 0 && col >= 0 && row < wire.size && col < wire.size

        uniquePositions =
            Set.size (Set.fromList positions) == List.length positions

        validClues =
            List.all (\clue -> clue >= 0 && clue <= wire.size) wire.rows
                && List.all (\clue -> clue >= 0 && clue <= 3 * wire.size) wire.cols

        validLengths =
            List.all ((==) wire.size)
                [ List.length wire.suns, List.length wire.rows, List.length wire.cols ]
    in
    if not (List.member wire.size [ 5, 6, 7 ]) then
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
        Decode.succeed
            { size = wire.size
            , rowClues = List.map2 Ocaso.RowClue wire.suns wire.rows
            , colClues = wire.cols
            , lakes = wire.lakes
            , givens = wire.givens
            }


{-| a solução: `size` linhas com `size` casas, cada uma chão ou torre
-}
solutionDecoder : Int -> Decoder (List (List Content))
solutionDecoder size =
    Decode.field "towers" (Decode.list (Decode.list (Decode.int |> Decode.andThen contentDecoder)))
        |> Decode.andThen
            (\lines ->
                if List.length lines == size && List.all (\line -> List.length line == size) lines then
                    Decode.succeed lines

                else
                    Decode.fail "a solução tem dimensões inválidas"
            )


{-| as dicas chegam com um campo `kind` que diz a forma do resto do JSON.
`Decode.andThen` lê esse campo primeiro e escolhe o decoder de cada caso.
-}
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


{-| 0 é chão; 1 a 3 são torres, qualquer outro número é um erro.
-}
contentDecoder : Int -> Decoder Content
contentDecoder value =
    if value == 0 then
        Decode.succeed Ground

    else
        Ocaso.heightFromInt value
            |> Maybe.map (Tower >> Decode.succeed)
            |> Maybe.withDefault (Decode.fail "valor de casa inválido")



-- ERROS
--
-- `Http.expectJson` descarta o corpo das respostas de erro. o backend manda
-- uma mensagem útil em `{"detail": "..."}`, então esta versão a aproveita


expectJson : (Result String value -> msg) -> Decoder value -> Http.Expect msg
expectJson toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.GoodStatus_ _ body ->
                    Decode.decodeString decoder body
                        |> Result.mapError decodeErrorMessage

                Http.BadStatus_ metadata body ->
                    Err (errorDetail metadata.statusCode body)

                Http.BadUrl_ url ->
                    Err ("URL inválida: " ++ url)

                Http.Timeout_ ->
                    Err "O servidor demorou demais para responder."

                Http.NetworkError_ ->
                    Err "Não foi possível falar com o servidor. O backend está rodando?"


{-| as falhas que os próprios decoders declaram (`Decode.fail`, como em
`toPuzzle`) já trazem uma mensagem legível, as demais viram um texto genérico
-}
decodeErrorMessage : Decode.Error -> String
decodeErrorMessage error =
    case error of
        Decode.Failure message _ ->
            message

        _ ->
            "Resposta inesperada do servidor."


{-| quando o Pydantic rejeita o JSON, `detail` é uma lista de erros e não um
texto, nesse caso mostramos uma mensagem genérica com o código HTTP
-}
errorDetail : Int -> String -> String
errorDetail status body =
    case Decode.decodeString (Decode.field "detail" Decode.string) body of
        Ok detail ->
            detail

        Err _ ->
            "Erro no servidor (código " ++ String.fromInt status ++ ")."
