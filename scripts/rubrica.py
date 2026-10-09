#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["markdown-it-py>=3", "rich>=13"]
# ///
"""Preenche a rubrica da nota do grupo (G) durante a apresentação.

Ferramenta do professor. Interativa, no terminal:

    uv run scripts/rubrica.py REPO [--saida avaliacoes/] [--sem-metricas] [--instalar]

O script lê o RELATORIO.md do repositório (nome do projeto e integrantes),
roda as métricas de scripts/metricas.py e sugere um nível inicial para os
critérios que elas informam ("Funciona" e "Qualidade do código"). Depois
percorre os seis critérios de AVALIACAO.md: mostra os níveis, pede o nível
(0 a 4) e uma observação opcional, e no fim calcula G, aplica penalidades e
grava.

Depois dos critérios, pergunta a faixa de ponto de partida e a de uso de IA
(AVALIACAO.md, seção 1.5; os valores declarados no relatório aparecem como
padrão), o lote de entrega (seção 3) e, para cada integrante, o desconto da
verificação de compreensão (seção 2.1).

Saída, na pasta --saida (padrão: avaliacoes/ na pasta atual):

    <repositorio>.json          níveis, observações, ajustes, métricas e G
    notas-grupo.csv             projeto;grupo;...;nota_grupo, uma linha por
                                grupo, lido por agregar_360.py --notas-grupo
    descontos-individuais.csv   matricula;nome;desconto;motivo, lido por
                                agregar_360.py --descontos

Rodar de novo para o mesmo repositório carrega a avaliação anterior como
ponto de partida. O CSV é sempre regenerado a partir de todos os JSON da
pasta, então ele é a soma do que está lá.

Os critérios, pesos e textos dos níveis abaixo espelham AVALIACAO.md.
Mudou um, mude o outro.
"""

import argparse
import csv
import json
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.prompt import Confirm, FloatPrompt, IntPrompt, Prompt
from rich.table import Table

sys.path.insert(0, str(Path(__file__).resolve().parent))
import metricas
from agregar_360 import read_members
from validar_entrega import load, normalize

VALIDATOR_PENALTY = 0.5  # AVALIACAO.md, seção 1.4

# Ajuste de escopo e IA (AVALIACAO.md, seção 1.5).
SCOPE_LEVELS = [
    ("template", "Template do Sudoku com ajustes (visual, níveis, dicas, cronômetro)", -1.0),
    ("variante", "Variante do Sudoku (novas restrições, Killer, diagonal, 16x16)", -0.5),
    ("conhecido", "Outro jogo ou quebra-cabeça conhecido, implementado pelo grupo", 0.0),
    ("remix", "Remix original: mecânicas conhecidas com uma regra própria", 0.5),
    ("inventado", "Jogo inventado pelo grupo, com regras próprias e jogável", 1.0),
]
AI_LEVELS = ["nenhum", "pontual", "auxiliar", "intensivo"]
AI_INTENSIVE_SHIFT = -0.5
BONUS_REQUIRES = {"funciona": 3, "prolog": 3}  # níveis mínimos para Δ positivo

# Lotes de entrega (AVALIACAO.md, seção 3): fator multiplicado em G.
LATE_FACTORS = {1: 1.0, 2: 0.9, 3: 0.75}
COMPREHENSION_MAX = 1.0  # desconto individual máximo (seção 2.1)


@dataclass
class Criterion:
    key: str
    name: str
    weight: float
    evidence: str
    levels: list[str]  # níveis 1 a 4; o nível 0 é sempre "ausente"


