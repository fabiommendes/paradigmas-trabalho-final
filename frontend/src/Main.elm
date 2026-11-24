module Main exposing (main)

{-| Interface do Ocaso, na Arquitetura Elm

  - `Model`: o estado inteiro da aplicação, num valor imutável;
  - `Msg`: tudo o que pode acontecer (cliques, teclas, respostas HTTP);
  - `update`: recebe uma `Msg` e o `Model` e devolve o novo `Model` e os
    efeitos (requisições) a executar;
  - `view`: desenha o `Model`. A tela é uma função do estado.

as regras do jogo ficam em `Ocaso`, os textos das dicas em `Hint` e o HTTP
em `Api`. este módulo só liga as peças umas nas outras

-}

import Api exposing (Difficulty(..))
import Browser
import Browser.Events
import Hint exposing (Hint(..))
import Html exposing (Html, aside, button, div, footer, h1, header, input, label, main_, p, section, span, text)
import Html.Attributes exposing (attribute, checked, class, classList, disabled, style, type_, value)
import Html.Events exposing (onCheck, onClick)
import Json.Decode as Decode exposing (Decoder)
import Ocaso exposing (Analysis, Board, Cell(..), ClueStatus(..), Content(..), Height(..), Position, Puzzle, RowClue, Source(..), Sun(..))
import Set



-- MAIN


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }



-- MODEL


{-| dados que o main.js entrega na inicialização
-}
type alias Flags =
    { darkTheme : Bool
    }


{-| Qual requisição está em andamento, se alguma

com um `Bool loading` não daria para saber o que mostrar ("gerando",
"resolvendo"...), e nada impediria dois pedidos ao mesmo tempo. com este
tipo, a mensagem de espera sai de um `case`, e os botões ficam desativados
enquanto o valor não for `Idle`

-}
type Pending
    = Idle
    | Generating
    | Solving
    | RequestingHint


{-| Uma partida em andamento

puzzle, tabuleiro, seleção, histórico e dica vivem e morrem juntos, quando
chega um puzzle novo, tudo isso é recriado de uma vez. por isso ficam num
mesmo registro, e o `Model` guarda um `Maybe Game`. assim não existe
"tabuleiro sem puzzle" nem "seleção sem tabuleiro"

-}
type alias Game =
    { puzzle : Puzzle
    , board : Board
    , selected : Maybe Position
    , history : List Board
    , hint : Maybe Hint
    }


type alias Model =
    { game : Maybe Game
    , difficulty : Difficulty
    , pending : Pending
    , darkTheme : Bool
    , error : Maybe String
    }


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { game = Nothing
      , difficulty = Medium
      , pending = Generating
      , darkTheme = flags.darkTheme
      , error = Nothing
      }
    , Api.generate Medium GotPuzzle
    )


newGame : Puzzle -> Game
newGame puzzle =
    { puzzle = puzzle
    , board = Ocaso.boardFromPuzzle puzzle
    , selected = Nothing
    , history = []
    , hint = Nothing
    }



