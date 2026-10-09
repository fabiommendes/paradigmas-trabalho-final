#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py>=3"]
# ///
"""Baixa as entregas do GitHub Classroom e classifica cada uma por lote.

Ferramenta do professor. Precisa do `gh` autenticado e da extensão
classroom (`gh extension install github/gh-classroom`).

Uso:

    uv run scripts/baixar.py --listar                    # turmas e atividades
    uv run scripts/baixar.py --grupos ID --alunos ID     # clona as duas atividades
    uv run scripts/baixar.py --grupos ID --alunos ID --atualizar   # git pull nas já clonadas
    uv run scripts/baixar.py --so-lotes                  # só recalcula lotes.csv

Os repositórios vão para PASTA/grupos e PASTA/alunos (padrão: entregas/).
Para cada repositório de grupo, o script lê o campo "Commit ou tag entregue"
do RELATORIO.md e faz checkout dessa revisão, se ela existir; é essa a
versão que vale (AVALIACAO.md, seção 3). Depois grava PASTA/lotes.csv com
a data do último commit e o lote de cada repositório, de grupo ou
individual. Nada do que foi baixado é executado aqui: rode
`scripts/auditar.py` antes de `metricas.py` e `rubrica.py`.
"""

import argparse
import csv
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from metricas import DEADLINES, last_commit, lot_of
from validar_entrega import load, normalize, unfilled

GROUPS, STUDENTS = "grupos", "alunos"


def run(command: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=1800)


def gh_classroom(*args: str) -> None:
    proc = subprocess.run(["gh", "classroom", *args], text=True, timeout=1800)
    if proc.returncode != 0:
        print(f"gh classroom {' '.join(args)} falhou (código {proc.returncode})", file=sys.stderr)


def repositories(folder: Path) -> list[Path]:
    """Toda pasta com .git abaixo de `folder` (o gh cria uma subpasta com o
    nome da atividade, e os repositórios ficam dentro dela)."""
    if not folder.exists():
        return []
    return sorted(p.parent for p in folder.rglob(".git") if p.is_dir())


def declared_revision(repo: Path) -> str | None:
    report = repo / "RELATORIO.md"
    if not report.exists():
        return None
    doc = load(report)
    section = doc.section("1. Identificação") if doc.readable else None
    if not section:
        return None
    _, value = doc.fields(section).get(normalize("Commit ou tag entregue"), (0, ""))
    value = value.strip("` ")
    return None if not value or unfilled(value) or " " in value else value


def checkout_declared(repo: Path) -> tuple[str, str]:
    """Faz checkout da revisão declarada. Devolve (revisão usada, observação)."""
    revision = declared_revision(repo)
    if revision is None:
        return "HEAD", "sem commit ou tag declarado; usando o último commit"
    exists = run(["git", "rev-parse", "--verify", "--quiet", f"{revision}^{{commit}}"], cwd=repo)
    if exists.returncode != 0:
        return "HEAD", f"revisão declarada {revision!r} não existe; usando o último commit"
    run(["git", "checkout", "--quiet", "--detach", revision], cwd=repo)
    return revision, ""


def write_lots(folder: Path) -> list[list[str]]:
    rows = []
    for kind in (GROUPS, STUDENTS):
        for repo in repositories(folder / kind):
            revision, note = checkout_declared(repo) if kind == GROUPS else ("HEAD", "")
            moment = last_commit(repo)
            lot = lot_of(moment) if moment else None
            rows.append(
                [
                    kind,
                    repo.name,
                    str(repo.relative_to(folder)),
                    revision,
                    moment.isoformat(timespec="minutes") if moment else "",
                    str(lot) if lot else "fora do prazo",
                    note,
                ]
            )
    target = folder / "lotes.csv"
    with open(target, "w", newline="", encoding="utf-8") as out:
        writer = csv.writer(out, delimiter=";")
        writer.writerow(["tipo", "repositorio", "caminho", "revisao", "ultimo_commit", "lote", "observacao"])
        writer.writerows(rows)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--listar", action="store_true", help="mostra turmas e atividades e sai")
    parser.add_argument("--grupos", type=int, metavar="ID", help="id da atividade dos grupos")
    parser.add_argument("--alunos", type=int, metavar="ID", help="id da atividade individual (avaliação 360)")
    parser.add_argument("-d", "--pasta", type=Path, default=Path("entregas"), help="pasta de destino")
    parser.add_argument("--atualizar", action="store_true", help="git pull nos repositórios já clonados")
    parser.add_argument("--so-lotes", action="store_true", help="não baixa nada; só recalcula lotes.csv")
    args = parser.parse_args()

    if args.listar:
        gh_classroom("list")
        print("\nPara ver as atividades de uma turma: gh classroom assignments -c ID_DA_TURMA")
        return 0

    if not args.so_lotes:
        if args.grupos is None and args.alunos is None:
            parser.error("informe --grupos e/ou --alunos (ou --listar para descobrir os ids)")
        for kind, assignment in ((GROUPS, args.grupos), (STUDENTS, args.alunos)):
            if assignment is None:
                continue
            folder = args.pasta / kind
            folder.mkdir(parents=True, exist_ok=True)
            verb = "pull" if args.atualizar else "clone"
            gh_classroom(verb, "student-repos", "-a", str(assignment), "-d", str(folder))

    rows = write_lots(args.pasta)
    if not rows:
        print(f"nenhum repositório em {args.pasta}", file=sys.stderr)
        return 1
    width = max(len(r[1]) for r in rows)
    for kind, name, _, revision, moment, lot, note in rows:
        print(f"{kind:<7} {name:<{width}}  {revision:<12} {moment:<17} lote {lot:<14} {note}")
    print("\nPrazos: " + ", ".join(f"lote {n} até {d:%d/%m %H:%M}" for n, d in DEADLINES))
    print(f"Gravado em {args.pasta / 'lotes.csv'}. Próximo passo: uv run scripts/auditar.py {args.pasta}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
