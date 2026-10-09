#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py>=3"]
# ///
"""Agrega as avaliações 360 graus de todos os alunos em planilhas CSV.

Ferramenta do professor. Os alunos não precisam dela.

Uso:

    uv run scripts/agregar_360.py PASTA [PASTA...] [-o PREFIXO]

Cada PASTA é percorrida recursivamente à procura de:

    RELATORIO.md                    repositórios dos grupos: diz quem está
                                    em cada grupo (tabela da seção 1)
    avaliacao-360/<matricula>.md    repositórios individuais: as avaliações

Com o GitHub Classroom, basta clonar as duas atividades (por exemplo com
`gh classroom clone student-repos`) e apontar o script para as pastas.
Repositórios individuais criados a partir do template trazem um
RELATORIO.md vazio; ele é ignorado, pois não tem integrantes.

Com `--notas-grupo avaliacoes/notas-grupo.csv` (gerado por rubrica.py), o
script também calcula a nota individual e a final de cada aluno pela regra
de AVALIACAO.md, seção 2.

Saída:

    PREFIXO.csv           uma linha por aluno: médias recebidas por critério,
                          média geral, esforço mediano atribuído pelos
                          colegas, esforço que a pessoa atribuiu a si mesma,
                          se entregou a própria avaliação e, com as notas de
                          grupo, o fator 360, a nota individual e a final
    PREFIXO-detalhe.csv   uma linha por par avaliador/avaliado, com as notas
                          e o esforço como foram escritos

Os CSV usam ponto e vírgula e vírgula decimal, que é o que o Excel e o
LibreOffice em português esperam.

Avisos (nomes que não casam com a tabela de integrantes, avaliações que
faltam, matrículas desconhecidas) vão para stderr.
"""

import argparse
import csv
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from statistics import median

# Reaproveitamos a leitura de markdown do validador. Como os dois scripts
# ficam na mesma pasta, o import direto funciona quando este arquivo é
# executado como script (o Python coloca a pasta do script no sys.path).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from validar_entrega import (
    SELF_MARK,
    Document,
    load,
    normalize,
    to_decimal,
    unfilled,
)

REPORT_NAME = "RELATORIO.md"
PEER_DIR = "avaliacao-360"
# Ordem das colunas na planilha; os títulos da tabela do aluno são casados
# por `normalize`, então "Tecnica" e "Técnica" são a mesma coluna.
CRITERIA = ["Técnica", "Participação", "Comunicação", "Compromisso", "Colaboração"]
SKIP_DIRS = {"node_modules", ".venv", "elm-stuff", ".git", "dist"}

# Regra da nota individual (AVALIACAO.md, seção 2). Mudou lá, mude aqui.
GROUP_WEIGHT = Decimal("0.25")  # Final = 0,25 G + 0,75 I
FACTOR_MIN, FACTOR_MAX = Decimal("0.6"), Decimal("1.2")
MIN_REVIEWS = 2  # abaixo disso não há dado: F = 1
MISSING_REVIEW_PENALTY = Decimal("0.5")  # quem não entregou a própria 360


# ---------------------------------------------------------------------------
# Estruturas
# ---------------------------------------------------------------------------


@dataclass
class Member:
    name: str
    registration: str
    group_class: str
    github: str
    project: str  # campo "Nome do projeto" (ou o título # do relatório)
    group_name: str  # campo "Nome do grupo"
    group: Path  # pasta do repositório do grupo


@dataclass
class Review:
    """Uma avaliação 360 graus, como escrita pelo aluno."""

    path: Path
    evaluator: str  # matrícula (nome do arquivo)
    project: str
    grades: dict[str, dict[str, str]] = field(default_factory=dict)  # nome -> critério -> nota
    effort: dict[str, Decimal] = field(default_factory=dict)  # nome -> %
    self_grades: dict[str, str] = field(default_factory=dict)
    self_effort: Decimal | None = None


