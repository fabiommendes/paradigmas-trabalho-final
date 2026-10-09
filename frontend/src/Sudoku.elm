module Sudoku exposing
    ( Board
    , Cell(..)
    , Position
    , cellAt
    , clearGuesses
    , conflicts
    , empty
    , fromLists
    , isComplete
    , isGiven
    , isGuess
    , isRevealed
    , positions
    , removeMarkFromPeers
    , revealSolution
    , sameBox
    , setCell
    , toLists
    , toggleMark
    , valueOf
    )

{-| Regras e representação do tabuleiro de Sudoku, do lado do Elm.

Este módulo é PURO: não faz HTTP, não sabe nada de HTML. São só dados e
funções sobre esses dados, o que o torna fácil de testar e de entender.

A linha `module Sudoku exposing (...)` lista o que outros módulos podem usar.
`Cell(..)` exporta o tipo E seus construtores (Given, Guess, ...). Se
escrevêssemos só `Board`, o tipo seria "opaco": quem está de fora saberia que
ele existe, mas não conseguiria ver nem montar seu conteúdo diretamente.

-}

import Array exposing (Array)
import Set exposing (Set)



-- TIPOS


{-| Uma casa do tabuleiro.

Isto é um _custom type_ (também chamado de tipo soma ou tipo algébrico): uma
casa é EXATAMENTE uma das cinco alternativas abaixo. Alguns construtores
carregam dados (o número da casa, ou um conjunto de números); `Empty` não
carrega nada.

O compilador obriga todo `case` sobre `Cell` a tratar as cinco alternativas.
Quando adicionamos `Marks` a este tipo, o compilador apontou cada `case` do
programa que precisava ser atualizado. Esse é um dos grandes trunfos de uma
linguagem com tipos estáticos fortes: mudar o modelo de dados é seguro.

-}
type Cell
    = Given Int -- pista original do puzzle (não pode ser alterada)
    | Guess Int -- número colocado pelo jogador
    | Revealed Int -- número revelado pelo computador (dica ou "resolver")
    | Marks (Set Int) -- casa vazia com marcações de canto (candidatos)
    | Empty


{-| Posição de uma casa: (linha, coluna), ambas de 0 a 8.

`type alias` só dá um nome novo para um tipo que já existe. Aqui, `Position`
é exatamente a mesma coisa que uma tupla `( Int, Int )`, mas o nome deixa as
assinaturas mais legíveis.

-}
type alias Position =
    ( Int, Int )


{-| O tabuleiro inteiro: 81 casas em um Array, linha por linha.

A casa (linha, coluna) fica no índice `linha * 9 + coluna`. Usamos Array em
vez de List porque Array tem acesso por índice eficiente.

Lembre-se: em Elm, tudo é imutável. `setCell` não modifica o tabuleiro; ele
devolve um tabuleiro NOVO com a casa alterada.

-}
type alias Board =
    Array Cell



-- CONSTRUÇÃO E CONVERSÃO


empty : Board
empty =
    Array.repeat 81 Empty


{-| Converte o formato usado pela API (lista de linhas, 0 = vazio) em um
tabuleiro. Os números recebidos viram pistas (`Given`).

`List.concat` achata a lista de listas; `List.map toCell` converte cada número
e `Array.fromList` transforma a lista final em Array. O operador `|>` passa o
resultado da esquerda como último argumento da função da direita, deixando o
fluxo de dados legível de cima para baixo.

-}
fromLists : List (List Int) -> Board
fromLists rows =
    rows
        |> List.concat
        |> List.map
            (\n ->
                -- `\n -> ...` é uma função anônima (lambda).
                if n == 0 then
                    Empty

                else
                    Given n
            )
        |> Array.fromList


