module Main exposing (main)

import Api exposing (Difficulty(..))
import Array
import Browser
import Browser.Events
import Hint exposing (Hint(..))
import Html exposing (Html, aside, button, div, footer, h1, header, input, label, main_, p, section, span, text)
import Html.Attributes exposing (attribute, checked, class, classList, disabled, style, type_, value)
import Html.Events exposing (onCheck, onClick)
import Json.Decode as Decode exposing (Decoder)
import Ocaso exposing (Board, Cell(..), ClueStatus(..), Content(..), Height(..), Position, Puzzle, Source(..), Sun(..))
import Set exposing (Set)


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


type alias Flags =
    { darkTheme : Bool
    }


type Pending
    = Idle
    | Generating
    | Solving
    | RequestingHint


type alias Model =
    { puzzle : Maybe Puzzle
    , board : Board
    , selected : Maybe Position
    , difficulty : Difficulty
    , pending : Pending
    , darkTheme : Bool
    , error : Maybe String
    , hint : Maybe Hint
    , history : List Board
    }


type Msg
    = NewGame Difficulty
    | GotPuzzle (Result String Puzzle)
    | CellClicked Position
    | ContentSelected Content
    | ErasePressed
    | UndoRequested
    | MoveSelection Int Int
    | HintRequested
    | GotHint (Result String Hint)
    | SolveRequested
    | GotSolution (Result String (List (List Int)))
    | ThemeToggled Bool
    | ErrorDismissed


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { puzzle = Nothing
      , board = Ocaso.empty 5
      , selected = Nothing
      , difficulty = Medium
      , pending = Generating
      , darkTheme = flags.darkTheme
      , error = Nothing
      , hint = Nothing
      , history = []
      }
    , Api.generate Medium GotPuzzle
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NewGame difficulty ->
            if model.pending /= Idle then
                ( model, Cmd.none )

            else
                ( { model
                    | difficulty = difficulty
                    , pending = Generating
                    , error = Nothing
                    , hint = Nothing
                  }
                , Api.generate difficulty GotPuzzle
                )

        GotPuzzle (Ok puzzle) ->
            ( { model
                | puzzle = Just puzzle
                , board = Ocaso.boardFromPuzzle puzzle
                , selected = Nothing
                , pending = Idle
                , error = Nothing
                , hint = Nothing
                , history = []
              }
            , Cmd.none
            )

        GotPuzzle (Err error) ->
            ( failed error model, Cmd.none )

        CellClicked position ->
            let
                selected =
                    { model | selected = Just position }
            in
            ( editAt position Ocaso.cycleCell selected, Cmd.none )

        ContentSelected content ->
            ( editSelected (\position size board -> Ocaso.setPlayerContent position size content board) model
            , Cmd.none
            )

        ErasePressed ->
            ( editSelected Ocaso.clearPlayerCell model, Cmd.none )

        UndoRequested ->
            if model.pending /= Idle then
                ( model, Cmd.none )

            else
                case model.history of
                    previous :: rest ->
                        ( { model | board = previous, history = rest, hint = Nothing }
                        , Cmd.none
                        )

                    [] ->
                        ( model, Cmd.none )

        MoveSelection dRow dCol ->
            let
                size =
                    model.puzzle
                        |> Maybe.map .size
                        |> Maybe.withDefault 5

                move ( row, col ) =
                    ( modBy size (row + dRow), modBy size (col + dCol) )
            in
            ( { model
                | selected =
                    Just
                        (model.selected
                            |> Maybe.map move
                            |> Maybe.withDefault ( 0, 0 )
                        )
              }
            , Cmd.none
            )

        HintRequested ->
            case ( model.puzzle, model.pending ) of
                ( Just puzzle, Idle ) ->
                    ( { model | pending = RequestingHint, error = Nothing, hint = Nothing }
                    , Api.hint puzzle model.board GotHint
                    )

                _ ->
                    ( model, Cmd.none )

        GotHint (Ok hint) ->
            case ( model.puzzle, hint ) of
                ( Just puzzle, Deduce deduction ) ->
                    let
                        position =
                            ( deduction.row, deduction.col )

                        board =
                            Ocaso.revealHint position deduction.value puzzle.size model.board

                        updated =
                            withBoardIfChanged board model
                    in
                    ( { updated | selected = Just position, hint = Just hint, pending = Idle }
                    , Cmd.none
                    )

                ( _, Mistake mistake ) ->
                    ( { model
                        | selected = Just ( mistake.row, mistake.col )
                        , hint = Just hint
                        , pending = Idle
                      }
                    , Cmd.none
                    )

                _ ->
                    ( { model | hint = Just hint, pending = Idle }, Cmd.none )

        GotHint (Err error) ->
            ( failed error model, Cmd.none )

        SolveRequested ->
            case ( model.puzzle, model.pending ) of
                ( Just puzzle, Idle ) ->
                    ( { model | pending = Solving, error = Nothing, hint = Nothing }
                    , Api.solve puzzle GotSolution
                    )

                _ ->
                    ( model, Cmd.none )

        GotSolution (Ok towers) ->
            case model.puzzle of
                Just puzzle ->
                    let
                        board =
                            Ocaso.revealSolution towers puzzle model.board
                    in
                    ( withBoardIfChanged board { model | pending = Idle }, Cmd.none )

                Nothing ->
                    ( { model | pending = Idle }, Cmd.none )

        GotSolution (Err error) ->
            ( failed error model, Cmd.none )

        ThemeToggled dark ->
            ( { model | darkTheme = dark }, Cmd.none )

        ErrorDismissed ->
            ( { model | error = Nothing }, Cmd.none )


