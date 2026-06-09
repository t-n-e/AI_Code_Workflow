#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# createProject.sh – Multi-agent AI workspace bootstrap
#
# Použití:
#   bash createProject.sh [--reinit] [--develop] [--local-only] <target_dir> [zadani_projektu_md]
#   bash createProject.sh --update-agents  [--develop|--local-only] <target_dir>
#   bash createProject.sh --update-skills  [--develop|--local-only] <target_dir>
#   bash createProject.sh --update-process [--develop|--local-only] <target_dir>
#
# Argumenty:
#   target_dir           Cílový adresář projektu (může už existovat).
#   zadani_projektu_md   Volitelná cesta k vyplněnému zadání projektu (Markdown).
#                        Pokud není zadáno, použije se inline šablona.
# =============================================================================

usage() {
  cat >&2 <<'USAGE'
Použití:
  bash createProject.sh [--reinit] [--develop] [--local-only] <target_dir> [zadani_projektu_md]
  bash createProject.sh --update-agents  [--develop|--local-only] <target_dir>
  bash createProject.sh --update-skills  [--develop|--local-only] <target_dir>
  bash createProject.sh --update-process [--develop|--local-only] <target_dir>

Režimy source:
  default       Stáhne `agents/` a `tools/` z repo ref `stable`.
  --develop     Stáhne `agents/` a `tools/` z repo ref `develop`.
  --local-only  Použije lokální `./agents` a `./tools` vedle skriptu.

Selektivní update (nad existujícím projektem, nezahazuje workflow data):
  --update-agents   Přepíše agent definice a AGENTS.md soubory agentů.
  --update-skills   Přepíše .claude/commands/ (repo skills).
  --update-process  Přepíše .aiworkflow/AGENTS.md + CLAUDE.md/CODEX.md v kořeni projektu.

Poznámka k --reinit: zachová .aiworkflow/zadani_projektu.md pokud existuje a obsahuje obsah.

Příklady:
  bash createProject.sh ./my-project
  bash createProject.sh --develop ./my-project
  bash createProject.sh --local-only ./my-project
  bash createProject.sh ./already-cloned-repo
  bash createProject.sh --reinit ./already-cloned-repo
  bash createProject.sh ./my-project ./zadani_projektu.my-project.md
  bash createProject.sh --update-agents ./already-running-project
  bash createProject.sh --update-skills --develop ./already-running-project
  bash createProject.sh --update-process ./already-running-project
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE_REPO_URL="https://github.com/t-n-e/AI_Code_Workflow.git"
BOOTSTRAP_SOURCE_MODE="remote"
BOOTSTRAP_SOURCE_REF="stable"
BOOTSTRAP_SOURCE_REPO_URL="${AIWORKFLOW_SOURCE_REPO_URL:-}"
SOURCE_AGENT_DEFINITIONS_DIR=""
SOURCE_DEFINITION_PARSER=""
SOURCE_DASHBOARD_SCRIPT=""
SOURCE_SKILLS_DIR=""
SOURCE_TEMPLATES_DIR=""
SOURCE_WORKDIR=""
SOURCE_DESCRIPTION=""
AGENT_CATALOG_TABLE_FILE=""

die() {
  printf 'Chyba: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$AGENT_CATALOG_TABLE_FILE" && -f "$AGENT_CATALOG_TABLE_FILE" ]]; then
    rm -f "$AGENT_CATALOG_TABLE_FILE"
  fi

  if [[ -n "$SOURCE_WORKDIR" && -d "$SOURCE_WORKDIR" ]]; then
    rm -rf "$SOURCE_WORKDIR"
  fi
}
trap cleanup EXIT

slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/-\+/-/g; s/^-//; s/-$//'
}

# Nahrazení textu v souboru (portabilní – funguje na macOS i Linux)
safe_replace() {
  local file="$1" from="$2" to="$3"
  local tmp
  tmp="$(mktemp)"
  sed "s|${from}|${to}|g" "$file" > "$tmp" && mv "$tmp" "$file"
}

replace_placeholder_from_file() {
  local file="$1" placeholder="$2" replacement_file="$3"
  python3 - "$file" "$placeholder" "$replacement_file" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1])
placeholder = sys.argv[2]
replacement = Path(sys.argv[3]).read_text(encoding="utf-8")
content = target.read_text(encoding="utf-8")
target.write_text(content.replace(placeholder, replacement), encoding="utf-8")
PY
}

detect_source_repo_url() {
  if [[ -n "$BOOTSTRAP_SOURCE_REPO_URL" ]]; then
    printf '%s\n' "$BOOTSTRAP_SOURCE_REPO_URL"
    return 0
  fi

  if git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    if BOOTSTRAP_SOURCE_REPO_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)"; then
      printf '%s\n' "$BOOTSTRAP_SOURCE_REPO_URL"
      return 0
    fi
  fi

  printf '%s\n' "$DEFAULT_SOURCE_REPO_URL"
}

github_repo_slug_from_url() {
  local repo_url="$1"

  case "$repo_url" in
    https://github.com/*/*.git)
      printf '%s\n' "${repo_url#https://github.com/}" | sed 's/\.git$//'
      return 0
      ;;
    https://github.com/*/*)
      printf '%s\n' "${repo_url#https://github.com/}"
      return 0
      ;;
    git@github.com:*.git)
      printf '%s\n' "${repo_url#git@github.com:}" | sed 's/\.git$//'
      return 0
      ;;
    git@github.com:*)
      printf '%s\n' "${repo_url#git@github.com:}"
      return 0
      ;;
    ssh://git@github.com/*/*.git)
      printf '%s\n' "${repo_url#ssh://git@github.com/}" | sed 's/\.git$//'
      return 0
      ;;
    ssh://git@github.com/*/*)
      printf '%s\n' "${repo_url#ssh://git@github.com/}"
      return 0
      ;;
  esac

  return 1
}