{-| O caminho inverso: tabuleiro -> lista de linhas, com 0 nas casas vazias.
É o formato que enviamos ao backend.
-}
toLists : Board -> List (List Int)
toLists board =
    board
        |> Array.toList
        -- `valueOf >> Maybe.withDefault 0` é uma COMPOSIÇÃO de funções:
        -- primeiro aplica `valueOf`, depois `Maybe.withDefault 0` no
        -- resultado. Casas vazias (Nothing) viram 0.
        |> List.map (valueOf >> Maybe.withDefault 0)
        |> chunksOf9


{-| Quebra uma lista em pedaços de 9. É recursiva: pega os 9
primeiros, e chama a si mesma com o resto.
-}
chunksOf9 : List a -> List (List a)
chunksOf9 list =
    case list of
        [] ->
            []

        _ ->
            List.take 9 list :: chunksOf9 (List.drop 9 list)



-- CONSULTAS


{-| O número de uma casa, se houver.

`Maybe Int` é o jeito do Elm de dizer "pode ter um Int, ou pode não ter nada".
Não existe `null` em Elm: quem chama esta função é obrigado a tratar o caso
`Nothing`.

-}
valueOf : Cell -> Maybe Int
valueOf cell =
    case cell of
        Given n ->
            Just n

        Guess n ->
            Just n

        Revealed n ->
            Just n

        -- Marcações são só lembretes do jogador: a casa continua sem número.
        Marks _ ->
            Nothing

        Empty ->
            Nothing


cellAt : Position -> Board -> Cell
cellAt ( row, col ) board =
    -- Array.get devolve Maybe, pois o índice pode estar fora do Array.
    Array.get (row * 9 + col) board
        |> Maybe.withDefault Empty


{-| Perguntas sobre a origem de uma casa. Cada uma casa um único construtor;
o `_` cobre todos os outros. São úteis onde um `case` completo seria
exagero, como numa lista de `classList`.
-}
isGiven : Cell -> Bool
isGiven cell =
    case cell of
        Given _ ->
            True

        _ ->
            False


isGuess : Cell -> Bool
isGuess cell =
    case cell of
        Guess _ ->
            True

        _ ->
            False


isRevealed : Cell -> Bool
isRevealed cell =
    case cell of
        Revealed _ ->
            True

        _ ->
            False


{-| Todas as 81 posições, na ordem de leitura.

Isto é uma "list comprehension" feita à mão: para cada linha, geramos a
lista de posições daquela linha, e `List.concatMap` junta tudo.

-}
positions : List Position
positions =
    List.range 0 8
        |> List.concatMap (\row -> List.map (\col -> ( row, col )) (List.range 0 8))


sameBox : Position -> Position -> Bool
sameBox ( r1, c1 ) ( r2, c2 ) =
    -- `//` é divisão inteira: 0-2 -> 0, 3-5 -> 1, 6-8 -> 2
    r1 // 3 == r2 // 3 && c1 // 3 == c2 // 3


{-| Duas posições diferentes "se enxergam" se estão na mesma linha, coluna
ou bloco. Nessas condições não podem ter o mesmo número.
-}
peers : Position -> Position -> Bool
peers (( r1, c1 ) as p1) (( r2, c2 ) as p2) =
    -- `( r1, c1 ) as p1` desestrutura a tupla E dá nome à tupla inteira.
    p1 /= p2 && (r1 == r2 || c1 == c2 || sameBox p1 p2)


{-| Posições que violam as regras: casas com o mesmo número de outra casa na
mesma linha, coluna ou bloco.

Esta checagem é feita no Elm (e não no Prolog) porque precisa ser instantânea
a cada tecla. É uma verificação simples, O(81 × 81), que não precisa de busca.

-}
conflicts : Board -> Set Position
conflicts board =
    let
        -- `let ... in` define nomes locais. Aqui: lista de (posição, número)
        -- apenas das casas preenchidas. `List.filterMap` aplica a função e
        -- descarta os resultados `Nothing`.
        filled : List ( Position, Int )
        filled =
            positions
                |> List.filterMap
                    (\pos ->
                        cellAt pos board
                            |> valueOf
                            |> Maybe.map (\n -> ( pos, n ))
                    )

        inConflict ( pos, n ) =
            List.any (\( other, m ) -> n == m && peers pos other) filled
    in
    filled
        |> List.filter inConflict
        |> List.map Tuple.first
        |> Set.fromList


