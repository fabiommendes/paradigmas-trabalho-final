#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py>=3"]
# ///
"""Valida a FORMA dos arquivos de entrega (não o conteúdo).

Verifica o relatório (RELATORIO.md) e as avaliações 360 graus
(avaliacao-360/<matricula>.md): comentários de instrução apagados, campos
entre colchetes preenchidos, tabelas bem formadas, seções e subseções
presentes, arquivos referenciados existentes, somas e formatos de campos.

Uso, normalmente a partir da raiz do repositório:

    uv run scripts/validar_entrega.py             # relatório + avaliações
    uv run scripts/validar_entrega.py RELATORIO.md
    uv run scripts/validar_entrega.py avaliacao-360/202312345.md

No repositório do grupo interessa o RELATORIO.md; no repositório individual
de cada aluno, a sua avaliação 360 (passe o arquivo como argumento, pois o
RELATORIO.md que estiver lá pode ser só o template).

Em Linux/macOS também funciona `./scripts/validar_entrega.py`. O script
descobre a raiz do repositório pela sua própria posição (a pasta acima de
scripts/), então os caminhos padrão funcionam de qualquer pasta.

O validador sempre lista TODOS os problemas encontrados, em todos os
arquivos. Cada verificação roda de forma independente: se uma delas falhar
(por exemplo, num documento muito malformado), a falha vira mais um ERRO da
lista e as demais verificações continuam.

Sai com código 1 se houver algum ERRO. AVISOS não impedem a entrega, mas
merecem uma conferida.
"""

import argparse
import re
import subprocess
import sys
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import TypeVar

from markdown_it import MarkdownIt
from markdown_it.token import Token

REPO_ROOT = Path(__file__).resolve().parent.parent
REPORT_NAME = "RELATORIO.md"
PEER_DIR = "avaliacao-360"
PEER_TEMPLATE = "TEMPLATE.md"
MIN_GROUP, MAX_GROUP = 3, 7
PRESENTATION_MINUTES = 15
# A divisão do esforço é aceita se a soma ficar entre 100 - X e 100 + X.
# Absorve arredondamentos como 33,3 + 33,3 + 33,3 = 99,9.
EFFORT_TOLERANCE = Decimal("1")
CLASSES = {"14h", "16h"}

REPORT_SECTIONS = [
    "1. Identificação",
    "2. Resumo",
    "3. Como executar",
    "4. Arquitetura",
    "5. Parte em Prolog",
    "6. Parte em Elm",
    "7. Integração",
    "8. Testes e validação",
    "9. Limitações e problemas conhecidos",
    "10. Contribuição de cada integrante",
    "11. Fontes, código de terceiros e uso de IA",
    "12. Apresentação oral",
    "13. Reflexão sobre os paradigmas",
]

# Subseções (h3) obrigatórias dentro das seções 5 e 6, na ordem.
REPORT_SUBSECTIONS = {
    "5. Parte em Prolog": [
        "5.1 Predicados principais",
        "5.2 Conceitos do paradigma lógico utilizados",
        "5.3 Trecho em destaque",
    ],
    "6. Parte em Elm": [
        "6.1 Modelo e mensagens",
        "6.2 Conceitos do paradigma funcional utilizados",
        "6.3 Trecho em destaque",
    ],
}

PEER_SECTIONS = [
    "Quem está avaliando",
    "1. Escala",
    "2. Notas",
    "3. Divisão do esforço",
    "4. Comentários sobre cada colega",
    "5. Autoavaliação",
    "6. Sobre o grupo (opcional)",
]
PEER_OPTIONAL_SECTIONS = {"6. Sobre o grupo (opcional)"}

# Um "[campo]" do template. Não casa com checkboxes de lista: [ ] e [x].
PLACEHOLDER = re.compile(r"\[(?![ xX]\])[^\[\]\n]*\]")
FIELD_LINE = re.compile(r"^\s*[-*]\s*\*\*(?P<key>[^*]+?):?\*\*:?\s*(?P<value>.*)$")
# Sufixo que marca a linha da própria pessoa na tabela de notas da 360.
SELF_MARK = re.compile(r"\s*\(autoavalia[cç][aã]o\)\s*$", re.I)
# Formas aceitas para "não tem" nos campos de slides.
NONE_VALUES = {"nao ha", "nao ha slides", "nenhum", "nenhuma", "nao"}
# Faixas de AVALIACAO.md, seção 1.5. Comparadas com `normalize`.
SCOPE_OPTIONS = ["template do Sudoku com ajustes", "variante do Sudoku", "outro jogo conhecido", "remix original", "jogo inventado"]
AI_OPTIONS = ["nenhum", "pontual", "auxiliar", "intensivo"]