def warn(message: str) -> None:
    print(f"AVISO: {message}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Leitura
# ---------------------------------------------------------------------------


def find_files(roots: list[Path]) -> tuple[list[Path], list[Path]]:
    reports, reviews = [], []
    for root in roots:
        for path in sorted(root.rglob("*.md")):
            if SKIP_DIRS & set(path.parts):
                continue
            if path.name == REPORT_NAME:
                reports.append(path)
            elif path.parent.name == PEER_DIR and re.fullmatch(r"\d+", path.stem):
                reviews.append(path)
    return reports, reviews


def title_of(doc: Document) -> str:
    for index, token in enumerate(doc.tokens):
        if token.type == "heading_open" and token.tag == "h1":
            return doc.tokens[index + 1].content.strip()
    return ""


def read_members(path: Path) -> list[Member]:
    doc = load(path)
    section = doc.section("1. Identificação")
    if not doc.readable or not section or not section.tables:
        return []
    fields = doc.fields(section)
    _, project = fields.get(normalize("Nome do projeto"), (0, ""))
    _, group_name = fields.get(normalize("Nome do grupo"), (0, ""))
    if unfilled(project) or not project:
        project = title_of(doc)
    if unfilled(group_name):
        group_name = ""
    members = []
    for row in section.tables[0].rows:
        if len(row) < 4 or unfilled(row[0]) or unfilled(row[1]):
            continue
        members.append(Member(row[0], row[1], row[2], row[3], project, group_name, path.parent))
    return members


def read_review(path: Path) -> Review | None:
    doc = load(path)
    if not doc.readable:
        warn(f"{path}: não foi possível ler o arquivo")
        return None
    review = Review(path, path.stem, "")
    aliases = {normalize("Você")}  # formas pelas quais o aluno se refere a si

    header = doc.section("Quem está avaliando")
    if header:
        fields = doc.fields(header)
        _, name = fields.get(normalize("Nome"), (0, ""))
        if not unfilled(name):
            aliases.add(normalize(name))
        _, review.project = fields.get(normalize("Projeto"), (0, ""))

    grades = doc.section("2. Notas")
    if grades and grades.tables:
        table = grades.tables[0]
        criteria = table.header[1:]
        for row in table.rows:
            if not row or unfilled(row[0]):
                continue
            name = SELF_MARK.sub("", row[0])
            marks = {c: g.strip() for c, g in zip(criteria, row[1:]) if not unfilled(g)}
            if SELF_MARK.search(row[0]) or normalize(name) in aliases:
                aliases.add(normalize(name))
                review.self_grades = marks
            else:
                review.grades[name] = marks

    effort = doc.section("3. Divisão do esforço")
    if effort and effort.tables:
        for row in effort.tables[0].rows:
            if len(row) < 2 or unfilled(row[0]) or unfilled(row[1]):
                continue
            name = row[0].strip("* ")
            number = re.fullmatch(r"\**\s*(\d+(?:[.,]\d+)?)\s*%?\s*\**", row[1].strip())
            if normalize(name) == "total" or not number:
                continue
            if normalize(name) in aliases:
                review.self_effort = to_decimal(number[1])
            else:
                review.effort[name] = to_decimal(number[1])
    return review


# ---------------------------------------------------------------------------
# Cruzamento
# ---------------------------------------------------------------------------


def match_member(name: str, candidates: list[Member]) -> Member | None:
    """Acha o integrante a que `name` se refere.

    Primeiro pelo nome completo; depois, se só um candidato começa com o
    texto escrito (ou o contém), aceita esse. "Ana" casa com "Ana Souza" se
    não houver outra Ana no grupo.
    """
    wanted = normalize(name)
    exact = [m for m in candidates if normalize(m.name) == wanted]
    if exact:
        return exact[0]
    partial = [m for m in candidates if normalize(m.name).startswith(wanted) or wanted in normalize(m.name)]
    return partial[0] if len(partial) == 1 else None


def grade_value(grade: str) -> int | None:
    return int(grade) if re.fullmatch(r"[1-5]", grade) else None


def mean(values: list[Decimal | int]) -> Decimal | None:
    if not values:
        return None
    return sum(map(Decimal, values), Decimal(0)) / len(values)


def fmt(value: Decimal | int | None) -> str:
    """Número para o CSV: vírgula decimal, duas casas, vazio se não houver."""
    if value is None:
        return ""
    return f"{Decimal(value):.2f}".replace(".", ",")


def grade_for(criteria_written: dict[str, str], wanted: str) -> str | None:
    """Nota dada no critério `wanted`, casando o título da coluna sem acento."""
    for written, grade in criteria_written.items():
        if normalize(written) == normalize(wanted):
            return grade
    return None


def read_group_grades(path: Path | None) -> dict[str, Decimal]:
    """Lê o notas-grupo.csv do rubrica.py: projeto -> G."""
    if path is None:
        return {}
    grades = {}
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle, delimiter=";"):
            grades[normalize(row["projeto"])] = to_decimal(row["nota_grupo"])
    return grades