gh_auth_available() {
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

github_ssh_url_from_url() {
  local repo_url="$1"
  local repo_slug

  repo_slug="$(github_repo_slug_from_url "$repo_url")" || return 1
  printf 'git@github.com:%s.git\n' "$repo_slug"
}

clone_github_source_with_ssh() {
  local repo_url="$1"
  local ref="$2"
  local checkout_dir="$3"
  local ssh_repo_url

  ssh_repo_url="$(github_ssh_url_from_url "$repo_url")" || return 1

  if [[ "$ssh_repo_url" == "$repo_url" ]]; then
    return 1
  fi

  printf '▶ GitHub SSH fallback přes %s\n' "$ssh_repo_url"
  env GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$ref" --single-branch "$ssh_repo_url" "$checkout_dir" >/dev/null 2>&1
}

clone_github_source_with_gh() {
  local repo_url="$1"
  local ref="$2"
  local checkout_dir="$3"
  local repo_slug

  repo_slug="$(github_repo_slug_from_url "$repo_url")" || return 1
  gh_auth_available || return 1

  printf '▶ GitHub auth fallback přes gh pro %s\n' "$repo_slug"
  gh repo clone "$repo_slug" "$checkout_dir" -- --depth 1 --branch "$ref" --single-branch >/dev/null 2>&1
}

first_nonempty_line() {
  local file="$1"
  awk 'NF { print; exit }' "$file"
}

use_local_source_assets() {
  SOURCE_AGENT_DEFINITIONS_DIR="$SCRIPT_DIR/agents"
  SOURCE_DEFINITION_PARSER="$SCRIPT_DIR/tools/parse_agent_definitions.py"
  SOURCE_DASHBOARD_SCRIPT="$SCRIPT_DIR/tools/gen-dashboard.py"
  SOURCE_SKILLS_DIR="$SCRIPT_DIR/skills"
  SOURCE_TEMPLATES_DIR="$SCRIPT_DIR/templates"
  SOURCE_DESCRIPTION="lokální ./agents a ./tools"
}

fetch_remote_source_assets() {
  local repo_url="$1"
  local ref="$2"
  local checkout_dir
  local clone_log
  local clone_error

  SOURCE_WORKDIR="$(mktemp -d)"
  checkout_dir="$SOURCE_WORKDIR/repo"
  clone_log="$SOURCE_WORKDIR/git-clone.log"

  printf '▶ Stahuji bootstrap source z %s (ref %s)\n' "$repo_url" "$ref"
  if ! env GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$ref" --single-branch "$repo_url" "$checkout_dir" >/dev/null 2>"$clone_log"; then
    if ! clone_github_source_with_ssh "$repo_url" "$ref" "$checkout_dir" \
      && ! clone_github_source_with_gh "$repo_url" "$ref" "$checkout_dir"; then
      clone_error="$(first_nonempty_line "$clone_log" || true)"
      if [[ -n "$clone_error" ]]; then
        die "Nepodařilo se stáhnout ref '$ref' z repo '$repo_url'. Git hlásil: $clone_error Pro offline režim použij --local-only a měj lokální ./agents a ./tools."
      fi
      die "Nepodařilo se stáhnout ref '$ref' z repo '$repo_url'. Pro offline režim použij --local-only a měj lokální ./agents a ./tools."
    fi
  fi

  SOURCE_AGENT_DEFINITIONS_DIR="$checkout_dir/agents"
  SOURCE_DEFINITION_PARSER="$checkout_dir/tools/parse_agent_definitions.py"
  SOURCE_DASHBOARD_SCRIPT="$checkout_dir/tools/gen-dashboard.py"
  SOURCE_SKILLS_DIR="$checkout_dir/skills"
  SOURCE_TEMPLATES_DIR="$checkout_dir/templates"
  SOURCE_DESCRIPTION="repo $repo_url (ref $ref)"
}

initialize_source_assets() {
  if [[ "$BOOTSTRAP_SOURCE_MODE" == "local" ]]; then
    use_local_source_assets
    return 0
  fi

  BOOTSTRAP_SOURCE_REPO_URL="$(detect_source_repo_url)"

  fetch_remote_source_assets "$BOOTSTRAP_SOURCE_REPO_URL" "$BOOTSTRAP_SOURCE_REF"
}

ensure_ignored() {
  local gitignore="$1"
  local marker="# --- aiworkflow bootstrap ---"

  if [[ -f "$gitignore" ]] && grep -Fq "$marker" "$gitignore"; then
    return 0
  fi

  mkdir -p "$(dirname "$gitignore")"
  [[ -f "$gitignore" ]] || : > "$gitignore"

  if [[ -s "$gitignore" ]]; then
    printf '\n' >> "$gitignore"
  fi

  cat >> "$gitignore" <<'EOF'
# --- aiworkflow bootstrap ---
.aiworkflow/
.claude/
.claude-local/
AGENTS.md
CLAUDE.md
CODEX.md
EOF
}

write_root_entrypoints() {
  cat > "$ROOT_DIR/AGENTS.md" <<'EOF'
# AI Workflow Entry Point

Source of truth for the workflow lives under `.aiworkflow/`.

## Start Here
1. Read `.aiworkflow/AGENTS.md`
2. Treat every workflow path as rooted under `.aiworkflow/`
3. If you are operating as the workflow entrypoint/orchestrator, also read `.aiworkflow/agents/orchestrator/AGENTS.md` and treat yourself as one of the agents
4. Keep project code outside `.aiworkflow/`; use `.aiworkflow/` only for orchestration, prompts, notes, and generated workflow artifacts

## Repo Skills Catalog
Repo skills are implemented as command files under `.claude/commands/`.
Treat this section as a lightweight index, not a second instruction layer.

### How to use this catalog
- Load a full command file only when the user explicitly invokes that command or when the task is an obvious match for that workflow.
- Do not preload all files under `.claude/commands/`; read only the command you are about to use.
- When a command file is loaded, follow that file as the source of truth for the workflow details.

### Available repo skills
- `/init-iteration`
  Purpose: initialize a new iteration (branch, plan.md, dashboard, quality gate).
  Path: `.claude/commands/init-iteration.md`

- `/dispatch-agent`
  Purpose: dispatch workflow work to one or more agents.
  Path: `.claude/commands/dispatch-agent.md`

- `/close-iteration`
  Purpose: close the active iteration workflow.
  Path: `.claude/commands/close-iteration.md`

### Catalog Guardrail
- If a repo command is added, renamed, or removed under `.claude/commands/`, update this catalog in the same change set.

## Git & PR Rules
- Do not add `Co-Authored-By: Claude`, `Co-Authored-By: Anthropic`, or any similar AI attribution to commit messages or PR descriptions.
EOF

  ln -sfn AGENTS.md "$ROOT_DIR/CLAUDE.md"
  ln -sfn AGENTS.md "$ROOT_DIR/CODEX.md"
}

install_project_skills() {
  [[ -d "$SOURCE_SKILLS_DIR" ]] || return 0

  local commands_dir="$ROOT_DIR/.claude/commands"
  local workflow_scripts_dir="$WORKFLOW_DIR/orchestration/scripts"
  local installed=0

  mkdir -p "$commands_dir" "$workflow_scripts_dir"

  while IFS= read -r -d '' skill_file; do
    local skill_name skill_scripts_dir
    skill_name="$(basename "$(dirname "$skill_file")")"
    cp "$skill_file" "$commands_dir/${skill_name}.md"

    skill_scripts_dir="$(dirname "$skill_file")/scripts"
    if [[ -d "$skill_scripts_dir" ]]; then
      find "$skill_scripts_dir" -maxdepth 1 -type f -print0 \
        | xargs -0 -I{} install -m 755 {} "$workflow_scripts_dir/"
    fi

    installed=$(( installed + 1 ))
  done < <(find "$SOURCE_SKILLS_DIR" -mindepth 2 -maxdepth 2 -name 'SKILL.md' -print0 | sort -z)

  if [[ "$installed" -gt 0 ]]; then
    printf '▶ Nainstalováno %d projektových skill(s) do .claude/commands/\n' "$installed"
  fi
}

install_coldstart_hook() {
  local hooks_dir="$ROOT_DIR/.claude/hooks"
  local claude_dir="$ROOT_DIR/.claude"
  local bootstrap_version_file="$hooks_dir/.bootstrap-version"

  # Najdi zdrojový adresář s coldstart šablonami
  # Priorita: SOURCE_TEMPLATES_DIR (může být remote checkout nebo lokální templates/)
  # Fallback: .aiworkflow/implementation/templates/ (lokální repo – pro případ local-only)
  local tmpl_src=""
  if [[ -n "$SOURCE_TEMPLATES_DIR" && -f "$SOURCE_TEMPLATES_DIR/coldstart.sh" ]]; then
    tmpl_src="$SOURCE_TEMPLATES_DIR"
  elif [[ -f "$SCRIPT_DIR/.aiworkflow/implementation/templates/coldstart.sh" ]]; then
    tmpl_src="$SCRIPT_DIR/.aiworkflow/implementation/templates"
  fi

  if [[ -z "$tmpl_src" ]]; then
    printf 'Varování: coldstart.sh nebyl nalezen, přeskakuji coldstart hook instalaci.\n' >&2
    return 0
  fi

  mkdir -p "$hooks_dir"

  # Instaluj coldstart.sh
  cp "$tmpl_src/coldstart.sh" "$hooks_dir/coldstart.sh"
  chmod +x "$hooks_dir/coldstart.sh"

  # Instaluj no-hooks.json
  if [[ -n "$SOURCE_TEMPLATES_DIR" && -f "$SOURCE_TEMPLATES_DIR/no-hooks.json" ]]; then
    cp "$SOURCE_TEMPLATES_DIR/no-hooks.json" "$claude_dir/no-hooks.json"
  elif [[ -n "$tmpl_src" && -f "$tmpl_src/no-hooks.json" ]]; then
    cp "$tmpl_src/no-hooks.json" "$claude_dir/no-hooks.json"
  else
    printf '{"hooks":{"SessionStart":[]}}\n' > "$claude_dir/no-hooks.json"
  fi

  # Merguj settings-hook.json do .claude/settings.json
  local hook_snippet=""
  if [[ -f "$SOURCE_TEMPLATES_DIR/settings-hook.json" ]]; then
    hook_snippet="$SOURCE_TEMPLATES_DIR/settings-hook.json"
  elif [[ -f "$tmpl_src/settings-hook.json" ]]; then
    hook_snippet="$tmpl_src/settings-hook.json"
  fi

  local settings_file="$claude_dir/settings.json"
  if [[ -n "$hook_snippet" ]]; then
    if [[ -f "$settings_file" ]]; then
      # Merguj hook sekci do existujícího settings.json (zachovej ostatní klíče)
      python3 - "$settings_file" "$hook_snippet" <<'PY'
import json, sys
from pathlib import Path

settings_path = Path(sys.argv[1])
snippet_path = Path(sys.argv[2])

existing = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.exists() else {}
snippet = json.loads(snippet_path.read_text(encoding="utf-8"))

# Merguj pouze hooks.SessionStart
existing.setdefault("hooks", {})
existing["hooks"]["SessionStart"] = snippet["hooks"]["SessionStart"]

settings_path.write_text(json.dumps(existing, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
    else
      cp "$hook_snippet" "$settings_file"
    fi
  fi

  # Zaloguj bootstrap verzi
  printf 'bootstrap-source: %s\ntimestamp: %s\n' "$SOURCE_DESCRIPTION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$bootstrap_version_file"

  printf '▶ Coldstart hook nainstalován do %s\n' "$hooks_dir"
}

write_lore_scripts() {
  local lore_dir="$WORKFLOW_DIR/scripts/lore"
  mkdir -p "$lore_dir/hooks"

  # VERSION
  printf '1.0.0\n' > "$lore_dir/VERSION"

  # lore.sh (iter-022 fix: project→projects/, iconv patch, slug guard)
  cat > "$lore_dir/lore.sh" <<'LORE_SH_END'
#!/usr/bin/env bash
# lore – unified CLI pro memory-neur
# Instalace: make install-skills
# Verze: viz ~/.local/lib/lore/VERSION nebo lore --version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_LIB="${HOME}/.local/lib/lore"
LORE_VERSION="$(cat "${LORE_LIB}/VERSION" 2>/dev/null || cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")"
LORE_DIR="${LORE_PATH:-$HOME/.lore}"

usage() {
  cat <<EOF
lore – memory-neur CLI v${LORE_VERSION}

Použití: lore <subcommand> [argumenty]

Subcommandů:
  init      [--remote <url>] [--update-remote]  Inicializuj ~/.lore/ jako git repo
  health    [--json]                             Zkontroluj stav ~/.lore/
  doctor                                         Interaktivní diagnostika
  git       <git-args>                           Git operace nad ~/.lore/
  new       <typ> <název>                        Vytvoř nový záznam (lessons/processes/clients/projects/…)
  rescue    [--yes] [--dry-run]                  Zachraň existující ~/.lore/ bez git repo

Volby:
  --version   Zobraz verzi
  --help      Zobraz tuto nápovědu

Příklady:
  lore init --remote git@github.com:user/lore.git
  lore health --json
  lore git pull
  lore new knowledge "git workflow tipy"
EOF
}


# ---------------------------------------------------------------------------
# Stub funkce pro T-006/T-007/T-008 – přepsat v příslušných iteracích
# ---------------------------------------------------------------------------

# EXTEND-T-006: implementováno v T-006
lore_health() {
  bash "${LORE_LIB}/health-check.sh" "$@"
}

# EXTEND-T-006: implementováno v T-006
lore_doctor() {
  bash "${LORE_LIB}/doctor.sh" "$@"
}

# EXTEND-T-007: implementováno v T-007
lore_git() {
  bash "${LORE_LIB}/lore-git-wrapper.sh" "$@"
}

# EXTEND-T-008: implementováno v T-008
lore_rescue() {
  bash "${LORE_LIB}/rescue.sh" "$@"
}

# ---------------------------------------------------------------------------
# lore init – EXTEND-T-009: plná idempotentní implementace
# ---------------------------------------------------------------------------

lore_init() {
  local remote=""
  local update_remote=false
  local local_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) remote="$2"; shift 2 ;;
      --update-remote) update_remote=true; shift ;;
      --local-only) local_only=true; shift ;;
      *) echo "[lore] Neznámý argument: $1" >&2; exit 1 ;;
    esac
  done

  echo "[lore init] Inicializace ${LORE_DIR}..."

  # === Krok 1: Idempotentní kontroly existence ===
  # ~/.lore/ existuje jako soubor (ne adresář) → fatální chyba
  if [[ -e "${LORE_DIR}" && ! -d "${LORE_DIR}" ]]; then
    echo "[lore init] ERR: ${LORE_DIR} existuje jako soubor, nelze inicializovat." >&2
    echo "[lore init] Odstraň ho ručně nebo použij jiný LORE_PATH." >&2
    exit 1
  fi

  # ~/.lore/ existuje bez .git/ → nebezpečný stav, odkazuj na rescue
  if [[ -d "${LORE_DIR}" && ! -d "${LORE_DIR}/.git" ]]; then
    echo "[lore init] WARN: ${LORE_DIR} existuje ale neobsahuje git repo." >&2
    echo "[lore init] Existující soubory by mohly být přepsány. Spusť nejdřív: lore rescue" >&2
    exit 1
  fi

  # === Krok 2: Vytvoř adresářovou strukturu ===
  # Idempotentní – mkdir -p nevadí pokud existuje
  mkdir -p \
    "${LORE_DIR}/lessons" \
    "${LORE_DIR}/processes" \
    "${LORE_DIR}/clients" \
    "${LORE_DIR}/projects" \
    "${LORE_DIR}/decisions" \
    "${LORE_DIR}/sessions" \
    "${LORE_DIR}/knowledge" \
    "${LORE_DIR}/scripts" \
    "${LORE_DIR}/scripts/hooks"

  # === Krok 3: Git init ===
  if [[ ! -d "${LORE_DIR}/.git" ]]; then
    git -C "${LORE_DIR}" init --quiet
    echo "[lore init] git repo inicializováno v ${LORE_DIR}"
  else
    echo "[lore init] [SKIP] git repo již existuje v ${LORE_DIR}"
  fi

  # === Krok 4: Remote nastavení ===
  if [[ "${local_only}" == true && -z "${remote}" ]]; then
    # Explicitní local-only mode
    touch "${LORE_DIR}/.lore-local-only"
    echo "[lore init] Local-only mode – remote není nastaven. Pro sync přidej: lore init --remote <url>"
  elif [[ -z "${remote}" ]]; then
    # Žádný remote nezadán → local-only marker
    touch "${LORE_DIR}/.lore-local-only"
    echo "[lore init] Local-only mode – remote není nastaven. Pro sync přidej: lore init --remote <url>"
  else
    # Remote byl zadán → odstraň local-only marker pokud existuje
    rm -f "${LORE_DIR}/.lore-local-only"

    local existing_remote=""
    existing_remote="$(git -C "${LORE_DIR}" remote get-url origin 2>/dev/null || true)"

    if [[ -z "${existing_remote}" ]]; then
      # Remote neexistuje → přidej ho
      git -C "${LORE_DIR}" remote add origin "${remote}"
      echo "[lore init] Remote nastaven na ${remote}"
    elif [[ "${existing_remote}" == "${remote}" ]]; then
      # Remote je stejný → přeskoč
      echo "[lore init] [SKIP] git repo a remote již nastaveny (${remote})"
    elif [[ "${update_remote}" == true ]]; then
      # Jiný remote + --update-remote → přepiš
      git -C "${LORE_DIR}" remote set-url origin "${remote}"
      echo "[lore init] Remote aktualizován: ${existing_remote} → ${remote}"
    else
      # Jiný remote bez --update-remote → WARN + exit 1
      echo "[lore init] WARN: remote je již nastaven na ${existing_remote}." >&2
      echo "[lore init] Pro přepsání použij: lore init --remote ${remote} --update-remote" >&2
      exit 1
    fi

    # === Krok 5: WSL2 / GCM detekce ===
    local is_wsl2=false
    local has_gcm=false
    if [[ -f /proc/version ]] && grep -qi "microsoft" /proc/version 2>/dev/null; then
      is_wsl2=true
    fi
    if git config --global credential.helper 2>/dev/null | grep -q "manager"; then
      has_gcm=true
    fi
    # Detekuj HTTPS remote (ne SSH)
    if [[ "${is_wsl2}" == true && "${has_gcm}" == true && "${remote}" == https://* ]]; then
      echo "[lore init] WARN: WSL2 + Windows Credential Manager detekován."
      echo "[lore init] Pokud máš více GitHub účtů, GCM může mixovat credentials."
      echo "[lore init] Doporučení: Použij SSH remote místo HTTPS. Viz: docs/setup-credentials.md"
    fi
  fi

  # === Krok 6: Instalace hooks ===
  # Kopírování skriptů do ~/.lore/scripts/ PŘED voláním install-hooks.sh
  # (impl.sh musí být na místě PŘED shimem)
  local hooks_src="${LORE_LIB}/hooks"
  if [[ -d "${hooks_src}" ]]; then
    if [[ -f "${hooks_src}/pre-commit-impl.sh" ]]; then
      cp "${hooks_src}/pre-commit-impl.sh" "${LORE_DIR}/scripts/hooks/pre-commit-impl.sh"
      chmod +x "${LORE_DIR}/scripts/hooks/pre-commit-impl.sh"
    fi
    if [[ -f "${hooks_src}/pre-commit-shim.sh" ]]; then
      cp "${hooks_src}/pre-commit-shim.sh" "${LORE_DIR}/scripts/hooks/pre-commit-shim.sh"
      chmod +x "${LORE_DIR}/scripts/hooks/pre-commit-shim.sh"
    fi
  fi

  # Zkopíruj validate-all.sh
  local validate_src="${LORE_LIB}/validate-all.sh"
  if [[ -f "${validate_src}" ]]; then
    cp "${validate_src}" "${LORE_DIR}/scripts/validate-all.sh"
    chmod +x "${LORE_DIR}/scripts/validate-all.sh"
  fi

  # Zavolej install-hooks.sh (pokud existuje a ~/.lore/.git/ existuje)
  local install_hooks_sh="${LORE_LIB}/install-hooks.sh"
  if [[ -f "${install_hooks_sh}" && -d "${LORE_DIR}/.git" ]]; then
    bash "${install_hooks_sh}"
  fi

  echo "[lore init] Dokončeno."
}

# ---------------------------------------------------------------------------
# lore new
# ---------------------------------------------------------------------------

lore_new() {
  local type="${1:-knowledge}"
  local title="${2:-}"

  if [[ -z "${title}" ]]; then
    echo "[lore] Použití: lore new <typ> <název>" >&2
    echo "[lore] Typy: gotcha | anti-pattern | heuristika | principle | preference | decision-minor" >&2
    echo "[lore]       workflow | ritual | client | project | decision | session | knowledge" >&2
    exit 1
  fi

  if [[ ! -d "${LORE_DIR}" ]]; then
    echo "[lore] ~/.lore/ neexistuje. Spusť nejprve: lore init" >&2
    exit 1
  fi

  # Mapování typ → složka
  local target_dir
  case "${type}" in
    gotcha|anti-pattern|heuristika|principle|preference|decision-minor|lesson)
      target_dir="${LORE_DIR}/lessons" ;;
    workflow|ritual|process)
      target_dir="${LORE_DIR}/processes" ;;
    client)
      target_dir="${LORE_DIR}/clients" ;;
    project)
      target_dir="${LORE_DIR}/projects" ;;
    decision)
      target_dir="${LORE_DIR}/decisions" ;;
    session)
      target_dir="${LORE_DIR}/sessions" ;;
    *)
      target_dir="${LORE_DIR}/knowledge" ;;
  esac
  mkdir -p "${target_dir}"

  local date
  date="$(date +%Y-%m-%d)"

  local slug
  if command -v iconv >/dev/null 2>&1; then
    slug="$(echo "${title}" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-\+//;s/-\+$//;s/-\+/-/g')"
  else
    # fallback bez iconv – alespoň základní sanitizace
    slug="$(echo "${title}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')"
  fi

  # Guard: prázdný slug
  if [[ -z "${slug}" ]]; then
    slug="entry-$(date +%s)"
  fi

  local filename="${date}-${slug}.md"
  local filepath="${target_dir}/${filename}"

  if [[ -f "${filepath}" ]]; then
    echo "[lore] Soubor již existuje: ${filepath}" >&2
    exit 1
  fi

  cat > "${filepath}" <<EOF
---
schema_version: "1"
title: ${title}
type: ${type}
date: ${date}
tags: []
---

# ${title}

<!-- Sem zapiš obsah -->
EOF

  echo "[lore] Vytvořeno: ${filepath}"
}

# ---------------------------------------------------------------------------
# Dispatch subcommandů
# ---------------------------------------------------------------------------

case "${1:-}" in
  --version|-v)
    echo "lore ${LORE_VERSION}"
    ;;
  --help|-h|"")
    usage
    ;;
  init)
    shift
    lore_init "$@"
    ;;
  health)
    # EXTEND-T-006: implementováno v T-006
    shift
    lore_health "$@"
    ;;
  doctor)
    # EXTEND-T-006: implementováno v T-006
    shift
    lore_doctor "$@"
    ;;
  git)
    # EXTEND-T-007: implementováno v T-007
    shift
    lore_git "$@"
    ;;
  new)
    shift
    lore_new "$@"
    ;;
  rescue)
    # EXTEND-T-008: implementováno v T-008
    shift
    lore_rescue "$@"
    ;;
  *)
    echo "[lore] Neznámý subcommand: ${1}" >&2
    echo "Spusť 'lore --help' pro nápovědu." >&2
    exit 1
    ;;
esac
LORE_SH_END
  chmod +x "$lore_dir/lore.sh"

  # health-check.sh (iter-022 fix: Check 11 required_dirs)
  cat > "$lore_dir/health-check.sh" <<'HEALTH_CHECK_END'
#!/usr/bin/env bash
# health-check.sh – kontrola stavu ~/.lore/
# Nikdy nevolá zakázané git subcommands – jen standardní: git log, git status, git remote, git rev-list
# Výstup: HEALTHY / WARN / BROKEN
# --json flag pro strojový výstup (agent use case)
# --brief flag pro jednořádkový stav (scripting)

set -euo pipefail

LORE_DIR="${LORE_PATH:-$HOME/.lore}"
JSON_OUTPUT=false
BRIEF_OUTPUT=false
LOCAL_ONLY_MODE=false
LORE_VERSION="$(cat "$(dirname "$0")/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"

# Parsuj argumenty
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  JSON_OUTPUT=true;  shift ;;
    --brief) BRIEF_OUTPUT=true; shift ;;
    *) shift ;;
  esac
done

# Detekuj local-only mode
if [[ -f "${LORE_DIR}/.lore-local-only" ]]; then
  LOCAL_ONLY_MODE=true
fi

# Výsledky checků: pole stringů "id|name|status|message"
checks=()

# Celkový stav: začínáme HEALTHY, escalujeme na WARN nebo BROKEN
overall="HEALTHY"

set_overall() {
  local new_level="$1"
  if [[ "${overall}" == "HEALTHY" && ( "${new_level}" == "WARN" || "${new_level}" == "BROKEN" ) ]]; then
    overall="${new_level}"
  elif [[ "${overall}" == "WARN" && "${new_level}" == "BROKEN" ]]; then
    overall="${new_level}"
  fi
}

add_check() {
  local id="$1"
  local name="$2"
  local status="$3"   # OK | WARN | BROKEN | SKIP
  local message="${4:-}"
  checks+=("${id}|${name}|${status}|${message}")
  if [[ "${status}" == "WARN" ]]; then
    set_overall "WARN"
  elif [[ "${status}" == "BROKEN" ]]; then
    set_overall "BROKEN"
  fi
}

# ---------------------------------------------------------------------------
# Check 1: LORE_BYPASS – musí být PRVNÍ (viditelné okamžitě)
# ---------------------------------------------------------------------------
if [[ -n "${LORE_BYPASS:-}" ]]; then
  add_check 1 "lore_bypass" "WARN" "LORE_BYPASS=${LORE_BYPASS} je nastaven globálně"
else
  add_check 1 "lore_bypass" "OK" ""
fi

# ---------------------------------------------------------------------------
# Check 2: ~/.lore/ existuje
# ---------------------------------------------------------------------------
if [[ -d "${LORE_DIR}" ]]; then
  add_check 2 "lore_dir_exists" "OK" ""
else
  add_check 2 "lore_dir_exists" "BROKEN" "${LORE_DIR} neexistuje"
fi

# ---------------------------------------------------------------------------
# Check 3: je git repo
# ---------------------------------------------------------------------------
if [[ -d "${LORE_DIR}/.git" ]]; then
  add_check 3 "git_repo" "OK" ""
else
  add_check 3 "git_repo" "BROKEN" "není git repo (.git/ chybí)"
fi

# ---------------------------------------------------------------------------
# Check 4: má aspoň 1 commit
# ---------------------------------------------------------------------------
if git -C "${LORE_DIR}" log -1 2>/dev/null | grep -q .; then
  add_check 4 "has_commit" "OK" ""
else
  add_check 4 "has_commit" "BROKEN" "prázdný repo (žádný commit)"
fi

# ---------------------------------------------------------------------------
# Check 5: remote nastaven (přeskočit v local-only mode)
# ---------------------------------------------------------------------------
if [[ "${LOCAL_ONLY_MODE}" == "true" ]]; then
  add_check 5 "remote_configured" "SKIP" "local-only mode"
else
  remote_url="$(git -C "${LORE_DIR}" remote get-url origin 2>/dev/null || echo "")"
  if [[ -n "${remote_url}" ]]; then
    add_check 5 "remote_configured" "OK" "${remote_url}"
  else
    add_check 5 "remote_configured" "WARN" "remote není nastaven (local-only mode)"
  fi
fi

# ---------------------------------------------------------------------------
# Check 6: není drift (working tree čistý)
# ---------------------------------------------------------------------------
dirty="$(git -C "${LORE_DIR}" status --porcelain 2>/dev/null || echo "")"
if [[ -z "${dirty}" ]]; then
  add_check 6 "working_tree_clean" "OK" ""
