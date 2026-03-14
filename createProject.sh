#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# createProject.sh – Multi-agent AI workspace bootstrap
#
# Použití:
#   bash createProject.sh [--reinit] [--develop] [--local-only] <target_dir> [zadani_projektu_md]
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

Režimy source:
  default       Stáhne `agents/` a `tools/` z repo ref `stable`.
  --develop     Stáhne `agents/` a `tools/` z repo ref `develop`.
  --local-only  Použije lokální `./agents` a `./tools` vedle skriptu.

Příklady:
  bash createProject.sh ./my-project
  bash createProject.sh --develop ./my-project
  bash createProject.sh --local-only ./my-project
  bash createProject.sh ./already-cloned-repo
  bash createProject.sh --reinit ./already-cloned-repo
  bash createProject.sh ./my-project ./zadani_projektu.my-project.md
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
# Argumenty
# =============================================================================
REINIT=0
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reinit|--force-reinit)
      REINIT=1
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

if [[ -e "$WORKFLOW_DIR" ]]; then
  [[ -d "$WORKFLOW_DIR" ]] || die "Workflow path existuje a není adresář: $WORKFLOW_DIR"
  if find "$WORKFLOW_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    if [[ "$REINIT" -eq 1 ]]; then
      printf '▶ Reinitializuji existující workflow v %s\n' "$WORKFLOW_DIR"
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
write_root_entrypoints
install_project_skills

# =============================================================================
# Root struktura
# =============================================================================
mkdir -p "$WORKFLOW_DIR"/{agent_definitions,agents,orchestration/{plans,runs,logs,decisions,metrics,scripts,tmp},shared/{docs,schemas,templates,glossary,conventions},project/{requirements,architecture,design,research,planning},implementation/{src,infra,ci},data/{schemas,migrations,samples,seeds},tools,docs,archive}

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

cat > "$WORKFLOW_DIR/AGENTS.md" <<'EOF'
# Multi-Agent Project – Root Instructions

## Where to Start (Cold Start Protokol) – POVINNÉ POŘADÍ

**Přečti tyto kroky celé před tím, než cokoliv uděláš.**

### Krok 1 – Načti kontext
1. Přečti `zadani_projektu.md` – pochop cíl, scope a stav projektu
2. Přečti `project/done-criteria.md` – kdy je projekt hotový
3. Přečti `shared/docs/lessons_learned.md` – poučení z předchozích sezení (POVINNÉ)
4. Jako entrypoint orchestrator POVINNĚ přečti `agents/orchestrator/AGENTS.md` a přistupuj k sobě jako k jednomu z agentů, ne jako k výjimce mimo workflow.

### Krok 2 – Zjisti stav iterace
5. Zkontroluj aktivní iteraci:
   - Otevři `orchestration/plans/active.md`
   - **Existuje a není symlink na nic** → přečti plan.md, zkontroluj master checklist, pokračuj
   - **Neexistuje nebo je broken** → vytvoř novou iteraci: `make init-iteration ITER=iter-001`
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
EOF
replace_placeholder_from_file "$WORKFLOW_DIR/AGENTS.md" "__AGENT_CATALOG_TABLE__" "$AGENT_CATALOG_TABLE_FILE"

# =============================================================================
# Zadání projektu
# =============================================================================
if [[ -n "$PROJECT_INPUT_MD" ]]; then
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

printf 'Iterace vytvořena: %s\n' "$ROOT/orchestration/runs/$ITER"
printf 'Plan: %s\n' "$PLAN"
printf 'Active symlink: orchestration/plans/active.md → runs/%s/plan.md\n' "$ITER"
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

printf 'Iterace %s uzavřena.\n' "$ITER"
printf 'Exit summary: %s\n' "$SUMMARY"
printf 'Tip: spusť make init-iteration ITER=iter-XXX pro další iteraci.\n'
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
cat > "$WORKFLOW_DIR/Makefile" <<'EOF'
SHELL := /usr/bin/env bash
ROOT  := .

.PHONY: help list-agents status init-iteration close-iteration \
        new-decision dispatch-brief reopen-task validate tree dashboard

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
EOF

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
make init-iteration ITER=iter-001

# 3. Zkontroluj agenty
make list-agents

# 4. Zobraz celkový stav
make status
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
