# AI Code Workflow

CZ: [README.md](README.md)

A tool for developers who want to manage more complex projects using specialised AI agents in Claude Code. Each agent has a defined role (architect, coder, reviewer…), the workflow is coordinated by an orchestrator, and the resulting runtime is generated into a local `.aiworkflow/` directory in your project.

This repository contains the versioned source for the bootstrap of a local multi-agent workflow (a set of specialised AI agents coordinated by an orchestrator). The source files live in the GitHub repository, the bootstrap (a one-time run of `createProject.sh`) fetches them from the stable tag by default, and the resulting runtime is generated into a local `.aiworkflow/` directory that is not committed.

## What is in the repository

- `createProject.sh`: bootstrap script that creates or reinitializes a local workflow in a target project.
- `agents/*.json`: versioned agent definitions.
- `agents/README.md`: short rules for the agent definition format.
- `tools/parse_agent_definitions.py`: validation and helper commands for `agents/*.json`.

The repository root does not contain a ready-made versioned workflow tree. That is created only after running `createProject.sh`.

## Quick start

Create a new project:

```bash
bash createProject.sh ./my-project
```

Bootstrap from the development ref `develop`:

```bash
bash createProject.sh --develop ./my-project
```

Bootstrap only from local `agents/` and `tools/`:

```bash
bash createProject.sh --local-only ./my-project
```

Bootstrap into an already existing repository or directory:

```bash
bash createProject.sh ./already-cloned-repo
```

Force reinitialize an existing `.aiworkflow/`:

```bash
bash createProject.sh --reinit ./already-cloned-repo
```

Bootstrap with a custom project brief:

```bash
bash createProject.sh ./my-project ./zadani_projektu.my-project.md
```

## What `createProject.sh` does

The script:

1. resolves the bootstrap source:
   - by default from repository ref `stable`
   - via `--develop` from ref `develop`
   - via `--local-only` from local `./agents` and `./tools`
2. validates `agents/*.json` using `tools/parse_agent_definitions.py`
3. creates `.aiworkflow/` in the target directory
4. copies agent definitions into `.aiworkflow/agent_definitions/`
5. generates `agents/<slug>/AGENTS.md` and the agent workspace directories from each JSON file
6. creates the root entry points `AGENTS.md`, `CLAUDE.md`, `CODEX.md`
7. updates `.gitignore` with `.aiworkflow/`, `AGENTS.md`, `CLAUDE.md`, `CODEX.md`
8. runs `git init` if the target directory is not yet a git repository
9. generates lore scripts into `.aiworkflow/scripts/lore/` (CLI for shared memory in `~/.lore/`, installed via `make install-skills`)

The default remote mode requires repository access and trust in the selected remote ref. If you do not want or cannot use that access, use `--local-only` and keep local `agents/` and `tools/` directories next to the script.

If `.aiworkflow/` already exists and is not empty, the script:

- prompts before overwriting in an interactive shell
- exits with an error in non-interactive mode unless you use `--reinit`

Help:

```bash
bash createProject.sh --help
```

## Versioned source vs. local runtime

Versioned source in this repository:

```text
createProject.sh
agents/
  00-orchestrator.json
  10-requirements.json
  ...
  100-bfu.json
  README.md
tools/
  parse_agent_definitions.py
```

Local output after bootstrap in the target project:

```text
<project>/
  .aiworkflow/
  AGENTS.md
  CLAUDE.md -> AGENTS.md
  CODEX.md  -> AGENTS.md
```

In practice: you keep definitions and bootstrap logic in the versioned repository, while day-to-day agent work, briefs, artifacts, and iterations live only in the local `.aiworkflow/`.

## Source modes

- `default`: the bootstrap fetches `agents/` and `tools/` from the GitHub repository stable ref `stable`
- `--develop`: the bootstrap fetches `agents/` and `tools/` from ref `develop`
- `--local-only`: the bootstrap uses local `./agents` and `./tools` next to the script and downloads nothing

For GitHub remote bootstrap, the script first tries a non-interactive `git clone` against the provided URL. If direct clone fails, it tries the GitHub SSH URL next and only then retries via `gh repo clone` when `gh auth status` is available. This avoids a username/password prompt and prefers the SSH path.

If the remote fetch fails or the requested ref is unavailable, the script exits with an error and points to `--local-only`.

## The `agents/` directory