else
  add_check 6 "working_tree_clean" "WARN" "working tree není čistý (dirty)"
fi

# ---------------------------------------------------------------------------
# Check 7: není za remote (přeskočit v local-only mode)
# ---------------------------------------------------------------------------
if [[ "${LOCAL_ONLY_MODE}" == "true" ]]; then
  add_check 7 "in_sync_with_remote" "SKIP" "local-only mode"
else
  ahead_count="$(git -C "${LORE_DIR}" rev-list HEAD..@{u} 2>/dev/null | wc -l | tr -d ' ')" || ahead_count="0"
  if [[ "${ahead_count}" == "0" ]]; then
    add_check 7 "in_sync_with_remote" "OK" ""
  else
    add_check 7 "in_sync_with_remote" "WARN" "${ahead_count} nepushnuté commity"
  fi
fi

# ---------------------------------------------------------------------------
# Check 8: lore v PATH
# ---------------------------------------------------------------------------
lore_path="$(which lore 2>/dev/null || echo "")"
if [[ -n "${lore_path}" ]]; then
  add_check 8 "lore_in_path" "OK" "${lore_path}"
else
  add_check 8 "lore_in_path" "BROKEN" "lore není v PATH"
fi

# ---------------------------------------------------------------------------
# Check 9: lore git funguje
# ---------------------------------------------------------------------------
if lore_git_ver="$(lore git --version 2>/dev/null)"; then
  add_check 9 "lore_git_works" "OK" "${lore_git_ver}"
else
  add_check 9 "lore_git_works" "BROKEN" "lore git nefunguje"
fi

# ---------------------------------------------------------------------------
# Check 10: PATH conflict – lore není stíněn jinou instalací
# ---------------------------------------------------------------------------
lore_bin="$(which lore 2>/dev/null || echo "")"
expected_prefix="${HOME}/.local/bin"
if [[ -z "${lore_bin}" ]]; then
  # lore není vůbec v PATH – BROKEN je už v check 8
  add_check 10 "path_no_conflict" "SKIP" "lore není v PATH (viz check 8)"
elif echo "${lore_bin}" | grep -q "^${expected_prefix}"; then
  add_check 10 "path_no_conflict" "OK" ""
else
  add_check 10 "path_no_conflict" "WARN" "jiný lore stínuje ~/.local/bin: ${lore_bin}"
fi

# ---------------------------------------------------------------------------
# Check 11: required subdirectories existují
# ---------------------------------------------------------------------------
required_dirs=("lessons" "processes" "clients" "projects" "decisions" "knowledge")
missing_dirs=()
for d in "${required_dirs[@]}"; do
  if [[ ! -d "${LORE_DIR}/${d}" ]]; then
    missing_dirs+=("${d}")
  fi
done
if [[ ${#missing_dirs[@]} -eq 0 ]]; then
  add_check 11 "required_dirs" "OK" ""
else
  add_check 11 "required_dirs" "WARN" "chybí adresáře: ${missing_dirs[*]} – spusť: lore init"
fi

# ---------------------------------------------------------------------------
# Výstup
# ---------------------------------------------------------------------------

if [[ "${BRIEF_OUTPUT}" == "true" ]]; then
  # Jednořádkový stav pro scripting
  printf '%s\n' "${overall}"
elif [[ "${JSON_OUTPUT}" == "true" ]]; then
  # JSON výstup se status, version, timestamp, checks
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")"
  printf '{\n'
  printf '  "status": "%s",\n' "${overall}"
  printf '  "version": "%s",\n' "${LORE_VERSION}"
  printf '  "timestamp": "%s",\n' "${timestamp}"
  printf '  "lore_dir": "%s",\n' "${LORE_DIR}"
  printf '  "checks": [\n'
  total=${#checks[@]}
  idx=0
  for entry in "${checks[@]}"; do
    IFS='|' read -r cid cname cstatus cmsg <<< "${entry}"
    idx=$((idx + 1))
    comma=""
    if [[ ${idx} -lt ${total} ]]; then
      comma=","
    fi
    if [[ -n "${cmsg}" ]]; then
      printf '    {"id": %s, "name": "%s", "status": "%s", "message": "%s"}%s\n' \
        "${cid}" "${cname}" "${cstatus}" "${cmsg}" "${comma}"
    else
      printf '    {"id": %s, "name": "%s", "status": "%s"}%s\n' \
        "${cid}" "${cname}" "${cstatus}" "${comma}"
    fi
  done
  printf '  ]\n'
  printf '}\n'
else
  # Lidský výstup
  printf 'lore health\n'
  printf '──────────────────────────────\n'
  for entry in "${checks[@]}"; do
    IFS='|' read -r cid cname cstatus cmsg <<< "${entry}"
    case "${cstatus}" in
      OK)     icon="✓" ;;
      WARN)   icon="⚠" ;;
      BROKEN) icon="✗" ;;
      SKIP)   icon="–" ;;
      *)      icon="?" ;;
    esac
    if [[ -n "${cmsg}" ]]; then
      printf '%s %s (%s)\n' "${icon}" "${cname}" "${cmsg}"
    else
      printf '%s %s\n' "${icon}" "${cname}"
    fi
  done
  printf '──────────────────────────────\n'
  printf 'Stav: %s\n' "${overall}"
fi

# Exit kódy dle designu: HEALTHY=0, WARN=1, BROKEN=2
case "${overall}" in
  HEALTHY) exit 0 ;;
  WARN)    exit 1 ;;
  BROKEN)  exit 2 ;;
esac
HEALTH_CHECK_END
  chmod +x "$lore_dir/health-check.sh"

  # doctor.sh
  cat > "$lore_dir/doctor.sh" <<'DOCTOR_SH_END'
#!/usr/bin/env bash
# doctor.sh – interaktivní diagnostika (brew doctor styl)
# Volá health-check.sh a pro každý problém navrhuje řešení

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK="${SCRIPT_DIR}/health-check.sh"

if [[ ! -f "${HEALTH_CHECK}" ]]; then
  echo "[lore doctor] health-check.sh nenalezen: ${HEALTH_CHECK}" >&2
  exit 1
fi

# Spusť health-check v JSON módu (ignoruj exit kód, zpracujeme sami)
health_json="$(bash "${HEALTH_CHECK}" --json 2>/dev/null)" || true

if [[ -z "${health_json}" ]]; then
  echo "[lore doctor] health-check.sh nevrátil žádný výstup." >&2
  exit 1
fi

# Parsuj JSON – vyber checks se statusem WARN nebo BROKEN
# Použijeme pouze standardní bash+grep+sed bez závislostí na jq
overall_status="$(echo "${health_json}" | grep '"status"' | head -1 | sed 's/.*"status": *"\([^"]*\)".*/\1/')"

echo "lore doctor"
echo "══════════════════════════════════════"
echo "Celkový stav: ${overall_status}"
echo ""

# Funkce pro extrakci hodnoty z JSON řádku check záznamu
get_check_field() {
  local line="$1"
  local field="$2"
  echo "${line}" | sed "s/.*\"${field}\": *\"\([^\"]*\)\".*/\1/"
}

# Najdi řádky checks (řádky obsahující "id":)
problem_found=false

while IFS= read -r line; do
  # Přeskočí řádky které nejsou check záznamy
  echo "${line}" | grep -q '"id"' || continue

  cid="$(echo "${line}" | sed 's/.*"id": *\([0-9]*\).*/\1/')"
  cname="$(get_check_field "${line}" "name")"
  cstatus="$(get_check_field "${line}" "status")"
  cmsg="$(get_check_field "${line}" "message")" || cmsg=""

  # Pokud status je OK nebo SKIP, přeskočíme
  [[ "${cstatus}" == "OK" || "${cstatus}" == "SKIP" ]] && continue

  problem_found=true

  case "${cstatus}" in
    WARN)   icon="⚠" ;;
    BROKEN) icon="✗" ;;
    *)      icon="?" ;;
  esac

  echo "${icon} [${cstatus}] ${cname}: ${cmsg}"

  # Navrhni opravu podle check ID a názvu
  case "${cid}" in
    1)
      echo "   Oprava: Spusť: lore init"
      echo "           nebo: lore init --remote git@github.com:user/lore.git"
      ;;
    2)
      echo "   Oprava: Spusť: lore init"
      ;;
    3)
      echo "   Oprava: Spusť: lore init  (repo je prázdné, přidej první commit)"
      ;;
    4)
      echo "   Oprava: Spusť: lore init --remote git@github.com:user/lore.git"
      echo "           nebo:  touch ~/.lore/.lore-local-only  (pro local-only provoz)"
      ;;
    5)
      echo "   Oprava: Spusť: lore git status  (zjisti co je dirty)"
      echo "           nebo:  lore git add -A && lore git commit -m 'snapshot'"
      ;;
    6)
      echo "   Oprava: Spusť: lore git push"
      ;;
    7)
      echo "   Oprava: Spusť: make install-skills"
      echo "           nebo zkontroluj, zda ~/.local/bin je v PATH"
      ;;
    8)
      echo "   Oprava: Spusť: make install-skills  (reinstaluj lore)"
      ;;
    9)
      echo "   Oprava: Zkontroluj: which lore  (očekáváno ~/.local/bin/lore)"
      echo "           Odstraň konfliktní instalaci nebo oprav pořadí v PATH"
      ;;
    10)
      echo "   Oprava: Odstraň LORE_BYPASS z ~/.bashrc nebo ~/.zshrc"
      echo "           pak spusť: source ~/.bashrc"
      ;;
    *)
      echo "   Oprava: Podívej se do dokumentace nebo spusť: lore --help"
      ;;
  esac

  echo ""
done <<< "${health_json}"

if [[ "${problem_found}" == "false" ]]; then
  echo "✓ Vše vypadá v pořádku. Žádné problémy nenalezeny."
  echo ""
fi

echo "══════════════════════════════════════"

# Exit kód dle celkového stavu
case "${overall_status}" in
  HEALTHY) exit 0 ;;
  WARN)    exit 0 ;;
  BROKEN)  exit 1 ;;
  *)       exit 1 ;;
esac
DOCTOR_SH_END
  chmod +x "$lore_dir/doctor.sh"

  # rescue.sh
  cat > "$lore_dir/rescue.sh" <<'RESCUE_SH_END'
#!/usr/bin/env bash
# rescue.sh – záchrana ~/.lore/ bez git repo
# Použití: rescue.sh [--yes] [--dry-run]
# YES=1 nebo --yes: přeskočí interaktivní potvrzení (pro Claude Code)
# DRY_RUN=1 nebo --dry-run: zobrazí co by se stalo bez akce

set -euo pipefail

LORE_DIR="${LORE_PATH:-$HOME/.lore}"
YES="${YES:-false}"
DRY_RUN="${DRY_RUN:-false}"

# ---------------------------------------------------------------------------
# Parsování argumentů
# ---------------------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --yes)     YES="true" ;;
    --dry-run) DRY_RUN="true" ;;
    *)
      echo "[lore rescue] Neznámý argument: $arg" >&2
      echo "Použití: rescue.sh [--yes] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# YES=1 → true
if [ "${YES}" = "1" ]; then YES="true"; fi
# DRY_RUN=1 → true
if [ "${DRY_RUN}" = "1" ]; then DRY_RUN="true"; fi

# ---------------------------------------------------------------------------
# Detekce stavu
# ---------------------------------------------------------------------------

if [ ! -d "${LORE_DIR}" ]; then
  echo "[lore rescue] ${LORE_DIR} neexistuje. Spusť nejprve: lore init" >&2
  exit 1
fi

if [ -d "${LORE_DIR}/.git" ]; then
  echo "[lore rescue] ${LORE_DIR} je již git repo, rescue není potřeba."
  exit 0
fi

# ---------------------------------------------------------------------------
# Dry-run preview
# ---------------------------------------------------------------------------

MD_COUNT=$(find "${LORE_DIR}" -maxdepth 3 -name "*.md" 2>/dev/null | wc -l)

DIVIDER="────────────────────────────"

echo ""
echo "lore rescue – přehled:"
echo "${DIVIDER}"
echo "Adresář:    ${LORE_DIR}/"
echo "Souborů:    ${MD_COUNT} (.md souborů)"
echo "Git status: CHYBÍ (.git/ neexistuje)"
echo ""
echo "Co se provede:"
echo "  1. git init ${LORE_DIR}"
echo "  2. Validace záznamů (validate-all.sh)"
echo "  3. git add -A"
echo "  4. git commit -m \"rescue: zachráněno ${MD_COUNT} souborů [lore rescue]\""
echo ""
echo "Pro přidání remote po rescue: lore init --remote <url> --update-remote"
echo "${DIVIDER}"
echo ""

if [ "${DRY_RUN}" = "true" ]; then
  echo "[lore rescue] Dry-run: žádná akce provedena."
  exit 0
fi

# ---------------------------------------------------------------------------
# Potvrzení – non-TTY bezpečné pro Claude Code
# ---------------------------------------------------------------------------

if [ -t 0 ] && [ "${YES}" != "true" ]; then
  read -r -p "Pokračovat? [y/N] " CONFIRM
  case "${CONFIRM}" in
    [yY]|[yY][eE][sS]) ;;
    *)
      echo "Přerušeno."
      exit 0
      ;;
  esac
elif [ "${YES}" != "true" ]; then
  echo "[lore rescue] Non-TTY prostředí. Použij YES=1 nebo --yes pro automatické potvrzení." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Rescue akce
# ---------------------------------------------------------------------------

echo "[lore rescue] Spouštím git init..."
git init "${LORE_DIR}"

# Validace – nezastaví rescue při WARN, zastaví pouze při závažném selhání skriptu
VALIDATE_SCRIPT="$(dirname "$0")/validate-all.sh"
ERRORS=0
WARNS=0
VALID=0

if [ -f "${VALIDATE_SCRIPT}" ]; then
  VALIDATE_RESULT=$(bash "${VALIDATE_SCRIPT}" --path "${LORE_DIR}" --json 2>/dev/null || true)
  ERRORS=$(echo "${VALIDATE_RESULT}" | grep -o '"errors":[0-9]*' | cut -d: -f2 || echo "0")
  WARNS=$(echo "${VALIDATE_RESULT}"  | grep -o '"warnings":[0-9]*' | cut -d: -f2 || echo "0")
  VALID=$(echo "${VALIDATE_RESULT}"  | grep -o '"valid":[0-9]*'    | cut -d: -f2 || echo "0")
  ERRORS="${ERRORS:-0}"
  WARNS="${WARNS:-0}"
  VALID="${VALID:-0}"
else
  echo "[lore rescue] validate-all.sh nenalezen – přeskakuji validaci."
fi

git -C "${LORE_DIR}" add -A
FILE_COUNT=$(git -C "${LORE_DIR}" diff --cached --name-only | wc -l | tr -d ' ')

TODAY="$(date +%Y-%m-%d)"
git -C "${LORE_DIR}" commit -m "rescue: zachráněno ${FILE_COUNT} souborů [lore rescue ${TODAY}]"

# ---------------------------------------------------------------------------
# Výstup rescue reportu
# ---------------------------------------------------------------------------

echo ""
echo "✓ git init dokončen"
if [ -f "${VALIDATE_SCRIPT}" ]; then
  echo "✓ Validace: ${VALID} OK, ${WARNS} WARN, ${ERRORS} ERR"
fi
echo "✓ Zachráněno ${FILE_COUNT} souborů (1 commit)"
echo ""
echo "Doporučené další kroky:"
echo "  lore health           – zkontroluj stav"
echo "  lore init --remote <url> --update-remote  – připoj remote (volitelné)"
RESCUE_SH_END
  chmod +x "$lore_dir/rescue.sh"

  # lore-git-wrapper.sh
  cat > "$lore_dir/lore-git-wrapper.sh" <<'LORE_GIT_WRAP_END'
#!/usr/bin/env bash
# lore-git-wrapper.sh – wrapper nad git -C ~/.lore/
# Nastavuje LORE_CTX=1 pro pre-commit hook enforcement
# Srozumitelné chybové hlášky místo raw git output

set -euo pipefail

LORE_DIR="${LORE_PATH:-$HOME/.lore}"

# Ověř existenci ~/.lore/.git/
if [ ! -d "$LORE_DIR/.git" ]; then
  echo "[lore] ~/.lore/ není git repo. Spusť: lore init" >&2
  exit 1
fi

# Nastav context pro pre-commit hook enforcement
export LORE_CTX=1

# Spusť git s přesměrováním na ~/.lore/
# Zachyť specifické git chyby a přepiš je srozumitelnými hláškami
STDERR_TMP="$(mktemp)"
trap 'rm -f "$STDERR_TMP"' EXIT