# ---------------------------------------------------------------------------
# Estruturas
# ---------------------------------------------------------------------------


@dataclass
class Issue:
    line: int | None  # 1-based; None = o arquivo todo
    message: str
    error: bool = True


@dataclass
class Table:
    line: int  # linha do cabeçalho (1-based)
    header: list[str]
    rows: list[list[str]]
    row_lines: list[int]


@dataclass
class Section:
    title: str
    line: int
    end: int  # linha seguinte ao fim da seção (1-based, exclusiva)
    tables: list[Table] = field(default_factory=list)


@dataclass
class Document:
    path: Path
    lines: list[str]
    tokens: list[Token]
    code_lines: set[int]  # linhas (1-based) dentro de blocos de código
    sections: list[Section]
    issues: list[Issue] = field(default_factory=list)
    registrations: list[str] = field(default_factory=list)  # só no relatório
    readable: bool = True

    def error(self, line: int | None, message: str) -> None:
        self.issues.append(Issue(line, message, error=True))

    def warn(self, line: int | None, message: str) -> None:
        self.issues.append(Issue(line, message, error=False))

    def section(self, title: str) -> Section | None:
        wanted = normalize(title)
        return next((s for s in self.sections if normalize(s.title) == wanted), None)

    def fields(self, section: Section) -> dict[str, tuple[int, str]]:
        """Linhas no formato `- **Chave:** valor` dentro da seção."""
        found = {}
        for number in range(section.line + 1, section.end):
            match = FIELD_LINE.match(self.lines[number - 1])
            if match and number not in self.code_lines:
                found[normalize(match["key"])] = (number, match["value"].strip())
        return found


# ---------------------------------------------------------------------------
# Leitura do markdown
# ---------------------------------------------------------------------------


