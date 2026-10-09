#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Triagem estática dos repositórios entregues, antes de executar qualquer um.

Ferramenta do professor. Só lê arquivos, nunca roda nada deles. Procura o
que um trabalho de Sudoku em Prolog + Elm não tem motivo para conter:
chamadas ao sistema, rede, leitura de arquivos fora do projeto, scripts de
instalação do npm, alterações no Makefile (que `make install` e `make test`
executam na sua máquina), dependências novas, arquivos binários, texto
ofuscado. Cada achado tem gravidade alta, média ou baixa, com arquivo,
linha e o trecho.

Uso:

    uv run scripts/auditar.py entregas/            # tudo o que baixar.py trouxe
    uv run scripts/auditar.py repo-a repo-b        # repositórios específicos
    uv run scripts/auditar.py entregas/ --json > auditoria.json

Arquivos idênticos aos do template são ignorados (o próprio scripts/ deste
projeto usa subprocess, por exemplo). Sai com código 1 se houver achado de
gravidade alta. Isto é uma triagem, não um veredito: leia os achados e os
diffs indicados antes de rodar metricas.py ou rubrica.py.
"""

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from dataclasses import asdict, dataclass
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent.parent
SKIP_DIRS = {"node_modules", ".venv", "elm-stuff", ".git", "dist", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"}
TEXT_SUFFIXES = {".py", ".pl", ".elm", ".js", ".ts", ".mjs", ".cjs", ".html", ".css", ".json", ".toml", ".md", ".txt", ".yml", ".yaml", ".sh", ".cfg", ".ini", ""}
BINARY_SUFFIXES = {".exe", ".dll", ".so", ".dylib", ".bin", ".pyc", ".pyd", ".class", ".jar", ".wasm", ".o", ".a"}
BIG_FILE = 2 * 1024 * 1024
HIGH, MEDIUM, LOW = "alta", "média", "baixa"

# Arquivos do template que o professor executa ou que controlam execução.
INFRA_FILES = {"Makefile", "frontend/vite.config.js", "frontend/package.json", "frontend/index.html", "frontend/src/main.js", "backend/pyproject.toml"}
EXPECTED_NPM_SCRIPTS = {"dev", "build", "preview"}

# (extensões, regex, gravidade, descrição). A regex é aplicada linha a linha.
PATTERNS: list[tuple[set[str], str, str, str]] = [
    # Python
    ({".py"}, r"\b(subprocess|os\.system|os\.popen|os\.exec\w*|os\.spawn\w*|pty\.|commands\.)", HIGH, "executa comandos do sistema"),
    ({".py"}, r"\b(eval|exec)\s*\(", HIGH, "avalia código dinamicamente"),
    ({".py"}, r"\b(__import__|importlib\.import_module|pickle\.loads?|marshal\.loads?|ctypes\b)", HIGH, "carrega código ou objetos em tempo de execução"),
    ({".py"}, r"\b(socket\.|smtplib|paramiko|ftplib|telnetlib)", HIGH, "abre conexões de rede de baixo nível"),
    ({".py"}, r"\b(shutil\.rmtree|os\.remove|os\.unlink|os\.rmdir|os\.removedirs|Path\([^)]*\)\.unlink)", HIGH, "apaga arquivos"),
    ({".py"}, r"\b(requests|urllib\.request|httpx|aiohttp)\b", MEDIUM, "faz requisições HTTP (o backend não precisa)"),
    ({".py"}, r"\b(os\.environ|os\.getenv|dotenv)", MEDIUM, "lê variáveis de ambiente"),
    ({".py"}, r"\b(Path\.home|expanduser|~/|/home/|/root/|/etc/|\.ssh|\.aws|\.gnupg|id_rsa)", HIGH, "acessa caminhos fora do projeto"),
    ({".py"}, r"\b(base64\.b64decode|codecs\.decode|bytes\.fromhex|zlib\.decompress)", MEDIUM, "decodifica dados embutidos"),
    ({".py"}, r"\bos\.chmod|\bstat\.S_I", MEDIUM, "muda permissões de arquivo"),
    # Prolog
    ({".pl"}, r"\b(shell|process_create|exec|win_exec)\s*\(", HIGH, "executa comandos do sistema"),
    ({".pl"}, r"\b(http_open|http_get|http_post|tcp_\w+|socket_\w+|http_client)", HIGH, "abre conexões de rede"),
    ({".pl"}, r"\b(delete_file|delete_directory|rename_file|make_directory|chmod)\s*\(", HIGH, "altera o sistema de arquivos"),
    ({".pl"}, r"\bopen\s*\(\s*['\"]?(/|~)", HIGH, "abre arquivo por caminho absoluto"),
    ({".pl"}, r"\b(setenv|getenv|unsetenv)\s*\(", MEDIUM, "mexe em variáveis de ambiente"),
    ({".pl"}, r":-\s*initialization\s*\(", MEDIUM, "roda algo ao carregar o arquivo (o swipl das métricas executa isso)"),
    ({".pl"}, r"\b(py_call|py_iter|py_func)\s*\(", HIGH, "chama Python a partir do Prolog"),
    ({".pl"}, r"\b(load_files|consult|ensure_loaded)\s*\(\s*['\"]?(https?:|/)", HIGH, "carrega código de fora do projeto"),
    ({".pl"}, r"\b(qsave_program|save_program)\s*\(", MEDIUM, "grava executável"),
    # JavaScript, HTML, CSS
    ({".js", ".mjs", ".cjs", ".ts", ".html"}, r"\b(eval\s*\(|new\s+Function\s*\()", HIGH, "avalia código dinamicamente"),
    ({".js", ".mjs", ".cjs", ".ts", ".html"}, r"\b(child_process|require\s*\(\s*['\"]fs['\"]|process\.env|Deno\.|Bun\.)", HIGH, "código de servidor no frontend (roda no vite/node)"),
    ({".js", ".mjs", ".cjs", ".ts", ".html"}, r"(fetch|XMLHttpRequest|WebSocket|sendBeacon|EventSource)\s*\(?\s*['\"`]?https?://", HIGH, "envia dados para um endereço externo"),
    ({".js", ".mjs", ".cjs", ".ts", ".html"}, r"document\.cookie|navigator\.(clipboard|geolocation|mediaDevices|credentials)", HIGH, "acessa cookies ou recursos sensíveis do navegador"),
    ({".js", ".mjs", ".cjs", ".ts"}, r"\batob\s*\(|\\x[0-9a-fA-F]{2}\\x[0-9a-fA-F]{2}|\\u00[0-9a-fA-F]{2}\\u00", MEDIUM, "texto codificado ou ofuscado"),
    ({".js", ".mjs", ".cjs", ".ts"}, r"\bimport\s*\(\s*['\"`]https?://", HIGH, "importa código de fora do projeto"),
    ({".html"}, r"<script[^>]+src\s*=\s*['\"]https?://", HIGH, "script externo no HTML"),
    ({".html"}, r"<(iframe|embed|object)\b", MEDIUM, "conteúdo embutido de terceiros"),
    ({".css"}, r"url\(\s*['\"]?https?://", MEDIUM, "recurso externo no CSS (pode rastrear acessos)"),
    # Elm
    ({".elm"}, r"^port\s+module\b|^port\s+\w+\s*:", MEDIUM, "ports Elm: confira o JavaScript correspondente"),
    # Makefile e shell
    ({"Makefile", ".sh", ".mk"}, r"\b(curl|wget|sudo|ssh|scp|nc|ncat|socat|chmod|chown|dd|mkfs|crontab)\b|rm\s+-rf|base64\s+-d|\|\s*(ba)?sh\b|python3?\s+-c|eval\b", HIGH, "comando perigoso em receita ou script de shell"),
    # Qualquer texto
    (set(TEXT_SUFFIXES), r"[A-Za-z0-9+/=]{200,}", MEDIUM, "sequência longa parecida com base64"),
    (set(TEXT_SUFFIXES), r"(?i)(password|senha|api[_-]?key|secret|token)\s*[=:]\s*['\"][^'\"]{8,}", MEDIUM, "possível credencial embutida"),
]
# Caracteres invisíveis ou de direção usados em "trojan source".
DANGEROUS_CHARS = {chr(c) for c in (0x200B, 0x200C, 0x200D, 0x2060, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF)}


@dataclass
class Finding:
    repo: str
    severity: str
    file: str
    line: int | None
    description: str
    snippet: str


def template_hashes() -> dict[str, str]:
    hashes = {}
    for path in TEMPLATE.rglob("*"):
        if path.is_file() and not SKIP_DIRS & set(path.relative_to(TEMPLATE).parts):
            hashes[str(path.relative_to(TEMPLATE))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def project_files(repo: Path) -> list[Path]:
    return sorted(p for p in repo.rglob("*") if p.is_file() and not SKIP_DIRS & set(p.relative_to(repo).parts))


def suffix_key(path: Path) -> set[str]:
    """Chaves usadas em PATTERNS: a extensão e, para o Makefile, o nome."""
    keys = {path.suffix.lower()}
    if path.name in ("Makefile", "makefile", "GNUmakefile"):
        keys.add("Makefile")
    return keys


def scan_text(repo: Path, path: Path, relative: str, findings: list[Finding]) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        findings.append(Finding(repo.name, MEDIUM, relative, None, "arquivo não é UTF-8 (binário ou codificação estranha)", ""))
        return
    keys = suffix_key(path)
    for number, line in enumerate(text.splitlines(), start=1):
        if any(c in DANGEROUS_CHARS for c in line):
            names = ", ".join(sorted({unicodedata.name(c, hex(ord(c))) for c in line if c in DANGEROUS_CHARS}))
            findings.append(Finding(repo.name, HIGH, relative, number, f"caractere invisível ou de direção ({names})", line.strip()[:100]))
        stripped = line.strip()
        if is_comment(stripped, keys):
            continue
        for suffixes, pattern, severity, description in PATTERNS:
            if keys & suffixes and re.search(pattern, line):
                findings.append(Finding(repo.name, severity, relative, number, description, stripped[:100]))


def is_comment(line: str, keys: set[str]) -> bool:
    if {".py", ".sh", ".toml", ".yml", ".yaml", "Makefile"} & keys and line.startswith("#"):
        return True
    if ".pl" in keys and line.startswith("%"):
        return True
    if {".js", ".ts", ".mjs", ".cjs", ".css"} & keys and line.startswith("//"):
        return True
    return ".elm" in keys and line.startswith("--")


def scan_manifests(repo: Path, findings: list[Finding]) -> None:
    package = repo / "frontend" / "package.json"
    if package.exists():
        try:
            data = json.loads(package.read_text(encoding="utf-8"))
            base = json.loads((TEMPLATE / "frontend" / "package.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            findings.append(Finding(repo.name, MEDIUM, "frontend/package.json", None, "package.json ilegível", ""))
        else:
            for name, command in data.get("scripts", {}).items():
                if name not in EXPECTED_NPM_SCRIPTS:
                    severity = HIGH if re.match(r"(pre|post)?(install|prepare|publish)", name) else MEDIUM
                    findings.append(Finding(repo.name, severity, "frontend/package.json", None, f"script npm {name!r} (roda no npm install)" if severity == HIGH else f"script npm {name!r} fora do padrão", command[:100]))
            known = set(base.get("devDependencies", {})) | set(base.get("dependencies", {}))
            new = (set(data.get("devDependencies", {})) | set(data.get("dependencies", {}))) - known
            if new:
                findings.append(Finding(repo.name, MEDIUM, "frontend/package.json", None, "dependências npm além do template", ", ".join(sorted(new))))
    pyproject = repo / "backend" / "pyproject.toml"
    if pyproject.exists():
        base_deps = set(re.findall(r'"([A-Za-z0-9_.\[\]-]+)[>=<~!]', (TEMPLATE / "backend" / "pyproject.toml").read_text(encoding="utf-8")))
        deps = set(re.findall(r'"([A-Za-z0-9_.\[\]-]+)[>=<~!]', pyproject.read_text(encoding="utf-8", errors="replace")))
        if deps - base_deps:
            findings.append(Finding(repo.name, MEDIUM, "backend/pyproject.toml", None, "dependências Python além do template", ", ".join(sorted(deps - base_deps))))


def scan_repo(repo: Path, base_hashes: dict[str, str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in project_files(repo):
        relative = str(path.relative_to(repo))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if base_hashes.get(relative) == digest:
            continue  # igual ao template
        if relative in INFRA_FILES and relative in base_hashes:
            findings.append(Finding(repo.name, LOW, relative, None, "arquivo de infraestrutura alterado em relação ao template: leia o diff", f"diff {TEMPLATE / relative} {path}"))
        if path.suffix.lower() in BINARY_SUFFIXES:
            findings.append(Finding(repo.name, HIGH, relative, None, "arquivo binário ou executável", ""))
            continue
        if path.stat().st_size > BIG_FILE:
            findings.append(Finding(repo.name, MEDIUM, relative, None, f"arquivo grande ({path.stat().st_size // 1024} KiB)", ""))
            continue
        if path.suffix.lower() in TEXT_SUFFIXES or path.name in ("Makefile", "makefile", "GNUmakefile"):
            scan_text(repo, path, relative, findings)
        elif path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".pdf", ".woff", ".woff2", ".ttf", ".lock"}:
            findings.append(Finding(repo.name, LOW, relative, None, "tipo de arquivo inesperado", ""))
    if (repo / ".github").exists():
        findings.append(Finding(repo.name, LOW, ".github", None, "há workflows ou configuração do GitHub (rodam lá, não aqui)", ""))
    scan_manifests(repo, findings)
    order = {HIGH: 0, MEDIUM: 1, LOW: 2}
    return sorted(findings, key=lambda f: (order[f.severity], f.file, f.line or 0))


def repositories(paths: list[Path]) -> list[Path]:
    repos = []
    for path in paths:
        if (path / ".git").exists() or (path / "RELATORIO.md").exists() or (path / "avaliacao-360").exists():
            repos.append(path)
        else:
            repos += sorted(p.parent for p in path.rglob(".git") if p.is_dir())
    return repos


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("caminhos", nargs="+", type=Path, help="repositórios, ou pastas que os contêm")
    parser.add_argument("--json", action="store_true", help="saída em JSON")
    args = parser.parse_args()

    base_hashes = template_hashes()
    repos = repositories([p.resolve() for p in args.caminhos])
    if not repos:
        print("nenhum repositório encontrado", file=sys.stderr)
        return 1
    results = {repo.name: scan_repo(repo, base_hashes) for repo in repos}

    if args.json:
        print(json.dumps({name: [asdict(f) for f in items] for name, items in results.items()}, ensure_ascii=False, indent=2))
    else:
        for name, items in results.items():
            counts = {s: sum(1 for f in items if f.severity == s) for s in (HIGH, MEDIUM, LOW)}
            print(f"== {name}: {counts[HIGH]} alta, {counts[MEDIUM]} média, {counts[LOW]} baixa")
            for f in items:
                where = f"{f.file}:{f.line}" if f.line else f.file
                print(f"  [{f.severity:<5}] {where}: {f.description}" + (f"\n          {f.snippet}" if f.snippet else ""))
            print()
    high = sum(1 for items in results.values() for f in items if f.severity == HIGH)
    print(f"{len(repos)} repositório(s); {high} achado(s) de gravidade alta." + (" Leia antes de executar qualquer coisa." if high else ""), file=sys.stderr)
    return 1 if high else 0


if __name__ == "__main__":
    sys.exit(main())
