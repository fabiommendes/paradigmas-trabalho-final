/*  test_sudoku.pl: Testes unitários com plunit (já vem com o SWI-Prolog).

    Para rodar:
        $ swipl -g run_tests -t halt backend/prolog/test_sudoku.pl

    Cada teste é escrito como uma cláusula `test(Nome) :- Corpo.`. O teste
    passa se o corpo tiver sucesso. Opções entre parênteses mudam o que se
    espera: `fail` (deve falhar), `true(Cond)` (Cond deve valer no final),
    `nondet` (tudo bem deixar pontos de escolha abertos).
*/

:- use_module(sudoku).
:- use_module(library(plunit)).
:- use_module(library(lists)).
:- use_module(library(apply)).

:- begin_tests(solve).

test(example_puzzle, true(Row1 == [5,3,4,6,7,8,9,1,2])) :-
    example_puzzle(P),
    solve(P, [Row1 | _]).

test(solution_keeps_clues) :-
    example_puzzle(P),
    solve(P, S),

    % Toda pista (número =\= 0) do puzzle deve aparecer igual na solução.
    % [X, Y] >> Corpo é um LAMBDA (library(yall)), uma função anônima.
    % Usamos "Se -> Então ; Senão" em vez de uma disjunção simples
    % (A ; B): a disjunção deixaria um ponto de escolha aberto a cada casa,
    % e o plunit avisaria "Test succeeded with choicepoint".
    append(P, FlatP), append(S, FlatS),
    maplist([Clue, Value] >> ( Clue =:= 0 -> true ; Clue =:= Value ), FlatP, FlatS).

test(invalid_puzzle, fail) :-
    % Dois 5 na primeira linha: impossível.
    % Atenção à ORDEM dos objetivos: primeiro montamos o tabuleiro inteiro,
    % só depois chamamos solve/2. Se invertêssemos, solve/2 receberia linhas
    % desconhecidas e passaria a "inventar" tabuleiros indefinidamente.
    length(Rest, 8),
    maplist(=([0,0,0,0,0,0,0,0,0]), Rest),

    solve([[5,5,0,0,0,0,0,0,0] | Rest], _).

test(empty_puzzle_has_many_solutions, true(N == 2)) :-
    length(Rows, 9),
    maplist(=([0,0,0,0,0,0,0,0,0]), Rows),
    count_solutions(Rows, 2, N).

:- end_tests(solve).

:- begin_tests(generate).

test(unique_solution, true(N == 1)) :-
    generate(easy, P),
    count_solutions(P, 2, N).

test(clue_count, true(Clues =< 40)) :-
    generate(easy, P),
    append(P, Flat),
    include(\==(0), Flat, Filled),
    length(Filled, Clues).

test(bad_difficulty, error(type_error(_, impossible))) :-
    generate(impossible, _).

:- end_tests(generate).

:- begin_tests(hint).

test(hint_matches_solution, true(Value == Expected)) :-
    example_puzzle(P),
    hint(P, [Row, Col, Value]),
    solve(P, S),
    nth0(Row, S, SRow), nth0(Col, SRow, Expected).

test(hint_on_empty_cell) :-
    example_puzzle(P),
    hint(P, [Row, Col, _]),
    nth0(Row, P, PRow), nth0(Col, PRow, 0).

test(complete_board, true(Result == complete)) :-
    example_puzzle(P),
    solve(P, S),
    hint(S, Result).

test(unsolvable_board, true(Result == unsolvable)) :-
    example_puzzle(P),
    solve(P, [[A, B | Rest] | Rows]),

    % Troca os dois primeiros números da solução: continua cheio, mas errado.
    hint([[B, A | Rest] | Rows], Result).

:- end_tests(hint).