def normalize(text: str) -> str:
    """Compara textos ignorando acentos, maiúsculas e espaços extras."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    return " ".join(text.casefold().split())


def load(path: Path) -> Document:
    """Lê e interpreta o arquivo. Se não der para ler, devolve um documento
    vazio com o erro registrado, e as verificações simplesmente não acham
    nada para conferir."""
    try:
        return parse(path, path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        problem = "arquivo não encontrado"
    except UnicodeDecodeError:
        problem = "o arquivo não está em UTF-8 (salve-o com a codificação UTF-8)"
    except OSError as exc:
        problem = f"não foi possível ler o arquivo: {exc.strerror}"
    doc = Document(path, [], [], set(), [])
    doc.error(None, problem)
    doc.readable = False
    return doc


def parse(path: Path, text: str) -> Document:
    tokens = MarkdownIt("commonmark").enable("table").parse(text)
    lines = text.splitlines()

    code_lines = set()
    for token in tokens:
        if token.type in ("fence", "code_block") and token.map:
            code_lines.update(range(token.map[0] + 1, token.map[1] + 1))

    headings = []
    for index, token in enumerate(tokens):
        if token.type == "heading_open" and token.tag == "h2":
            headings.append((tokens[index + 1].content.strip(), token.map[0] + 1))
    sections = [
        Section(title, line, headings[i + 1][1] if i + 1 < len(headings) else len(lines) + 1)
        for i, (title, line) in enumerate(headings)
    ]

    for table in extract_tables(tokens):
        for section in sections:
            if section.line <= table.line < section.end:
                section.tables.append(table)

    return Document(path, lines, tokens, code_lines, sections)


def extract_tables(tokens: list[Token]) -> list[Table]:
    tables = []
    current: Table | None = None
    row: list[str] = []
    row_line = 0
    for token in tokens:
        if token.type == "table_open":
            current = Table(token.map[0] + 1, [], [], [])
        elif token.type == "tr_open":
            row, row_line = [], token.map[0] + 1
        elif token.type == "inline" and current is not None:
            row.append(token.content.strip())
        elif token.type == "tr_close" and current is not None:
            if not current.header:
                current.header = row
            else:
                current.rows.append(row)
                current.row_lines.append(row_line)
        elif token.type == "table_close" and current is not None:
            tables.append(current)
            current = None
    return tables


def split_row(line: str) -> list[str]:
    """Divide uma linha de tabela em células, respeitando `código` e \\|."""
    cells, cell, in_code = [], "", False
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|") and not text.endswith("\\|"):
        text = text[:-1]
    index = 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text):
            cell += text[index : index + 2]
            index += 2
            continue
        if char == "`":
            in_code = not in_code
        if char == "|" and not in_code:
            cells.append(cell.strip())
            cell = ""
        else:
            cell += char
        index += 1
    cells.append(cell.strip())
    return cells


def inline_text(token: Token) -> str:
    """Texto visível de um trecho inline, trocando código por `§`.

    Assim, colchetes dentro de `código` (listas Prolog, por exemplo) não são
    confundidos com campos não preenchidos. Quebras de linha viram "\\n",
    para podermos calcular a linha de cada problema.
    """
    parts = []
    for child in token.children or []:
        if child.type == "text":
            parts.append(child.content)
        elif child.type == "code_inline":
            parts.append("§")
        elif child.type in ("softbreak", "hardbreak"):
            parts.append("\n")
    return "".join(parts)


# ---------------------------------------------------------------------------
# Verificações comuns
# ---------------------------------------------------------------------------


def check_comments(doc: Document) -> None:
    """Um erro por bloco <!-- ... -->, indicando as linhas que ele ocupa."""
    start = None
    for number, line in enumerate(doc.lines, start=1):
        if number in doc.code_lines:
            continue
        if start is None and "<!--" in line:
            start = number
        if start is not None and "-->" in line[line.find("<!--") + 4 if number == start else 0 :]:
            where = f"linha {start}" if start == number else f"linhas {start}–{number}"
            doc.error(start, f"comentário de instrução não apagado ({where})")
            start = None
        elif start is None and "-->" in line:
            doc.error(number, "fim de comentário (-->) sobrando")
    if start is not None:
        doc.error(start, "comentário <!-- aberto e nunca fechado com -->")


def check_placeholders(doc: Document) -> None:
    for token in doc.tokens:
        if token.type != "inline" or not token.map:
            continue
        text = inline_text(token)
        for match in PLACEHOLDER.finditer(text):
            line = token.map[0] + 1 + text.count("\n", 0, match.start())
            shown = match.group().replace("§", "`…`")
            doc.error(line, f"campo não preenchido: {shown}")
        rest = PLACEHOLDER.sub("", text)
        if "..." in rest:
            line = token.map[0] + 1 + rest.count("\n", 0, rest.find("..."))
            doc.warn(line, 'texto "..." do template: confira se falta completar algo')


def check_tables(doc: Document) -> None:
    table_lines = set()
    for token in doc.tokens:
        if token.type == "table_open":
            table_lines.update(range(token.map[0] + 1, token.map[1] + 1))

    # Linhas que parecem tabela (começam com "|"), agrupadas em blocos.
    blocks: list[list[int]] = []
    for number, line in enumerate(doc.lines, start=1):
        if number in doc.code_lines or not line.lstrip().startswith("|"):
            continue
        if blocks and blocks[-1][-1] == number - 1:
            blocks[-1].append(number)
        else:
            blocks.append([number])

    for block in blocks:
        first = block[0]
        if first not in table_lines:
            doc.error(
                first,
                "tabela malformada: o markdown não a reconhece como tabela "
                "(a 2ª linha deve ser o separador, ex.: |---|---|)",
            )
            continue
        widths = [len(split_row(doc.lines[n - 1])) for n in block]
        for number, width in zip(block, widths):
            if width != widths[0]:
                doc.error(
                    number,
                    f"tabela com {width} colunas nesta linha, mas {widths[0]} no cabeçalho",
                )

    for section in doc.sections:
        for table in section.tables:
            for number, row in zip(table.row_lines, table.rows):
                if any(cell == "" for cell in row):
                    doc.error(number, "tabela com célula vazia")


def check_sections(
    doc: Document, expected: list[str], optional: set[str] = frozenset()
) -> None:
    titles = [normalize(s.title) for s in doc.sections]
    position = -1
    for title in expected:
        wanted = normalize(title)
        if wanted not in titles:
            doc.error(None, f'seção obrigatória ausente: "## {title}"')
            continue
        index = titles.index(wanted)
        if index < position:
            doc.error(doc.sections[index].line, f'seção fora de ordem: "## {title}"')
        position = max(position, index)

        section = doc.sections[index]
        content = [
            line
            for line in doc.lines[section.line : section.end - 1]
            if line.strip() and not line.lstrip().startswith("#")
        ]
        if not content and title not in optional:
            doc.error(section.line, f'seção vazia: "## {title}"')

    if not any(t.type == "heading_open" and t.tag == "h1" for t in doc.tokens):
        doc.error(None, 'falta o título principal ("# ...")')


def check_links(doc: Document) -> None:
    base = doc.path.parent
    for token in doc.tokens:
        if token.type != "inline" or not token.map:
            continue
        for child in token.children or []:
            target = None
            if child.type == "link_open":
                target = child.attrGet("href")
            elif child.type == "image":
                target = child.attrGet("src")
            if target and is_local(target) and not (base / target.split("#")[0]).exists():
                doc.error(token.map[0] + 1, f"arquivo referenciado não existe: {target}")


def unfilled(value: str) -> bool:
    """O valor ainda é (ou contém) um campo do template? Nesse caso o erro
    "campo não preenchido" já foi dado, e não conferimos o formato."""
    return bool(PLACEHOLDER.search(re.sub(r"`[^`]*`", "§", value)))


def to_decimal(number: str) -> Decimal:
    """Converte "33,3" ou "33.3" em Decimal.

    Usamos Decimal, e não float, porque float não representa exatamente a
    maioria das frações decimais, e o erro depende até da ordem da soma:

        33.3 + 33.3 + 33.4                  -> 100.0
        33.3 + 33.4 + 33.3                  -> 99.99999999999999
        16.6 + 16.6 + 16.7 + 16.7 + 16.7 + 16.7 -> 100.00000000000001

    Com Decimal, "33,3" é exatamente 33,3 e a soma dá o mesmo resultado em
    qualquer ordem. A tolerância (EFFORT_TOLERANCE) serve só para aceitar os
    arredondamentos de quem preenche, e a fronteira dela também é exata:
    99,0 passa e 98,9 não, sem surpresas.
    """
    return Decimal(number.replace(",", "."))


def show(number: Decimal) -> str:
    """Formata um Decimal para mensagens: 99.90 -> "99,9"."""
    return f"{number.normalize():f}".replace(".", ",")


def is_local(target: str) -> bool:
    return not re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) and not target.startswith("#")


# ---------------------------------------------------------------------------
# Relatório
# ---------------------------------------------------------------------------


def check_report(doc: Document) -> None:
    run_check(doc, "seções", lambda: check_sections(doc, REPORT_SECTIONS))
    run_check(doc, "subseções", lambda: check_subsections(doc))
    identification = run_check(doc, "identificação", lambda: check_identification(doc))
    members, doc.registrations = identification or ([], [])
    run_check(doc, "contribuições", lambda: check_contributions(doc, members))
    run_check(doc, "apresentação", lambda: check_presentation(doc, members))
    run_check(doc, "uso de IA", lambda: check_ai_field(doc))


def check_subsections(doc: Document) -> None:
    """Confere as subseções (###) obrigatórias dentro das seções 5 e 6.

    O parser só coleta títulos h2 em `Section` (usado em vários outros
    lugares), então em vez de generalizar essa estrutura para guardar o
    nível do título, procuramos os h3 direto em `doc.lines`, dentro do
    intervalo de cada seção h2, do mesmo jeito que check_comments_per_colleague
    faz para as subseções da avaliação 360.
    """
    for parent_title, expected in REPORT_SUBSECTIONS.items():
        section = doc.section(parent_title)
        if not section:
            continue
        headings = [
            (line[4:].strip(), number)
            for number, line in enumerate(
                doc.lines[section.line : section.end - 1], start=section.line + 1
            )
            if line.startswith("### ")
        ]
        titles = [normalize(title) for title, _ in headings]
        position = -1
        for title in expected:
            wanted = normalize(title)
            if wanted not in titles:
                doc.error(section.line, f'subseção obrigatória ausente: "### {title}"')
                continue
            index = titles.index(wanted)
            if index < position:
                doc.error(headings[index][1], f'subseção fora de ordem: "### {title}"')
            position = max(position, index)

            start = headings[index][1]
            end = headings[index + 1][1] if index + 1 < len(headings) else section.end
            content = [
                line
                for line in doc.lines[start:end - 1]
                if line.strip() and not line.lstrip().startswith("#")
            ]
            if not content:
                doc.error(start, f'subseção vazia: "### {title}"')


def check_identification(doc: Document) -> tuple[list[str], list[str]]:
    section = doc.section("1. Identificação")
    if not section:
        return [], []
    if not section.tables:
        doc.error(section.line, "falta a tabela de integrantes")
        return [], []

    table = section.tables[0]
    members, registrations = [], []
    for number, row in zip(table.row_lines, table.rows):
        if len(row) < 4:
            continue
        name, registration, group_class, github = row[:4]
        if unfilled(name) or unfilled(registration):
            continue
        members.append(name)
        registrations.append(registration)
        if not registration.isdigit():
            doc.error(number, f"matrícula deve ter só dígitos: {registration!r}")
        if not unfilled(group_class) and normalize(group_class).replace(" ", "") not in CLASSES:
            doc.error(number, f"turma deve ser 14h ou 16h: {group_class!r}")
        if not unfilled(github) and not re.match(r"^(@[\w-]+|https://github\.com/[\w-]+/?)$", github):
            doc.error(number, f"usuário GitHub deve ser @usuario: {github!r}")
    if members and not MIN_GROUP <= len(members) <= MAX_GROUP:
        doc.error(
            table.line,
            f"o grupo tem {len(members)} integrantes; deve ter de {MIN_GROUP} a {MAX_GROUP}",
        )
    if len(set(registrations)) != len(registrations):
        doc.error(table.line, "há matrículas repetidas na tabela de integrantes")

    fields = doc.fields(section)
    check_field_present(doc, section, fields, "Nome do projeto")
    check_field_present(doc, section, fields, "Nome do grupo")
    check_url_field(doc, section, fields, "Repositório")
    check_revision_field(doc, section, fields)
    check_choice_field(doc, section, fields, "Ponto de partida", SCOPE_OPTIONS)
    check_slides_field(doc, section, fields)
    return members, registrations


def check_field_present(doc: Document, section: Section, fields: dict, key: str) -> None:
    """Só exige que o campo exista; o placeholder já é conferido à parte."""
    if normalize(key) not in fields:
        doc.error(section.line, f'falta o campo "**{key}:**"')


def check_choice_field(doc: Document, section: Section, fields: dict, key: str, options: list[str]) -> None:
    """O campo existe e, se preenchido, é uma das opções (sem diferenciar
    acentos, maiúsculas ou pontuação no fim)."""
    line, value = fields.get(normalize(key), (section.line, None))
    if value is None:
        doc.error(line, f'falta o campo "**{key}:**"')
    elif not unfilled(value) and normalize(value).strip(" .") not in {normalize(o) for o in options}:
        doc.error(line, f"{key}: escreva uma das opções: {', '.join(options)}")


def check_ai_field(doc: Document) -> None:
    section = doc.section("11. Fontes, código de terceiros e uso de IA")
    if section:
        check_choice_field(doc, section, doc.fields(section), "Faixa de uso no código", AI_OPTIONS)


def check_url_field(doc: Document, section: Section, fields: dict, key: str) -> None:
    line, value = fields.get(normalize(key), (section.line, None))
    if value is None:
        doc.error(line, f'falta o campo "**{key}:**"')
    elif not unfilled(value) and not re.search(r"https?://\S+", value):
        doc.error(line, f"{key}: informe um endereço começando com https://")


def check_revision_field(doc: Document, section: Section, fields: dict) -> None:
    key = normalize("Commit ou tag entregue")
    line, value = fields.get(key, (section.line, None))
    if value is None:
        doc.error(line, 'falta o campo "**Commit ou tag entregue:**"')
        return
    if unfilled(value):
        return
    revision = value.strip("` ")
    if not revision or " " in revision:
        doc.error(line, "commit ou tag: informe um único hash ou nome de tag")
        return
    try:
        result = subprocess.run(
            ["git", "-C", str(doc.path.parent), "rev-parse", "--verify", "--quiet", f"{revision}^{{commit}}"],
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        doc.warn(line, "não foi possível rodar o git para conferir o commit ou tag")
        return
    if b"not a git repository" in result.stderr:
        doc.warn(line, "a pasta não é um repositório git; não dá para conferir o commit ou tag")
    elif result.returncode != 0:
        doc.warn(
            line,
            f"commit ou tag {revision!r} não existe neste repositório "
            "(se for uma tag, crie-a depois do commit final)",
        )


def check_slides_field(doc: Document, section: Section, fields: dict) -> None:
    key = normalize("Slides da apresentação oral")
    line, value = fields.get(key, (section.line, None))
    if value is None:
        doc.error(line, 'falta o campo "**Slides da apresentação oral:**"')
        return
    # "Não há", "não há." ou "Nenhum!" valem como "não tem slides".
    if unfilled(value) or normalize(value).strip(" .!") in NONE_VALUES:
        return
    code_path = re.fullmatch(r"`([^`]+)`", value)
    if code_path and is_local(code_path[1]):
        if not (doc.path.parent / code_path[1]).exists():
            doc.error(line, f"arquivo dos slides não existe: {code_path[1]}")
    elif not re.search(r"\]\([^)]+\)|https?://", value):
        doc.error(
            line,
            'slides: use um caminho entre crases (`docs/apresentacao.pdf`), '
            'um link ou "não há"',
        )


def check_contributions(doc: Document, members: list[str]) -> None:
    section = doc.section("10. Contribuição de cada integrante")
    if not section or not members:
        return
    if not section.tables:
        doc.error(section.line, "falta a tabela de contribuições")
        return
    table = section.tables[0]
    names = [row[0] for row in table.rows if row and not unfilled(row[0])]
    check_same_people(doc, table.line, "contribuições", names, members)


def check_presentation(doc: Document, members: list[str]) -> None:
    section = doc.section("12. Apresentação oral")
    if not section:
        return
    if not section.tables:
        doc.error(section.line, "falta a tabela do roteiro da apresentação")
        return
    table = section.tables[0]
    total = Decimal(0)
    for number, row in zip(table.row_lines, table.rows):
        if len(row) < 3 or unfilled(row[1]):
            continue
        minutes = re.fullmatch(r"(\d+(?:[.,]\d+)?)\s*(min(utos?)?)?", row[1].strip())
        if not minutes:
            doc.error(number, f"duração deve ser em minutos, ex.: 3 min ({row[1]!r})")
        else:
            total += to_decimal(minutes[1])
        known = {normalize(m) for m in members}
        for person in re.split(r"\s*(?:,|/| e )\s*", row[2]):
            if members and person and not unfilled(person) and normalize(person) not in known:
                doc.warn(number, f"quem apresenta não está na tabela de integrantes: {person!r}")
    if total > PRESENTATION_MINUTES:
        doc.error(table.line, f"o roteiro soma {show(total)} min; o limite é {PRESENTATION_MINUTES} min")


def check_same_people(
    doc: Document, line: int, where: str, names: list[str], members: list[str]
) -> None:
    """Compara os nomes de uma tabela com a lista de integrantes.

    É só um AVISO: "Ana" e "Ana Souza" são a mesma pessoa, e o validador não
    tem como saber. Serve para pegar quem esqueceu alguém ou trocou o nome.
    """
    listed = {normalize(n) for n in names}
    expected = {normalize(m) for m in members}
    for name in names:
        if normalize(name) not in expected:
            doc.warn(line, f"{where}: {name!r} não está na tabela de integrantes")
    for member in members:
        if normalize(member) not in listed:
            doc.warn(line, f"{where}: falta o integrante {member!r}")


# ---------------------------------------------------------------------------
# Avaliação 360 graus
# ---------------------------------------------------------------------------


@dataclass
class Evaluator:
    """Quem escreveu a avaliação 360 graus, e como aparece nas tabelas.

    A própria pessoa pode aparecer como "Você", com o nome escrito no campo
    "Nome" ou com o nome escrito na linha "(autoavaliação)" da tabela de
    notas. `aliases` reúne todas essas formas (já normalizadas) para que as
    tabelas possam ser comparadas sem depender da ordem das linhas.
    """

    aliases: set[str] = field(default_factory=lambda: {normalize("Você")})

    def add(self, name: str | None) -> None:
        if name and not unfilled(name):
            self.aliases.add(normalize(name))

    def owns(self, name: str) -> bool:
        return normalize(name) in self.aliases


@dataclass
class Colleague:
    """Um colega citado na tabela de notas (seção 2).

    `extreme_grades` guarda os pares (critério, nota) em que a nota foi 1, 2
    ou 5: para essas, a seção 4 exige comentário sobre a pessoa.
    """

    name: str
    line: int  # linha da pessoa na tabela de notas
    extreme_grades: list[tuple[str, str]] = field(default_factory=list)


def check_peer_review(doc: Document) -> None:
    run_check(doc, "seções", lambda: check_sections(doc, PEER_SECTIONS, PEER_OPTIONAL_SECTIONS))
    evaluator = run_check(doc, "identificação", lambda: check_evaluator(doc)) or Evaluator()
    colleagues = run_check(doc, "notas", lambda: check_grades(doc, evaluator)) or []
    run_check(doc, "divisão do esforço", lambda: check_effort(doc, evaluator, colleagues))
    run_check(doc, "comentários", lambda: check_comments_per_colleague(doc, colleagues))


def check_evaluator(doc: Document) -> Evaluator:
    evaluator = Evaluator()
    if not re.fullmatch(r"\d+", doc.path.stem):
        doc.error(None, "o nome do arquivo deve ser a sua matrícula, ex.: 202312345.md")

    section = doc.section("Quem está avaliando")
    if section:
        fields = doc.fields(section)
        for key in ("Nome", "Matrícula", "Turma", "Projeto", "Grupo"):
            if normalize(key) not in fields:
                doc.error(section.line, f'falta o campo "**{key}:**"')
        _, name = fields.get(normalize("Nome"), (section.line, ""))
        evaluator.add(name)
        line, registration = fields.get(normalize("Matrícula"), (section.line, ""))
        if registration and not unfilled(registration) and registration != doc.path.stem:
            doc.error(line, f"matrícula {registration!r} não bate com o nome do arquivo")
        line, group_class = fields.get(normalize("Turma"), (section.line, ""))
        if group_class and not unfilled(group_class) and normalize(group_class).replace(" ", "") not in CLASSES:
            doc.error(line, f"turma deve ser 14h ou 16h: {group_class!r}")
    return evaluator


def check_grades(doc: Document, evaluator: Evaluator) -> list[Colleague]:
    """Confere as notas e devolve os COLEGAS (sem a própria pessoa), já com
    as notas 1, 2 ou 5 que cada um recebeu.

    A linha da própria pessoa é a que termina em "(autoavaliação)" ou se
    chama "Você". Ela pode estar em qualquer posição da tabela.
    """
    section = doc.section("2. Notas")
    if not section or not section.tables:
        if section:
            doc.error(section.line, "falta a tabela de notas")
        return []
    table = section.tables[0]
    criteria = table.header[1:]
    colleagues, self_rows = [], 0
    for number, row in zip(table.row_lines, table.rows):
        if not row or unfilled(row[0]):
            continue
        name = SELF_MARK.sub("", row[0])
        colleague = None
        if SELF_MARK.search(row[0]) or evaluator.owns(name):
            self_rows += 1
            evaluator.add(name)
        else:
            colleague = Colleague(name, number)
            colleagues.append(colleague)
        for criterion, grade in zip(criteria, row[1:]):
            if unfilled(grade):
                continue
            if not re.fullmatch(r"[1-5]|NA|N/A", grade.strip(), re.I):
                doc.error(number, f"nota deve ser de 1 a 5, ou NA: {grade!r}")
            elif colleague is not None and grade.strip() in {"1", "2", "5"}:
                colleague.extreme_grades.append((criterion, grade.strip()))
    people = len(colleagues) + self_rows
    if people and self_rows == 0:
        doc.error(table.line, 'falta a linha da autoavaliação (termine-a com "(autoavaliação)")')
    if self_rows > 1:
        doc.error(table.line, "há mais de uma linha de autoavaliação na tabela de notas")
    if people and not MIN_GROUP <= people <= MAX_GROUP:
        doc.error(
            table.line,
            f"a tabela avalia {people} pessoas; o grupo deve ter de {MIN_GROUP} a {MAX_GROUP}",
        )
    return colleagues


def check_effort(doc: Document, evaluator: Evaluator, colleagues: list[Colleague]) -> None:
    section = doc.section("3. Divisão do esforço")
    if not section or not section.tables:
        if section:
            doc.error(section.line, "falta a tabela de divisão do esforço")
        return
    table = section.tables[0]
    total, names, has_self = Decimal(0), [], False
    for number, row in zip(table.row_lines, table.rows):
        if len(row) < 2:
            continue
        name = row[0].strip("* ")
        if unfilled(row[0]) or unfilled(row[1]) or normalize(name) == "total":
            # Uma linha "Total" é opcional e não conta como pessoa: a soma é
            # conferida logo abaixo.
            continue
        value = re.fullmatch(r"\**\s*(\d+(?:[.,]\d+)?)\s*%?\s*\**", row[1].strip())
        if not value:
            doc.error(number, f"esforço deve ser um número (porcentagem): {row[1]!r}")
            continue
        total += to_decimal(value[1])
        if evaluator.owns(name):
            has_self = True
        else:
            names.append(name)
    if (names or has_self) and abs(total - 100) > EFFORT_TOLERANCE:
        low, high = show(100 - EFFORT_TOLERANCE), show(100 + EFFORT_TOLERANCE)
        doc.error(
            table.line,
            f"a divisão do esforço soma {show(total)}%; deve somar 100% "
            f"(aceitamos de {low}% a {high}%, por causa de arredondamentos)",
        )
    if colleagues:
        if not has_self:
            doc.warn(table.line, 'divisão do esforço: falta a sua própria linha ("Você")')
        check_same_people(doc, table.line, "divisão do esforço", names, [c.name for c in colleagues])


def check_comments_per_colleague(doc: Document, colleagues: list[Colleague]) -> None:
    section = doc.section("4. Comentários sobre cada colega")
    if not section or not colleagues:
        return
    # Guardamos a linha de cada "### Nome" para depois isolar o texto da
    # subseção e conferir se os dois itens foram preenchidos.
    headings = [
        (line[4:].strip(), number)
        for number, line in enumerate(
            doc.lines[section.line : section.end - 1], start=section.line + 1
        )
        if line.startswith("### ") and not unfilled(line[4:])
    ]
    subsections = [title for title, _ in headings]
    check_same_people(doc, section.line, "comentários", subsections, [c.name for c in colleagues])

    by_name = {normalize(title): number for title, number in headings}
    for colleague in colleagues:
        if not colleague.extreme_grades:
            continue
        start = by_name.get(normalize(colleague.name))
        if start is None:
            continue  # já avisado acima, por check_same_people
        end = next((n for _, n in headings if n > start), section.end)
        comment_fields = doc.fields(Section(colleague.name, start, end))
        filled = all(
            key in comment_fields and comment_fields[key][1].strip() and not unfilled(comment_fields[key][1])
            for key in (normalize("O que fez de melhor"), normalize("O que poderia melhorar"))
        )
        if not filled:
            criterion, grade = colleague.extreme_grades[0]
            doc.warn(
                colleague.line,
                f"{colleague.name} recebeu nota {grade} em {criterion}; "
                "o comentário sobre essa pessoa é obrigatório (seção 4)",
            )


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------


T = TypeVar("T")


def run_check(doc: Document, name: str, check: Callable[[], T]) -> T | None:
    """Roda uma verificação sem deixar que um erro inesperado interrompa as
    outras: a falha é registrada como mais um ERRO do documento."""
    try:
        return check()
    except Exception as exc:  # noqa: BLE001 (queremos mesmo capturar tudo)
        doc.error(
            None,
            f"não foi possível verificar {name} ({type(exc).__name__}: {exc}); "
            "o documento pode estar malformado nesse trecho",
        )
        return None


def validate(path: Path) -> Document:
    doc = load(path)
    if not doc.readable:
        return doc
    run_check(doc, "comentários", lambda: check_comments(doc))
    run_check(doc, "campos entre colchetes", lambda: check_placeholders(doc))
    run_check(doc, "tabelas", lambda: check_tables(doc))
    run_check(doc, "links", lambda: check_links(doc))
    if path.parent.name == PEER_DIR:
        check_peer_review(doc)
    else:
        check_report(doc)
    return doc


def default_files(root: Path) -> list[Path]:
    files = [root / REPORT_NAME]
    files += sorted(p for p in (root / PEER_DIR).glob("*.md") if p.name != PEER_TEMPLATE)
    return files


def print_report(doc: Document, root: Path) -> None:
    try:
        name = doc.path.relative_to(root)
    except ValueError:
        name = doc.path
    errors = [i for i in doc.issues if i.error]
    warnings = [i for i in doc.issues if not i.error]
    if not doc.issues:
        print(f"✔ {name}: tudo certo")
        return
    status = "✘" if errors else "!"
    print(f"{status} {name}: {len(errors)} erro(s), {len(warnings)} aviso(s)")
    for issue in sorted(doc.issues, key=lambda i: (i.line or 0, not i.error)):
        where = f"{name}:{issue.line}" if issue.line else f"{name}"
        kind = "ERRO " if issue.error else "AVISO"
        print(f"  {kind} {where}: {issue.message}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "arquivos",
        nargs="*",
        type=Path,
        help=f"arquivos a validar (padrão: {REPORT_NAME} e {PEER_DIR}/*.md)",
    )
    args = parser.parse_args()

    root = REPO_ROOT
    files = [p.resolve() for p in args.arquivos] or default_files(root)
    docs = [validate(p) for p in files]

    # Com a validação completa, confere se toda avaliação 360 encontrada é de
    # alguém que está na tabela de integrantes do relatório. (O inverso, se
    # cada integrante entregou a sua, é conferido pelo professor com o
    # scripts/agregar_360.py, porque as avaliações ficam nos repositórios
    # individuais.)
    if not args.arquivos:
        report = next((d for d in docs if d.path.name == REPORT_NAME), None)
        if report and report.registrations:
            known = set(report.registrations)
            for doc in docs:
                if doc.path.parent.name == PEER_DIR and doc.path.stem not in known:
                    doc.warn(
                        None,
                        f"a matrícula {doc.path.stem} não está na tabela de integrantes do RELATORIO.md",
                    )

    for doc in docs:
        print_report(doc, root)

    failed = any(i.error for d in docs for i in d.issues)
    if any("campo não preenchido" in i.message for d in docs for i in d.issues):
        print()
        print(
            "Dica: se um texto entre colchetes NÃO for um campo do template "
            "(uma lista Prolog, por exemplo), escreva-o entre crases: `[H|T]`."
        )
    print()
    print("Há erros para corrigir antes da entrega." if failed else "Nenhum erro encontrado.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