{-| O jogo termina quando todas as casas têm número e não há conflitos.
-}
isComplete : Board -> Bool
isComplete board =
    List.all (\cell -> valueOf cell /= Nothing) (Array.toList board)
        && Set.isEmpty (conflicts board)



-- ALTERAÇÕES


{-| Coloca uma casa numa posição, exceto se ela for uma pista original.
-}
setCell : Position -> Cell -> Board -> Board
setCell (( row, col ) as pos) cell board =
    case cellAt pos board of
        Given _ ->
            -- `_` casa com qualquer valor, que ignoramos.
            board

        _ ->
            Array.set (row * 9 + col) cell board


{-| Liga ou desliga a marcação de canto `n` numa casa.

Só faz sentido em casas sem número. Em casas com número (pista, palpite ou
revelada), o tabuleiro volta inalterado.

-}
toggleMark : Position -> Int -> Board -> Board
toggleMark position n board =
    case cellAt position board of
        Empty ->
            setCell position (Marks (Set.singleton n)) board

        Marks marks ->
            let
                toggled =
                    if Set.member n marks then
                        Set.remove n marks

                    else
                        Set.insert n marks
            in
            setCell position (fromMarks toggled) board

        _ ->
            board


{-| Apaga a marcação `n` de todas as casas que "enxergam" `position`.

Chamamos isto quando o jogador coloca o número `n` em `position`: nenhum
vizinho pode mais ter `n`, então a marcação deixou de ser um candidato.

A posição de cada casa é recuperada a partir do índice no Array:
linha = índice // 9, coluna = resto da divisão por 9.

-}
removeMarkFromPeers : Position -> Int -> Board -> Board
removeMarkFromPeers position n board =
    Array.indexedMap
        (\index cell ->
            case cell of
                Marks marks ->
                    if peers position ( index // 9, modBy 9 index ) then
                        fromMarks (Set.remove n marks)

                    else
                        cell

                _ ->
                    cell
        )
        board


{-| "Construtor inteligente" (smart constructor) para marcações.

Queremos garantir uma regra: nunca existe `Marks` com o conjunto vazio,
porque isso seria só uma forma disfarçada de `Empty`. Se todo o código criar
marcações por meio desta função, a regra vale sempre. O `Main` também não cria
`Marks` diretamente: ele chama `toggleMark`, que usa esta função.

(Para garantir a regra pelo compilador, precisaríamos esconder os
construtores de `Cell`, exportando `Cell` em vez de `Cell(..)`. Aqui
preferimos a simplicidade.)

-}
fromMarks : Set Int -> Cell
fromMarks marks =
    if Set.isEmpty marks then
        Empty

    else
        Marks marks


{-| Copia os valores de uma solução para todas as casas que não são pistas,
marcando-os como `Revealed`.

`Array.indexedMap` é como `Array.map`, mas a função também recebe o índice
de cada elemento, e com ele buscamos a casa correspondente na solução.
`Maybe.andThen` encadeia operações que podem falhar: se `Array.get` der
`Nothing`, o resto é pulado e caímos no `withDefault`.

-}
revealSolution : Board -> Board -> Board
revealSolution solution board =
    Array.indexedMap
        (\index cell ->
            case cell of
                Given _ ->
                    cell

                _ ->
                    Array.get index solution
                        |> Maybe.andThen valueOf
                        |> Maybe.map Revealed
                        |> Maybe.withDefault cell
        )
        board


{-| Apaga tudo o que não é pista original, inclusive as marcações.
-}
clearGuesses : Board -> Board
clearGuesses board =
    Array.map
        (\cell ->
            case cell of
                Given _ ->
                    cell

                _ ->
                    Empty
        )
        board
