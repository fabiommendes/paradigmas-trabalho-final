/*  test_ocaso.pl: testes do Ocaso com plunit.

    Rodar: swipl -g run_tests -t halt backend/prolog/test_ocaso.pl
    (ou `make test-prolog` na raiz do repositório)

    Cada bloco begin_tests/end_tests agrupa testes de uma parte do jogo.
    Opções úteis de test/2:
        true(Cond)  o teste passa se Cond for verdadeira depois do corpo;
        fail        o teste passa se o corpo FALHAR;
        nondet      o corpo pode deixar pontos de escolha.
*/

:- use_module(ocaso).
:- use_module(library(plunit)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module(library(yall)).
:- use_module(library(clpfd)).

example_solution([[2,0,0,3,0],
                  [2,0,0,0,0],
                  [0,0,0,0,1],
                  [0,0,0,0,2],
                  [3,0,0,0,0]]).

%   Auxiliares usados por vários blocos. Ficam fora dos blocos porque cada
%   bloco begin_tests/end_tests é um módulo separado.
at(Grid, L, C, V) :-
    nth0(L, Grid, Row),
    nth0(C, Row, V).

lake(puzzle(_, _, _, _, Lakes, _), Position) :-
    memberchk(Position, Lakes).



/* ---- Geometria da sombra ---------------------------------------------- */

:- begin_tests(sombra).

test(sol_a_oeste, S == [0,1,1,0,1]) :-
    row_shadows(west, [2,0,0,1,0], S).

test(sol_a_leste, S == [1,1,0,0,0]) :-
    row_shadows(east, [0,0,2,0,0], S).

% Com a sombra ainda livre, a relação tem uma única resposta e termina no
% backtracking (antes, reverse/2 com lista sem tamanho entrava em laço).
test(sol_a_leste_termina, all(S == [[1,1,0,0,0]])) :-
    row_shadows(east, [0,0,2,0,0], S).

test(sombra_cortada_na_borda, S == [0,0,0,0,0]) :-
    row_shadows(west, [0,0,0,0,3], S).

% A relação funciona "ao contrário": dada a sombra (só a casa 3), o
% Prolog descobre as alturas possíveis. A torre que sombreia a casa 3 só
% pode ser a da casa 2, com altura 1; a da casa 4 pode ter qualquer
% altura, porque a sombra dela sai do tabuleiro.
test(sombra_determina_torres,
     all(Hs == [[0,0,1,0,0], [0,0,1,0,1], [0,0,1,0,2], [0,0,1,0,3]])) :-
    length(Hs, 5),
    Hs ins 0..3,
    row_shadows(west, Hs, [0,0,0,1,0]),
    label(Hs).

:- end_tests(sombra).


/* ---- Resolvedor -------------------------------------------------------- */

:- begin_tests(resolver).

test(resolve_exemplo, T == S) :-
    example_puzzle(P),
    example_solution(S),
    solve(P, T).

test(exemplo_tem_solucao_unica, N == 1) :-
    example_puzzle(P),
    count_solutions(P, 5, N).

test(sem_as_reveladas_ha_varias_solucoes, true(N > 1)) :-
    example_puzzle(puzzle(Size, Suns, Rows, Cols, Lakes, _)),
    count_solutions(puzzle(Size, Suns, Rows, Cols, Lakes, []), 5, N).

test(pista_impossivel, fail) :-
    example_puzzle(puzzle(N, Suns, [_ | Rows], Cols, Lakes, Givens)),
    solve(puzzle(N, Suns, [5 | Rows], Cols, Lakes, Givens), _).

test(revelada_contraditoria, fail) :-
    example_puzzle(puzzle(N, Suns, Rows, Cols, Lakes, Givens)),
    solve(puzzle(N, Suns, Rows, Cols, Lakes, [cell(0, 0, 1) | Givens]), _).

:- end_tests(resolver).


/* ---- Gerador ----------------------------------------------------------- */

:- begin_tests(gerador).

%   forall/2 + o teste de propriedades: para cada nível, o puzzle gerado tem
%   o tamanho certo, solução única e pistas coerentes com a solução.
test(niveis) :-
    forall(member(Level-Size, [easy-5, medium-6, hard-7]),
           ( generate(Level, P),
             P = puzzle(Size, _, _, _, _, _),
             consistent(P) )).

test(varios_puzzles_dificeis) :-
    forall(between(1, 5, _),
           ( generate(hard, P), consistent(P) )).

test(nivel_desconhecido, error(type_error(_, impossible))) :-
    generate(impossible, _).

%   As pistas de linha e coluna batem com a solução, os lagos estão na
%   sombra e sem torre, nenhuma torre está na sombra e a solução é única.
consistent(P) :-
    P = puzzle(_, Suns, Rows, Cols, Lakes, Givens),
    count_solutions(P, 2, 1),
    solve(P, T),
    maplist(row_shadows, Suns, T, Shade),
    maplist(sum_list, Shade, Rows),
    transpose(T, Columns),
    maplist(sum_list, Columns, Cols),
    forall(member(L-C, Lakes), ( at(Shade, L, C, 1), at(T, L, C, 0) )),
    forall(( at(T, L, C, H), H > 0 ), at(Shade, L, C, 0)),
    forall(member(cell(L, C, H), Givens), at(T, L, C, H)).

:- end_tests(gerador).


/* ---- Dicas ------------------------------------------------------------- */

:- begin_tests(dicas).

test(dica_bate_com_a_solucao) :-
    example_puzzle(P),
    example_solution(S),
    hint(P, [], cell(L, C, H, _How, Excluded)),
    at(S, L, C, H),
    pairs_keys(Excluded, Others),
    msort(Others, Sorted),
    subtract([0,1,2,3], [H], Sorted).

% Na linha 3 (sol a leste), a torre de altura 2 já sombreia as duas casas
% pedidas pela pista. Uma torre na casa (3,1) faria mais sombra: o motivo
% é a regra da linha 3, sozinha. why_not/5 não é exportado; chamamos com o
% nome do módulo na frente.
test(motivo_da_linha, Reason == [row(3)]) :-
    example_puzzle(P),
    ocaso:why_not(P, [], 3-1, 1, Reason).

% A coluna 0 soma 7 e já tem 2 em (1,0) e 3 em (4,0). Se (0,0) ficasse
% vazia, a coluna sozinha ainda fecharia com uma torre 2 em (2,0); para
% excluir esse caso é preciso combinar a coluna com outras regras.
test(motivo_composto, true(Reason \== [col(0)])) :-
    example_puzzle(P),
    ocaso:why_not(P, [cell(1, 0, 2)], 0-0, 0, Reason).

test(casa_errada_e_apontada, Hint = wrong(0, 0, 1, _)) :-
    example_puzzle(P),
    hint(P, [cell(4, 4, 0), cell(0, 0, 1)], Hint).

% A torre de altura 2 em (1,0) faz sombra em (1,1) e (1,2). Uma torre em
% (1,1) ficaria na sombra: a regra do sol, sozinha, basta.
test(motivo_do_sol, Hint = wrong(1, 1, 1, [sun])) :-
    example_puzzle(P),
    hint(P, [cell(1, 0, 2), cell(1, 1, 1)], Hint).

test(tabuleiro_completo, Hint == complete) :-
    example_puzzle(P),
    example_solution(S),
    findall(cell(L, C, H),
            ( at(S, L, C, H), \+ lake(P, L-C) ),
            Placed),
    hint(P, Placed, Hint).

test(dica_nunca_aponta_casa_decidida) :-
    example_puzzle(P),
    Placed = [cell(0, 0, 2), cell(1, 0, 2), cell(4, 4, 0)],
    hint(P, Placed, cell(L, C, _, _, _)),
    \+ memberchk(cell(L, C, _), Placed),
    \+ lake(P, L-C).

:- end_tests(dicas).


/* ---- Fronteira com o Python -------------------------------------------- */

:- begin_tests(api).

test(dict_ida_e_volta) :-
    api_generate("medium", Dict),
    get_dict(size, Dict, 6),
    api_solve(Dict, Towers),
    length(Towers, 6).

test(dica_como_dict, Kind == wrong) :-
    example_puzzle(puzzle(N, _Suns, Rows, Cols, Lakes, Givens)),
    maplist([L-C, [L, C]] >> true, Lakes, LakeLists),
    maplist([cell(L, C, H), [L, C, H]] >> true, Givens, GivenLists),
    Dict = _{size: N, suns: ["west", "west", "east", "east", "west"],
             rows: Rows, cols: Cols, lakes: LakeLists, givens: GivenLists},
    api_hint(Dict, [[0, 0, 1]], Hint),
    get_dict(kind, Hint, Kind).

:- end_tests(api).