-- UPDATE


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
    | GotSolution (Result String (List (List Content)))
    | ThemeToggled Bool
    | ErrorDismissed


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NewGame difficulty ->
            whenIdle model
                ( { model | difficulty = difficulty, pending = Generating, error = Nothing }
                , Api.generate difficulty GotPuzzle
                )

        GotPuzzle (Ok puzzle) ->
            ( { model | game = Just (newGame puzzle), pending = Idle, error = Nothing }
            , Cmd.none
            )

        GotPuzzle (Err error) ->
            ( failed error model, Cmd.none )

        CellClicked position ->
            ( playing (\game -> edit (Ocaso.cycleCell position) { game | selected = Just position }) model
            , Cmd.none
            )

        ContentSelected content ->
            ( playing (editSelected (\position -> Ocaso.placeContent position content)) model
            , Cmd.none
            )

        ErasePressed ->
            ( playing (editSelected Ocaso.clearCell) model, Cmd.none )

        UndoRequested ->
            ( playing undo model, Cmd.none )

        MoveSelection dRow dCol ->
            ( playing (moveSelection dRow dCol) model, Cmd.none )

        HintRequested ->
            withIdleGame model
                (\game ->
                    ( { model | pending = RequestingHint, error = Nothing }
                    , Api.hint game.puzzle game.board GotHint
                    )
                )

        GotHint (Ok hint) ->
            ( updateGame (applyHint hint) { model | pending = Idle }, Cmd.none )

        GotHint (Err error) ->
            ( failed error model, Cmd.none )

        SolveRequested ->
            withIdleGame model
                (\game ->
                    ( { model | pending = Solving, error = Nothing }
                    , Api.solve game.puzzle GotSolution
                    )
                )

        GotSolution (Ok solution) ->
            ( updateGame (edit (Ocaso.revealSolution solution)) { model | pending = Idle }
            , Cmd.none
            )

        GotSolution (Err error) ->
            ( failed error model, Cmd.none )

        ThemeToggled dark ->
            -- A troca de cores é feita pelo CSS (theme-controller do
            -- daisyUI); aqui só guardamos o estado do checkbox.
            ( { model | darkTheme = dark }, Cmd.none )

        ErrorDismissed ->
            ( { model | error = Nothing }, Cmd.none )


failed : String -> Model -> Model
failed error model =
    { model | pending = Idle, error = Just error }


{-| executa o passo só se não houver requisição em andamento
-}
whenIdle : Model -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
whenIdle model next =
    if model.pending == Idle then
        next

    else
        ( model, Cmd.none )


withIdleGame : Model -> (Game -> ( Model, Cmd Msg )) -> ( Model, Cmd Msg )
withIdleGame model next =
    case model.game of
        Just game ->
            whenIdle model (next game)

        Nothing ->
            ( model, Cmd.none )


updateGame : (Game -> Game) -> Model -> Model
updateGame change model =
    { model | game = Maybe.map change model.game }


{-| como `updateGame`, mas só quando o jogador pode mexer no tabuleiro (nada
em andamento). um clique durante uma requisição é ignorado
-}
playing : (Game -> Game) -> Model -> Model
playing change model =
    if model.pending == Idle then
        updateGame change model

    else
        model


{-| aplica uma alteração ao tabuleiro. se algo mudou, o tabuleiro anterior
vai para o histórico (para desfazer) e a dica antiga deixa de valer.

desfazer é simples porque os dados são imutáveis: guardar o tabuleiro
anterior é só guardar uma referência a ele; nada o modifica depois

-}
edit : (Board -> Board) -> Game -> Game
edit change game =
    let
        board =
            change game.board
    in
    if board == game.board then
        game

    else
        { game | board = board, history = game.board :: game.history, hint = Nothing }


editSelected : (Position -> Board -> Board) -> Game -> Game
editSelected change game =
    case game.selected of
        Just position ->
            edit (change position) game

        Nothing ->
            game


undo : Game -> Game
undo game =
    case game.history of
        previous :: rest ->
            { game | board = previous, history = rest, hint = Nothing }

        [] ->
            game


{-| move a seleção com as setas, `modBy` faz a seleção dar a volta nas bordas.
-}
moveSelection : Int -> Int -> Game -> Game
moveSelection dRow dCol game =
    let
        size =
            game.puzzle.size

        move ( row, col ) =
            ( modBy size (row + dRow), modBy size (col + dCol) )
    in
    { game | selected = Just (Maybe.withDefault ( 0, 0 ) (Maybe.map move game.selected)) }


applyHint : Hint -> Game -> Game
applyHint hint game =
    case hint of
        Deduce deduction ->
            let
                position =
                    ( deduction.row, deduction.col )

                revealed =
                    edit (Ocaso.revealCell position deduction.value) game
            in
            { revealed | selected = Just position, hint = Just hint }

        Mistake mistake ->
            { game | selected = Just ( mistake.row, mistake.col ), hint = Just hint }

        AllDone ->
            { game | hint = Just hint }



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Browser.Events.onKeyDown keyDecoder