# Lokálně vypni set -e aby EXIT_CODE byl zachycen při git chybě
EXIT_CODE=0
set +e
git -C "$LORE_DIR" "$@" 2>"$STDERR_TMP"
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ]; then
  STDERR_CONTENT="$(cat "$STDERR_TMP")"

  if echo "$STDERR_CONTENT" | grep -q "Could not resolve host"; then
    echo "[lore] Není připojení k remote. Commit uložen lokálně." >&2
  elif echo "$STDERR_CONTENT" | grep -qE "Permission denied \(publickey\)|Authentication failed"; then
    echo "[lore] Autentizace selhala. Zkontroluj SSH klíč: ssh -T git@github.com" >&2
  elif echo "$STDERR_CONTENT" | grep -q "remote: Repository not found"; then
    echo "[lore] Remote repozitář nenalezen. Zkontroluj URL: lore git remote -v" >&2
  elif echo "$STDERR_CONTENT" | grep -q "does not appear to be a git repository"; then
    echo "[lore] ~/.lore/ není git repo. Spusť: lore init" >&2
  else
    # Nezachycená chyba – propaguj raw stderr
    cat "$STDERR_TMP" >&2
  fi
fi

exit $EXIT_CODE
LORE_GIT_WRAP_END
  chmod +x "$lore_dir/lore-git-wrapper.sh"

  # validate-all.sh
  cat > "$lore_dir/validate-all.sh" <<'VALIDATE_ALL_END'
#!/usr/bin/env bash
# validate-all.sh – validace všech lore záznamů
# Použití: validate-all.sh [--path <lore-dir>] [--json]
# Exit code: 0 = vše OK nebo jen WARNy, 1 = nalezeny ERR

set -euo pipefail

# ---------------------------------------------------------------------------
# Výchozí konfigurace
# ---------------------------------------------------------------------------
LORE_DIR="${LORE_PATH:-$HOME/.lore}"
JSON_OUTPUT=false
ERRORS=0
WARNINGS=0
CHECKED=0
OK=0

declare -a RECORDS=()

# ---------------------------------------------------------------------------
# Parsování argumentů
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      LORE_DIR="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    -h|--help)
      printf 'Použití: %s [--path <lore-dir>] [--json]\n' "$(basename "$0")"
      printf '  --path <dir>  Adresář s lore záznamy (výchozí: ~/.lore)\n'
      printf '  --json        Výstup ve formátu JSON\n'
      exit 0
      ;;
    *)
      printf 'Neznámý argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Kontrola existence adresáře
# ---------------------------------------------------------------------------
if [[ ! -d "$LORE_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    printf '{"status":"ok","checked":0,"ok":0,"warnings":0,"errors":0,"records":[],"note":"Adresář neexistuje: %s"}\n' "$LORE_DIR"
  else
    printf 'Adresář neexistuje nebo je prázdný: %s\n' "$LORE_DIR"
    printf 'Výsledek: 0 OK, 0 WARN, 0 ERR\n'
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Pomocné funkce
# ---------------------------------------------------------------------------

# Extrahuje hodnotu YAML pole z frontmatteru souboru
# Vrátí prázdný řetězec pokud pole chybí
get_frontmatter_field() {
  local file="$1"
  local field="$2"
  # Načteme pouze obsah mezi prvním a druhým ---
  awk '/^---$/{if(++c==2) exit} c==1 && /^'"$field"':/' "$file" \
    | sed "s/^${field}:[[:space:]]*//" \
    | tr -d '"'"'"
}

# Kontroluje zda soubor má YAML frontmatter
has_frontmatter() {
  local file="$1"
  local first_line
  first_line=$(head -1 "$file" 2>/dev/null || true)
  [[ "$first_line" == "---" ]]
}

# Kontroluje formát data (YYYY-MM-DD nebo ISO 8601)
is_valid_date() {
  local val="$1"
  # Akceptuje YYYY-MM-DD nebo YYYY-MM-DDThh:mm:ss[Z|±hh:mm]
  [[ "$val" =~ ^[0-9]{4}-[0-1][0-9]-[0-3][0-9](T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})?)?$ ]]
}

# Přidá záznam do pole RECORDS pro JSON výstup
add_record() {
  local file="$1"
  local status="$2"   # ok | warn | err
  local message="$3"
  RECORDS+=("{\"file\":\"${file}\",\"status\":\"${status}\",\"message\":\"${message}\"}")
}

# ---------------------------------------------------------------------------
# Výstupní pomocníci
# ---------------------------------------------------------------------------
print_ok() {
  local file="$1"
  if [[ "$JSON_OUTPUT" == false ]]; then
    printf '[OK]   %s\n' "$file"
  fi
}

print_warn() {
  local file="$1"
  local msg="$2"
  if [[ "$JSON_OUTPUT" == false ]]; then
    printf '[WARN] %s – %s\n' "$file" "$msg"
  fi
}

print_compat() {
  local file="$1"
  local msg="$2"
  if [[ "$JSON_OUTPUT" == false ]]; then
    printf '[COMPAT] %s – %s\n' "$file" "$msg"
  fi
}

print_err() {
  local file="$1"
  local msg="$2"
  if [[ "$JSON_OUTPUT" == false ]]; then
    printf '[ERR]  %s – %s\n' "$file" "$msg"
  fi
}

# ---------------------------------------------------------------------------
# Validační logika jednoho souboru
# ---------------------------------------------------------------------------
validate_file() {
  local abs_path="$1"
  local rel_path="${abs_path#$LORE_DIR/}"
  local file_errors=0
  local file_warnings=0
  local messages=()

  CHECKED=$((CHECKED + 1))

  # Kontrola 1: soubor není prázdný
  if [[ ! -s "$abs_path" ]]; then
    messages+=("soubor je prázdný")
    file_errors=$((file_errors + 1))
    ERRORS=$((ERRORS + 1))
    print_err "$rel_path" "soubor je prázdný"
    add_record "$rel_path" "err" "soubor je prázdný"
    return
  fi

  # Kontrola 2: YAML frontmatter
  if ! has_frontmatter "$abs_path"; then
    messages+=("chybí YAML frontmatter (soubor nezačíná ---)")
    file_errors=$((file_errors + 1))
    ERRORS=$((ERRORS + 1))
    print_err "$rel_path" "chybí YAML frontmatter"
    add_record "$rel_path" "err" "chybí YAML frontmatter"
    return
  fi

  # Kontrola 3: povinná pole
  local required_fields=("title" "type" "date")
  for field in "${required_fields[@]}"; do
    local value
    value=$(get_frontmatter_field "$abs_path" "$field")
    if [[ -z "$value" ]]; then
      messages+=("chybí povinné pole: ${field}")
      file_errors=$((file_errors + 1))
      ERRORS=$((ERRORS + 1))
      print_err "$rel_path" "chybí povinné pole: ${field}"
    fi
  done

  # Kontrola 4: schema_version – chybějící = [COMPAT] implicitně v1, neznámá = [WARN] (ne ERR)
  local sv
  sv=$(get_frontmatter_field "$abs_path" "schema_version")
  if [[ -z "$sv" ]]; then
    # Starší záznamy bez schema_version jsou implicitně v1 – zpětná kompatibilita
    messages+=("chybí schema_version (implicitně v1)")
    file_warnings=$((file_warnings + 1))
    WARNINGS=$((WARNINGS + 1))
    print_compat "$rel_path" "chybí schema_version (implicitně v1)"
  elif [[ "$sv" != "1" ]]; then
    # Neznámá verze = WARN, ne ERR – neblokuje zpracování (budoucí verze schématu)
    messages+=("neznámá schema_version: ${sv} (očekáváno: 1)")
    file_warnings=$((file_warnings + 1))
    WARNINGS=$((WARNINGS + 1))
    print_warn "$rel_path" "neznámá schema_version: ${sv} (očekáváno: 1)"
  fi

  # Kontrola 5: formát pole date
  local date_val
  date_val=$(get_frontmatter_field "$abs_path" "date")
  if [[ -n "$date_val" ]] && ! is_valid_date "$date_val"; then
    messages+=("pole date má neplatný formát: ${date_val}")
    file_errors=$((file_errors + 1))
    ERRORS=$((ERRORS + 1))
    print_err "$rel_path" "pole date má neplatný formát: ${date_val}"
  fi

  # Výsledek souboru
  if [[ $file_errors -eq 0 && $file_warnings -eq 0 ]]; then
    OK=$((OK + 1))
    print_ok "$rel_path"
    add_record "$rel_path" "ok" ""
  elif [[ $file_errors -eq 0 ]]; then
    OK=$((OK + 1))
    local combined_msg
    combined_msg=$(printf '%s; ' "${messages[@]}")
    add_record "$rel_path" "warn" "${combined_msg%; }"
  else
    local combined_msg
    combined_msg=$(printf '%s; ' "${messages[@]}")
    add_record "$rel_path" "err" "${combined_msg%; }"
  fi
}

# ---------------------------------------------------------------------------
# Hlavní smyčka
# ---------------------------------------------------------------------------
if [[ "$JSON_OUTPUT" == false ]]; then
  printf 'Validuji záznamy v %s...\n' "$LORE_DIR"
fi

# Najdeme všechny .md soubory v adresáři
mapfile -t md_files < <(find "$LORE_DIR" -type f -name "*.md" | sort)

