#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Métricas objetivas de um repositório de trabalho final.

Ferramenta do professor. Mede o que AVALIACAO.md (seção 1.2) lista: testes,
avisos do swipl, compilação do Elm, elm-format, proporção de linhas por
linguagem, validador e distribuição de commits. Nada aqui vira nota sozinho;
o resultado alimenta o preenchimento inicial da rubrica (scripts/rubrica.py)
e serve de alerta.

Uso:

    uv run scripts/metricas.py REPO            # tabela legível
    uv run scripts/metricas.py REPO --json     # para outros scripts
    uv run scripts/metricas.py REPO --instalar # roda `npm install` e `uv sync` antes

O repositório precisa ter as dependências instaladas (node_modules e .venv)
para os testes e a compilação rodarem; `--instalar` cuida disso. Cada
métrica roda isolada: se uma falhar, ela vira "erro: ..." e as outras
continuam. Só biblioteca padrão, para funcionar em qualquer máquina.
"""

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

SKIP_DIRS = {"node_modules", ".venv", "elm-stuff", ".git", "dist", "__pycache__", ".pytest_cache"}
TIMEOUT = 600  # segundos por comando; o primeiro `elm make` baixa pacotes
VALIDATOR = Path(__file__).resolve().parent / "validar_entrega.py"

# Lotes de entrega (AVALIACAO.md, seção 3), no fuso de Brasília.
BRASILIA = timezone(timedelta(hours=-3))
DEADLINES = [
    (1, datetime(2026, 11, 18, 23, 59, 59, tzinfo=BRASILIA)),
    (2, datetime(2026, 11, 23, 23, 59, 59, tzinfo=BRASILIA)),
    (3, datetime(2026, 11, 30, 23, 59, 59, tzinfo=BRASILIA)),
]


def lot_of(moment: datetime) -> int | None:
    """Lote em que um commit cai; None se ficou depois do último prazo."""
    for lot, deadline in DEADLINES:
        if moment <= deadline:
            return lot
    return None


def last_commit(repo: Path, revision: str = "HEAD") -> datetime | None:
    """Data do commit (a do autor do commit, com fuso), ou None sem git."""
    proc = subprocess.run(["git", "log", "-1", "--format=%cI", revision], cwd=repo, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return datetime.fromisoformat(proc.stdout.strip())


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT)


def files(repo: Path, suffix: str) -> list[Path]:
    return sorted(p for p in repo.rglob(f"*{suffix}") if not SKIP_DIRS & set(p.relative_to(repo).parts))


# ---------------------------------------------------------------------------
# Métricas
# ---------------------------------------------------------------------------


def lines_of_code(repo: Path) -> dict:
    """Linhas não vazias por linguagem. A pasta scripts/ (ferramentas do
    template, em Python) fica de fora para não inflar o Python do grupo."""
    counts = {}
    for language, suffix in (("prolog", ".pl"), ("elm", ".elm"), ("python", ".py")):
        total = 0
        for path in files(repo, suffix):
            if path.relative_to(repo).parts[0] == "scripts":
                continue
            total += sum(1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip())
        counts[language] = total
    graded = counts["prolog"] + counts["elm"] + counts["python"]
    counts["python_%"] = round(100 * counts["python"] / graded, 1) if graded else 0.0
    return counts


def prolog_warnings(repo: Path) -> dict:
    """Carrega cada .pl com o swipl e conta os avisos (singletons, cláusulas
    descontíguas, etc.)."""
    result = {"arquivos": 0, "avisos": 0, "mensagens": []}
    for path in files(repo, ".pl"):
        result["arquivos"] += 1
        proc = run(["swipl", "-q", "-g", "halt", "-t", "halt", str(path)], cwd=path.parent)
        warnings = [line.strip() for line in proc.stderr.splitlines() if line.startswith("Warning:")]
        result["avisos"] += len(warnings)
        result["mensagens"] += warnings[:5]
    return result


def prolog_tests(repo: Path) -> dict:
    """Roda os arquivos que têm begin_tests (plunit)."""
    result = {"arquivos": 0, "passaram": 0, "falharam": 0, "ok": True}
    for path in files(repo, ".pl"):
        if "begin_tests" not in path.read_text(encoding="utf-8", errors="replace"):
            continue
        result["arquivos"] += 1
        proc = run(["swipl", "-g", "run_tests", "-t", "halt", str(path)], cwd=path.parent)
        output = proc.stdout + proc.stderr
        # Formatos do plunit: "% All 11 tests passed", "% 2 tests failed",
        # "% 9 tests passed" (versões mais antigas).
        passed = re.search(r"(\d+) tests? passed", output)
        failed = re.search(r"(\d+) (?:tests? )?failed", output)
        result["passaram"] += int(passed[1]) if passed else 0
        result["falharam"] += int(failed[1]) if failed else 0
        result["ok"] = result["ok"] and proc.returncode == 0
    return result


def elm_project(repo: Path) -> Path | None:
    candidates = [p.parent for p in files(repo, "elm.json") if p.name == "elm.json"]
    return candidates[0] if candidates else None


def elm_make(repo: Path) -> dict:
    """Compila cada Main.elm dos source-directories do elm.json."""
    project = elm_project(repo)
    if project is None:
        return {"ok": None, "detalhe": "sem elm.json"}
    if not (project / "node_modules").exists():
        return {"ok": None, "detalhe": "node_modules ausente (rode com --instalar)"}
    config = json.loads((project / "elm.json").read_text(encoding="utf-8"))
    mains = [
        path
        for source in config.get("source-directories", ["src"])
        for path in (project / source).rglob("Main.elm")
    ]
    if not mains:
        return {"ok": None, "detalhe": "nenhum Main.elm"}
    errors = []
    for main in mains:
        proc = run(["npx", "--no-install", "elm", "make", str(main), "--output=/dev/null"], cwd=project)
        if proc.returncode != 0:
            errors.append((proc.stderr or proc.stdout).strip().splitlines()[:8])
    return {"ok": not errors, "modulos": len(mains), "erros": errors}


def elm_format(repo: Path) -> dict:
    project = elm_project(repo)
    if project is None:
        return {"ok": None, "detalhe": "sem elm.json"}
    proc = run(["npx", "--no-install", "elm-format", "--validate", "src"], cwd=project)
    output = proc.stdout + proc.stderr
    if proc.returncode != 0 and re.search(r"missing packages|not found|could not determine", output, re.I):
        return {"ok": None, "detalhe": "elm-format não instalado no projeto"}
    # Com arquivos fora do formato, o --validate imprime um JSON com um
    # objeto {"path": ..., "message": ...} por arquivo.
    return {"ok": proc.returncode == 0, "arquivos_fora": proc.stdout.count('"path"')}


def elm_tests(repo: Path) -> dict:
    project = elm_project(repo)
    if project is None or not (project / "tests").exists():
        return {"ok": None, "detalhe": "sem pasta tests/"}
    proc = run(["npx", "--no-install", "elm-test"], cwd=project)
    output = proc.stdout + proc.stderr
    passed = re.search(r"Passed:\s+(\d+)", output)
    failed = re.search(r"Failed:\s+(\d+)", output)
    if not passed and not failed:
        return {"ok": None, "detalhe": "elm-test não rodou: " + output.strip().splitlines()[-1][:80] if output.strip() else "elm-test não rodou"}
    return {"ok": proc.returncode == 0, "passaram": int(passed[1]) if passed else 0, "falharam": int(failed[1]) if failed else 0}


def pytest_tests(repo: Path) -> dict:
    projects = [p.parent for p in files(repo, "pyproject.toml") if (p.parent / "tests").exists()]
    if not projects:
        return {"ok": None, "detalhe": "sem projeto Python com tests/"}
    result = {"ok": True, "passaram": 0, "falharam": 0}
    for project in projects:
        proc = run(["uv", "run", "--quiet", "pytest", "-q"], cwd=project)
        output = proc.stdout + proc.stderr
        passed = re.search(r"(\d+) passed", output)
        failed = re.search(r"(\d+) failed", output)
        result["passaram"] += int(passed[1]) if passed else 0
        result["falharam"] += int(failed[1]) if failed else 0
        result["ok"] = result["ok"] and proc.returncode == 0
    return result


def validator(repo: Path) -> dict:
    """Roda o validador DESTE template (não a cópia que estiver no repositório
    do grupo, que pode estar desatualizada) sobre o RELATORIO.md do grupo."""
    report = repo / "RELATORIO.md"
    if not report.exists():
        return {"ok": False, "erros": None, "detalhe": "RELATORIO.md ausente"}
    proc = run(["uv", "run", "--quiet", str(VALIDATOR), str(report)], cwd=repo)
    summary = re.search(r"(\d+) erro\(s\), (\d+) aviso\(s\)", proc.stdout)
    if summary:
        return {"ok": proc.returncode == 0, "erros": int(summary[1]), "avisos": int(summary[2])}
    return {"ok": proc.returncode == 0, "erros": 0, "avisos": 0}


def commits(repo: Path) -> dict:
    proc = run(["git", "shortlog", "-sn", "--no-merges", "HEAD"], cwd=repo)
    if proc.returncode != 0:
        return {"total": None, "detalhe": "não é um repositório git"}
    authors = Counter()
    for line in proc.stdout.splitlines():
        count, _, author = line.strip().partition("\t")
        authors[author] = int(count)
    total = sum(authors.values())
    moment = last_commit(repo)
    return {
        "total": total,
        "autores": dict(authors.most_common()),
        "ultimo_commit": moment.isoformat() if moment else None,
        "lote": lot_of(moment) if moment else None,
    }


METRICS = {
    "linhas": lines_of_code,
    "prolog_avisos": prolog_warnings,
    "prolog_testes": prolog_tests,
    "elm_make": elm_make,
    "elm_format": elm_format,
    "elm_testes": elm_tests,
    "pytest": pytest_tests,
    "validador": validator,
    "commits": commits,
}


def install(repo: Path) -> None:
    project = elm_project(repo)
    if project is not None:
        run(["npm", "install", "--no-audit", "--no-fund"], cwd=project)
    for pyproject in files(repo, "pyproject.toml"):
        run(["uv", "sync", "--quiet"], cwd=pyproject.parent)


def measure(repo: Path, install_first: bool = False) -> dict:
    if install_first:
        install(repo)
    results = {}
    for name, metric in METRICS.items():
        try:
            results[name] = metric(repo)
        except Exception as exc:  # noqa: BLE001 (uma métrica não pode derrubar as outras)
            results[name] = {"ok": None, "detalhe": f"erro: {type(exc).__name__}: {exc}"}
    return results


# ---------------------------------------------------------------------------
# Saída legível
# ---------------------------------------------------------------------------


def status(entry: dict) -> str:
    ok = entry.get("ok")
    if ok is None:
        return "-"
    return "ok" if ok else "FALHOU"


def summarize(results: dict) -> list[tuple[str, str, str]]:
    """Linhas (métrica, estado, detalhe) para a tabela e para a rubrica."""
    lines = results["linhas"]
    rows = [
        (
            "linhas de código",
            "alerta" if lines["python_%"] > 30 else "ok",
            f"Prolog {lines['prolog']}, Elm {lines['elm']}, Python {lines['python']} ({lines['python_%']}%)",
        )
    ]
    pw = results["prolog_avisos"]
    rows.append(("swipl carrega sem avisos", "ok" if pw.get("avisos") == 0 else "FALHOU", pw.get("detalhe") or f"{pw.get('avisos')} aviso(s) em {pw.get('arquivos')} arquivo(s)"))
    for key, label in (("prolog_testes", "testes plunit"), ("elm_testes", "testes elm-test"), ("pytest", "testes pytest")):
        entry = results[key]
        detail = entry.get("detalhe") or f"{entry.get('passaram', 0)} passaram, {entry.get('falharam', 0)} falharam"
        if key == "prolog_testes" and entry.get("arquivos") == 0:
            detail, entry = "nenhum arquivo de teste", {"ok": None}
        rows.append((label, status(entry), detail))
    em = results["elm_make"]
    rows.append(("elm make", status(em), em.get("detalhe") or f"{em.get('modulos')} módulo(s)" + (f", erros: {em['erros'][0][0]}" if em.get("erros") else "")))
    ef = results["elm_format"]
    rows.append(("elm-format", status(ef), ef.get("detalhe") or (f"{ef.get('arquivos_fora')} arquivo(s) fora do formato" if not ef.get("ok") else "aplicado")))
    va = results["validador"]
    rows.append(("validador", status(va), va.get("detalhe") or f"{va.get('erros')} erro(s), {va.get('avisos')} aviso(s)"))
    co = results["commits"]
    if co.get("total") is None:
        rows.append(("commits", "-", co.get("detalhe", "")))
    else:
        authors = ", ".join(f"{a} {n}" for a, n in co["autores"].items())
        rows.append(("commits", "ok", f"{co['total']} no total: {authors}"))
        when = co["ultimo_commit"][:16].replace("T", " ") if co.get("ultimo_commit") else "?"
        lot = f"lote {co['lote']}" if co.get("lote") else "FORA DO PRAZO"
        rows.append(("último commit", "ok" if co.get("lote") == 1 else "alerta", f"{when} ({lot})"))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("repo", type=Path, help="pasta do repositório do grupo")
    parser.add_argument("--json", action="store_true", help="imprime o resultado completo em JSON")
    parser.add_argument("--instalar", action="store_true", help="roda npm install e uv sync antes de medir")
    args = parser.parse_args()

    repo = args.repo.resolve()
    if not repo.is_dir():
        print(f"pasta não encontrada: {repo}", file=sys.stderr)
        return 1
    results = measure(repo, args.instalar)
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return 0
    width = max(len(name) for name, _, _ in summarize(results))
    for name, state, detail in summarize(results):
        print(f"{name:<{width}}  {state:<7} {detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
