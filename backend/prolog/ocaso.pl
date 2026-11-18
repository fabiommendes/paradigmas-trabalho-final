/*  ocaso.pl: as regras, o resolvedor, o gerador e as dicas do jogo Ocaso.

    O JOGO
    ------
    Ao entardecer, o sol está baixo e cada torre projeta uma sombra comprida.
    O tabuleiro é uma grade N x N. Cada casa é um LAGO (fixo, faz parte do
    puzzle) ou um terreno, que pode estar vazio ou ter uma torre de altura
    1, 2 ou 3.

    Em cada linha o sol vem de um lado (oeste ou leste, mostrado no
    tabuleiro). Uma torre de altura H faz sombra nas H casas seguintes, no
    sentido oposto ao do sol. A sombra é cortada na borda do tabuleiro.

    As quatro regras:

        1. SOL     nenhuma torre pode ficar na sombra de outra;
        2. LAGOS   todo lago precisa estar na sombra;
        3. LINHAS  o número no fim da linha diz quantas casas dela estão na
                   sombra (lagos inclusive);
        4. COLUNAS o número no alto da coluna é a soma das alturas das torres
                   dessa coluna.

    Lagos nunca têm torre. Algumas casas podem vir reveladas no início, para
    que a solução seja única.

    REPRESENTAÇÃO
    -------------
    Dentro deste arquivo um puzzle é o termo

        puzzle(Tamanho, Sois, PistasLinhas, PistasColunas, Lagos, Reveladas)

    com Sois = [west, east, ...] (um por linha), Lagos = [L-C, ...] e
    Reveladas = [cell(L, C, Altura), ...], em que Altura 0 é "sem torre".
    Linhas e colunas contam a partir de 0.

    Uma solução é uma lista de N linhas com N alturas cada (0 a 3).

    A IDEIA CENTRAL
    ---------------
    Tudo é escrito como RESTRIÇÕES do CLP(FD). Cada casa ganha duas
    variáveis: a altura H (0..3) e a sombra S (0 ou 1). A definição de
    sombra é uma equivalência lógica (S é 1 se e só se alguma torre "alcança"
    a casa) e as regras são somas e implicações sobre H e S.

    O mesmo modelo serve para quatro coisas diferentes, sem nenhum algoritmo
    específico para cada uma:

        * resolver:  impor tudo e pedir valores (labeling);
        * contar soluções: o mesmo, coletando até 2 respostas;
        * gerar:     impor só a geometria e sortear valores;
        * explicar:  impor UMA regra de cada vez e ver qual delas, sozinha,
                     já torna um valor impossível.

    COMO TESTAR NO TERMINAL
    -----------------------
        $ swipl backend/prolog/ocaso.pl
        ?- example_puzzle(P), print_puzzle(P).
        ?- example_puzzle(P), solve(P, T), print_solution(P, T).
        ?- generate(hard, P), print_puzzle(P).
        ?- example_puzzle(P), hint(P, [], Dica).
*/

:- module(ocaso,
          [ solve/2,            % +Puzzle, -Towers
            count_solutions/3,  % +Puzzle, +Limit, -Count
            generate/2,         % +Difficulty, -Puzzle
            hint/3,             % +Puzzle, +Placed, -Hint
            row_shadows/3,      % ?Sun, ?Heights, ?Shade
            example_puzzle/1,   % -Puzzle
            print_puzzle/1,     % +Puzzle
            print_solution/2,   % +Puzzle, +Towers
            api_generate/2,     % +DifficultyName, -PuzzleDict
            api_solve/2,        % +PuzzleDict, -Towers
            api_hint/3          % +PuzzleDict, +Placed, -HintDict
          ]).

%   +Arg: entrada (instanciada); -Arg: saída; ?Arg: tanto faz.

:- use_module(library(clpfd)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(yall)).    % lambdas: [X] >> objetivo

%   Cuidado com lambdas: uma variável que aparece no corpo do lambda mas
%   não nos parâmetros é tratada como LOCAL (renomeada a cada chamada).
%   Por isso só usamos lambdas cujo corpo depende apenas dos parâmetros;
%   nos outros casos, um predicado auxiliar com nome.
:- use_module(library(pairs)).
:- use_module(library(random)).
:- use_module(library(solution_sequences)).