Each agent has one JSON file named `NN-slug.json`.

Examples from the current repository:

- `agents/00-orchestrator.json`
- `agents/55-prototype.json`
- `agents/60-coder.json`
- `agents/70-reviewer.json`

The numeric prefix defines ordering. `metadata.order` must match the file prefix and `metadata.slug` must match the slug part of the filename.

Current validation commands:

```bash
python3 tools/parse_agent_definitions.py validate-dir agents
python3 tools/parse_agent_definitions.py count agents
python3 tools/parse_agent_definitions.py slug-list agents
python3 tools/parse_agent_definitions.py catalog-table agents
```

## Meaning of fields in an agent JSON definition

Each file must have `apiVersion: "aiworkflow/v1"` and `kind: "AgentDefinition"`.

- `metadata.name`: human-readable agent name, for example `Coder`
- `metadata.slug`: stable identifier used in directories, for example `coder`
- `metadata.order`: ordering of the agent in the catalog and during bootstrap
- `role`: short role description, shown in generated `AGENTS.md`
- `gallup_profile`: work style and talent profile of the agent
- `mission`: main purpose of the agent
- `primary_inputs`: what the agent starts work from
- `required_outputs`: what the agent must deliver
- `handoff_targets`: who the agent typically hands work off to
- `quality_gate`: definition of done for that agent
- `ask_first_triggers`: when the agent should ask questions first
- `extra_rules`: additional role-specific rules

The parser also checks:

- JSON must be an object
- all required content sections must be non-empty strings
- `metadata.slug` may contain only `a-z`, `0-9`, and `-`
- `orchestrator` must exist
- `metadata.name` and `role` must be single-line values without `|`

## Concrete JSON example

A shortened example based on the current format:

```json
{
  "apiVersion": "aiworkflow/v1",
  "kind": "AgentDefinition",
  "metadata": {
    "name": "Coder",
    "slug": "coder",
    "order": 60
  },
  "role": "Senior software engineer – implements according to the approved design.",
  "gallup_profile": "**Domains:** Executing ...",
  "mission": "Implement decisions approved by the architect.",
  "primary_inputs": "- Approved architecture\n- Task assignment with AC",
  "required_outputs": "- Implementation (code)\n- Short technical change record",
  "handoff_targets": "- Reviewer\n- Tester\n- Orchestrator",
  "quality_gate": "- Implementation matches the approved design",
  "ask_first_triggers": "- What is the exact task scope?",
  "extra_rules": "- Read existing code first, then write."
}
```

The real files in this repository contain longer Markdown texts, but still stored as JSON strings. That matters because the bootstrap generates the final `AGENTS.md` files for individual agents from them.

## What the resulting `.aiworkflow/` looks like

After bootstrap, the project gets roughly this structure:

```text
.aiworkflow/
  AGENTS.md
  README.md
  Makefile
  agent_definitions/
    *.json
    README.md
  agents/
    orchestrator/
    coder/
    reviewer/
    tester/
    ...
  orchestration/
    plans/
    runs/
    scripts/
    decisions/
  project/
    requirements/
    architecture/
    design/
    research/
    planning/
  shared/
    docs/
    schemas/
    templates/
    glossary/
    conventions/
  implementation/
  data/
  tools/
  archive/
```

Each agent has its own workspace:

```text
.aiworkflow/agents/coder/
  AGENTS.md
  scripts/handoff-out.sh
  context/inbox/
  context/outbox/
  context/refs/
  artifacts/drafts/
  artifacts/final/
  state/current-task.md
  logs/
  runs/
  scratch/
  tests/
```

Purpose of the main parts:

- `agent_definitions/`: runtime copy of the versioned JSON definitions
- `agents/<slug>/`: workspace of a specific role
- `orchestration/`: iterations, checklists, brief dispatch, decision records
- `project/`: brief, design, planning, and other project materials
- `shared/`: shared templates and conventions
- `tools/`: workflow helper scripts

## How the workflow works in practice

A typical iteration flow:

1. bootstrap creates `.aiworkflow/`
2. orchestrator starts from `.aiworkflow/AGENTS.md`
3. creates an iteration with `make init-iteration ITER=iter-001`
4. fills in `orchestration/plans/active.md`
5. sends briefs into `agents/<slug>/context/inbox/`
6. the agent works on the task and updates `state/current-task.md`
7. when done, it runs `bash scripts/handoff-out.sh <task-id> "<description>"`
8. the script writes a handoff into the agent `context/outbox/` and copies a notification to `agents/orchestrator/context/inbox/`
9. orchestrator checks off the master checklist and optionally sends the next round of review/testing