CRITERIA = [
    Criterion(
        "funciona",
        "Funciona e é reprodutível",
        0.15,
        "Seção 3 numa máquina limpa; demonstração; casos de borda da seção 8",
        [
            "Só roda com ajuda do grupo, ou não roda.",
            "Roda seguindo a seção 3, mas falha em uso normal.",
            "Roda e faz o que o relatório promete.",
            "Roda, trata os casos de borda da seção 8 e tem testes que provam isso.",
        ],
    ),
    Criterion(
        "prolog",
        "Prolog: uso do paradigma lógico",
        0.20,
        "Seções 5.1 a 5.3; arquivos .pl; testes plunit",
        [
            "Prolog decorativo: caberia num `if` em Python.",
            "Funciona, mas é algoritmo imperativo traduzido cláusula a cláusula.",
            "Unificação, backtracking, CLP(FD) ou similar de forma idiomática; a seção 5.3 explica por que é lógico.",
            "Além disso, modela algo não trivial (múltiplas soluções, explicação, geração) e tem testes plunit.",
        ],
    ),
    Criterion(
        "elm",
        "Elm: uso do paradigma funcional",
        0.30,
        "Seções 6.1 a 6.3; arquivos .elm",
        [
            "Elm como HTML com estado solto: Bool para tudo, Maybe.withDefault em todo canto.",
            "Arquitetura Elm correta, mas tipos pobres, que permitem estados inválidos.",
            "Custom types que tornam estados inválidos irrepresentáveis; Maybe e Result bem usados; decoders próprios; 6.1 justifica.",
            "Além disso, módulos com fronteiras claras (domínio puro, HTTP, view) e evidência de que o compilador guiou refatorações.",
        ],
    ),
    Criterion(
        "qualidade",
        "Qualidade do código",
        0.10,
        "O código; as métricas",
        [
            "Difícil de ler: nomes ruins, funções enormes, código morto, avisos ignorados.",
            "Legível com esforço; formatação irregular; comentários que repetem o código.",
            "Nomes claros, funções curtas, elm-format aplicado, swipl sem avisos, comentários que explicam decisões.",
            "Além disso, módulos coerentes e o Python permanece só integração.",
        ],
    ),
    Criterion(
        "relatorio",
        "Relatório",
        0.10,
        "Seções 2, 4, 8, 9, 11 e 13",
        [
            "Seções incompletas ou com texto genérico.",
            "Completo, mas descreve o código em vez de apontar para ele.",
            "Resumo compreensível; referências a arquivo:linha; limitações honestas; seção 11 completa.",
            "Além disso, a reflexão da seção 13 traz observações próprias, com exemplos do código.",
        ],
    ),
    Criterion(
        "apresentacao",
        "Apresentação oral",
        0.15,
        "Os 15 minutos; seção 12",
        [
            "Só slides, sem sistema funcionando.",
            "A demonstração falha ou o grupo estoura o tempo.",
            "Demonstração funciona, código Prolog e Elm mostrados, tempo respeitado, todos falam.",
            "Além disso, o grupo responde bem a perguntas sobre o próprio código.",
        ],
    ),
]

console = Console()


# ---------------------------------------------------------------------------
# Sugestões a partir das métricas
# ---------------------------------------------------------------------------


def suggest(results: dict | None) -> dict[str, int | None]:
    """Nível inicial para os critérios que as métricas informam. Os demais
    ficam sem sugestão: dependem de ler o código e assistir à apresentação."""
    suggestion: dict[str, int | None] = {c.key: None for c in CRITERIA}
    if not results:
        return suggestion

    suites = [results[k] for k in ("prolog_testes", "elm_testes", "pytest") if results[k].get("ok") is not None]
    if results["prolog_testes"].get("arquivos") == 0:
        suites = [s for s in suites if s is not results["prolog_testes"]]
    compiles = results["elm_make"].get("ok")
    if compiles is False or any(s["ok"] is False for s in suites):
        suggestion["funciona"] = 1 if compiles is False else 2
    elif suites:
        suggestion["funciona"] = 3

    quality = 3
    if results["prolog_avisos"].get("avisos", 0) > 0:
        quality -= 1
    if results["elm_format"].get("ok") is False:
        quality -= 1
    if results["linhas"].get("python_%", 0) > 30:
        quality -= 1
    suggestion["qualidade"] = max(quality, 1)
    return suggestion


# ---------------------------------------------------------------------------
# Interface
# ---------------------------------------------------------------------------


def show_header(repo: Path, project: str, group_name: str, members: list) -> None:
    title = f"[bold]{project or repo.name}[/bold]" + (f"  [dim]({group_name})[/dim]" if group_name else "")
    console.rule(title)
    if members:
        table = Table(show_header=True, header_style="dim", box=None, pad_edge=False)
        table.add_column("Integrante")
        table.add_column("Matrícula")
        table.add_column("Turma")
        for m in members:
            table.add_row(m.name, m.registration, m.group_class)
        console.print(table)
    else:
        console.print("[yellow]RELATORIO.md sem tabela de integrantes preenchida.[/yellow]")
    console.print()


def show_metrics(results: dict) -> None:
    table = Table(title="Métricas", title_justify="left", show_header=False, box=None, pad_edge=False)
    table.add_column("Métrica", style="dim")
    table.add_column("Estado")
    table.add_column("Detalhe")
    styles = {"ok": "green", "FALHOU": "red", "alerta": "yellow", "-": "dim"}
    for name, state, detail in metricas.summarize(results):
        table.add_row(name, f"[{styles.get(state, '')}]{state}[/]", detail)
    console.print(table)
    console.print()