def read_discounts(path: Path | None) -> dict[str, Decimal]:
    """Lê o descontos-individuais.csv do rubrica.py: matrícula -> desconto."""
    if path is None:
        return {}
    discounts: dict[str, Decimal] = defaultdict(Decimal)
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle, delimiter=";"):
            discounts[row["matricula"]] += to_decimal(row["desconto"])
    return discounts


def individual_grade(
    group_grade: Decimal, shares: list[Decimal], group_size: int, delivered: bool, discount: Decimal = Decimal(0)
) -> tuple[Decimal, Decimal, Decimal]:
    """Aplica a regra de AVALIACAO.md: devolve (F, I, Final). `discount` é o
    desconto da verificação de compreensão (seção 2.1)."""
    fair_share = Decimal(100) / group_size
    if len(shares) < MIN_REVIEWS:
        factor = Decimal(1)
    else:
        # Duas casas: 33,3% num grupo de 3 é a parte justa, não 0,999 dela.
        factor = (median(shares) / fair_share).quantize(Decimal("0.01"))
        factor = min(max(factor, FACTOR_MIN), FACTOR_MAX)
    individual = min(Decimal(10), group_grade * factor)
    final = GROUP_WEIGHT * group_grade + (1 - GROUP_WEIGHT) * individual
    if not delivered:
        final -= MISSING_REVIEW_PENALTY
    final -= discount
    return factor, individual, max(final, Decimal(0))