failed : String -> Model -> Model
failed error model =
    { model | pending = Idle, error = Just error }


editSelected : (Position -> Int -> Board -> Board) -> Model -> Model
editSelected change model =
    case model.selected of
        Just position ->
            editAt position change model

        Nothing ->
            model


editAt : Position -> (Position -> Int -> Board -> Board) -> Model -> Model
editAt position change model =
    case ( model.puzzle, model.pending ) of
        ( Just puzzle, Idle ) ->
            withBoardIfChanged (change position puzzle.size model.board) model

        _ ->
            model


withBoardIfChanged : Board -> Model -> Model
withBoardIfChanged board model =
    if Array.toList board == Array.toList model.board then
        model

    else
        case model.puzzle of
            Just _ ->
                { model | board = board, history = model.board :: model.history, hint = Nothing }

            Nothing ->
                model


subscriptions : Model -> Sub Msg
subscriptions _ =
    Browser.Events.onKeyDown keyDecoder


keyDecoder : Decoder Msg
keyDecoder =
    Decode.field "key" Decode.string
        |> Decode.andThen keyToMsg


keyToMsg : String -> Decoder Msg
keyToMsg key =
    case key of
        "ArrowUp" ->
            Decode.succeed (MoveSelection -1 0)

        "ArrowDown" ->
            Decode.succeed (MoveSelection 1 0)

        "ArrowLeft" ->
            Decode.succeed (MoveSelection 0 -1)

        "ArrowRight" ->
            Decode.succeed (MoveSelection 0 1)

        "Backspace" ->
            Decode.succeed ErasePressed

        "Delete" ->
            Decode.succeed ErasePressed

        "." ->
            Decode.succeed (ContentSelected Ground)

        "z" ->
            Decode.succeed UndoRequested

        "Z" ->
            Decode.succeed UndoRequested

        _ ->
            case String.toInt key of
                Just 0 ->
                    Decode.succeed (ContentSelected Ground)

                Just value ->
                    Ocaso.heightFromInt value
                        |> Maybe.map (Tower >> ContentSelected >> Decode.succeed)
                        |> Maybe.withDefault (Decode.fail "tecla ignorada")

                Nothing ->
                    Decode.fail "tecla ignorada"


