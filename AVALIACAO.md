# Critérios de avaliação do trabalho final

Este documento diz como a nota do trabalho é calculada. Leia antes de
começar: ele explica o que vale mais e o que não vale nada.

A nota de cada aluno tem duas partes:

```
Nota final = 0,25 × G + 0,75 × I
```

- **G** é a nota do grupo: avalia o sistema entregue, o relatório e a
  apresentação, com a rubrica da seção 1.
- **I** é a nota individual: parte de G e é ajustada pela avaliação 360
  graus dos colegas, como explica a seção 2.

Quem fez a sua parte recebe I = G, e a nota final é G. A avaliação 360 só
muda a nota de quem carregou o grupo ou de quem deixou os colegas na mão.

## 1. Nota do grupo (G)

Seis critérios, cada um pontuado de 0 a 4. A nota é a média ponderada,
convertida para 0 a 10:

```
G = 10 × Σ (peso × nível / 4)
```

| # | Critério | Peso | Onde o avaliador olha |
|---|----------|-----:|-----------------------|
| 1 | Funciona e é reprodutível | 15% | Seção 3 do relatório numa máquina limpa; demonstração; casos de borda da seção 8 |
| 2 | Prolog: uso do paradigma lógico | 20% | Seções 5.1 a 5.3; os arquivos `.pl`; testes plunit |
| 3 | Elm: uso do paradigma funcional | 30% | Seções 6.1 a 6.3; os arquivos `.elm` |
| 4 | Qualidade do código | 10% | O código; as métricas da seção 1.2 |
| 5 | Relatório | 10% | Seções 2, 4, 8, 9, 11 e 13 |
| 6 | Apresentação oral | 15% | Os 15 minutos; seção 12 |

O Elm pesa mais que o Prolog porque ocupa a maior parte do curso e,
normalmente, a maior parte do código.

### 1.1 Níveis de cada critério

Nível 0 é "ausente" em todos os critérios. Os demais:

**1. Funciona e é reprodutível**

1. Só roda com ajuda do grupo, ou não roda.
2. Roda seguindo a seção 3, mas falha em uso normal.
3. Roda e faz o que o relatório promete.
4. Roda, trata os casos de borda declarados na seção 8 e tem testes que provam isso.

**2. Prolog: uso do paradigma lógico**

O eixo é a declaratividade e a adequação do problema: o Prolog precisa estar
resolvendo algo que pede busca, restrições ou base de conhecimento, e o
código deve descrever o quê, não o como.

1. Prolog decorativo: o que ele faz caberia num `if` em Python.
2. Funciona, mas é um algoritmo imperativo traduzido cláusula a cláusula.
3. Usa unificação, backtracking, CLP(FD) ou similar de forma idiomática, e a seção 5.3 explica corretamente por que a solução é lógica.
4. Além disso, modela algo não trivial (múltiplas soluções, explicação de resultados, geração) e tem testes plunit.

**3. Elm: uso do paradigma funcional**

O eixo é a modelagem por tipos e o controle de efeitos.

1. Elm usado como HTML com estado solto: `Bool` para tudo, `Maybe.withDefault` em todo canto.
2. Arquitetura Elm correta, mas tipos pobres, que permitem estados inválidos.
3. Custom types que tornam estados inválidos irrepresentáveis, `Maybe` e `Result` bem usados, decoders próprios, e a seção 6.1 justifica as escolhas.
4. Além disso, módulos com fronteiras claras (domínio puro separado de HTTP e de view) e evidência de que o compilador guiou refatorações (a seção 13 costuma revelar isso).

**4. Qualidade do código**

1. Difícil de ler: nomes ruins, funções enormes, código morto, avisos do compilador ignorados.
2. Legível com esforço; formatação irregular; comentários que só repetem o código.
3. Nomes claros, funções curtas, `elm-format` aplicado, `swipl` carrega sem avisos, comentários que explicam decisões.
4. Além disso, organização em módulos coerente e o Python permanece só integração.

**5. Relatório**

