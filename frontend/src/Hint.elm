module Hint exposing
    ( Exclusion
    , Hint(..)
    , Method(..)
    , Rule(..)
    , explanation
    )

{-| Tipos e textos das dicas

as dicas são calculadas pelo Prolog, aqui elas viram valores Elm e, depois,
frases em português. o módulo não conhece HTML: `explanation`
devolve só o texto, e a tela decide como mostrá-lo

-}

import Ocaso exposing (Content(..))


{-| as quatro regras do jogo, como o Prolog as cita ao explicar uma dica.
`RowRule` e `ColRule` carregam o índice (a partir de 0) da linha ou coluna
-}
type Rule
    = SunRule
    | LakeRule
    | RowRule Int
    | ColRule Int


{-| como o Prolog chegou à casa, só pela propagação das restrições, ou
precisando testar hipóteses (busca)
-}
type Method
    = Propagation
    | Search


{-| um valor que a casa não pode ter e as regras que o excluem. lista vazia
quer dizer que só a combinação de todas as regras o exclui
-}
type alias Exclusion =
    { value : Content
    , rules : List Rule
    }


{-| cada forma de dica carrega só os dados que fazem sentido para ela, uma
dedução tem método e exclusões, um erro tem as regras violadas, e
`AllDone` não tem nada. com um único record cheio de `Maybe`, a tela
teria de lidar com combinações que nunca acontecem
-}
type Hint
    = Deduce
        { row : Int
        , col : Int
        , value : Content
        , method : Method
        , excluded : List Exclusion
        }
    | Mistake
        { row : Int
        , col : Int
        , value : Content
        , rules : List Rule
        }
    | AllDone


explanation : Hint -> String
explanation hint =
    case hint of
        Deduce deduction ->
            let
                methodText =
                    case deduction.method of
                        Propagation ->
                            "pela propagação das restrições"

                        Search ->
                            "pela busca de uma solução"

                exclusions =
                    if List.isEmpty deduction.excluded then
                        ""

                    else
                        " " ++ String.join " " (List.map exclusionText deduction.excluded)
            in
            "O Prolog deduz "
                ++ contentText deduction.value
                ++ " na linha "
                ++ positionText deduction.row
                ++ ", coluna "
                ++ positionText deduction.col
                ++ " "
                ++ methodText
                ++ "."
                ++ exclusions

        Mistake mistake ->
            "A decisão de "
                ++ contentText mistake.value
                ++ " na linha "
                ++ positionText mistake.row
                ++ ", coluna "
                ++ positionText mistake.col
                ++ " está errada: ela é excluída "
                ++ ruleExplanation mistake.rules

        AllDone ->
            "O tabuleiro já satisfaz todas as regras do Ocaso."


exclusionText : Exclusion -> String
exclusionText exclusion =
    "A opção "
        ++ contentText exclusion.value
        ++ " é impossível "
        ++ ruleExplanation exclusion.rules


{-| completa frases como "é impossível ..." e "ela é excluída ...". a lista
vazia vem do Prolog quando nenhuma regra isolada nem nenhum par de regras
basta para excluir o valor
-}
ruleExplanation : List Rule -> String
ruleExplanation rules =
    case rules of
        [] ->
            "pela combinação de todas as regras."

        _ ->
            String.join " e " (List.map ruleText rules) ++ "."


ruleText : Rule -> String
ruleText rule =
    case rule of
        SunRule ->
            "pela regra do Sol"

        LakeRule ->
            "pela regra dos lagos"

        RowRule index ->
            "pela pista da linha " ++ positionText index

        ColRule index ->
            "pela pista da coluna " ++ positionText index


contentText : Content -> String
contentText content =
    case content of
        Ground ->
            "chão"

        Tower height ->
            "uma torre de altura " ++ String.fromInt (Ocaso.heightValue height)


positionText : Int -> String
positionText index =
    String.fromInt (index + 1)