def ask_criterion(index: int, criterion: Criterion, default: int | None, note: str) -> tuple[int, str]:
    body = "\n".join(
        f"[bold]{level}[/bold]  {text}" + ("  [cyan]<- sugestão das métricas[/cyan]" if level == default else "")
        for level, text in enumerate(["Ausente."] + criterion.levels)
    )
    console.print(
        Panel(
            body,
            title=f"[bold]{index}. {criterion.name}[/bold]  ({criterion.weight:.0%})",
            subtitle=f"[dim]{criterion.evidence}[/dim]",
            subtitle_align="left",
        )
    )
    level = IntPrompt.ask("Nível", choices=[str(n) for n in range(5)], default=default, show_default=default is not None)
    note = Prompt.ask("Observação", default=note, show_default=bool(note))
    console.print()
    return level, note


def declared_scope(report: Path) -> int | None:
    """Índice em SCOPE_LEVELS da faixa escrita no campo "Ponto de partida"."""
    doc = load(report)
    section = doc.section("1. Identificação") if doc.readable else None
    if not section:
        return None
    _, value = doc.fields(section).get(normalize("Ponto de partida"), (0, ""))
    for index, (key, _, _) in enumerate(SCOPE_LEVELS):
        if key in normalize(value):
            return index
    return None


def declared_ai(report: Path) -> str | None:
    doc = load(report)
    section = doc.section("11. Fontes, código de terceiros e uso de IA") if doc.readable else None
    if not section:
        return None
    _, value = doc.fields(section).get(normalize("Faixa de uso no código"), (0, ""))
    return normalize(value) if normalize(value) in AI_LEVELS else None


def ask_scope(default: int | None) -> int:
    body = "\n".join(
        f"[bold]{n}[/bold]  {text}  [dim]({delta:+.1f})[/dim]" + ("  [cyan]<- declarado no relatório[/cyan]" if default == n - 1 else "")
        for n, (_, text, delta) in enumerate(SCOPE_LEVELS, start=1)
    )
    console.print(Panel(body, title="[bold]Ponto de partida[/bold]  (ajuste Δ, seção 1.5)", subtitle="[dim]confirme na apresentação[/dim]", subtitle_align="left"))
    choice = IntPrompt.ask("Faixa", choices=[str(n) for n in range(1, len(SCOPE_LEVELS) + 1)], default=None if default is None else default + 1)
    console.print()
    return choice - 1


def ask_ai(default: str | None) -> str:
    console.print(
        Panel(
            "nenhum, pontual, auxiliar: sem efeito.  intensivo: Δ cai 0,5."
            + (f"\n[cyan]Declarado no relatório: {default}[/cyan]" if default else "\n[yellow]O relatório não declara a faixa.[/yellow]"),
            title="[bold]Uso de IA[/bold]  (seção 1.5)",
        )
    )
    choice = Prompt.ask("Faixa", choices=AI_LEVELS, default=default)
    console.print()
    return choice


def scope_delta(scope: int, ai: str, levels: dict[str, int]) -> tuple[float, str]:
    """Δ efetivo e uma explicação curta para o resumo."""
    delta = SCOPE_LEVELS[scope][2]
    reasons = [SCOPE_LEVELS[scope][0]]
    if ai == "intensivo":
        delta += AI_INTENSIVE_SHIFT
        reasons.append("IA intensiva")
    if delta > 0 and any(levels[key] < minimum for key, minimum in BONUS_REQUIRES.items()):
        delta = 0.0
        reasons.append("bônus suspenso: critérios 1 ou 2 abaixo de 3")
    return delta, ", ".join(reasons)


def grade(levels: dict[str, int], penalties: float, delta: float, late_factor: float) -> float:
    raw = 10 * sum(c.weight * levels[c.key] / 4 for c in CRITERIA)
    adjusted = min(max(raw - penalties + delta, 0), 10)
    return round(adjusted * late_factor, 2)


