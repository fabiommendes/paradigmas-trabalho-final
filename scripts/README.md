# Ferramentas de correção

Esta pasta é de uso do professor. Alunos podem ler por curiosidade ou para
estudar (os scripts são Python comum, com `argparse`, `dataclasses`,
`markdown-it-py` e `rich`), mas não há nada aqui de que o grupo precise,
com uma exceção: `validar_entrega.py`, que confere a forma do relatório e da
avaliação 360 e é chamado por `make validar`. O uso dele está no README da
raiz e nos comentários dos templates.

Todos os scripts rodam com `uv run`, que instala as dependências declaradas
no cabeçalho de cada arquivo. Nenhum precisa de instalação.

## Fluxo de correção

```sh
uv run scripts/baixar.py --listar                        # descobre os ids das atividades
uv run scripts/baixar.py --grupos ID --alunos ID         # clona tudo em entregas/ e gera lotes.csv
uv run scripts/auditar.py entregas/                      # triagem estática, sem executar nada
uv run scripts/rubrica.py entregas/grupos/.../repo       # um grupo por vez (roda metricas.py)
uv run scripts/agregar_360.py entregas/grupos entregas/alunos \
    --notas-grupo avaliacoes/notas-grupo.csv --descontos avaliacoes/descontos-individuais.csv
```

1. **Baixar.** `baixar.py` usa a extensão classroom do `gh`, faz checkout
   do commit ou tag declarado em cada relatório e classifica cada
   repositório por lote de entrega.
2. **Auditar antes de executar qualquer coisa.** `metricas.py` e
   `rubrica.py` rodam código dos alunos: `npm install` executa scripts de
   instalação, `uv sync` e `pytest` importam o backend, e o `swipl` carrega
   os `.pl`, que podem ter diretivas `:- initialization(...)`. Só o
   `elm make` é inofensivo. `auditar.py` só lê os arquivos e aponta o que
   merece leitura; para os achados de gravidade alta, leia o código antes
   de seguir, ou rode as métricas num contêiner ou VM descartável.
3. **Métricas e rubrica**, um grupo por vez, de preferência durante a
   apresentação.
4. **Agregação das avaliações 360** com as notas de grupo e os descontos,
   uma vez, no fim.

## Os scripts

### `baixar.py`

Clona (ou atualiza, com `--atualizar`) as duas atividades do GitHub
Classroom em `entregas/grupos` e `entregas/alunos`. Precisa do `gh`
autenticado e de `gh extension install github/gh-classroom`. Para cada
repositório de grupo, lê "Commit ou tag entregue" no `RELATORIO.md` e faz
checkout dessa revisão quando ela existe (é a versão que vale). Grava
`entregas/lotes.csv` com a data do último commit e o lote de cada
repositório, de grupo ou individual.

```sh
uv run scripts/baixar.py --listar
uv run scripts/baixar.py --grupos 12345 --alunos 12346 -d entregas
uv run scripts/baixar.py -d entregas --so-lotes          # só recalcula lotes.csv
```

Os prazos ficam em `metricas.py` (`DEADLINES`), que a rubrica também usa
para sugerir o lote.

### `auditar.py`

Triagem estática de código suspeito. Ignora arquivos idênticos aos do
template e procura, no resto: comandos do sistema, rede, acesso a caminhos
fora do projeto, `eval`, scripts `postinstall` no `package.json`,
dependências além do template, receitas perigosas no Makefile, binários,
caracteres invisíveis ou de direção, texto codificado. Achados com
gravidade alta, média ou baixa, com arquivo, linha e trecho; arquivos de
infraestrutura alterados (Makefile, `vite.config.js`, `package.json`,
`index.html`, `main.js`, `pyproject.toml`) ganham um lembrete de ler o
diff. Sai com código 1 se houver achado alto. É triagem, não veredito.

```sh
uv run scripts/auditar.py entregas/
uv run scripts/auditar.py entregas/ --json > auditoria.json
```

### `validar_entrega.py`

Valida a forma de `RELATORIO.md` e de `avaliacao-360/<matricula>.md`. É o
único script que os alunos usam. Os outros importam dele a leitura de
markdown.

```sh
uv run scripts/validar_entrega.py                                   # relatório + avaliações da pasta
uv run scripts/validar_entrega.py avaliacao-360/202312345.md        # um arquivo
```