{-| para as teclas que não interessam, o decoder falha, um decoder que falha
não gera mensagem, então o `update` nem fica sabendo delas
-}
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

        "0" ->
            Decode.succeed (ContentSelected Ground)

        "z" ->
            Decode.succeed UndoRequested

        "Z" ->
            Decode.succeed UndoRequested

        _ ->
            String.toInt key
                |> Maybe.andThen Ocaso.heightFromInt
                |> Maybe.map (Tower >> ContentSelected >> Decode.succeed)
                |> Maybe.withDefault (Decode.fail "tecla ignorada")



-- VIEW
--
-- As classes são semânticas ("board", "cell--shadow"); a aparência fica
-- toda em src/style.css. Os modificadores (com `--`) são ligados com
-- `classList`.


view : Model -> Html Msg
view model =
    let
        -- A análise do tabuleiro é calculada uma única vez por desenho e
        -- repassada ao tabuleiro e à mensagem de status.
        gameAnalysis =
            Maybe.map (\game -> ( game, Ocaso.analyze game.puzzle game.board )) model.game
    in
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
                [ viewBoard model gameAnalysis
                , aside [ class "side-panel" ]
                    [ span [ class "panel-label" ] [ text "Novo puzzle" ]
                    , viewDifficulty model
                    , div [ class "message-area" ] [ viewStatus model gameAnalysis ]
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


{-| checkbox `theme-controller` do daisyUI: marcado, o CSS aplica o tema escuro
-}
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


viewStatus : Model -> Maybe ( Game, Analysis ) -> Html Msg
viewStatus model gameAnalysis =
    case ( model.error, model.pending ) of
        ( Just error, _ ) ->
            div [ class "message message--error" ]
                [ span [] [ text error ]
                , button [ class "message-close", onClick ErrorDismissed ] [ text "×" ]
                ]

        ( Nothing, Generating ) ->
            loadingMessage "O Prolog está gerando um puzzle..."

        ( Nothing, Solving ) ->
            loadingMessage "O Prolog está resolvendo..."

        ( Nothing, RequestingHint ) ->
            loadingMessage "O Prolog está analisando as jogadas..."

        ( Nothing, Idle ) ->
            case gameAnalysis of
                Just ( _, { solved } ) ->
                    if solved then
                        div [ class "message message--success" ] [ text "Puzzle resolvido!" ]

                    else
                        text ""

                Nothing ->
                    text ""


loadingMessage : String -> Html Msg
loadingMessage message =
    div [ class "message message--loading" ]
        [ span [ class "spinner" ] []
        , span [] [ text message ]
        ]


viewBoard : Model -> Maybe ( Game, Analysis ) -> Html Msg
viewBoard model gameAnalysis =
    case gameAnalysis of
        Nothing ->
            -- Sem partida: ou o primeiro puzzle ainda está chegando, ou o
            -- pedido falhou (o erro aparece no painel ao lado).
            if model.error == Nothing then
                div [ class "board-loading" ] [ text "Preparando o tabuleiro..." ]

            else
                div [ class "board-loading" ]
                    [ text "Não foi possível carregar o puzzle. Escolha uma dificuldade para tentar de novo." ]

        Just ( game, analysis ) ->
            let
                columnTemplate =
                    "repeat(" ++ String.fromInt game.puzzle.size ++ ", minmax(0, 1fr))"
            in
            section [ class "board-area", attribute "aria-label" "Tabuleiro do Ocaso" ]
                [ div [ class "column-clues-row" ]
                    [ div [ class "annotation-spacer" ] []
                    , div
                        [ class "board-grid board-grid--columns"
                        , style "grid-template-columns" columnTemplate
                        ]
                        (List.indexedMap viewColumnClue
                            (List.map2 Tuple.pair game.puzzle.colClues analysis.colStatuses)
                        )
                    , div [ class "annotation-spacer" ] []
                    ]
                , div [ class "board-rows" ]
                    (List.map4 (viewRow game analysis columnTemplate)
                        (List.range 0 (game.puzzle.size - 1))
                        game.puzzle.rowClues
                        analysis.rowStatuses
                        (Ocaso.rows game.board)
                    )
                ]


viewColumnClue : Int -> ( Int, ClueStatus ) -> Html Msg
viewColumnClue col ( clue, status ) =
    div
        [ class "clue"
        , class (clueClass status)
        , attribute "aria-label" ("Soma da coluna " ++ String.fromInt (col + 1))
        ]
        [ text (String.fromInt clue) ]


{-| uma linha do tabuleiro: o sol fica no lado de onde vem e a pista de
sombra no lado para onde a sombra vai
-}
viewRow : Game -> Analysis -> String -> Int -> RowClue -> ClueStatus -> List ( Position, Cell ) -> Html Msg
viewRow game analysis columnTemplate row rowClue status line =
    let
        sunMarker =
            span
                [ class "sun-marker"
                , attribute "aria-label"
                    (case rowClue.sun of
                        West ->
                            "Sol a oeste"

                        East ->
                            "Sol a leste"
                    )
                ]
                [ text "☀" ]

        shadeClue =
            span
                [ class "clue"
                , class (clueClass status)
                , attribute "aria-label" ("Casas sombreadas na linha " ++ String.fromInt (row + 1))
                ]
                [ text (String.fromInt rowClue.shade) ]

        ( left, right ) =
            case rowClue.sun of
                West ->
                    ( sunMarker, shadeClue )

                East ->
                    ( shadeClue, sunMarker )
    in
    div [ class "board-row" ]
        [ div [ class "row-annotation" ] [ left ]
        , div
            [ class "board-grid board-grid--row"
            , style "grid-template-columns" columnTemplate
            , style "height" ("calc(var(--board-size) / " ++ String.fromInt game.puzzle.size ++ ")")
            ]
            (List.map (viewCell game analysis) line)
        , div [ class "row-annotation" ] [ right ]
        ]


viewCell : Game -> Analysis -> ( Position, Cell ) -> Html Msg
viewCell game analysis ( ( row, col ) as position, cell ) =
    button
        [ class "cell"
        , classList
            [ ( "cell--selected", game.selected == Just position )
            , ( "cell--shadow", Set.member position analysis.shaded )
            , ( "cell--lake", cell == Lake )
            , ( "cell--error"
              , Set.member position analysis.towersInShadow
                    || Set.member position analysis.lakesInSun
              )
            , ( "cell--given", sourceIs Given cell )
            , ( "cell--player", sourceIs Player cell )
            , ( "cell--prolog", sourceIs Prolog cell )
            ]
        , attribute "aria-label"
            ("Linha "
                ++ String.fromInt (row + 1)
                ++ ", coluna "
                ++ String.fromInt (col + 1)
                ++ ": "
                ++ cellDescription cell
            )
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
                    Ocaso.heightValue height
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
            "torre de altura " ++ String.fromInt (Ocaso.heightValue height)


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
        noSelection =
            model.game
                |> Maybe.andThen .selected
                |> (==) Nothing

        inactive =
            model.pending /= Idle || noSelection

        key extraClass msg label =
            button [ class extraClass, disabled inactive, onClick msg ] [ text label ]
    in
    div [ class "number-pad" ]
        [ key "number-key" (ContentSelected (Tower Low)) "1"
        , key "number-key" (ContentSelected (Tower Mid)) "2"
        , key "number-key" (ContentSelected (Tower High)) "3"
        , key "number-key number-key--ground" (ContentSelected Ground) "Chão"
        , key "erase-key" ErasePressed "⌫ Apagar"
        ]


viewActions : Model -> Html Msg
viewActions model =
    let
        busy =
            model.pending /= Idle || model.game == Nothing

        nothingToUndo =
            model.game
                |> Maybe.map (.history >> List.isEmpty)
                |> Maybe.withDefault True
    in
    div [ class "actions" ]
        [ button [ class "action-button action-button--hint", disabled busy, onClick HintRequested ]
            [ text "Pedir dica" ]
        , button [ class "action-button action-button--solve", disabled busy, onClick SolveRequested ]
            [ text "Resolver" ]
        , button
            [ class "action-button action-button--undo"
            , disabled (model.pending /= Idle || nothingToUndo)
            , onClick UndoRequested
            ]
            [ text "Desfazer (Z)" ]
        ]


viewHint : Model -> Html Msg
viewHint model =
    case Maybe.andThen .hint model.game of
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