def show_summary(
    levels: dict, notes: dict, penalties: list[tuple[str, float]], delta: tuple[float, str], lot: int
) -> float:
    table = Table(title="Resumo", title_justify="left", box=None, pad_edge=False)
    table.add_column("#")
    table.add_column("Critério")
    table.add_column("Peso", justify="right")
    table.add_column("Nível", justify="right")
    table.add_column("Pontos", justify="right")
    table.add_column("Observação", style="dim")
    for index, c in enumerate(CRITERIA, start=1):
        points = 10 * c.weight * levels[c.key] / 4
        table.add_row(str(index), c.name, f"{c.weight:.0%}", str(levels[c.key]), f"{points:.2f}", notes.get(c.key, ""))
    total_penalty = sum(p for _, p in penalties)
    for reason, points in penalties:
        table.add_row("", f"[red]Penalidade: {reason}[/red]", "", "", f"[red]-{points:.2f}[/red]", "")
    color = "green" if delta[0] > 0 else "red" if delta[0] < 0 else "dim"
    table.add_row("", "Ajuste de escopo e IA", "", "", f"[{color}]{delta[0]:+.2f}[/]", delta[1])
    if lot > 1:
        table.add_row("", f"[red]Lote {lot}[/red]", "", "", f"[red]x {LATE_FACTORS[lot]:.2f}[/red]", "")
    g = grade(levels, total_penalty, delta[0], LATE_FACTORS[lot])
    table.add_row("", "[bold]G[/bold]", "", "", f"[bold]{g:.2f}[/bold]", "")
    console.print(table)
    console.print()
    return g


def ask_comprehension(members: list, previous: list[dict]) -> list[dict]:
    """Desconto da verificação de compreensão, por integrante."""
    if not members:
        return []
    console.print(Panel(f"Até {COMPREHENSION_MAX:.1f} ponto na nota individual de quem não explica o próprio código. Enter mantém 0.", title="[bold]Verificação de compreensão[/bold]  (seção 2.1)"))
    earlier = {p["matricula"]: p for p in previous}
    result = []
    for m in members:
        before = earlier.get(m.registration, {})
        discount = FloatPrompt.ask(f"{m.name} ({m.registration})", default=float(before.get("desconto", 0.0)))
        discount = min(max(discount, 0.0), COMPREHENSION_MAX)
        reason = Prompt.ask("  Motivo", default=before.get("motivo", "")) if discount else ""
        result.append({"matricula": m.registration, "nome": m.name, "desconto": discount, "motivo": reason})
    console.print()
    return result


# ---------------------------------------------------------------------------
# Persistência
# ---------------------------------------------------------------------------


def load_previous(path: Path) -> dict | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def decimal(value: float) -> str:
    return f"{value:.2f}".replace(".", ",")