def aggregate(
    members: list[Member],
    reviews: list[Review],
    prefix: Path,
    group_grades: dict[str, Decimal],
    discounts: dict[str, Decimal],
) -> None:
    by_registration = {m.registration: m for m in members}
    by_group: dict[Path, list[Member]] = defaultdict(list)
    for m in members:
        by_group[m.group].append(m)

    received_grades: dict[str, dict[str, list[int]]] = defaultdict(lambda: defaultdict(list))
    received_effort: dict[str, list[Decimal]] = defaultdict(list)
    received_from: dict[str, set[str]] = defaultdict(set)  # avaliado -> avaliadores
    delivered: dict[str, Review] = {}
    detail_rows = []

    for review in reviews:
        evaluator = by_registration.get(review.evaluator)
        if evaluator is None:
            warn(f"{review.path}: matrícula {review.evaluator} não está em nenhum RELATORIO.md")
            continue
        if review.evaluator in delivered:
            warn(f"{review.path}: matrícula {review.evaluator} tem mais de uma avaliação; usando a primeira")
            continue
        delivered[review.evaluator] = review
        if review.project and normalize(review.project) != normalize(evaluator.project):
            warn(f"{review.path}: projeto {review.project!r} difere do relatório do grupo ({evaluator.project!r})")
        colleagues = [m for m in by_group[evaluator.group] if m is not evaluator]

        for name, marks in review.grades.items():
            target = match_member(name, colleagues)
            if target is None:
                warn(f"{review.path}: {name!r} não casa com nenhum integrante do grupo (notas ignoradas)")
                continue
            effort = review.effort.get(name)
            if effort is None:
                # O nome pode estar escrito de outro jeito na tabela de esforço.
                effort = next((v for n, v in review.effort.items() if match_member(n, [target])), None)
            received_from[target.registration].add(evaluator.registration)
            for criterion in CRITERIA:
                grade = grade_for(marks, criterion)
                if grade is not None and grade_value(grade) is not None:
                    received_grades[target.registration][criterion].append(grade_value(grade))
            if effort is not None:
                received_effort[target.registration].append(effort)
            detail_rows.append(
                [evaluator.registration, evaluator.name, target.registration, target.name, evaluator.project]
                + [grade_for(marks, c) or "" for c in CRITERIA]
                + [fmt(effort)]
            )
        for name in review.effort:
            if name not in review.grades and match_member(name, colleagues) is None:
                warn(f"{review.path}: {name!r} (esforço) não casa com nenhum integrante do grupo")

    # Planilha resumo
    with open(prefix.with_suffix(".csv"), "w", newline="", encoding="utf-8") as out:
        writer = csv.writer(out, delimiter=";")
        writer.writerow(
            ["turma", "grupo", "projeto", "matricula", "nome", "github", "entregou_360", "avaliacoes_recebidas"]
            + [f"media_{normalize(c).replace(' ', '_')}" for c in CRITERIA]
            + ["media_geral", "esforco_recebido_%", "esforco_proprio_%", "esforco_igualitario_%"]
            + ["nota_grupo", "fator_360", "nota_individual", "desconto_compreensao", "nota_final"]
        )
        projects_without_grade = set()
        for member in sorted(members, key=lambda m: (m.group_class, m.project, m.name)):
            grades = received_grades[member.registration]
            per_criterion = [mean(grades[c]) for c in CRITERIA]
            all_grades = [g for c in CRITERIA for g in grades[c]]
            group_size = len(by_group[member.group])
            review = delivered.get(member.registration)
            shares = received_effort[member.registration]
            if review and review.self_effort is not None and shares:
                gap = review.self_effort - median(shares)
                if abs(gap) >= 10:
                    warn(f"{member.name} ({member.registration}) se atribuiu {fmt(review.self_effort)}% e recebeu {fmt(median(shares))}%")

            group_grade = group_grades.get(normalize(member.project))
            if group_grades and group_grade is None:
                projects_without_grade.add(member.project)
            if group_grade is not None and len(shares) < MIN_REVIEWS:
                warn(f"{member.name} ({member.registration}) recebeu só {len(shares)} avaliação(ões); fator 360 = 1")
            final_columns = ["", "", "", "", ""]
            if group_grade is not None:
                discount = discounts.get(member.registration, Decimal(0))
                factor, individual, final = individual_grade(group_grade, shares, group_size, review is not None, discount)
                final_columns = [fmt(group_grade), fmt(factor), fmt(individual), fmt(discount) if discount else "", fmt(final)]

            writer.writerow(
                [
                    member.group_class,
                    member.group_name,
                    member.project,
                    member.registration,
                    member.name,
                    member.github,
                    "sim" if review else "não",
                    len(received_from[member.registration]),
                ]
                + [fmt(v) for v in per_criterion]
                + [
                    fmt(mean(all_grades)),
                    fmt(median(shares) if shares else None),
                    fmt(review.self_effort if review else None),
                    fmt(Decimal(100) / group_size if group_size else None),
                ]
                + final_columns
            )
        for project in sorted(projects_without_grade):
            warn(f"projeto {project!r} não está no CSV de notas de grupo; notas finais em branco")

    # Planilha detalhada
    with open(prefix.with_name(prefix.name + "-detalhe.csv"), "w", newline="", encoding="utf-8") as out:
        writer = csv.writer(out, delimiter=";")
        writer.writerow(
            ["avaliador_matricula", "avaliador", "avaliado_matricula", "avaliado", "projeto"]
            + [normalize(c).replace(" ", "_") for c in CRITERIA]
            + ["esforco_%"]
        )
        writer.writerows(sorted(detail_rows))

    missing = [m for m in members if m.registration not in delivered]
    for member in sorted(missing, key=lambda m: (m.project, m.name)):
        warn(f"falta a avaliação 360 de {member.name} ({member.registration}, {member.project})")
    print(
        f"{len(members)} alunos em {len(by_group)} grupos; {len(delivered)} avaliações lidas, "
        f"{len(missing)} faltando. Planilhas: {prefix}.csv e {prefix}-detalhe.csv"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("pastas", nargs="+", type=Path, help="pastas com os repositórios clonados")
    parser.add_argument("-o", "--saida", type=Path, default=Path("notas-360"), help="prefixo dos CSV gerados")
    parser.add_argument(
        "--notas-grupo",
        type=Path,
        help="notas-grupo.csv gerado por rubrica.py; com ele, calcula a nota individual e a final",
    )
    parser.add_argument(
        "--descontos",
        type=Path,
        help="descontos-individuais.csv gerado por rubrica.py (verificação de compreensão)",
    )
    args = parser.parse_args()

    reports, review_files = find_files(args.pastas)
    members = [m for path in reports for m in read_members(path)]
    if not members:
        print("nenhum RELATORIO.md com tabela de integrantes preenchida foi encontrado", file=sys.stderr)
        return 1
    seen: dict[str, Member] = {}
    for member in members:
        if member.registration in seen and seen[member.registration].group != member.group:
            warn(f"matrícula {member.registration} aparece em dois grupos: {seen[member.registration].group} e {member.group}")
        seen.setdefault(member.registration, member)
    members = list(seen.values())

    reviews = [r for r in (read_review(p) for p in review_files) if r is not None]
    aggregate(members, reviews, args.saida, read_group_grades(args.notas_grupo), read_discounts(args.descontos))
    return 0


if __name__ == "__main__":
    sys.exit(main())