Most-used commands inside the generated `.aiworkflow/`:

```bash
make list-agents
make status
make init-iteration ITER=iter-001
make dispatch-brief AGENT=coder BRIEF=/path/to/brief.md
make reopen-task AGENT=coder TASK=T-001 REASON="fix issue"
make close-iteration ITER=iter-001
make validate
make tree
make dashboard
```

`make dashboard` generates `.aiworkflow/dashboard.html` — open it in a browser. The dashboard shows the active iteration state (checklist, progress), agents (status, token usage), agent outputs (links to artifact files), and metrics. The page auto-refreshes every 10 seconds.

## Agent Prompts

The `agent-prompts/` directory contains ready-made system prompts for each agent. These files can be used directly as a system prompt or as the first message in a Claude chat session, without requiring Claude Code.

## Skills

The `skills/` directory contains the source files for project skills. A skill is a prompt document that Claude reads and executes as a sequence of steps. Unlike agents, skills are triggered explicitly by the user via a slash command (e.g. `/dispatch-agent`). The slash command is entered directly in Claude Code – in the terminal or IDE where your Claude Code session is running.

During bootstrap, `createProject.sh` copies each `skills/<name>/SKILL.md` into `.claude/commands/<name>.md` in the target project. This makes skills available as project commands in Claude Code, without being global or committed to the project.

To add a new skill: create `skills/<name>/SKILL.md` in this repository. No changes to `createProject.sh` are needed.

### dispatch-agent

**Purpose**: Enforces the correct protocol when dispatching subagents – audit log, updating plan.md before spawning, waiting for output, and ticking the checklist immediately on completion.

**When to use**: Whenever the orchestrator spawns an agent via `claude --print`. The skill covers the full sequence: write the brief → save the prompt to the audit log → add an entry to plan.md → remove stale output → spawn the agent → wait for output → verify → tick.

**Trigger**: `/dispatch-agent`

### close-iteration

**Purpose**: Standardises and automates iteration closure – replacing a lengthy manual process with a repeatable procedure (checklist review, commit, push, optional PR, running close-iteration.sh, and a final summary).

**When to use**: At the end of each iteration, once all tasks are done (or the user has decided on their status) and the outputs need to be archived, the branch pushed, and active.md closed.

**Trigger**: `/close-iteration`

## Lore – shared memory across projects

`lore` is a standalone CLI for a persistent knowledge base shared across projects (lessons learned, processes, client context). Records live in `~/.lore/` as a git repository and are typed – routed into `lessons/`, `processes/`, `clients/`, and `projects/`. Agents read from lore (grep over `~/.lore/`) and write exclusively via `lore new` / `lore git commit`; a direct `git commit` into `~/.lore/` is blocked by a pre-commit hook (write gate). Lore is local-only by default – a remote is configured only if you set one yourself.

During bootstrap, `createProject.sh` generates the lore scripts into `.aiworkflow/scripts/lore/`. The `lore` CLI itself is installed into `~/.local/` from the generated `.aiworkflow/`:

```bash
make install-skills     # installs the lore CLI into ~/.local/bin and ~/.local/lib/lore/
make validate-lore      # validates the records in ~/.lore/
```

Most-used commands:

```bash
lore init [--remote <url>]      # initializes ~/.lore/ as a git repository
lore new <type> "<name>"        # new record (lessons/processes/clients/projects)
lore health [--json]            # status of ~/.lore/
lore doctor                     # interactive diagnostics
lore git <git-args>             # git operations over ~/.lore/ (commit/push/pull)
lore rescue                     # rescues an existing ~/.lore/ without a git repo
```

## When to change what

- want to change bootstrap behavior: edit `createProject.sh`
- want to change an agent role or instructions: edit `agents/<NN-slug>.json`
- want to verify definition consistency: run `tools/parse_agent_definitions.py`
- want to work on a concrete project: work only in its local `.aiworkflow/`

## Validation after changes

Minimal checks in this repository:

```bash
python3 tools/parse_agent_definitions.py validate-dir agents
bash -n createProject.sh
```
