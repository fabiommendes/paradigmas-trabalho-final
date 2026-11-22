module Hint exposing
    ( Exclusion
    , Hint(..)
    , Method(..)
    , Rule(..)
    , explanation
    )

{-| Tipos e textos das dicas. Este módulo continua independente da interface.
-}

import Ocaso exposing (Content(..), Height(..))


type Rule
    = SunRule
    | LakeRule
    | RowRule Int
    | ColRule Int


type Method
    = Propagation
    | Search


type alias Exclusion =
    { value : Content
    , rules : List Rule
    }


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
                ++ " não pode fazer parte de uma solução. "
                ++ ruleExplanation mistake.rules

        AllDone ->
            "O tabuleiro já satisfaz todas as regras do Ocaso."


exclusionText : Exclusion -> String
exclusionText exclusion =
    "A opção "
        ++ contentText exclusion.value
        ++ " é impossível por "
        ++ ruleExplanation exclusion.rules


ruleExplanation : List Rule -> String
ruleExplanation rules =
    case rules of
        [] ->
            "todas as regras consideradas em conjunto."

        _ ->
            String.join " e " (List.map ruleText rules) ++ "."


ruleText : Rule -> String
ruleText rule =
    case rule of
        SunRule ->
            "a regra do Sol"

        LakeRule ->
            "a regra dos lagos"

        RowRule index ->
            "a pista da linha " ++ positionText index

        ColRule index ->
            "a pista da coluna " ++ positionText index


contentText : Content -> String
contentText content =
    case content of
        Ground ->
            "chão"

        Tower height ->
            "uma torre de altura " ++ String.fromInt (heightValue height)


heightValue : Height -> Int
heightValue height =
    case height of
        Low ->
            1

        Mid ->
            2

        High ->
            3


positionText : Int -> String
positionText index =
    String.fromInt (index + 1)