1. Seções incompletas ou preenchidas com texto genérico.
2. Completo, mas descreve o código em vez de apontar para ele.
3. Resumo compreensível por quem não viu o projeto; referências a `arquivo:linha`; limitações honestas na seção 9; seção 11 completa.
4. Além disso, a reflexão da seção 13 traz observações próprias sobre os dois paradigmas, com exemplos do próprio código.

**6. Apresentação oral**

1. Só slides, sem sistema funcionando.
2. A demonstração falha ou o grupo estoura o tempo.
3. Demonstração funciona, código Prolog e Elm mostrados, tempo respeitado, todos falam.
4. Além disso, o grupo responde bem a perguntas sobre o próprio código.

### 1.2 Métricas

O avaliador roda um script em cada repositório que mede:

- se os testes passam (`make test` ou o comando da seção 3) e quantos são;
- se o `swipl` carrega os arquivos `.pl` sem avisos e o `elm make` compila;
- se o `elm-format` está aplicado;
- a proporção de linhas em Prolog, Elm e Python;
- se o validador (`scripts/validar_entrega.py`) passa sem erros;
- a distribuição dos commits por autor.

As métricas alimentam os critérios 1 e 4 e servem de alerta. Nenhuma delas
vira nota sozinha: todas são fáceis de inflar, e inflar não ajuda. Python
acima de uns 30% do código é sinal de que a lógica vazou para onde não é
avaliada. A distribuição de commits não entra em G, mas é confrontada com a
seção 10 e com a avaliação 360.

### 1.3 Faltas que invalidam o trabalho

O grupo recebe zero, e o caso é encaminhado conforme as normas da
universidade, se o trabalho contiver:

- **Plágio de outros projetos**: código copiado de outros grupos, de
  semestres anteriores ou de repositórios públicos sem a declaração na
  seção 11. Reaproveitar código declarado é permitido; esconder a origem,
  não.
- **Uso de IA não declarado**: qualquer trecho gerado por ferramenta de IA
  que não esteja na tabela da seção 11. Declarar não tira pontos.
- **Código malicioso**: qualquer coisa que tente ler, alterar ou enviar
  dados fora do próprio projeto, ou interferir na máquina de quem roda o
  sistema. Os repositórios são inspecionados antes de serem executados.

### 1.4 Penalidades

- Validador com erros na versão entregue: 0,5 ponto a menos em G.
- Escopo modesto não é penalizado. Escopo ambicioso e quebrado cai no
  critério 1. Prefira um problema pequeno que funciona a um grande que não.

### 1.5 Escopo, originalidade e uso de IA

A rubrica mede a qualidade do que foi feito. Este ajuste mede quanto foi
feito, considerando de onde o grupo partiu. Ele é somado a G depois da
rubrica e das penalidades, e G continua limitado a 10:

```
G = min(10, rubrica − penalidades + Δ)
```

| Ponto de partida do projeto (seção 1 do relatório) | Δ |
|----------------------------------------------------|---:|
| Template do Sudoku com ajustes (visual, níveis, dicas, cronômetro) | −1,0 |
| Variante do Sudoku (novas restrições, Killer, diagonal, 16x16) | −0,5 |
| Outro jogo ou quebra-cabeça conhecido, implementado pelo grupo | 0 |
| Remix original: mecânicas conhecidas combinadas com uma regra própria | +0,5 |
| Jogo inventado pelo grupo, com regras próprias e jogável | +1,0 |

Como o ajuste é aplicado:

- **Bônus só para o que funciona.** Δ positivo exige nível 3 ou mais nos
  critérios 1 (funciona) e 2 (o Prolog faz trabalho de verdade). Se o jogo
  inventado não roda, o bônus vira zero, nunca negativo: arriscar não custa
  mais do que fazer o seguro, e acertar rende.
- **O grupo declara a faixa** no campo "Ponto de partida" e o professor a
  confirma na apresentação. Se a declaração não bate com o código, vale a
  leitura do professor.
- **Jogo conhecido implementado do zero conta como zero**, não como bônus:
  a estrutura do template (servidor, integração, arquitetura Elm) continua
  herdada. O que se premia é inventar regras, que é onde o Prolog fica
  interessante.

**Uso de IA.** A seção 11 do relatório pede a faixa de uso de ferramentas de
IA no código:

| Faixa | O que significa | Efeito |
|-------|-----------------|--------|
| nenhum | o grupo não usou IA | nenhum |
| pontual | autocompletar, tirar dúvidas, explicar erros | nenhum |
| auxiliar | trechos gerados pela IA e revisados pelo grupo | nenhum |
| intensivo | a IA escreveu a maior parte do código | Δ cai 0,5 |

Com IA intensiva, a tabela de escopo desloca uma linha: uma variante do
Sudoku conta como −1,0 e um jogo inventado como +0,5. A razão é simples:
com a IA escrevendo, o mesmo escopo custa menos, então se espera mais. O
custo de declarar é pequeno de propósito. A alternativa, não declarar, anula
o trabalho (seção 1.3). A faixa "nenhum" existe só para o professor mapear
as turmas; ela não vale nada a mais.

O uso de IA não é verificável, e por isso não rende bônus para quem diz que
não usou. O que se verifica é a compreensão, na seção 2.1.

## 2. Nota individual (I)

A avaliação 360 graus pede que cada integrante distribua 100% de esforço
entre todos do grupo. A nota individual usa essa distribuição:

```
parte_justa = 100 / n                         n = tamanho do grupo
esforço     = mediana do % que os COLEGAS lhe atribuíram
F           = esforço / parte_justa, limitado ao intervalo [0,6, 1,2]
I           = min(10, G × F)
```

O que você atribuiu a si mesmo não entra na conta. Exemplo com G = 8 num
grupo de 4 (parte justa 25%):

| % recebido dos colegas | F    | I   | Nota final |
|-----------------------:|-----:|----:|-----------:|
| 15                     | 0,60 | 4,8 | 5,6        |
| 20                     | 0,80 | 6,4 | 6,8        |
| 25                     | 1,00 | 8,0 | 8,0        |
| 30                     | 1,20 | 9,6 | 9,2        |
| 35 ou mais             | 1,20 | 9,6 | 9,2        |

Salvaguardas:

- A mediana faz com que uma única avaliação, vingativa ou combinada, não
  mude o resultado.
- Quem recebeu menos de duas avaliações fica com F = 1 (não há dado).
- Quem não entregou a própria avaliação 360 perde 0,5 ponto na nota final:
  ela é um item da entrega.
- As notas de 1 a 5 por critério e os comentários não entram na fórmula.
  Eles servem para o professor entender o que aconteceu no grupo, e são
  lidos com atenção quando alguém recebe 1, 2 ou 5.

Em uma frase: sua nota é a do grupo, ajustada pela fatia de esforço que os
colegas reconheceram, entre 60% e 120%.

### 2.1 Verificação de compreensão

Na apresentação, o professor escolhe um trecho de Prolog ou de Elm e pede a
um integrante que explique o que ele faz e por que está daquele jeito. Quem
não consegue explicar código que a seção 10 do relatório atribui a si perde
até 1,0 ponto na própria nota final. A nota do grupo não muda.

É este o mecanismo que distingue quem usou IA para aprender de quem usou
para não aprender, e ele não depende de declaração nenhuma. Prepare-se
entendendo cada linha que você entregou, tenha ela sido escrita por você,
por um colega ou por uma ferramenta.

## 3. Prazos

A entrega é aceita em três lotes. Vale o horário do último commit no
repositório do GitHub Classroom (o commit ou tag indicado na seção 1 do
relatório), no fuso de Brasília:

| Lote | Até | Efeito na nota |
|------|-----|----------------|
| 1 | 18/11/2026, 23h59 | nenhum |
| 2 | 23/11/2026, 23h59 | G multiplicado por 0,90 |
| 3 | 30/11/2026, 23h59 | G multiplicado por 0,75 |

Depois de 30/11 o trabalho não é aceito. O desconto se aplica a G depois de
todos os ajustes da seção 1, e portanto chega à nota individual pela
fórmula da seção 2.

A avaliação 360, no repositório individual, não tem desconto por lote: ela
é aceita até 30/11/2026, 23h59, junto com o último lote. Quem não a entrega
até essa data perde os 0,5 ponto da seção 2, e só isso. A apresentação oral
acontece no fim do semestre, em data marcada pelo professor.