view : Model -> Html Msg
view model =
    div [ class "app" ]
        [ header [ class "app-header" ]
            [ div [ class "app-container app-header-content" ]
                [ h1 [ class "app-title" ] [ text "Ocaso" ]
                , span [ class "app-subtitle" ] [ text "Torres e sombras ao entardecer" ]
                , viewThemeToggle model
                ]
            ]
        , main_ [ class "app-main" ]
            [ div [ class "app-container game" ]
                [ viewBoard model
                , aside [ class "side-panel" ]
                    [ span [ class "panel-label" ] [ text "Novo puzzle" ]
                    , viewDifficulty model
                    , div [ class "message-area" ] [ viewStatus model ]
                    , span [ class "panel-label" ] [ text "Jogadas" ]
                    , viewNumberPad model
                    , span [ class "panel-label" ] [ text "Ações" ]
                    , viewActions model
                    , span [ class "panel-label" ] [ text "Explicação da dica" ]
                    , viewHint model
                    , viewLegend
                    ]
                ]
            ]
        , footer [ class "app-footer" ]
            [ text "Teclas: "
            , kbd [] [ text "1–3" ]
            , text " torre, "
            , kbd [] [ text "0 / ." ]
            , text " chão, "
            , kbd [] [ text "⌫" ]
            , text " apagar, "
            , kbd [] [ text "Z" ]
            , text " desfazer, "
            , kbd [] [ text "setas" ]
            , text " mover."
            ]
        ]


kbd : List (Html.Attribute msg) -> List (Html msg) -> Html msg
kbd =
    Html.node "kbd"


viewThemeToggle : Model -> Html Msg
viewThemeToggle model =
    label [ class "theme-toggle", attribute "aria-label" "Alternar tema claro/escuro" ]
        [ input
            [ type_ "checkbox"
            , class "theme-controller"
            , value "dark"
            , checked model.darkTheme
            , onCheck ThemeToggled
            ]
            []
        , span [ class "swap-off" ] [ text "☀" ]
        , span [ class "swap-on" ] [ text "☾" ]
        ]


viewDifficulty : Model -> Html Msg
viewDifficulty model =
    let
        option difficulty sizeLabel =
            button
                [ class "difficulty-option"
                , classList [ ( "difficulty-option--active", difficulty == model.difficulty ) ]
                , disabled (model.pending /= Idle)
                , onClick (NewGame difficulty)
                ]
                [ text (Api.difficultyLabel difficulty ++ " · " ++ sizeLabel) ]
    in
    div [ class "difficulty-picker" ]
        [ option Easy "5×5"
        , option Medium "6×6"
        , option Hard "7×7"
        ]


viewStatus : Model -> Html Msg
viewStatus model =
    case ( model.error, model.pending, model.puzzle ) of
        ( Just error, _, _ ) ->
            div [ class "message message--error" ]
                [ span [] [ text error ]
                , button [ class "message-close", onClick ErrorDismissed ] [ text "×" ]
                ]

        ( Nothing, Generating, _ ) ->
            loadingMessage "O Prolog está gerando um puzzle..."

        ( Nothing, Solving, _ ) ->
            loadingMessage "O Prolog está resolvendo..."

        ( Nothing, RequestingHint, _ ) ->
            loadingMessage "O Prolog está analisando as jogadas..."

        ( Nothing, Idle, Just puzzle ) ->
            if Ocaso.isSolved puzzle model.board then
                div [ class "message message--success" ] [ text "Puzzle resolvido!" ]

            else
                text ""

        ( Nothing, Idle, Nothing ) ->
            text ""


loadingMessage : String -> Html Msg
loadingMessage message =
    div [ class "message message--loading" ]
        [ span [ class "spinner" ] []
        , span [] [ text message ]
        ]