/* =========================================================================
   1. GEOMETRIA DA SOMBRA
   ========================================================================= */

%!  row_shadows(?Sun, ?Heights, ?Shade) is det.
%
%   Relaciona as alturas de uma linha com as casas sombreadas dela. Funciona
%   nos dois sentidos: com as alturas conhecidas calcula a sombra, e com a
%   sombra conhecida restringe as alturas possíveis.
%
%       ?- row_shadows(west, [2,0,0,1,0], S).
%       S = [0,1,1,0,1].
%
%   Com o sol a leste, a sombra anda para oeste. Em vez de escrever uma
%   segunda versão, invertemos a linha: o leste vira oeste.
row_shadows(west, Heights, Shade) :-
    cast(Heights, [], Shade).
row_shadows(east, Heights, Shade) :-
    reverse(Heights, ReversedHeights),
    reverse(Shade, ReversedShade),
    cast(ReversedHeights, [], ReversedShade).

%   cast(?Heights, +Behind, ?Shade)
%   Percorre a linha no sentido em que a sombra anda. Behind guarda as
%   alturas das até 3 casas anteriores, da mais próxima para a mais
%   distante: só elas podem alcançar a casa atual, porque a torre mais alta
%   tem altura 3.
cast([], _Behind, []).
cast([H | Hs], Behind, [S | Ss]) :-
    S in 0..1,
    reaches(Behind, 1, Reach),
    % #<==> é a equivalência reificada: S vale 1 exatamente quando a
    % fórmula Reach é verdadeira. Não dizemos COMO calcular S; dizemos o que
    % S significa, e a propagação funciona nos dois sentidos.
    S #<==> Reach,
    nearest_three([H | Behind], Behind1),
    cast(Hs, Behind1, Ss).