if [[ ${#md_files[@]} -eq 0 ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    printf '{"status":"ok","checked":0,"ok":0,"warnings":0,"errors":0,"records":[],"note":"Žádné .md soubory v %s"}\n' "$LORE_DIR"
  else
    printf 'Žádné .md soubory v: %s\n' "$LORE_DIR"
    printf 'Výsledek: 0 OK, 0 WARN, 0 ERR\n'
  fi
  exit 0
fi

for f in "${md_files[@]}"; do
  validate_file "$f"
done

# ---------------------------------------------------------------------------
# Výsledný výstup
# ---------------------------------------------------------------------------
if [[ "$JSON_OUTPUT" == true ]]; then
  # Sestavení JSON pole records
  local_status="ok"
  [[ $ERRORS -gt 0 ]] && local_status="err"
  if [[ ${#RECORDS[@]} -gt 0 ]]; then
    records_json=$(printf '%s,' "${RECORDS[@]}")
    records_json="[${records_json%,}]"
  else
    records_json="[]"
  fi
  printf '{"status":"%s","checked":%d,"ok":%d,"warnings":%d,"errors":%d,"records":%s}\n' \
    "$local_status" "$CHECKED" "$OK" "$WARNINGS" "$ERRORS" "$records_json"
else
  printf 'Výsledek: %d OK, %d WARN, %d ERR\n' "$OK" "$WARNINGS" "$ERRORS"
fi

# Exit kód: 1 pokud jsou jakékoliv ERR
if [[ $ERRORS -gt 0 ]]; then
  exit 1
fi
exit 0
VALIDATE_ALL_END
  chmod +x "$lore_dir/validate-all.sh"

  # install-hooks.sh
  cat > "$lore_dir/install-hooks.sh" <<'INSTALL_HOOKS_END'
#!/usr/bin/env bash
# install-hooks.sh – nainstaluje pre-commit hook do ~/.lore/.git/hooks/
# Používá shim pattern: tenký shim → upgradeable impl
# Chainuje existující user hook pokud existuje

set -euo pipefail

LORE_DIR="${LORE_PATH:-$HOME/.lore}"
HOOKS_DIR="$LORE_DIR/.git/hooks"
SHIM_SRC="$(cd "$(dirname "$0")" && pwd)/hooks/pre-commit-shim.sh"
IMPL_SRC="$(cd "$(dirname "$0")" && pwd)/hooks/pre-commit-impl.sh"
SHIM_MARKER="# lore-pre-commit-shim"

# Ověř že ~/.lore/ je git repo
if [ ! -d "$LORE_DIR/.git" ]; then
  echo "[lore] ~/.lore/ není git repo. Spusť nejprve: lore init" >&2
  exit 1
fi

# Ověř existence zdrojových souborů
if [ ! -f "$SHIM_SRC" ]; then
  echo "[lore] Shim nenalezen: $SHIM_SRC" >&2
  exit 1
fi

if [ ! -f "$IMPL_SRC" ]; then
  echo "[lore] Impl nenalezen: $IMPL_SRC" >&2
  exit 1
fi

mkdir -p "$HOOKS_DIR"

HOOK_PATH="$HOOKS_DIR/pre-commit"

# Zkontroluj, zda existující hook není již náš shim
if [ -f "$HOOK_PATH" ]; then
  if grep -q "$SHIM_MARKER" "$HOOK_PATH" 2>/dev/null; then
    echo "[lore] Pre-commit hook je již nainstalován (shim detekován). Přeskakuji."
  else
    # Existuje cizí hook – přejmenuj na pre-commit-user a chain
    echo "[lore] Existující pre-commit hook nalezen – přejmenovávám na pre-commit-user"
    mv "$HOOK_PATH" "$HOOKS_DIR/pre-commit-user"
    chmod +x "$HOOKS_DIR/pre-commit-user"

    # Nainstaluj shim s chain logikou
    cat > "$HOOK_PATH" <<SHIM
#!/usr/bin/env bash
$SHIM_MARKER
# Tento shim byl vygenerován install-hooks.sh
# Logika enforcement: pre-commit-impl.sh
# Původní user hook: pre-commit-user

IMPL="\$(dirname "\$0")/../../scripts/hooks/pre-commit-impl.sh"

if [ ! -f "\$IMPL" ]; then
  echo "[lore-enforcement] WARN: pre-commit-impl.sh nenalezen, enforcement přeskočen." >&2
else
  bash "\$IMPL" "\$@" || exit \$?
fi

# Spusť původní user hook pokud enforcement prošel
USER_HOOK="\$(dirname "\$0")/pre-commit-user"
if [ -f "\$USER_HOOK" ]; then
  bash "\$USER_HOOK" "\$@"
fi
SHIM
    chmod +x "$HOOK_PATH"
    echo "[lore] Shim nainstalován s chain na pre-commit-user"
  fi
else
  # Žádný existující hook – nainstaluj prostý shim
  cp "$SHIM_SRC" "$HOOK_PATH"
  # Přidej marker do nainstalovaného shimu
  sed -i "2i $SHIM_MARKER" "$HOOK_PATH"
  chmod +x "$HOOK_PATH"
  echo "[lore] Pre-commit shim nainstalován: $HOOK_PATH"
fi

# Zkopíruj impl.sh do ~/.lore/scripts/hooks/ pro runtime přístup
RUNTIME_HOOKS_DIR="$LORE_DIR/scripts/hooks"
mkdir -p "$RUNTIME_HOOKS_DIR"
cp "$IMPL_SRC" "$RUNTIME_HOOKS_DIR/pre-commit-impl.sh"
chmod +x "$RUNTIME_HOOKS_DIR/pre-commit-impl.sh"
echo "[lore] Impl zkopírován do: $RUNTIME_HOOKS_DIR/pre-commit-impl.sh"

echo "[lore] Instalace hooků dokončena."
INSTALL_HOOKS_END
  chmod +x "$lore_dir/install-hooks.sh"

  # hooks/pre-commit-impl.sh
  cat > "$lore_dir/hooks/pre-commit-impl.sh" <<'PRE_COMMIT_IMPL_END'
#!/usr/bin/env bash
# pre-commit-impl.sh – skutečná logika enforcement
# Ověří že commit do ~/.lore/ byl volán přes lore git wrapper

# Akceptuj LORE_CTX (nové) i LORE_GIT_CONTEXT (zpětná kompatibilita)
if [ -z "${LORE_CTX:-}" ] && [ -z "${LORE_GIT_CONTEXT:-}" ] && [ -z "${LORE_BYPASS:-}" ]; then
  echo "[lore-enforcement] CHYBA: Přímý git commit do ~/.lore/ je zakázán." >&2
  echo "[lore-enforcement] Použij: lore git commit <argumenty>" >&2
  echo "[lore-enforcement] Emergency override: LORE_BYPASS=1 git commit ..." >&2
  exit 1
fi

if [ -n "${LORE_BYPASS:-}" ]; then
  echo "[lore-enforcement] WARN: LORE_BYPASS=1 – enforcement obejit. Použij jen v nouzi." >&2
fi

exit 0
PRE_COMMIT_IMPL_END
  chmod +x "$lore_dir/hooks/pre-commit-impl.sh"

  # hooks/pre-commit-shim.sh
  cat > "$lore_dir/hooks/pre-commit-shim.sh" <<'PRE_COMMIT_SHIM_END'
#!/usr/bin/env bash
# pre-commit-shim.sh – tenký shim nainstalovaný do ~/.lore/.git/hooks/pre-commit
# Volá pre-commit-impl.sh kde je skutečná logika
# Shim je stabilní kontrakt – logika je upgradeable bez dotyku shimu

HOOK_IMPL="$(dirname "$0")/../../scripts/hooks/pre-commit-impl.sh"

if [ ! -f "$HOOK_IMPL" ]; then
  echo "[lore-enforcement] WARN: pre-commit-impl.sh nenalezen, enforcement přeskočen." >&2
  exit 0
fi

bash "$HOOK_IMPL" "$@"
PRE_COMMIT_SHIM_END
  chmod +x "$lore_dir/hooks/pre-commit-shim.sh"

  printf '▶ Lore skripty vygenerovány do %s\n' "$lore_dir"
}

write_makefile() {
cat > "$WORKFLOW_DIR/Makefile" <<'EOF'
SHELL := /usr/bin/env bash
ROOT  := .

.PHONY: help list-agents status init-iteration close-iteration \
        new-decision dispatch-brief reopen-task validate validate-lore tree dashboard \
        install-skills setup-lore lore-rescue

help:
	@printf 'Dostupné příkazy:\n'
	@printf '  make list-agents                              – vypíše agenty a jejich stav\n'
	@printf '  make status                                   – stav agentů + aktivní iterace\n'
	@printf '  make init-iteration ITER=iter-001             – založí iteraci\n'
	@printf '  make close-iteration ITER=iter-001            – uzavře iteraci\n'
	@printf '  make new-decision ID=DR-001 TOPIC=popis       – nový decision record\n'
	@printf '  make dispatch-brief AGENT=coder BRIEF=file.md – pošle brief agentovi\n'
	@printf '  make reopen-task AGENT=coder TASK=T-001 REASON="fix X"\n'
	@printf '  make validate                                 – zkontroluje agent složky\n'
	@printf '  make tree                                     – vypíše strukturu (3 úrovně)\n'
	@printf '  make dashboard                                – vygeneruje dashboard.html\n'
	@printf '  make install-skills                           – nainstaluje lore CLI do ~/.local/\n'
	@printf '  make validate-lore                            – validuje ~/.lore/ záznamy\n'

list-agents:
	@bash orchestration/scripts/scan-agents.sh "$(ROOT)"

status:
	@bash tools/status.sh "$(ROOT)"

init-iteration:
	@test -n "$(ITER)" || (printf 'Použití: make init-iteration ITER=iter-001\n' && exit 1)
	@bash orchestration/scripts/new-iteration.sh "$(ROOT)" "$(ITER)"

close-iteration:
	@test -n "$(ITER)" || (printf 'Použití: make close-iteration ITER=iter-001\n' && exit 1)
	@bash orchestration/scripts/close-iteration.sh "$(ROOT)" "$(ITER)"

new-decision:
	@test -n "$(ID)"    || (printf 'Použití: make new-decision ID=DR-001 TOPIC=popis\n' && exit 1)
	@test -n "$(TOPIC)" || (printf 'Použití: make new-decision ID=DR-001 TOPIC=popis\n' && exit 1)
	@bash orchestration/scripts/new-decision.sh "$(ROOT)" "$(ID)" "$(TOPIC)"

dispatch-brief:
	@test -n "$(AGENT)" || (printf 'Použití: make dispatch-brief AGENT=coder BRIEF=file.md\n' && exit 1)
	@test -n "$(BRIEF)" || (printf 'Použití: make dispatch-brief AGENT=coder BRIEF=file.md\n' && exit 1)
	@bash orchestration/scripts/dispatch-brief.sh "$(ROOT)" "$(AGENT)" "$(BRIEF)"

reopen-task:
	@test -n "$(AGENT)"  || (printf 'Použití: make reopen-task AGENT=coder TASK=T-001 REASON="popis"\n' && exit 1)
	@test -n "$(TASK)"   || (printf 'Použití: make reopen-task AGENT=coder TASK=T-001 REASON="popis"\n' && exit 1)
	@test -n "$(REASON)" || (printf 'Použití: make reopen-task AGENT=coder TASK=T-001 REASON="popis"\n' && exit 1)
	@bash orchestration/scripts/reopen-task.sh "$(ROOT)" "$(AGENT)" "$(TASK)" "$(REASON)"

validate:
	@bash tools/check-agent-folders.sh "$(ROOT)"

tree:
	@bash tools/tree-summary.sh "$(ROOT)"

dashboard:
	@python3 gen-dashboard.py

install-skills:
	@# Verze-aware instalace lore CLI
	@INSTALLED_VER=$$(cat ~/.local/lib/lore/VERSION 2>/dev/null || echo ""); \
	NEW_VER=$$(cat scripts/lore/VERSION | tr -d '[:space:]'); \
	if [ "$$INSTALLED_VER" = "$$NEW_VER" ]; then \
		echo "[SKIP] lore v$$NEW_VER already installed"; \
	else \
		if [ -n "$$INSTALLED_VER" ]; then \
			echo "[UPDATE] Upgrading lore v$$INSTALLED_VER → v$$NEW_VER"; \
		else \
			echo "[INSTALL] Installing lore v$$NEW_VER"; \
		fi; \
		mkdir -p ~/.local/bin ~/.local/lib/lore ~/.local/lib/lore/hooks ~/.lore/scripts; \
		cp scripts/lore/lore.sh ~/.local/bin/lore; \
		chmod +x ~/.local/bin/lore; \
		cp scripts/lore/VERSION scripts/lore/health-check.sh scripts/lore/doctor.sh \
		   scripts/lore/rescue.sh scripts/lore/lore-git-wrapper.sh \
		   scripts/lore/validate-all.sh scripts/lore/install-hooks.sh \
		   ~/.local/lib/lore/; \
		chmod +x ~/.local/lib/lore/health-check.sh ~/.local/lib/lore/doctor.sh \
		         ~/.local/lib/lore/rescue.sh ~/.local/lib/lore/lore-git-wrapper.sh \
		         ~/.local/lib/lore/validate-all.sh ~/.local/lib/lore/install-hooks.sh; \
		cp scripts/lore/hooks/pre-commit-impl.sh scripts/lore/hooks/pre-commit-shim.sh \
		   ~/.local/lib/lore/hooks/; \
		chmod +x ~/.local/lib/lore/hooks/pre-commit-impl.sh ~/.local/lib/lore/hooks/pre-commit-shim.sh; \
		echo "[OK] lore v$$NEW_VER nainstalováno do ~/.local/bin/lore + ~/.local/lib/lore/"; \
	fi

validate-lore:
	@bash scripts/lore/validate-all.sh

lore-rescue:
	@# Záchrana existující ~/.lore/ bez git repo
	@bash scripts/lore/rescue.sh \
		$(if $(filter true 1,$(YES)),--yes,) \
		$(if $(filter true 1,$(DRY_RUN)),--dry-run,)

setup-lore:
	@# Alias pro lore init – zachová zpětnou kompatibilitu s dokumentací
	@if command -v lore >/dev/null 2>&1; then \
		lore init $(if $(REMOTE),--remote $(REMOTE),) $(if $(UPDATE_REMOTE),--update-remote,); \
	else \
		echo "[setup-lore] lore CLI nenalezeno. Spusť nejdřív: make install-skills"; \
		exit 1; \
	fi
EOF
}

validate_source_agent_definitions() {
  [[ -d "$SOURCE_AGENT_DEFINITIONS_DIR" ]] || die "Zdrojové agent definice nebyly nalezeny: $SOURCE_AGENT_DEFINITIONS_DIR"
  [[ -f "$SOURCE_DEFINITION_PARSER" ]] || die "Parser agent definic nebyl nalezen: $SOURCE_DEFINITION_PARSER"
  printf '▶ Používám bootstrap source: %s\n' "$SOURCE_DESCRIPTION"
  python3 "$SOURCE_DEFINITION_PARSER" validate-dir "$SOURCE_AGENT_DEFINITIONS_DIR" >/dev/null
}

copy_agent_definition_assets() {
  local target_definitions_dir="$WORKFLOW_DIR/agent_definitions"
  mkdir -p "$target_definitions_dir" "$WORKFLOW_DIR/tools"

  cp "$SOURCE_DEFINITION_PARSER" "$WORKFLOW_DIR/tools/parse_agent_definitions.py"
  chmod +x "$WORKFLOW_DIR/tools/parse_agent_definitions.py"
  cp "$SOURCE_AGENT_DEFINITIONS_DIR"/*.json "$target_definitions_dir/"

  if [[ -f "$SOURCE_AGENT_DEFINITIONS_DIR/README.md" ]]; then
    cp "$SOURCE_AGENT_DEFINITIONS_DIR/README.md" "$target_definitions_dir/README.md"
  fi
}

copy_dashboard_script() {
  if [[ -z "$SOURCE_DASHBOARD_SCRIPT" || ! -f "$SOURCE_DASHBOARD_SCRIPT" ]]; then
    printf 'Varování: gen-dashboard.py nebyl nalezen, přeskakuji.\n' >&2
    return 0
  fi
  cp "$SOURCE_DASHBOARD_SCRIPT" "$WORKFLOW_DIR/gen-dashboard.py"
  chmod +x "$WORKFLOW_DIR/gen-dashboard.py"
}

copy_shared_templates() {
  [[ -d "$SOURCE_TEMPLATES_DIR" ]] || return 0

  local target_dir="$WORKFLOW_DIR/shared/templates"
  mkdir -p "$target_dir"
  find "$SOURCE_TEMPLATES_DIR" -maxdepth 1 -type f -name '*.md' -print0 \
    | xargs -0 -I{} cp {} "$target_dir/"
}

agent_catalog_table() {
  python3 "$SOURCE_DEFINITION_PARSER" catalog-table "$WORKFLOW_DIR/agent_definitions"
}

agent_slug_list() {
  python3 "$SOURCE_DEFINITION_PARSER" slug-list "$WORKFLOW_DIR/agent_definitions"
}

agent_count() {
  python3 "$SOURCE_DEFINITION_PARSER" count "$WORKFLOW_DIR/agent_definitions"
}

# =============================================================================
# write_workflow_agents_md – generuje .aiworkflow/AGENTS.md (Cold Start, Lore Contract,
# Master Checklist, katalog agentů, struktura orchestration/, decision records)
# Vyžaduje předem nastavené: WORKFLOW_DIR, AGENT_CATALOG_TABLE_FILE
# =============================================================================
write_workflow_agents_md() {
  cat > "$WORKFLOW_DIR/AGENTS.md" <<'EOF'
# Multi-Agent Project – Root Instructions

## Where to Start (Cold Start Protokol) – POVINNÉ POŘADÍ

**Přečti tyto kroky celé před tím, než cokoliv uděláš.**

### Krok 1 – Načti kontext
1. Přečti `zadani_projektu.md` – pochop cíl, scope a stav projektu
2. Přečti `project/done-criteria.md` – kdy je projekt hotový
3. Přečti `shared/docs/lessons_learned.md` – poučení z předchozích sezení (POVINNÉ)
4. Jako entrypoint orchestrator POVINNĚ přečti `agents/orchestrator/AGENTS.md` a přistupuj k sobě jako k jednomu z agentů, ne jako k výjimce mimo workflow.

### Krok 1b – Lore check (pokud ~/.lore/ existuje)

Pokud `~/.lore/` existuje na systému:

1. **Health check** (POVINNÝ):
   ```bash
   LORE_STATUS=$(lore health --json 2>/dev/null | grep '"status"' | head -1)
   ```
   - HEALTHY → pokračuj
   - WARN → pokračuj a zaloguj warning do `orchestrator/logs/`
   - BROKEN → zastav se a informuj uživatele: "~/.lore/ je poškozena, spusť: lore rescue"

2. **Relevantní lekce** (POVINNÝ – grep z keywords aktuálního Goal iterace):
   ```bash
   grep -r "<keyword-z-goal>" ~/.lore/knowledge/ 2>/dev/null | head -5
   grep -r "<keyword-z-goal>" ~/.lore/lessons/ 2>/dev/null | head -5
   ```
   - Použij 2–3 klíčová slova z Goal aktuální iterace (žádná obecná slova jako "task" nebo "implement").
   - Hard limit: max 5 relevantních hitů na složku.

3. **Zakázané scope**:
   - NIKDY: `grep -r "<keyword>" ~/.lore/intel-pass/` – `intel-pass/` je VŽDY manuální, nikdy automatický.
   - NIKDY: grep do `~/.lore/clients/` automaticky – obsahuje klientská data.
   - Pro `~/.lore/processes/` jen pokud je task explicitně o workflow procesech.

4. **Zápis nových poznatků**: vždy přes `lore new <typ> "<název>"` – nikdy přímý `git commit` do `~/.lore/`.

### Krok 1a – Zadání iterace
5. Zkontroluj `orchestration/assignments/active.md`:
   - **Existuje a je vyplněné** → přečti ho, pochop cíl a scope iterace
   - **Existuje ale je template** (obsahuje "–") → Claude ho vyplní v rámci `/init-iteration`
   - **Neexistuje** → žádná aktivní iterace nebo soubor ještě nevznikl (vznikne v `/init-iteration`)

### Krok 2 – Zjisti stav iterace
6. Zkontroluj aktivní iteraci:
   - Otevři `orchestration/plans/active.md`
   - **Existuje a není symlink na nic** → přečti plan.md, zkontroluj master checklist, pokračuj
   - **Neexistuje nebo je broken** → vytvoř novou iteraci: `make -C .aiworkflow init-iteration ITER=iter-001`
   - **Existuje ale je template** (obsahuje ITER-ID, "jedna věta", "–") → ZASTAV SE, vyplň ho

### Krok 3 – Zkontroluj inbox a agenty
6. Zkontroluj `agents/orchestrator/context/inbox/` – čekají briefy nebo notifikace?
7. Načti dostupné agenty: `make list-agents`

### Krok 3a – Prompt audit trail (POVINNÉ)
8. Než předáš brief nebo jiný požadavek libovolnému agentovi, ulož přesný prompt do `agents/<slug>/logs/`.
9. Teprve po uložení promptu odesílej brief nebo follow-up.

### Krok 4 – Vyplň plán (PŘED zahájením práce)
Pokud plan.md existuje ale obsahuje template (placeholder text jako "ITER-ID", "jedna věta", "–"):
- **Zastav se a vyplň ho** – Goal, Master Checklist s reálnými T-ID a tasky
- Teprve po vyplnění začni pracovat
- Prázdný nebo template plán = BLOCKER, nepokračuj bez jeho vyplnění

---

## Master Checklist Pravidlo (KRITICKÉ)

Orchestrátor udržuje master checklist v `orchestration/runs/<iter>/plan.md`.

### Pravidla:
1. Každý úkol má unikátní task-id (T-001, T-002, ...)
2. Odškrtni IHNED po dokončení – ne nakonec, ne v dávce
3. Nezahajuj další task dokud předchozí není odškrtnut

> Konkrétní kroky pro správu plan.md při dispatchi jsou v `/dispatch-agent` (krok 3 a krok 8).

### Časté chyby (viz lessons_learned.md):
- ❌ Nechat plán jako template a rovnou pracovat
- ❌ Odškrtat tasky nakonec místo průběžně

---

## Dostupní Agenti
__AGENT_CATALOG_TABLE__

## Doporučený Flow Iterace
1. Orchestrátor přečte zadání → vyplní iteration plan (Goal + Master Checklist s T-ID)
2. Orchestrátor dispatchne agenty → **skill \`/dispatch-agent\`** (audit log, plan.md, spawn, verify)
3. Agenti pracují, průběžně odškrtávají svůj dílčí checklist
4. Agent dokončí → \`bash scripts/handoff-out.sh <task-id> "<popis>"\` → orchestrátor IHNED odškrtne master checklist
5. Reviewer/Tester validují; při nálezu → \`make reopen-task\` + znovu dispatch přes \`/dispatch-agent\`
6. Uzavření iterace → **skill \`/close-iteration\`** (verify → commit → push → PR → close-iteration.sh)

## Struktura orchestration/ – kde žije co

### orchestration/plans/active.md  ← VŽDY ČTEŠ TENHLE
Symlink na plan.md aktuálně aktivní iterace.
- Vytvoří se automaticky při `make init-iteration`
- Odstraní se automaticky při `make close-iteration`
- Pokud neexistuje → žádná aktivní iterace, vytvoř novou

**Správné použití:**
- Čteš stav iterace? → `orchestration/plans/active.md`
- Odškrtáváš checklist? → `orchestration/plans/active.md` (symlink tě přesměruje)
- Nikdy nehledej plan.md ručně v runs/ – vždy jdi přes `plans/active.md`

### orchestration/runs/<iter>/plan.md  ← SKUTEČNÝ SOUBOR
Živý dokument iterace – Goal, master checklist, exit summary.
- `plans/active.md` vždy ukazuje sem
- Po `close-iteration` zůstane jako archivní záznam

### orchestration/runs/<iter>/  ← RUNTIME DATA ITERACE
Briefs, collected outputs, logy, reviews.
Neupravuj ručně – používej skripty.

### Typické chyby (viz lessons_learned.md)
- ❌ Hledám plan.md přímo v `runs/` místo přes `plans/active.md`
- ❌ `plans/active.md` je broken symlink a nevšimnu si toho → zkontroluj: `ls -la orchestration/plans/`
- ❌ Zapomenu vyplnit Goal a T-ID po `make init-iteration` → BLOCKER

## Scope Changes
Každá změna scope se zapisuje do `project/scope-changes.md`.

## Decision Records
Každé rozhodnutí s dopadem: `make new-decision ID=DR-001 TOPIC=popis`
Relevantní DR se kopírují do `agents/<slug>/context/refs/`.

---

## Lore Contract

Každý agent (včetně orchestrátora) musí dodržovat tato pravidla pro práci s `~/.lore/`:

### Čtení
- Přečti sekci `## Lore Context` ve svém briefu – pokud není "—", vezmi ji v potaz
- Volitelně: `grep -r "<téma>" ~/.lore/knowledge/ ~/.lore/lessons/ 2>/dev/null | head -5`
- NIKDY: grep do `~/.lore/intel-pass/` – `intel-pass/` je VŽDY manuální (skill `/intel-pass`), nikdy automatický
- NIKDY: grep do `~/.lore/clients/` automaticky – obsahuje klientská data
- `~/.lore/processes/` jen pro tasky o workflow procesech

### Zápis (Write Gate)
- Po dokončení tasku: zamysli se, zda jsi získal nový poznatek
- Pokud ANO (nová chyba, nový vzor, nové řešení): `lore new lesson "<popis>"` nebo `lore new knowledge "<popis>"`
- Pokud NE (rutinní implementace, zkopírovaný postup): nezapisuj nic
- Threshold pro zápis: "nová chyba nebo nový vzor" – nezahlcuj banalitami a duplikáty
- Commit výhradně přes `lore git commit` – nikdy `git commit` přímo

### Zakázané operace
- NIKDY: `git -C ~/.lore/ commit` (přímý commit mimo wrapper)
- NIKDY: `git -C ~/.lore/ push` (přímý push mimo wrapper)
- NIKDY: `cd ~/.lore/ && git ...` (změna working directory na ~/.lore/)
- VŽDY: `lore git commit`, `lore git push`, `lore git pull`

### Emergency override
- Pokud wrapper nefunguje a situace vyžaduje přímý přístup:
  `LORE_BYPASS=1 git -C ~/.lore/ <příkaz>`
- LORE_BYPASS se zaznamená v lore health jako WARN
- Použij jen v nouzi, ne jako standardní postup
EOF
  replace_placeholder_from_file "$WORKFLOW_DIR/AGENTS.md" "__AGENT_CATALOG_TABLE__" "$AGENT_CATALOG_TABLE_FILE"
}

# =============================================================================
# write_brief_template – generuje .aiworkflow/shared/templates/brief-template.md
# Vyžaduje předem nastavené: WORKFLOW_DIR
# =============================================================================
write_brief_template() {
  mkdir -p "$WORKFLOW_DIR/shared/templates"
  cat > "$WORKFLOW_DIR/shared/templates/brief-template.md" <<'EOF'
# Brief

- **Brief ID**: BRIEF-XXX
- **Iteration**: iter-XXX
- **From**: Orchestrator
- **To**: <agent-slug>
- **Date**: YYYY-MM-DD

## Goal
<!-- Jedna věta: čeho má agent dosáhnout -->

## Context
<!-- Co už víme, relevantní background -->

## Lore Context
<!-- Automaticky doplněno orchestrátorem přes grep ~/.lore/knowledge/ ~/.lore/lessons/ -->
<!-- Pokud nic relevantního → napsat "—" (NEsmazat sekci, NEsmazat tento komentář) -->
–

## Scope IN
–

## Scope OUT
–

## Task List (zkopíruj do svého dílčího checklistu)
- [ ] T-XXX: <popis úkolu>
- [ ] T-XXX: <popis úkolu>

## Inputs (soubory / reference)
–

## Acceptance Criteria
–

## Expected Outputs (cesty k souborům)
- `agents/<slug>/artifacts/final/...`

## Risks / Constraints
–
EOF
}

# =============================================================================
# Helper: agent workspace
# =============================================================================
make_agent_workspace() {
  local slug="$1"
  local dir="$WORKFLOW_DIR/agents/$slug"

  mkdir -p "$dir"/{scripts,logs,context/{inbox,outbox,refs},artifacts/{drafts,final},state,runs/{current,archive},scratch,tests,metrics}

  touch "$dir/logs/.gitkeep" \
        "$dir/context/inbox/.gitkeep" \
        "$dir/context/outbox/.gitkeep" \
        "$dir/context/refs/.gitkeep" \
        "$dir/artifacts/drafts/.gitkeep" \
        "$dir/artifacts/final/.gitkeep" \
        "$dir/runs/current/.gitkeep" \
        "$dir/runs/archive/.gitkeep" \
        "$dir/scratch/.gitkeep" \
        "$dir/tests/.gitkeep" \
        "$dir/metrics/.gitkeep"

  # state konvence
  cat > "$dir/state/current-task.md" <<'EOF'
# Current Task

- **Task ID**: –
- **Brief**: –
- **Iteration**: –
- **Status**: idle  <!-- idle | in-progress | done | blocked -->
- **Started**: –
- **Completed**: –

## Co teď dělám
–

## Předpoklady
–

## Blockery
–
EOF

  touch "$dir/state/assumptions.md"
  touch "$dir/state/blockers.md"
}

# =============================================================================
# Helper: AGENTS.md pro agenta
# =============================================================================
write_agent_instructions() {
  local dir="$1"
  local agent_name="$2"
  local short_role="$3"
  local gallup_profile="$4"
  local mission="$5"
  local inputs="$6"
  local outputs="$7"
  local handoff_to="$8"
  local quality_gate="$9"
  local asks="${10}"
  local extra_rules="${11}"

  cat > "$dir/AGENTS.md" <<EOF
# ${agent_name}

## Role
${short_role}

## Gallup Talent Profile
${gallup_profile}

## Mission
${mission}

## Primary Inputs
${inputs}

## Required Outputs
${outputs}

## Handoff Targets
${handoff_to}

## Working Style
- Buď věcný, stručný a přesný.
- Před prací si ověř kontext ve složce \`context/inbox/\` a reference ve \`context/refs/\`.
- Pokud něco zásadního chybí, polož max 3 cílené otázky.
- Preferuj rozhodnutí s jasným odůvodněním (trade-offs, rizika, dopady).
- Zapisuj průběh do \`logs/\` a průběžné poznámky do \`state/\`.

## Checkpoint Protokol (POVINNÉ)
Po každém dokončeném dílčím úkolu:
1. Aktualizuj \`state/current-task.md\` → status: done
2. Zavolej \`bash scripts/handoff-out.sh <task-id> "<popis>"\`

Pokud jsi zablokován: nastav status: blocked a zavolej handoff-out.sh s důvodem.

> Dispatch a handoff protokol (audit log, plan.md, čekání na output) provádí Orchestrátor
> přes skill \`/dispatch-agent\`. Tento soubor popisuje pouze povinnosti agenta.

## Dílčí checklist (udržuj aktuální)
Orchestrátor ti pošle task list v briefu. Kopíruj ho sem a odškrtávej průběžně – ihned po dokončení každého bodu, ne nakonec.

\`\`\`
<!-- Sem zkopíruj checklist z briefu -->
\`\`\`

## Quality Gate (Definition of Done)
${quality_gate}

## Ask-first Triggers (max 3 otázky)
${asks}

## File Conventions
- Vstupy od orchestrace: \`context/inbox/*.md\`
- Vlastní pracovní poznámky: \`state/\`
- Výstupní deliverables: \`artifacts/final/\`
- Dočasné návrhy: \`artifacts/drafts/\`
- Handoff metadata (co posílám dál): \`context/outbox/\`
- Log běhu: \`logs/YYYY-MM-DD_run.log\`
- Prompt předaný jinému agentovi: \`agents/<slug>/logs/YYYY-MM-DDTHH-MM-SSZ__prompt_<iter>_<task>.md\`

## Do / Don't
- Do: explicitně uveď předpoklady a nejistoty.
- Do: navrhuj varianty, pokud jsou relevantní.
- Do: odškrtávej checklist průběžně, ne nakonec.
- Don't: neměň scope bez uvedení důvodu a eskalace na Orchestrátora.
- Don't: netvrď rozhodnutí bez kritérií.
- Don't: nezavírej task bez zavolání handoff-out.sh.

## Extra Rules
${extra_rules}

## Lore Contract
Při práci s ~/.lore/ dodržuj pravidla v \`.aiworkflow/AGENTS.md\` (sekce Lore Contract).

### Čtení
- Přečti sekci \`## Lore Context\` ve svém briefu – pokud není "—", vezmi ji v potaz
- Volitelně: \`grep -r "<téma>" ~/.lore/knowledge/ ~/.lore/lessons/ 2>/dev/null | head -5\`
- NIKDY: grep do \`~/.lore/intel-pass/\` (intel-pass je vždy manuální, nikdy automatický)
- NIKDY: grep do \`~/.lore/clients/\` automaticky (obsahuje klientská data)

### Zápis (Write Gate)
- Po dokončení tasku: zamysli se, zda jsi získal nový poznatek
- Pokud ANO (nová chyba, nový vzor, nové řešení): \`lore new lesson "<popis>"\` nebo \`lore new knowledge "<popis>"\`
- Pokud NE (rutinní implementace, zkopírovaný postup): nezapisuj nic
- NIKDY: přímý git commit do ~/.lore/ – vždy přes \`lore git commit\`
EOF
}

# =============================================================================
# Helper: make_agent (workspace + AGENTS.md)
# =============================================================================
make_agent() {
  local slug="$1" name="$2" role="$3" gallup="$4" mission="$5" inputs="$6"
  local outputs="$7" handoff="$8" quality="$9" asks="${10}" extra="${11}"

  local dir="$WORKFLOW_DIR/agents/$slug"

  make_agent_workspace "$slug"

  # agent-local handoff-out.sh
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/handoff-out.sh" <<'HANDOFF_AGENT'
#!/usr/bin/env bash
set -euo pipefail
# Volej po dokončení každého úkolu:
#   bash scripts/handoff-out.sh <task-id> "<popis výstupu>"
TASK_ID="${1:?task-id required}"
DESC="${2:?popis required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_SLUG="$(basename "$AGENT_DIR")"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# 1. Zapsat do outboxu
OUTBOX="$AGENT_DIR/context/outbox"
mkdir -p "$OUTBOX"
cat > "$OUTBOX/done_${TASK_ID}_${TS//:/}.md" <<EOF
# Handoff: $TASK_ID
- Agent: $AGENT_SLUG
- Task: $TASK_ID
- Completed: $TS
- Description: $DESC
EOF

# 2. Aktualizovat state
sed -i.bak "s/Status: in-progress/Status: done/" "$AGENT_DIR/state/current-task.md" 2>/dev/null || true
sed -i.bak "s/Status: blocked/Status: done/" "$AGENT_DIR/state/current-task.md" 2>/dev/null || true
rm -f "$AGENT_DIR/state/current-task.md.bak"

# 3. Notifikovat orchestrátora
ORCH_INBOX="$ROOT/agents/orchestrator/context/inbox"
mkdir -p "$ORCH_INBOX"
cp "$OUTBOX/done_${TASK_ID}_${TS//:/}.md" "$ORCH_INBOX/"

printf '[%s] ✓ Task %s dokončen → notifikace odeslána orchestrátorovi\n' "$TS" "$TASK_ID"
HANDOFF_AGENT
  chmod +x "$dir/scripts/handoff-out.sh"

  write_agent_instructions "$dir" "$name" "$role" "$gallup" "$mission" \
    "$inputs" "$outputs" "$handoff" "$quality" "$asks" "$extra"

  # Symlinky: CLAUDE.md a CODEX.md → AGENTS.md (source of truth)
  ln -sf AGENTS.md "$dir/CLAUDE.md"
  ln -sf AGENTS.md "$dir/CODEX.md"
}

make_agent_from_definition() {
  local definition_file="$1"
  local -a agent_fields=()

  mapfile -d '' -t agent_fields < <(python3 "$SOURCE_DEFINITION_PARSER" shell-fields "$definition_file")
  [[ "${#agent_fields[@]}" -eq 11 ]] || die "Neplatný počet polí v definici agenta: $definition_file"

  make_agent \
    "${agent_fields[1]}" \
    "${agent_fields[0]}" \
    "${agent_fields[2]}" \
    "${agent_fields[3]}" \
    "${agent_fields[4]}" \
    "${agent_fields[5]}" \
    "${agent_fields[6]}" \
    "${agent_fields[7]}" \
    "${agent_fields[8]}" \
    "${agent_fields[9]}" \
    "${agent_fields[10]}"
}
# =============================================================================
# Argumenty
# =============================================================================
REINIT=0
UPDATE_AGENTS=0
UPDATE_SKILLS=0
UPDATE_PROCESS=0
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reinit|--force-reinit)
      REINIT=1
      shift
      ;;
    --update-agents)
      UPDATE_AGENTS=1
      shift
      ;;
    --update-skills)
      UPDATE_SKILLS=1
      shift
      ;;
    --update-process)
      UPDATE_PROCESS=1
      shift
      ;;
    --develop)
      BOOTSTRAP_SOURCE_REF="develop"
      shift
      ;;
    --local-only)
      BOOTSTRAP_SOURCE_MODE="local"
      shift
      ;;
    -h|--help)
      usage
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$BOOTSTRAP_SOURCE_MODE" == "local" && "$BOOTSTRAP_SOURCE_REF" != "stable" ]]; then
  die "Přepínače --local-only a --develop nelze kombinovat."
fi

UPDATE_MODE=$(( UPDATE_AGENTS + UPDATE_SKILLS + UPDATE_PROCESS ))
if [[ "$UPDATE_MODE" -gt 0 && "$REINIT" -eq 1 ]]; then
  die "Přepínač --reinit nelze kombinovat s --update-* přepínači."
fi

ROOT_DIR="${ARGS[0]:-}"
PROJECT_INPUT_MD="${ARGS[1]:-}"

if [[ -z "$ROOT_DIR" ]]; then
  usage; exit 2
fi

if [[ -e "$ROOT_DIR" ]]; then
  [[ -d "$ROOT_DIR" ]] || die "Target existuje a není adresář: $ROOT_DIR"
fi

if [[ -n "$PROJECT_INPUT_MD" && ! -f "$PROJECT_INPUT_MD" ]]; then
  die "Zadaný soubor zadání nebyl nalezen: $PROJECT_INPUT_MD"
fi

initialize_source_assets
validate_source_agent_definitions

WORKFLOW_DIR="$ROOT_DIR/.aiworkflow"
PROJECT_NAME="$(basename "$ROOT_DIR")"
CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

printf '▶ Zakládám projekt: %s\n' "$PROJECT_NAME"

mkdir -p "$ROOT_DIR"

if [[ "$UPDATE_MODE" -gt 0 ]]; then
  # Selektivní update – workflow musí existovat
  [[ -d "$WORKFLOW_DIR" ]] || die "Workflow adresář neexistuje: $WORKFLOW_DIR. Nejdřív spusť bootstrap bez --update-* přepínačů."
elif [[ -e "$WORKFLOW_DIR" ]]; then
  [[ -d "$WORKFLOW_DIR" ]] || die "Workflow path existuje a není adresář: $WORKFLOW_DIR"
  if find "$WORKFLOW_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    if [[ "$REINIT" -eq 1 ]]; then
      printf '▶ Reinitializuji existující workflow v %s\n' "$WORKFLOW_DIR"
      # Zachovej zadani_projektu.md pokud existuje a obsahuje jiný obsah než template
      SAVED_ZADANI=""
      ZADANI_FILE="$WORKFLOW_DIR/zadani_projektu.md"
      if [[ -f "$ZADANI_FILE" ]] && grep -qv '^[[:space:]]*–\?[[:space:]]*$\|^#\|^$' "$ZADANI_FILE" 2>/dev/null; then
        SAVED_ZADANI="$(mktemp)"
        cp "$ZADANI_FILE" "$SAVED_ZADANI"
        printf '▶ Zachovávám zadani_projektu.md (obsahuje obsah)\n'
      fi
      rm -rf "$WORKFLOW_DIR"
    elif [[ -t 0 ]]; then
      printf 'Workflow struktura už existuje v %s. Přepsat ji? [y/N]: ' "$WORKFLOW_DIR"
      read -r confirm
      if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        rm -rf "$WORKFLOW_DIR"
      else
        die "Workflow nebyl změněn. Pro vynucenou reinitializaci použij --reinit."
      fi
    else
      die "Workflow struktura už existuje v $WORKFLOW_DIR. Spusť skript s parametrem --reinit."
    fi
  fi
fi

ensure_ignored "$ROOT_DIR/.gitignore"

# =============================================================================
# Selektivní update módy – provede jen požadovanou část a skončí
# =============================================================================
if [[ "$UPDATE_MODE" -gt 0 ]]; then
  if [[ "$UPDATE_AGENTS" -eq 1 ]]; then
    printf '▶ Update agentů...\n'
    validate_source_agent_definitions
    copy_agent_definition_assets
    while IFS= read -r definition_file; do
      make_agent_from_definition "$definition_file"
    done < <(find "$WORKFLOW_DIR/agent_definitions" -maxdepth 1 -type f -name '*.json' | sort)
    AGENT_CATALOG_TABLE="$(agent_catalog_table)"
    AGENT_CATALOG_TABLE_FILE="$(mktemp)"
    printf '%s\n' "$AGENT_CATALOG_TABLE" > "$AGENT_CATALOG_TABLE_FILE"
    # Aktualizuj katalog agentů v AGENTS.md
    if [[ -f "$WORKFLOW_DIR/AGENTS.md" ]]; then
      python3 - "$WORKFLOW_DIR/AGENTS.md" "$AGENT_CATALOG_TABLE_FILE" <<'PY'
import sys, re
from pathlib import Path
target = Path(sys.argv[1])
table = Path(sys.argv[2]).read_text(encoding="utf-8").strip()
content = target.read_text(encoding="utf-8")
# Nahraď sekci Dostupní Agenti (tabulku mezi ## Dostupní Agenti a dalším ##)
new_content = re.sub(
    r'(## Dostupní Agenti\n).*?(\n## )',
    lambda m: m.group(1) + table + '\n' + m.group(2),
    content, flags=re.DOTALL
)
target.write_text(new_content, encoding="utf-8")
PY
    fi
    printf '▶ Agenti aktualizováni.\n'
  fi

  if [[ "$UPDATE_SKILLS" -eq 1 ]]; then
    printf '▶ Update skills...\n'
    install_project_skills
    write_lore_scripts
    write_makefile
    printf '▶ Skills aktualizovány.\n'
  fi

  if [[ "$UPDATE_PROCESS" -eq 1 ]]; then
    printf '▶ Update procesu (AGENTS.md + entrypoints + brief-template)...\n'
    validate_source_agent_definitions
    AGENT_CATALOG_TABLE="$(agent_catalog_table)"
    AGENT_CATALOG_TABLE_FILE="$(mktemp)"
    printf '%s\n' "$AGENT_CATALOG_TABLE" > "$AGENT_CATALOG_TABLE_FILE"
    # Přegeneruj root entrypoint AGENTS.md/CLAUDE.md/CODEX.md
    write_root_entrypoints
    # Přegeneruj .aiworkflow/AGENTS.md (Cold Start, Lore Contract, katalog agentů)
    write_workflow_agents_md
    # Přegeneruj brief-template.md (sekce ## Lore Context)
    write_brief_template
    printf '▶ Proces aktualizován.\n'
  fi

  exit 0
fi

write_root_entrypoints
install_project_skills
write_lore_scripts

# =============================================================================
# Root struktura
# =============================================================================
mkdir -p "$WORKFLOW_DIR"/{agent_definitions,agents,orchestration/{plans,runs,logs,decisions,metrics,scripts,tmp,assignments},shared/{docs,schemas,templates,glossary,conventions},project/{requirements,architecture,design,research,planning},implementation/{src,infra,ci},data/{schemas,migrations,samples,seeds},tools,docs,archive}


# =============================================================================
# AGENTI
# =============================================================================
copy_agent_definition_assets
copy_shared_templates
copy_dashboard_script
while IFS= read -r definition_file; do
  make_agent_from_definition "$definition_file"
done < <(find "$WORKFLOW_DIR/agent_definitions" -maxdepth 1 -type f -name '*.json' | sort)

# =============================================================================
# Root AGENTS.md (orchestrátor entry point)
# =============================================================================
AGENT_CATALOG_TABLE="$(agent_catalog_table)"
AGENT_SLUG_LIST="$(agent_slug_list)"
AGENT_COUNT="$(agent_count)"
AGENT_CATALOG_TABLE_FILE="$(mktemp)"
printf '%s\n' "$AGENT_CATALOG_TABLE" > "$AGENT_CATALOG_TABLE_FILE"

write_workflow_agents_md

# =============================================================================
# Zadání projektu
# =============================================================================
# Pokud --reinit zachoval předchozí zadání, obnov ho (má přednost před vším)
if [[ -n "${SAVED_ZADANI:-}" && -f "$SAVED_ZADANI" ]]; then
  cp "$SAVED_ZADANI" "$WORKFLOW_DIR/zadani_projektu.md"
  rm -f "$SAVED_ZADANI"
  printf '▶ Zadání projektu obnoveno ze zálohy.\n'
elif [[ -n "$PROJECT_INPUT_MD" ]]; then
  cp "$PROJECT_INPUT_MD" "$WORKFLOW_DIR/zadani_projektu.md"
else
  cat > "$WORKFLOW_DIR/zadani_projektu.md" <<'EOF'
# Zadání projektu

## Shrnutí (1 věta)
–

## Cíle
–

## Cílový uživatel a jeho problém
–

## Scope IN
–

## Scope OUT
–

## Omezení / předpoklady
–

## Deliverables
–

## Acceptance criteria (projekt je hotový když...)
–

## Rizika / otevřené otázky
–

## Workflow reference
- Dispatch agentů: skill `/dispatch-agent`
- Uzavření iterace: skill `/close-iteration`
- Checkpoint protokol a handoff: viz `docs/agent-workflow.md`
EOF
fi

# =============================================================================
# Project living documents
# =============================================================================
cat > "$WORKFLOW_DIR/project/done-criteria.md" <<'EOF'
# Project Definition of Done

## Projekt je uzavřen když:
- [ ] Všechny requirements mají ověřená AC
- [ ] Security review proběhl bez otevřených CRITICAL/HIGH nálezů
- [ ] QA: Go nebo Conditional Go s odůvodněním
- [ ] Dokumentace je aktuální
- [ ] Finální verze je v `artifacts/final/`
- [ ] Všechny decision records jsou doplněné

## Poznámky
–
EOF

cat > "$WORKFLOW_DIR/project/scope-changes.md" <<'EOF'
# Scope Changes Log

| Datum | Změna | Důvod | Schválil |
|---|---|---|---|
| – | – | – | – |
EOF

# =============================================================================
# Shared conventions a dokumenty
# =============================================================================
cat > "$WORKFLOW_DIR/shared/conventions/naming.md" <<'EOF'
# Naming Conventions

## Agent slugs
kebab-case (__AGENT_SLUG_LIST__)

## Soubory
- Markdown: `snake_case.md` nebo prefixy (`brief_`, `handoff_`, `report_`)
- Logs: `YYYY-MM-DD_run.log`
- Decisions: `DR-001_short-topic.md`

## Iteration IDs
`iter-001`, `iter-002`, ... (nebo `iter-001a`, `iter-001b` pro fáze)

## Task IDs
`T-001`, `T-002`, ... (unikátní v rámci iterace, přiřazuje Orchestrátor)
EOF
safe_replace "$WORKFLOW_DIR/shared/conventions/naming.md" "__AGENT_SLUG_LIST__" "$AGENT_SLUG_LIST"


cat > "$WORKFLOW_DIR/shared/docs/lessons_learned.md" << 'EOF'
# Lessons Learned

Tento soubor udržuje orchestrátor. Každou chybu nebo opravu od uživatele sem zapiš – stručně, konkrétně, s datem.
Přečti ho jako PRVNÍ krok každé session (viz Cold Start Protokol v AGENTS.md).

## Jak přidávat záznamy
```
### LL-XXX – YYYY-MM-DD – <krátký název>
**Co se stalo:** <popis chyby nebo problému>
**Dopad:** <co to způsobilo>
**Pravidlo do budoucna:** <konkrétní instrukce jak se tomu vyhnout>
```

---

## Záznamy

### LL-001 – 2026-03-01 – Plán nebyl vyplněn před zahájením práce
**Co se stalo:** Orchestrátor nechal plan.md jako prázdný template (obsahoval placeholder text) a rovnou začal pracovat na taskech bez vyplnění Goal a Master Checklistu.
**Dopad:** Neexistoval master checklist → nebylo co odškrtávat → stav iterace byl neviditelný.
**Pravidlo do budoucna:** Po `make init-iteration` je plan.md TEMPLATE. Orchestrátor ho MUSÍ vyplnit (Goal + T-ID tasky) PŘED zahájením jakékoli práce. Prázdný plán = BLOCKER.

### LL-002 – 2026-03-01 – Tasky nebyly odškrtávány průběžně
**Co se stalo:** Orchestrátor nedokončoval odškrtnutí checklistu po každém tasku – buď odškrtl jen první task, nebo nechával odškrtnutí na konec.
**Dopad:** Master checklist nereflektoval skutečný stav → uživatel nemohl sledovat průběh.
**Pravidlo do budoucna:** Každý task se odškrtne IHNED po dokončení – ne nakonec, ne v dávce. Postup: otevři plan.md → `- [ ]` → `- [x]` → ulož → teprve pak pokračuj dalším taskem.

EOF

cat > "$WORKFLOW_DIR/shared/conventions/briefing-rules.md" <<'EOF'
# Briefing Rules

Každý brief obsahuje:
1. **Cíl** – jedna věta
2. **Kontext** – co už víme
3. **Scope IN / OUT**
4. **Task list s task-id** – pro checkbox mechanismus (T-001, T-002, ...)
5. **Acceptance criteria**
6. **Vstupy** – konkrétní soubory nebo reference
7. **Výstupy** – co a kam uložit
8. **Rizika / omezení**
9. **Iteration link**

Každý úkol v task listu musí mít task-id, které agent použije v handoff-out.sh.
EOF

cat > "$WORKFLOW_DIR/docs/agent-workflow.md" <<'EOF'
# Agent Workflow

## Checkpoint Protokol (pro každého agenta)
Po dokončení každého úkolu:
1. Aktualizuj `state/current-task.md` → status: done
2. Zavolej `bash scripts/handoff-out.sh <task-id> "<popis>"`

Orchestrátor po přijetí notifikace provede dispatch protokol viz `/dispatch-agent`.
Pro uzavření iterace viz `/close-iteration`.

## Feedback Loop (Reopen)
Pokud Reviewer nebo Tester najde problém:
1. Orchestrátor zavolá `make reopen-task AGENT=coder TASK=T-003 REASON="..."`
2. Task se vrátí do agentova inboxu jako `reopen_T-003_*.md`
3. Agent opraví, znovu zavolá handoff-out.sh

## Doporučený rytmus iterace
1. Requirements → pochopení uživatelských potřeb
2. Architect → návrh řešení
3. Challenger → oponentura návrhu
4. Security → bezpečnostní review návrhu
5. Coder → implementace
6. Reviewer → code review
7. Tester → QA validace
8. BFU → uživatelský pohled
9. Process → retrospektiva procesu
EOF

# =============================================================================
# Šablony
# =============================================================================
write_brief_template

cat > "$WORKFLOW_DIR/shared/templates/handoff-template.md" <<'EOF'
# Handoff

- **From**: <agent>
- **To**: <agent>
- **Task ID**: T-XXX
- **Iteration**: iter-XXX
- **Date**: YYYY-MM-DD

## Task Summary
<!-- Co bylo řešeno -->

## Inputs Used
–

## Outputs Produced
–

## Key Decisions / Assumptions
–

## Open Questions
–

## Risks
–

## Recommended Next Step
–
EOF

cat > "$WORKFLOW_DIR/shared/templates/decision-record-template.md" <<'EOF'
# Decision Record

- **ID**: DR-XXX
- **Date**: YYYY-MM-DD
- **Status**: proposed | accepted | superseded
- **Related Iteration**: iter-XXX

## Context
<!-- Proč rozhodnutí vzniká -->

## Decision
<!-- Co bylo rozhodnuto -->

## Alternatives Considered
- Option A:
- Option B:

## Trade-offs
<!-- Výhody / nevýhody -->

## Consequences
<!-- Dopady na architekturu / implementaci / data / workflow -->

## Follow-up Actions
–
EOF

cat > "$WORKFLOW_DIR/shared/templates/test-report-template.md" <<'EOF'
# Test Report

- **Report ID**: TR-XXX
- **Iteration**: iter-XXX
- **Date**: YYYY-MM-DD

## Scope
–

## Environment / Build
–

## Test Cases Executed
–

## Results
- Passed:
- Failed:
- Blocked:

## Bugs / Findings
–

## Regression Risk
Low / Medium / High

## Recommendation
Go / No-Go / Conditional Go (důvod)
EOF

cat > "$WORKFLOW_DIR/shared/templates/iteration-plan-template.md" <<'EOF'
# Iteration Plan: ITER-ID

- **Created**: YYYY-MM-DD
- **Goal**: <!-- jedna věta -->
- **Status**: active | closed

## Master Checklist
<!-- Orchestrátor udržuje a průběžně odškrtává – IHNED po přijetí done notifikace -->
- [ ] T-001: <agent> – <popis>
- [ ] T-002: <agent> – <popis>

## Quality Gates
- [ ] Requirements reviewed
- [ ] Architecture reviewed + Challenger oponentura
- [ ] Security review
- [ ] Code review (Reviewer)
- [ ] QA validace (Tester)
- [ ] BFU pohled (pokud relevantní)

## Exit Criteria
–

## Decisions Made This Iteration
–

## Retrospective Notes
–
EOF

# =============================================================================
# Orchestration scripty
# =============================================================================
cat > "$WORKFLOW_DIR/orchestration/scripts/scan-agents.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
printf 'Dostupní agenti:\n'
find "$ROOT/agents" -mindepth 1 -maxdepth 1 -type d | sort | while read -r d; do
  slug="$(basename "$d")"
  inbox_count="$(find "$d/context/inbox" -name "*.md" ! -name ".gitkeep" 2>/dev/null | wc -l | tr -d ' ')"
  done_count="$(find "$d/context/outbox" -name "done_*.md" 2>/dev/null | wc -l | tr -d ' ')"
  printf '  %-20s  inbox: %s  done notifications: %s\n' "$slug" "$inbox_count" "$done_count"
done
EOF
chmod +x "$WORKFLOW_DIR/orchestration/scripts/scan-agents.sh"

cat > "$WORKFLOW_DIR/orchestration/scripts/new-iteration.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
ITER="${2:?iteration id required (např. iter-001)}"

mkdir -p "$ROOT/orchestration/runs/$ITER"/{briefs,collected,logs,reviews}
mkdir -p "$ROOT/orchestration/metrics/$ITER"

PLAN="$ROOT/orchestration/runs/$ITER/plan.md"

if [[ ! -f "$PLAN" ]]; then
  cp "$ROOT/shared/templates/iteration-plan-template.md" "$PLAN"
  # Portabilní náhrada (macOS + Linux)
  tmp="$(mktemp)"
  sed "s/ITER-ID/$ITER/g" "$PLAN" > "$tmp" && mv "$tmp" "$PLAN"
fi

# Aktualizuj symlink orchestration/plans/active.md → aktuální plan
mkdir -p "$ROOT/orchestration/plans"
ln -sf "../runs/$ITER/plan.md" "$ROOT/orchestration/plans/active.md"

# Zadání iterace – vytvoř soubor pokud ještě neexistuje (pre-fill od uživatele ho zachováme)
mkdir -p "$ROOT/orchestration/assignments"
ASSIGNMENT="$ROOT/orchestration/assignments/$ITER.md"
if [[ ! -f "$ASSIGNMENT" ]]; then
  CREATED_DATE="$(date -u +"%Y-%m-%d")"
  cat > "$ASSIGNMENT" <<AEOF
# Zadání iterace $ITER

- **Iterace**: $ITER
- **Datum**: $CREATED_DATE
- **Stav**: active

## Cíl iterace (jedna věta)
–

## Kontext / motivace
–

## Scope IN
–

## Scope OUT
–

## Poznámky / otevřené otázky
–
AEOF
fi
ln -sf "../assignments/$ITER.md" "$ROOT/orchestration/assignments/active.md"

printf 'Iterace vytvořena: %s\n' "$ROOT/orchestration/runs/$ITER"
printf 'Plan: %s\n' "$PLAN"
printf 'Active symlink: orchestration/plans/active.md → runs/%s/plan.md\n' "$ITER"
printf 'Assignment: %s\n' "$ASSIGNMENT"
printf 'Assignment symlink: orchestration/assignments/active.md → assignments/%s.md\n' "$ITER"
printf 'Další krok: vyplň Goal a Master Checklist v plan.md\n'
EOF
chmod +x "$WORKFLOW_DIR/orchestration/scripts/new-iteration.sh"

cat > "$WORKFLOW_DIR/orchestration/scripts/close-iteration.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Uzavře iteraci: zkontroluje master checklist, archivuje outputs, zapíše exit summary
ROOT="${1:-.}"
ITER="${2:?iteration id required}"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

PLAN="$ROOT/orchestration/runs/$ITER/plan.md"
[[ -f "$PLAN" ]] || { printf 'Chyba: plan.md nenalezen: %s\n' "$PLAN" >&2; exit 1; }

# Zkontroluj otevřené tasky
open_tasks="$(grep -c '^\- \[ \]' "$PLAN" 2>/dev/null || true)"
if [[ "$open_tasks" -gt 0 ]]; then
  printf 'VAROVÁNÍ: %s nedokončených úkolů v master checklistu!\n' "$open_tasks"
  grep '^\- \[ \]' "$PLAN"
  printf '\nChceš přesto uzavřít iteraci? (y/N): '
  read -r confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { printf 'Uzavření zrušeno.\n'; exit 0; }
fi

# Collect outputs
bash "$ROOT/orchestration/scripts/collect-outputs.sh" "$ROOT" "$ITER"

# Exit summary
SUMMARY="$ROOT/orchestration/runs/$ITER/exit-summary.md"
cat > "$SUMMARY" <<ESEOF
# Exit Summary: $ITER

- **Closed**: $TS
- **Open tasks at close**: $open_tasks

## Collected Outputs
$(find "$ROOT/orchestration/runs/$ITER/collected" -type f ! -name '.gitkeep' | sort | sed 's|^|- |')

## Notes
–
ESEOF

# Aktualizuj status v plan.md
tmp="$(mktemp)"
sed 's/Status: active/Status: closed/' "$PLAN" > "$tmp" && mv "$tmp" "$PLAN"

# Archivuj notifikace z orchestrátor inboxu
ORCH_INBOX="$ROOT/agents/orchestrator/context/inbox"
ARCHIVE="$ROOT/orchestration/runs/$ITER/logs/inbox-archive"
mkdir -p "$ARCHIVE"
find "$ORCH_INBOX" -name "done_*.md" -exec mv {} "$ARCHIVE/" \; 2>/dev/null || true

# Odstraň symlink active.md (iterace je uzavřena)
ACTIVE_LINK="$ROOT/orchestration/plans/active.md"
if [[ -L "$ACTIVE_LINK" ]]; then
  rm "$ACTIVE_LINK"
  printf 'Symlink orchestration/plans/active.md odstraněn.\n'
fi

# Odstraň symlink assignments/active.md (soubor s zadáním zůstane jako archiv)
ASSIGNMENT_LINK="$ROOT/orchestration/assignments/active.md"
if [[ -L "$ASSIGNMENT_LINK" ]]; then
  rm "$ASSIGNMENT_LINK"
  printf 'Symlink orchestration/assignments/active.md odstraněn.\n'
fi

printf 'Iterace %s uzavřena.\n' "$ITER"
printf 'Exit summary: %s\n' "$SUMMARY"
printf 'Tip: spusť make -C .aiworkflow init-iteration ITER=iter-XXX pro další iteraci.\n'
EOF
chmod +x "$WORKFLOW_DIR/orchestration/scripts/close-iteration.sh"

cat > "$WORKFLOW_DIR/orchestration/scripts/dispatch-brief.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Použití: dispatch-brief.sh <root> <agent-slug> <brief-file>
ROOT="${1:-.}"
AGENT="${2:?agent-slug required}"
BRIEF_FILE="${3:?brief file required}"

DEST="$ROOT/agents/$AGENT/context/inbox/$(basename "$BRIEF_FILE")"
[[ -d "$ROOT/agents/$AGENT" ]] || { printf 'Chyba: agent nenalezen: %s\n' "$AGENT" >&2; exit 1; }
[[ -f "$BRIEF_FILE" ]] || { printf 'Chyba: brief nenalezen: %s\n' "$BRIEF_FILE" >&2; exit 1; }

cp "$BRIEF_FILE" "$DEST"
printf 'Brief dispatchnut do: %s\n' "$DEST"
EOF
chmod +x "$WORKFLOW_DIR/orchestration/scripts/dispatch-brief.sh"

cat > "$WORKFLOW_DIR/orchestration/scripts/collect-outputs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
ITER="${2:?iteration id required}"

TARGET="$ROOT/orchestration/runs/$ITER/collected"
mkdir -p "$TARGET"

while IFS= read -r agent_dir; do
  slug="$(basename "$agent_dir")"
  src="$agent_dir/artifacts/final"
  outbox="$agent_dir/context/outbox"
  if [[ -d "$src" ]]; then
    mkdir -p "$TARGET/$slug/artifacts"
    cp -R "$src"/. "$TARGET/$slug/artifacts/" 2>/dev/null || true
  fi
  if [[ -d "$outbox" ]]; then
    mkdir -p "$TARGET/$slug/handoffs"
    find "$outbox" -name "done_*.md" -exec cp {} "$TARGET/$slug/handoffs/" \; 2>/dev/null || true
  fi
done < <(find "$ROOT/agents" -mindepth 1 -maxdepth 1 -type d | sort)

printf 'Outputs collected do: %s\n' "$TARGET"
EOF
chmod +x "$WORKFLOW_DIR/orchestration/scripts/collect-outputs.sh"

cat > "$WORKFLOW_DIR/orchestration/scripts/reopen-task.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Použití: reopen-task.sh <root> <agent-slug> <task-id> <reason>
ROOT="${1:-.}"
AGENT="${2:?agent-slug required}"
TASK_ID="${3:?task-id required}"
REASON="${4:?reason required}"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

INBOX="$ROOT/agents/$AGENT/context/inbox"
[[ -d "$INBOX" ]] || { printf 'Chyba: agent nenalezen: %s\n' "$AGENT" >&2; exit 1; }

cat > "$INBOX/reopen_${TASK_ID}_${TS//:/}.md" <<REOPEN
# Reopen: $TASK_ID

- **Task ID**: $TASK_ID
- **Agent**: $AGENT
- **Reopened**: $TS
- **Reason**: $REASON

## Co je potřeba opravit
$REASON

## Postup
1. Přečti tento soubor
2. Oprav problém
3. Znovu zavolej: bash scripts/handoff-out.sh $TASK_ID "opraveno: $REASON"
REOPEN

printf 'Task %s vrácen agentovi %s\n' "$TASK_ID" "$AGENT"
printf 'Důvod: %s\n' "$REASON"
EOF
chmod +x "$WORKFLOW_DIR/orchestration/scripts/reopen-task.sh"

cat > "$WORKFLOW_DIR/orchestration/scripts/new-decision.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
ID="${2:?DR ID required (např. DR-001)}"
TOPIC="${3:?topic required}"

mkdir -p "$ROOT/orchestration/decisions"
FILE="$ROOT/orchestration/decisions/${ID}_${TOPIC}.md"
[[ -f "$FILE" ]] && { printf 'Decision record již existuje: %s\n' "$FILE"; exit 1; }

cp "$ROOT/shared/templates/decision-record-template.md" "$FILE"
tmp="$(mktemp)"
sed "s/DR-XXX/$ID/" "$FILE" > "$tmp" && mv "$tmp" "$FILE"

printf 'Vytvořen: %s\n' "$FILE"
printf 'Tip: zkopíruj relevantní DR do agents/<slug>/context/refs/ pro informování agentů.\n'
EOF
chmod +x "$WORKFLOW_DIR/orchestration/scripts/new-decision.sh"

# =============================================================================
# Tools
# =============================================================================
cat > "$WORKFLOW_DIR/tools/check-agent-folders.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
PARSER="$ROOT/tools/parse_agent_definitions.py"
DEFINITIONS_DIR="$ROOT/agent_definitions"
rc=0

compare_file_content() {
  local expected_file="$1"
  local actual_file="$2"
  local label="$3"
  if ! cmp -s "$expected_file" "$actual_file"; then
    printf 'Obsah neodpovídá definici: %s\n' "$label"
    rc=1
  fi
}

python3 "$PARSER" validate-dir "$DEFINITIONS_DIR" >/dev/null

expected_slugs="$(mktemp)"
cleanup() {
  rm -f "$expected_slugs"
}
trap cleanup EXIT

while IFS= read -r slug; do
  printf '%s\n' "$slug" >> "$expected_slugs"
  d="$ROOT/agents/$slug"
  definition_file=
  for candidate in "$DEFINITIONS_DIR"/*-"$slug".json; do
    if [[ -f "$candidate" ]]; then
      definition_file="$candidate"
      break
    fi
  done
  if [[ -z "$definition_file" ]]; then
    printf 'Chybí definice agenta: %s\n' "$slug"
    rc=1
    continue
  fi
  for p in AGENTS.md CLAUDE.md CODEX.md logs context/inbox context/outbox artifacts/final state/current-task.md; do
    if [[ ! -e "$d/$p" ]]; then
      printf 'Chybí: %s/%s\n' "$slug" "$p"
      rc=1
    fi
  done
  # Zkontroluj že AGENTS.md má Gallup sekci (CLAUDE.md a CODEX.md jsou symlinky)
  if ! grep -q 'Gallup Talent Profile' "$d/AGENTS.md" 2>/dev/null; then
    printf 'Varování: %s/AGENTS.md chybí Gallup Talent Profile\n' "$slug"
    rc=1
  fi

  expected_doc="$(mktemp)"
  python3 "$PARSER" render-agent-doc "$definition_file" > "$expected_doc"
  compare_file_content "$expected_doc" "$d/AGENTS.md" "$slug/AGENTS.md"
  rm -f "$expected_doc"
done < <(python3 "$PARSER" list-slugs "$DEFINITIONS_DIR")

for d in "$ROOT"/agents/*; do
  [[ -d "$d" ]] || continue
  slug="$(basename "$d")"
  if ! grep -Fqx "$slug" "$expected_slugs"; then
    printf 'Neočekávaný agent workspace bez definice: %s\n' "$slug"
    rc=1
  fi
done

expected_table="$(python3 "$PARSER" catalog-table "$DEFINITIONS_DIR")"
expected_count="$(python3 "$PARSER" count "$DEFINITIONS_DIR")"
root_agents_content="$(<"$ROOT/AGENTS.md")"
readme_content="$(<"$ROOT/README.md")"
if [[ "$root_agents_content" != *"$expected_table"* ]]; then
  printf 'Obsah neodpovídá definicím: root AGENTS.md katalog agentů\n'
  rc=1
fi
if [[ "$readme_content" != *"## Dostupní agenti ($expected_count)"* ]]; then
  printf 'Obsah neodpovídá definicím: README.md count agentů\n'
  rc=1
fi
if [[ "$readme_content" != *"$expected_table"* ]]; then
  printf 'Obsah neodpovídá definicím: README.md katalog agentů\n'
  rc=1
fi

[[ $rc -eq 0 ]] && printf 'Všechny agent složky jsou v pořádku.\n'
exit $rc
EOF
chmod +x "$WORKFLOW_DIR/tools/check-agent-folders.sh"

cat > "$WORKFLOW_DIR/tools/tree-summary.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-.}"
find "$ROOT" -maxdepth 3 -type d | sort
EOF
chmod +x "$WORKFLOW_DIR/tools/tree-summary.sh"

cat > "$WORKFLOW_DIR/tools/status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Zobrazí stav agentů: co mají v inboxu a jaký je jejich current-task status
ROOT="${1:-.}"

printf '=== Agent Status ===\n\n'
for d in "$ROOT"/agents/*; do
  [[ -d "$d" ]] || continue
  slug="$(basename "$d")"
  status="$(grep 'Status:' "$d/state/current-task.md" 2>/dev/null | head -1 | sed 's/.*Status: //' | tr -d ' \r' || echo 'unknown')"
  inbox="$(find "$d/context/inbox" -name "*.md" ! -name ".gitkeep" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%-20s  status: %-12s  inbox: %s\n' "$slug" "$status" "$inbox"
done

printf '\n=== Aktivní iterace ===\n'
find "$ROOT/orchestration/runs" -name "plan.md" | sort | while read -r plan; do
  iter="$(basename "$(dirname "$plan")")"
  status_line="$(grep 'Status:' "$plan" 2>/dev/null | head -1 || echo 'Status: unknown')"
  open="$(grep -c '^\- \[ \]' "$plan" 2>/dev/null || true)"
  done="$(grep -c '^\- \[x\]' "$plan" 2>/dev/null || true)"
  printf '  %s  [%s]  open: %s  done: %s\n' "$iter" "$status_line" "$open" "$done"
done
EOF
chmod +x "$WORKFLOW_DIR/tools/status.sh"

# =============================================================================
# Makefile
# =============================================================================
write_makefile

# =============================================================================
# .gitignore
# =============================================================================
cat > "$WORKFLOW_DIR/.gitignore" <<'EOF'
# OS / Editors
.DS_Store
Thumbs.db
*.swp
*.swo
.vscode/
.idea/

# Python
__pycache__/
*.pyc
.venv/
venv/

# Node
node_modules/
npm-debug.log*

# Build / temp
dist/
build/
tmp/
temp/
*.tmp

# Logs
**/logs/*.log

# Scratch (keep structure)
**/scratch/*
!**/scratch/.gitkeep

# Large artifacts
**/artifacts/final/*.zip
**/artifacts/final/*.tar.gz

# Secrets
.env
.env.*
*.secret
secrets/
EOF

# =============================================================================
# README
# =============================================================================
cat > "$WORKFLOW_DIR/README.md" <<'EOF'
# Multi-Agent AI Workspace

Workspace pro řízení projektů pomocí specializovaných AI agentů s Gallup talent profily.

## Rychlý start

```bash
# 1. Vyplň zadání
vim zadani_projektu.md

# 2. Vytvoř první iteraci
make -C .aiworkflow init-iteration ITER=iter-001

# 3. Zkontroluj agenty
make -C .aiworkflow list-agents

# 4. Zobraz celkový stav
make -C .aiworkflow status
```

## Dostupní agenti (__AGENT_COUNT__)
__AGENT_CATALOG_TABLE__

Každý agent má Gallup talent profil definující styl uvažování – viz `agents/<slug>/AGENTS.md`.
Zdroj definic agentů je `agent_definitions/*.json`.

## Checkbox mechanismus
- **Master checklist**: `orchestration/runs/<iter>/plan.md` – spravuje Orchestrátor
- **Dílčí checklist**: v každém `agents/<slug>/AGENTS.md` – spravuje agent
- Agent signalizuje hotovo: `bash scripts/handoff-out.sh <task-id> "<popis>"`
- Orchestrátor IHNED odškrtne master checklist po přijetí notifikace

## Workflow (jedna iterace)
1. Orchestrátor vytvoří plan s master checklistem
2. Dispatchne briefy: `make dispatch-brief AGENT=architect BRIEF=briefs/incoming/brief_arch.md`
3. Agenti pracují, průběžně odškrtávají dílčí checklisty
4. Hotový task → `handoff-out.sh` → notifikace do orchestrátor inboxu
5. Reviewer/Tester validují → případně `make reopen-task`
6. Uzavření: skill \`/close-iteration\`

## Kde hledat co
- Zadání projektu: `zadani_projektu.md`
- Stav projektu: `make status`
- Šablony: `shared/templates/`
- Rozhodnutí: `orchestration/decisions/`
- Výstupy iterace: `orchestration/runs/<iter>/collected/`
- Scope změny: `project/scope-changes.md`

## Model entry points
Zdroj pravdy je `AGENTS.md`.
Kvůli kompatibilitě jsou přítomné i symlinky `CLAUDE.md` a `CODEX.md`.
EOF
safe_replace "$WORKFLOW_DIR/README.md" "__AGENT_COUNT__" "$AGENT_COUNT"
replace_placeholder_from_file "$WORKFLOW_DIR/README.md" "__AGENT_CATALOG_TABLE__" "$AGENT_CATALOG_TABLE_FILE"

# =============================================================================
# CONTRIBUTING
# =============================================================================
cat > "$WORKFLOW_DIR/CONTRIBUTING.md" <<'EOF'
# Contributing

## Principy
- Odděluj požadavky, návrh, implementaci a validaci
- Každé rozhodnutí s dopadem zapisuj jako DR
- Každý task má task-id a je odškrtnut ihned po dokončení
- Minimalizuj nezdokumentované změny scope

## Checkpoint pravidlo (pro agenty i lidi)
Každý dokončený úkol musí být:
1. Označen v dílčím checklistu agenta
2. Signalizován přes handoff-out.sh (nebo manuálně do orchestrátor inboxu)
3. Odškrtnut v master checklistu orchestrátorem

## Scope změny
Jakákoli změna scope → zapsat do `project/scope-changes.md`.
EOF

# =============================================================================
# Placeholders
# =============================================================================
touch "$WORKFLOW_DIR/orchestration/logs/.gitkeep"
touch "$WORKFLOW_DIR/orchestration/metrics/.gitkeep"
touch "$WORKFLOW_DIR/archive/.gitkeep"

# Root symlinks for model-specific entry points inside workflow
ln -sfn AGENTS.md "$WORKFLOW_DIR/CLAUDE.md"
ln -sfn AGENTS.md "$WORKFLOW_DIR/CODEX.md"

# =============================================================================
# Git init
# =============================================================================
if [[ -d "$ROOT_DIR/.git" ]]; then
  printf '▶ Git repozitář už existuje, git init přeskočen.\n'
else
  printf '▶ Inicializuji git repozitář...\n'
  git -C "$ROOT_DIR" init -q
  printf '  Git init hotov. Auto-commit se neprovádí.\n'
fi

# =============================================================================
# Finální výpis
# =============================================================================
printf '\n✅ Projekt "%s" je připraven.\n\n' "$PROJECT_NAME"
printf 'Quick start:\n'
printf '  cd %s\n' "$ROOT_DIR"
printf '  vim .aiworkflow/zadani_projektu.md\n'
printf '  make -C .aiworkflow init-iteration ITER=iter-001\n'
printf '  make -C .aiworkflow list-agents\n'
printf '  make -C .aiworkflow status\n'
printf '\nValidace:\n'
printf '  make -C .aiworkflow validate\n'