### `metricas.py`

Métricas objetivas de um repositório de grupo (AVALIACAO.md, seção 1.2):
linhas por linguagem e proporção de Python, avisos do `swipl`, testes
plunit, elm-test e pytest, `elm make`, `elm-format`, validador e commits
por autor. Só biblioteca padrão.

```sh
uv run scripts/metricas.py repo-do-grupo             # tabela legível
uv run scripts/metricas.py repo-do-grupo --json      # para outros scripts
uv run scripts/metricas.py repo-do-grupo --instalar  # npm install e uv sync antes
```

O repositório precisa ter `node_modules` e `.venv` para os testes e a
compilação rodarem. Sem isso, essas métricas aparecem como "não
disponível" e a sugestão de nível da rubrica fica vazia. Use `--instalar`
na primeira vez em cada repositório. O validador executado é o desta pasta,
não a cópia que estiver no repositório do grupo.

### `rubrica.py`

Preenche a rubrica da nota do grupo, interativamente, com `rich`. Lê o
projeto, o grupo e os integrantes do `RELATORIO.md`, roda as métricas,
sugere um nível inicial para "Funciona" e "Qualidade do código", percorre
os seis critérios pedindo nível (0 a 4) e observação, e depois pergunta:

- a faixa de ponto de partida e a de uso de IA (AVALIACAO.md, seção 1.5),
  com o que o relatório declara como padrão; o Δ resultante aparece no
  resumo, e o bônus é suspenso se os critérios 1 ou 2 ficaram abaixo de 3;
- o lote de entrega (seção 3), que multiplica G por 0,90 ou 0,75;
- o desconto da verificação de compreensão de cada integrante (seção 2.1),
  de 0 a 1,0, com motivo;
- as penalidades (a do validador é proposta automaticamente).

No resumo, `e` reabre escopo, IA e lote; um número reabre o critério.

```sh
uv run scripts/rubrica.py repo-do-grupo                    # com métricas
uv run scripts/rubrica.py repo-do-grupo --sem-metricas     # só a rubrica
uv run scripts/rubrica.py repo-do-grupo --saida avaliacoes/
```

Grava `avaliacoes/<repositorio>.json` (níveis, observações, ajustes,
descontos, métricas, G) e regenera, a partir de todos os JSON da pasta,
`avaliacoes/notas-grupo.csv` (uma linha por grupo, com faixa, IA, lote e G)
e `avaliacoes/descontos-individuais.csv` (uma linha por desconto de
compreensão). Rodar de novo para o mesmo repositório carrega a avaliação
anterior como ponto de partida. Os textos dos níveis e das faixas espelham
`AVALIACAO.md`: mudou um, mude o outro.

### `agregar_360.py`

Cruza as avaliações 360 dos repositórios individuais com as tabelas de
integrantes dos relatórios e gera duas planilhas: uma linha por aluno
(médias recebidas, esforço mediano recebido, esforço próprio, se entregou)
e uma linha por par avaliador/avaliado. Com `--notas-grupo`, calcula a nota
individual e a final pela regra de `AVALIACAO.md`, seção 2; com
`--descontos`, subtrai da final os descontos de compreensão da rubrica.

```sh
uv run scripts/agregar_360.py grupos/ alunos/ -o notas-360 \
    --notas-grupo avaliacoes/notas-grupo.csv \
    --descontos avaliacoes/descontos-individuais.csv
```

Os nomes dos colegas são casados com a tabela de integrantes por nome
completo ou, quando só um integrante combina, por prefixo ("Ana" casa com
"Ana Souza"). O que não casar vira aviso em stderr, junto com as avaliações
que faltam, matrículas desconhecidas e diferenças grandes entre o esforço
autoatribuído e o recebido. Os CSV usam ponto e vírgula e vírgula decimal.

## Regras espelhadas em código

Os números de `AVALIACAO.md` aparecem como constantes no topo de
`rubrica.py` (pesos e níveis, penalidade do validador, faixas de escopo e
IA, fatores dos lotes, teto do desconto de compreensão) e de
`agregar_360.py` (25/75, limites 0,6 e 1,2 do fator, mínimo de 2
avaliações, desconto de 0,5 por 360 não entregue). As opções válidas dos
campos "Ponto de partida" e "Faixa de uso no código" estão também em
`validar_entrega.py`, que as confere.