viewBoard : Model -> Html Msg
viewBoard model =
    case model.puzzle of
        Nothing ->
            div [ class "board-loading" ] [ text "Preparando o tabuleiro..." ]

        Just puzzle ->
            let
                columnTemplate =
                    "repeat(" ++ String.fromInt puzzle.size ++ ", minmax(0, 1fr))"
            in
            section [ class "board-area", attribute "aria-label" "Tabuleiro do Ocaso" ]
                [ div [ class "column-clues-row" ]
                    [ div [ class "annotation-spacer" ] []
                    , div
                        [ class "board-grid board-grid--columns"
                        , style "grid-template-columns" columnTemplate
                        ]
                        (List.range 0 (puzzle.size - 1)
                            |> List.map (viewColumnClue model puzzle)
                        )
                    , div [ class "annotation-spacer" ] []
                    ]
                , div [ class "board-rows" ]
                    (List.range 0 (puzzle.size - 1)
                        |> List.map (viewRow model puzzle columnTemplate)
                    )
                ]


viewColumnClue : Model -> Puzzle -> Int -> Html Msg
viewColumnClue model puzzle col =
    let
        clue =
            puzzle.cols
                |> List.drop col
                |> List.head
                |> Maybe.withDefault 0
    in
    div
        [ class "clue"
        , class (clueClass (Ocaso.colStatus puzzle model.board col))
        , attribute "aria-label" ("Soma da coluna " ++ String.fromInt (col + 1))
        ]
        [ text (String.fromInt clue) ]


viewRow : Model -> Puzzle -> String -> Int -> Html Msg
viewRow model puzzle columnTemplate row =
    let
        sun =
            puzzle.suns
                |> List.drop row
                |> List.head
                |> Maybe.withDefault West

        clue =
            puzzle.rows
                |> List.drop row
                |> List.head
                |> Maybe.withDefault 0

        sunMarker =
            span
                [ class "sun-marker"
                , attribute "aria-label"
                    (case sun of
                        West ->
                            "Sol a oeste"

                        East ->
                            "Sol a leste"
                    )
                ]
                [ text "☀" ]

        rowClue =
            span
                [ class "clue"
                , class (clueClass (Ocaso.rowStatus puzzle model.board row))
                , attribute "aria-label" ("Casas sombreadas na linha " ++ String.fromInt (row + 1))
                ]
                [ text (String.fromInt clue) ]

        cells =
            div
                [ class "board-grid board-grid--row"
                , style "grid-template-columns" columnTemplate
                , style "height" ("calc(var(--board-size) / " ++ String.fromInt puzzle.size ++ ")")
                ]
                (List.range 0 (puzzle.size - 1)
                    |> List.map
                        (\col ->
                            viewCell model puzzle ( row, col )
                        )
                )

        leftAnnotation =
            case sun of
                West ->
                    sunMarker

                East ->
                    rowClue

        rightAnnotation =
            case sun of
                West ->
                    rowClue

                East ->
                    sunMarker
    in
    div [ class "board-row" ]
        [ div [ class "row-annotation" ] [ leftAnnotation ]
        , cells
        , div [ class "row-annotation" ] [ rightAnnotation ]
        ]


viewCell : Model -> Puzzle -> Position -> Html Msg
viewCell model puzzle (( row, col ) as position) =
    let
        cell =
            Ocaso.cellAt position puzzle.size model.board

        shaded =
            Ocaso.shadowAt puzzle model.board position

        errors =
            Set.member position (Ocaso.towersInShadow puzzle model.board)
                || Set.member position (Ocaso.lakesInSun puzzle model.board)

        labelText =
            "Linha "
                ++ String.fromInt (row + 1)
                ++ ", coluna "
                ++ String.fromInt (col + 1)
                ++ ": "
                ++ cellDescription cell
    in
    button
        [ class "cell"
        , classList
            [ ( "cell--selected", model.selected == Just position )
            , ( "cell--shadow", shaded )
            , ( "cell--lake", cell == Lake )
            , ( "cell--error", errors )
            , ( "cell--given", sourceIs Given cell )
            , ( "cell--player", sourceIs Player cell )
            , ( "cell--prolog", sourceIs Prolog cell )
            ]
        , attribute "aria-label" labelText
        , onClick (CellClicked position)
        ]
        [ viewCellContent cell ]