def write_csv(folder: Path) -> tuple[Path, Path]:
    """Regenera notas-grupo.csv e descontos-individuais.csv a partir de todos
    os JSON da pasta, que são a fonte da verdade."""
    groups, discounts = [], []
    for path in sorted(folder.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        adjust = data.get("ajustes", {})
        groups.append(
            [
                data["projeto"],
                data.get("grupo", ""),
                data["repositorio"],
                adjust.get("ponto_de_partida", ""),
                adjust.get("ia", ""),
                adjust.get("lote", ""),
                decimal(data["G"]),
                data["data"],
            ]
        )
        for item in data.get("compreensao", []):
            if item["desconto"]:
                discounts.append([item["matricula"], item["nome"], data["projeto"], decimal(item["desconto"]), item["motivo"]])
    groups_csv = folder / "notas-grupo.csv"
    with open(groups_csv, "w", newline="", encoding="utf-8") as out:
        writer = csv.writer(out, delimiter=";")
        writer.writerow(["projeto", "grupo", "repositorio", "ponto_de_partida", "ia", "lote", "nota_grupo", "data"])
        writer.writerows(groups)
    discounts_csv = folder / "descontos-individuais.csv"
    with open(discounts_csv, "w", newline="", encoding="utf-8") as out:
        writer = csv.writer(out, delimiter=";")
        writer.writerow(["matricula", "nome", "projeto", "desconto", "motivo"])
        writer.writerows(discounts)
    return groups_csv, discounts_csv


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("repo", type=Path, help="pasta do repositório do grupo")
    parser.add_argument("--saida", type=Path, default=Path("avaliacoes"), help="pasta dos JSON e do notas-grupo.csv")
    parser.add_argument("--sem-metricas", action="store_true", help="não roda scripts/metricas.py")
    parser.add_argument("--instalar", action="store_true", help="roda npm install e uv sync antes das métricas")
    args = parser.parse_args()

    repo = args.repo.resolve()
    if not repo.is_dir():
        console.print(f"[red]pasta não encontrada: {repo}[/red]")
        return 1
    args.saida.mkdir(parents=True, exist_ok=True)
    target = args.saida / f"{repo.name}.json"
    previous = load_previous(target)

    report = repo / "RELATORIO.md"
    members = read_members(report) if report.exists() else []
    project = members[0].project if members else repo.name
    group_name = members[0].group_name if members else ""
    show_header(repo, project, group_name, members)
    if previous:
        console.print(f"[dim]Avaliação anterior de {previous['data']} carregada como ponto de partida.[/dim]\n")

    results = None
    if not args.sem_metricas:
        with console.status("Rodando as métricas (testes, compilação, validador)..."):
            results = metricas.measure(repo, args.instalar)
        show_metrics(results)
    suggestion = suggest(results)

    levels = dict(previous["niveis"]) if previous else {}
    notes = dict(previous["observacoes"]) if previous else {}
    for index, criterion in enumerate(CRITERIA, start=1):
        default = levels.get(criterion.key, suggestion[criterion.key])
        levels[criterion.key], notes[criterion.key] = ask_criterion(index, criterion, default, notes.get(criterion.key, ""))

    earlier = previous.get("ajustes", {}) if previous else {}
    scope_keys = [key for key, _, _ in SCOPE_LEVELS]
    scope_default = scope_keys.index(earlier["ponto_de_partida"]) if earlier.get("ponto_de_partida") in scope_keys else None
    if scope_default is None and report.exists():
        scope_default = declared_scope(report)
    scope = ask_scope(scope_default)
    ai = ask_ai(earlier.get("ia") or (declared_ai(report) if report.exists() else None))
    # O lote vem da avaliação anterior, senão da data do último commit
    # (métrica "commits"), senão 1.
    detected = (results or {}).get("commits", {}).get("lote") if results else None
    lot_default = int(earlier.get("lote") or detected or 1)
    if results and results.get("commits", {}).get("ultimo_commit"):
        when = results["commits"]["ultimo_commit"][:16].replace("T", " ")
        console.print(f"[dim]Último commit: {when}" + (f", lote {detected}" if detected else ", depois do último prazo") + "[/dim]")
    lot = IntPrompt.ask("Lote de entrada (1 = no prazo, 2 = até 23/11, 3 = até 30/11)", choices=["1", "2", "3"], default=lot_default)
    console.print()
    comprehension = ask_comprehension(members, previous.get("compreensao", []) if previous else [])

    while True:
        penalties = []
        validator_errors = results["validador"].get("erros") if results else None
        if validator_errors and Confirm.ask(
            f"O validador achou {validator_errors} erro(s). Aplicar a penalidade de {VALIDATOR_PENALTY}?", default=True
        ):
            penalties.append(("validador com erros", VALIDATOR_PENALTY))
        other = FloatPrompt.ask("Outras penalidades (pontos)", default=0.0)
        if other:
            penalties.append((Prompt.ask("Motivo"), other))
        delta = scope_delta(scope, ai, levels)
        g = show_summary(levels, notes, penalties, delta, lot)
        answer = Prompt.ask("Número do critério a rever, [bold]e[/bold] para escopo/IA/lote, ou Enter para salvar", default="")
        if not answer:
            break
        if answer.lower() == "e":
            scope = ask_scope(scope)
            ai = ask_ai(ai)
            lot = IntPrompt.ask("Lote de entrada", choices=["1", "2", "3"], default=lot)
        elif answer.isdigit() and 1 <= int(answer) <= len(CRITERIA):
            criterion = CRITERIA[int(answer) - 1]
            levels[criterion.key], notes[criterion.key] = ask_criterion(
                int(answer), criterion, levels[criterion.key], notes.get(criterion.key, "")
            )

    data = {
        "projeto": project,
        "grupo": group_name,
        "repositorio": repo.name,
        "integrantes": [m.registration for m in members],
        "data": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "niveis": levels,
        "observacoes": notes,
        "penalidades": penalties,
        "ajustes": {"ponto_de_partida": SCOPE_LEVELS[scope][0], "ia": ai, "lote": lot, "delta": delta[0]},
        "compreensao": comprehension,
        "G": g,
        "metricas": results,
    }
    target.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    groups_csv, discounts_csv = write_csv(args.saida)
    console.print(f"Gravado em [bold]{target}[/bold]; CSV atualizados: [bold]{groups_csv}[/bold] e [bold]{discounts_csv}[/bold].")
    return 0


if __name__ == "__main__":
    sys.exit(main())