%   reaches(+Behind, +Distance, -Formula)
%   Monta a fórmula "a torre à distância 1 tem altura >= 1, OU a torre à
%   distância 2 tem altura >= 2, OU ...". Sem casas atrás, a fórmula é 0
%   (falso): a primeira casa da linha nunca está na sombra.
reaches([], _Distance, 0).
reaches([H | Hs], Distance, (H #>= Distance) #\/ Rest) :-
    Next is Distance + 1,
    reaches(Hs, Next, Rest).

nearest_three(List, Prefix) :-
    length(List, Length),
    (   Length > 3
    ->  length(Prefix, 3),
        append(Prefix, _, List)
    ;   Prefix = List
    ).


/* =========================================================================
   2. O MODELO: VARIÁVEIS, CASAS CONHECIDAS E REGRAS
   ========================================================================= */

%!  board_model(+Puzzle, +Known, +Rules, -Towers, -Shade) is semidet.
%
%   Cria as variáveis do tabuleiro e impõe: a geometria da sombra, os lagos
%   sem torre, as casas conhecidas (reveladas pelo puzzle e as de Known) e
%   as regras pedidas em Rules. Falha se a propagação já encontrar uma
%   contradição.
%
%   Rules é uma lista com elementos sun, lakes, rows, cols, row(L), col(C).
%   Escolher QUAIS regras impor é o que permite explicar as dicas (seção 5).
board_model(puzzle(N, Suns, RowClues, ColClues, Lakes, Givens),
            Known, Rules, Towers, Shade) :-
    square(N, Towers),
    square(N, Shade),
    append(Towers, Heights),
    Heights ins 0..3,
    maplist(row_shadows, Suns, Towers, Shade),
    maplist(lake_has_no_tower(Towers), Lakes),
    append(Givens, Known, Fixed),
    maplist(fix_cell(Towers), Fixed),
    Board = board(Towers, Shade, RowClues, ColClues, Lakes),
    maplist(rule(Board), Rules).

all_rules([sun, lakes, rows, cols]).

%   square(+N, -Rows): N linhas de N variáveis novas.
square(N, Rows) :-
    length(Rows, N),
    maplist(length_of(N), Rows).

length_of(N, List) :-
    length(List, N).

lake_has_no_tower(Towers, L-C) :-
    cell_at(Towers, L, C, 0).

fix_cell(Towers, cell(L, C, Height)) :-
    cell_at(Towers, L, C, Var),
    Var #= Height.

cell_at(Grid, L, C, Value) :-
    nth0(L, Grid, Row),
    nth0(C, Row, Value).

%!  rule(+Board, +Rule) is semidet.
%
%   Cada cláusula impõe uma das regras do jogo.
rule(board(Towers, Shade, _, _, _), sun) :-
    append(Towers, Heights),
    append(Shade, Shadows),
    maplist(in_sun, Heights, Shadows).
rule(board(_, Shade, _, _, Lakes), lakes) :-
    maplist(lake_in_shade(Shade), Lakes).
rule(board(_, Shade, RowClues, _, _), rows) :-
    maplist(sum_is, Shade, RowClues).
rule(board(Towers, _, _, ColClues, _), cols) :-
    transpose(Towers, Columns),
    maplist(sum_is, Columns, ColClues).
rule(board(_, Shade, RowClues, _, _), row(L)) :-
    nth0(L, Shade, Row),
    nth0(L, RowClues, Clue),
    sum_is(Row, Clue).
rule(board(Towers, _, _, ColClues, _), col(C)) :-
    transpose(Towers, Columns),
    nth0(C, Columns, Column),
    nth0(C, ColClues, Clue),
    sum_is(Column, Clue).

%   Na sombra (S = 1), a altura tem de ser 0. É a regra 1 como implicação.
in_sun(Height, Shadow) :-
    Shadow #==> Height #= 0.

lake_in_shade(Shade, L-C) :-
    cell_at(Shade, L, C, 1).

sum_is(Vars, Total) :-
    sum(Vars, #=, Total).


/* =========================================================================
   3. RESOLVER E CONTAR SOLUÇÕES
   ========================================================================= */

%!  solve(+Puzzle, -Towers) is semidet.
%
%   Towers é a (primeira) solução de Puzzle; falha se não houver nenhuma.
solve(Puzzle, Towers) :-
    solution(Puzzle, [], Towers),
    !.

%   solution(+Puzzle, +Known, -Towers) is nondet.
%   Enumera, por backtracking, todas as soluções compatíveis com Known.
solution(Puzzle, Known, Towers) :-
    all_rules(Rules),
    board_model(Puzzle, Known, Rules, Towers, _Shade),
    append(Towers, Heights),
    labeling([ff], Heights).

%!  count_solutions(+Puzzle, +Limit, -Count) is det.
%
%   Quantas soluções Puzzle tem, contando até Limit. Com Limit = 2 sabemos
%   se a solução é única sem enumerar todas.
count_solutions(Puzzle, Limit, Count) :-
    aggregate_all(count, limit(Limit, solution(Puzzle, [], _)), Count).

unique(Puzzle) :-
    count_solutions(Puzzle, 2, 1).


/* =========================================================================
   4. GERADOR
   =========================================================================

   (a) Sorteamos o lado do sol em cada linha e uma distribuição de torres
       que respeite a regra do sol. Usamos o mesmo modelo, só com a
       geometria e a regra `sun`, e uma busca que testa os valores em ordem
       aleatória.
   (b) Escolhemos alguns lagos entre as casas que ficaram na sombra.
   (c) As pistas saem da própria solução: casas sombreadas por linha e
       soma das alturas por coluna.
   (d) Enquanto houver mais de uma solução, revelamos uma casa em que duas
       soluções discordam. Depois tentamos esconder cada casa revelada e
       mantemos escondidas as que não quebram a unicidade.
   (e) Nos níveis mais fáceis, revelamos algumas casas a mais.
*/

%!  level(?Difficulty, ?Size, ?ExtraGivens) is nondet.
level(easy,   5, 3).
level(medium, 6, 1).
level(hard,   7, 0).

%!  generate(+Difficulty, -Puzzle) is det.
generate(Difficulty, Puzzle) :-
    must_be(oneof([easy, medium, hard]), Difficulty),
    level(Difficulty, N, Extra),
    repeat,
    random_layout(N, Suns, Towers, Shade),
    random_lakes(N, Shade, Lakes),
    !,
    maplist(sum_list, Shade, RowClues),
    transpose(Towers, Columns),
    maplist(sum_list, Columns, ColClues),
    Bare = puzzle(N, Suns, RowClues, ColClues, Lakes, []),
    make_unique(Bare, Towers, Unique),
    minimize_givens(Unique, Minimal),
    add_givens(Extra, Towers, Minimal, Puzzle).

%!  random_layout(+N, -Suns, -Towers, -Shade) is semidet.
%
%   Uma distribuição aleatória de torres em que nenhuma fica na sombra e
%   cada linha tem pelo menos uma torre (esta última exigência é só do
%   gerador, para o tabuleiro não sair vazio; não é regra do jogo).
random_layout(N, Suns, Towers, Shade) :-
    length(Suns, N),
    maplist(random_member_of([west, east]), Suns),
    board_model(puzzle(N, Suns, _, _, [], []), [], [sun], Towers, Shade),
    maplist(has_tower, Towers),
    append(Towers, Heights),
    random_labeling(Heights),
    !.

random_member_of(Options, X) :-
    random_member(X, Options).

has_tower(Row) :-
    maplist(is_tower, Row, IsTower),
    sum(IsTower, #>=, 1).

is_tower(Height, Flag) :-
    Flag #<==> Height #> 0.

%   random_labeling(+Vars) is nondet.
%   Como label/1, mas em ordem aleatória e com preferência por casas vazias
%   (senão o tabuleiro fica lotado de torres).
random_labeling([]).
random_labeling([Var | Vars]) :-
    random_value_order(Order),
    member(Var, Order),
    random_labeling(Vars).

random_value_order(Order) :-
    random_permutation([1, 2, 3], Towers),
    (   random(X), X < 0.6
    ->  Order = [0 | Towers]
    ;   append(Towers, [0], Order)
    ).

%   random_lakes(+N, +Shade, -Lakes) is semidet.
%   Cada casa sombreada vira lago com 45% de chance. Exige ao menos N/2
%   lagos, para o puzzle ficar interessante; senão o `repeat` de generate/2
%   sorteia outro tabuleiro.
random_lakes(N, Shade, Lakes) :-
    findall(L-C,
            ( cell_at(Shade, L, C, 1),
              random(X), X < 0.45 ),
            Lakes),
    length(Lakes, Count),
    Count >= N // 2.

%!  make_unique(+Puzzle0, +Towers, -Puzzle) is det.
make_unique(Puzzle0, Towers, Puzzle) :-
    findall(T, limit(2, solution(Puzzle0, [], T)), Solutions),
    (   Solutions = [_]
    ->  Puzzle = Puzzle0
    ;   Solutions = [T1, T2],
        findall(L-C,
                ( cell_at(T1, L, C, V1),
                  cell_at(T2, L, C, V2),
                  V1 =\= V2 ),
                Disagreements),
        random_member(L-C, Disagreements),
        reveal(L-C, Towers, Puzzle0, Puzzle1),
        make_unique(Puzzle1, Towers, Puzzle)
    ).

reveal(L-C, Towers, puzzle(N, S, R, K, Lakes, Givens),
       puzzle(N, S, R, K, Lakes, [cell(L, C, H) | Givens])) :-
    cell_at(Towers, L, C, H).

%!  minimize_givens(+Puzzle0, -Puzzle) is det.
%
%   Tenta esconder cada casa revelada, em ordem aleatória. Uma casa só
%   continua revelada se escondê-la permitir uma segunda solução.
minimize_givens(puzzle(N, S, R, K, Lakes, Givens), Puzzle) :-
    random_permutation(Givens, Order),
    foldl(try_hide, Order, puzzle(N, S, R, K, Lakes, Givens), Puzzle).

try_hide(Given, puzzle(N, S, R, K, Lakes, Givens), Puzzle) :-
    selectchk(Given, Givens, Fewer),
    Candidate = puzzle(N, S, R, K, Lakes, Fewer),
    (   unique(Candidate)
    ->  Puzzle = Candidate
    ;   Puzzle = puzzle(N, S, R, K, Lakes, Givens)
    ).

%   add_givens(+Count, +Towers, +Puzzle0, -Puzzle)
%   Revela Count casas a mais (que não sejam lagos nem já reveladas).
add_givens(Count, Towers, puzzle(N, S, R, K, Lakes, Givens), Puzzle) :-
    findall(L-C,
            ( cell_at(Towers, L, C, _),
              \+ memberchk(L-C, Lakes),
              \+ memberchk(cell(L, C, _), Givens) ),
            Hidden),
    random_permutation(Hidden, Shuffled),
    length(Shuffled, Available),
    Take is min(Count, Available),
    length(Chosen, Take),
    append(Chosen, _, Shuffled),
    foldl(reveal_in(Towers), Chosen, puzzle(N, S, R, K, Lakes, Givens), Puzzle).

reveal_in(Towers, Position, Puzzle0, Puzzle) :-
    reveal(Position, Towers, Puzzle0, Puzzle).


/* =========================================================================
   5. DICAS COM EXPLICAÇÃO
   =========================================================================

   O jogador manda as casas que já decidiu (Placed = [cell(L, C, Altura)]).
   A dica pode ser:

     wrong(L, C, Altura, Motivo)   uma casa decidida está errada, e Motivo
                                   diz qual regra a contradiz;
     cell(L, C, Altura, Como, Excluídos)
                                   a próxima casa a decidir. Como é
                                   `propagation` se as regras já a
                                   determinam sem nenhuma tentativa, ou
                                   `search` se é preciso testar hipóteses.
                                   Excluídos = [Valor-Motivo, ...] explica
                                   por que cada um dos outros valores é
                                   impossível;
     complete                      não há casa por decidir.

   O Motivo é a lista das regras que justificam a exclusão: a primeira
   regra que, SOZINHA (com as casas já conhecidas), torna o valor
   impossível, como [row(2)]; senão, o primeiro PAR de regras que basta,
   como [lakes, col(3)]; senão, a lista vazia, que quer dizer "só todas as
   regras juntas". As regras candidatas são sun, lakes, row(L) e col(C),
   em que L e C são a linha e a coluna da casa.
*/

%!  hint(+Puzzle, +Placed, -Hint) is det.
hint(Puzzle, Placed, Hint) :-
    solve(Puzzle, Solution),
    partition(agrees_with(Solution), Placed, Correct, Wrong),
    (   Wrong = [cell(L, C, Height) | _]
    ->  why_not(Puzzle, Correct, L-C, Height, Reason),
        Hint = wrong(L, C, Height, Reason)
    ;   undecided(Puzzle, Placed, Open),
        (   Open == []
        ->  Hint = complete
        ;   easiest_cell(Puzzle, Correct, Open, L-C, How),
            cell_at(Solution, L, C, Height),
            exclusions(Puzzle, Correct, L-C, Height, Excluded),
            Hint = cell(L, C, Height, How, Excluded)
        )
    ).

agrees_with(Solution, cell(L, C, Height)) :-
    cell_at(Solution, L, C, Height).

%   undecided(+Puzzle, +Placed, -Open): casas que não são lagos, nem foram
%   reveladas pelo puzzle, nem decididas pelo jogador.
undecided(puzzle(N, _, _, _, Lakes, Givens), Placed, Open) :-
    Last is N - 1,
    findall(L-C,
            ( between(0, Last, L),
              between(0, Last, C),
              \+ memberchk(L-C, Lakes),
              \+ memberchk(cell(L, C, _), Givens),
              \+ memberchk(cell(L, C, _), Placed) ),
            Open).

%!  easiest_cell(+Puzzle, +Known, +Open, -Position, -How) is det.
%
%   Impõe todas as regras SEM buscar (sem labeling) e olha o domínio que a
%   propagação deixou em cada casa aberta. A casa com o menor domínio é a
%   mais fácil de deduzir; se o domínio tem um só valor, a dedução é
%   direta. Empates são desfeitos ao acaso.
easiest_cell(Puzzle, Known, Open, Position, How) :-
    all_rules(Rules),
    board_model(Puzzle, Known, Rules, Towers, _Shade),
    random_permutation(Open, Shuffled),
    map_list_to_pairs(domain_size(Towers), Shuffled, Pairs),
    keysort(Pairs, [Size-Position | _]),
    (   Size =:= 1
    ->  How = propagation
    ;   How = search
    ).

domain_size(Towers, L-C, Size) :-
    cell_at(Towers, L, C, Var),
    fd_size(Var, Size).

%   exclusions(+Puzzle, +Known, +Position, +Height, -Excluded)
exclusions(Puzzle, Known, Position, Height, Excluded) :-
    findall(Other-Reason,
            ( between(0, 3, Other),
              Other =\= Height,
              why_not(Puzzle, Known, Position, Other, Reason) ),
            Excluded).

%!  why_not(+Puzzle, +Known, +Position, +Height, -Reason) is det.
%
%   Quais regras impedem a altura Height na posição dada? Procuramos o
%   menor conjunto de regras (uma, depois duas) com o qual o tabuleiro não
%   tem NENHUM preenchimento que respeite as casas conhecidas e a casa
%   testada. Quem faz a busca é o próprio Prolog: rule_subset/3 gera os
%   candidatos por backtracking, e o primeiro que serve é o motivo.
why_not(Puzzle, Known, L-C, Height, Reason) :-
    Candidates = [sun, lakes, row(L), col(C)],
    (   between(1, 2, Size),
        rule_subset(Size, Candidates, Rules),
        \+ satisfiable(Puzzle, [cell(L, C, Height) | Known], Rules)
    ->  Reason = Rules
    ;   Reason = []
    ).

%   rule_subset(+Size, +List, -Subset): os subconjuntos de List com Size
%   elementos, na ordem da lista, um por solução.
rule_subset(0, _, []) :- !.
rule_subset(Size, [X | Xs], [X | Subset]) :-
    Rest is Size - 1,
    rule_subset(Rest, Xs, Subset).
rule_subset(Size, [_ | Xs], Subset) :-
    Size > 0,
    rule_subset(Size, Xs, Subset).

satisfiable(Puzzle, Known, Rules) :-
    board_model(Puzzle, Known, Rules, Towers, _Shade),
    append(Towers, Heights),
    once(labeling([ff], Heights)).


/* =========================================================================
   6. FRONTEIRA COM O PYTHON
   =========================================================================

   O janus converte dicts do Python em dicts do SWI-Prolog e vice-versa,
   mas não converte termos compostos como cell(1, 2, 3). Estes predicados
   traduzem entre os dicts da API e os termos usados acima, e são os
   únicos que o Python chama.
*/

%!  api_generate(+DifficultyName, -Dict) is det.
api_generate(Name, Dict) :-
    atom_string(Difficulty, Name),
    generate(Difficulty, Puzzle),
    puzzle_dict(Puzzle, Dict).

%!  api_solve(+Dict, -Towers) is semidet.
api_solve(Dict, Towers) :-
    puzzle_dict(Puzzle, Dict),
    solve(Puzzle, Towers).

%!  api_hint(+Dict, +Placed, -HintDict) is det.
%
%   Placed chega como lista de [Linha, Coluna, Altura]. Se o puzzle não
%   tem solução (só acontece com um puzzle adulterado), HintDict é
%   _{kind: unsolvable}.
api_hint(Dict, PlacedLists, HintDict) :-
    puzzle_dict(Puzzle, Dict),
    maplist([[L, C, H], cell(L, C, H)] >> true, PlacedLists, Placed),
    (   hint(Puzzle, Placed, Hint)
    ->  hint_dict(Hint, HintDict)
    ;   HintDict = _{kind: unsolvable}
    ).

%   puzzle_dict(?Puzzle, ?Dict): nos dois sentidos. Na ida (Prolog ->
%   Python) os sóis são átomos; na volta podem chegar como átomos ou
%   strings, e atom_string/2 aceita os dois.
puzzle_dict(puzzle(N, Suns, Rows, Cols, Lakes, Givens),
            _{size: N, suns: SunNames, rows: Rows, cols: Cols,
              lakes: LakeLists, givens: GivenLists}) :-
    maplist(sun_name, Suns, SunNames),
    maplist([L-C, [L, C]] >> true, Lakes, LakeLists),
    maplist([cell(L, C, H), [L, C, H]] >> true, Givens, GivenLists).

sun_name(Sun, Name) :-
    (   var(Sun)
    ->  atom_string(Sun, Name),
        must_be(oneof([west, east]), Sun)
    ;   Name = Sun
    ).

hint_dict(complete, _{kind: complete}).
hint_dict(wrong(L, C, H, Reason),
          _{kind: wrong, row: L, col: C, value: H, rules: RuleDicts}) :-
    maplist(rule_dict, Reason, RuleDicts).
hint_dict(cell(L, C, H, How, Excluded),
          _{kind: cell, row: L, col: C, value: H, method: How,
            excluded: ExcludedDicts}) :-
    maplist(excluded_dict, Excluded, ExcludedDicts).

excluded_dict(Value-Reason, _{value: Value, rules: RuleDicts}) :-
    maplist(rule_dict, Reason, RuleDicts).

rule_dict(row(L), _{rule: row, index: L}) :- !.
rule_dict(col(C), _{rule: col, index: C}) :- !.
rule_dict(Rule, _{rule: Rule}).


/* =========================================================================
   7. UTILITÁRIOS PARA O TERMINAL
   ========================================================================= */

%   Um puzzle 5 x 5 de solução única, usado nos testes.
%   Solução: [[2,0,0,3,0], [2,0,0,0,0], [0,0,0,0,1], [0,0,0,0,2], [3,0,0,0,0]].
example_puzzle(puzzle(5,
                      [west, west, east, east, west],
                      [3, 2, 1, 2, 3],
                      [7, 0, 0, 3, 3],
                      [0-1, 3-2, 3-3, 4-3],
                      [cell(3, 0, 0), cell(4, 0, 3), cell(3, 4, 2),
                       cell(2, 4, 1), cell(1, 3, 0)])).

%!  print_puzzle(+Puzzle) is det.
%
%   Desenha o puzzle: `~` é lago, `.` é casa desconhecida, dígitos são
%   casas reveladas. O sol aparece no lado de onde vem; a pista da linha
%   fica no outro lado.
print_puzzle(Puzzle) :-
    Puzzle = puzzle(N, _, _, _, Lakes, Givens),
    square(N, Grid),
    fill_grid(Grid, Lakes, Givens),
    print_grid(Puzzle, Grid).

%!  print_solution(+Puzzle, +Towers) is det.
%
%   Desenha uma solução: alturas das torres, `~` nos lagos, `#` nas
%   casas de terra na sombra e `.` nas casas de terra ao sol.
print_solution(Puzzle, Towers) :-
    Puzzle = puzzle(_, Suns, _, _, Lakes, _),
    maplist(row_shadows, Suns, Towers, Shade),
    maplist(maplist(solution_symbol), Towers, Shade, Symbols0),
    foldl(mark_lake, Lakes, Symbols0, Symbols),
    print_grid(Puzzle, Symbols).

mark_lake(Position, Grid0, Grid) :-
    replace_cell(Position, '~', Grid0, Grid).

solution_symbol(0, 1, '#') :- !.
solution_symbol(0, 0, '.') :- !.
solution_symbol(H, _, H).

%   Aqui usamos maplist, e não forall/2: forall desfaz as ligações de
%   variáveis feitas dentro dele, e queremos justamente ligar as casas.
fill_grid(Grid, Lakes, Givens) :-
    maplist(put_lake(Grid), Lakes),
    maplist(put_given(Grid), Givens),
    maplist(maplist(unknown_dot), Grid).

put_lake(Grid, L-C) :- cell_at(Grid, L, C, '~').
put_given(Grid, cell(L, C, H)) :- cell_at(Grid, L, C, H).
unknown_dot(X) :- ( var(X) -> X = '.' ; true ).

replace_cell(L-C, Symbol, Grid0, Grid) :-
    nth0(L, Grid0, Row0, OtherRows),
    nth0(C, Row0, _, OtherCells),
    nth0(C, Row, Symbol, OtherCells),
    nth0(L, Grid, Row, OtherRows).

print_grid(puzzle(_, Suns, RowClues, ColClues, _, _), Grid) :-
    format("    "), forall(member(K, ColClues), format(" ~w", [K])), nl,
    forall(nth0(L, Grid, Row),
           ( nth0(L, Suns, Sun),
             nth0(L, RowClues, Clue),
             print_row(Sun, Clue, Row) )).

print_row(west, Clue, Row) :-
    format(" * |"), forall(member(X, Row), format(" ~w", [X])), format(" | ~w~n", [Clue]).
print_row(east, Clue, Row) :-
    format(" ~w |", [Clue]), forall(member(X, Row), format(" ~w", [X])), format(" | *~n").