viewCellContent : Cell -> Html Msg
viewCellContent cell =
    case cell of
        Lake ->
            span [ class "lake-mark", attribute "aria-hidden" "true" ] [ text "≈" ]

        Undecided ->
            span [ class "ground-mark" ] [ text "·" ]

        Decided _ Ground ->
            span [ class "ground-mark" ] [ text "—" ]

        Decided _ (Tower height) ->
            let
                count =
                    case height of
                        Low ->
                            1

                        Mid ->
                            2

                        High ->
                            3
            in
            div
                [ class "tower"
                , class ("tower--" ++ String.fromInt count)
                , attribute "aria-label" ("Torre de altura " ++ String.fromInt count)
                ]
                (List.repeat count (span [ class "tower-block" ] []))


sourceIs : Source -> Cell -> Bool
sourceIs source cell =
    case cell of
        Decided cellSource _ ->
            cellSource == source

        _ ->
            False


cellDescription : Cell -> String
cellDescription cell =
    case cell of
        Lake ->
            "lago"

        Undecided ->
            "não decidida"

        Decided _ Ground ->
            "chão"

        Decided _ (Tower height) ->
            "torre de altura " ++ String.fromInt (heightNumber height)


heightNumber : Height -> Int
heightNumber height =
    case height of
        Low ->
            1

        Mid ->
            2

        High ->
            3


clueClass : ClueStatus -> String
clueClass status =
    case status of
        Below ->
            "clue--below"

        Exact ->
            "clue--exact"

        Above ->
            "clue--above"


viewNumberPad : Model -> Html Msg
viewNumberPad model =
    let
        numberButton height label =
            button
                [ class "number-key"
                , disabled (model.pending /= Idle || model.selected == Nothing)
                , onClick (ContentSelected (Tower height))
                ]
                [ text label ]
    in
    div [ class "number-pad" ]
        [ numberButton Low "1"
        , numberButton Mid "2"
        , numberButton High "3"
        , button
            [ class "number-key number-key--ground"
            , disabled (model.pending /= Idle || model.selected == Nothing)
            , onClick (ContentSelected Ground)
            ]
            [ text "Chão" ]
        , button
            [ class "erase-key"
            , disabled (model.pending /= Idle || model.selected == Nothing)
            , onClick ErasePressed
            ]
            [ text "⌫ Apagar" ]
        ]


viewActions : Model -> Html Msg
viewActions model =
    div [ class "actions" ]
        [ button
            [ class "action-button action-button--hint"
            , disabled (model.pending /= Idle || model.puzzle == Nothing)
            , onClick HintRequested
            ]
            [ text "Pedir dica" ]
        , button
            [ class "action-button action-button--solve"
            , disabled (model.pending /= Idle || model.puzzle == Nothing)
            , onClick SolveRequested
            ]
            [ text "Resolver" ]
        , button
            [ class "action-button action-button--undo"
            , disabled (model.pending /= Idle || List.isEmpty model.history)
            , onClick UndoRequested
            ]
            [ text "Desfazer (Z)" ]
        ]


viewHint : Model -> Html Msg
viewHint model =
    case model.hint of
        Just hint ->
            p [ class "hint-explanation" ] [ text (Hint.explanation hint) ]

        Nothing ->
            p [ class "hint-explanation hint-explanation--empty" ]
                [ text "Peça uma dica para ver uma dedução e as regras que a justificam." ]


viewLegend : Html Msg
viewLegend =
    div [ class "legend" ]
        [ span [] [ text "≈ Lago" ]
        , span [] [ text "Fundo âmbar: sombra" ]
        , span [] [ text "Blocos: torre (altura 1–3)" ]
        ]
