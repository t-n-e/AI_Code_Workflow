---
name: dispatch-agent
version: "1.1"
author: spiderik
description: >
  Use when spawning one or more subagents via the native Task tool. Triggers on:
  "dispatch coder agent", "spawn reviewer", "run agents in parallel",
  "hand off to architect", "send brief to tester", "dispatch in parallel".
  Enforces the full protocol: write brief → save audit log → update plan.md →
  remove stale output → spawn with & → block on wait_for_output.sh → verify →
  tick plan.md immediately. Works for both single and parallel batch dispatch.
examples:
  - "dispatch coder agent for T-003"
  - "spawn reviewer and tester in parallel"
  - "hand off to architect agent"
  - "run security agent on iter-001 T-007"
  - "send brief to tester"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
---

# Dispatch Agent

**Every step is mandatory. Do not skip or reorder.**

## Output locations

Agents write their output to one of two locations depending on output type:

- **Inter-agent communication** (handoff, notification, status): `agents/<agent-slug>/context/outbox/<file>.md`
- **Artifact** (deliverable, draft, final output): `agents/<agent-slug>/artifacts/draft/<file>.md` or `agents/<agent-slug>/artifacts/final/<file>.md`

The brief must explicitly tell the agent where to write its output. The orchestrator watches that same path with `wait_for_output.sh`.

---

## Single Agent Dispatch

Follow these steps in order:

### 0.5 Lore Lookup (POVINNÝ – před každým briefem)

Před zapsáním briefu proveď lore lookup pro keywords daného tasku:

```bash
LORE_HITS=$(grep -r "<task-keyword>" ~/.lore/knowledge/ ~/.lore/lessons/ 2>/dev/null \
  | grep -v "^Binary" | head -10)
```

Pravidla:
- Použij 2–3 klíčová slova z popisu tasku (ne obecná slova jako "task" nebo "implement")
- Výsledek (nebo `—` pokud prázdný) vlož jako obsah sekce `## Lore Context` v briefu
- Hard limit: max 5 relevantních hitů; pokud je víc, vyber nejrelevantnější
- Scope lookup: POUZE `~/.lore/knowledge/` + `~/.lore/lessons/`
- NIKDY: grep do `~/.lore/intel-pass/` (intel-pass je VŽDY manuální skill `/intel-pass`)
- NIKDY: grep do `~/.lore/clients/` automaticky (klientská data)
- `~/.lore/processes/` jen pro tasky o workflow procesech

I prázdný lookup musí být zaznamenán – sekce `## Lore Context` v briefu nesmí chybět; pokud nic relevantního, hodnota je `—`.

### 1. Write the brief
Use the template at `.aiworkflow/shared/templates/brief-template.md` — fill every section, no placeholders left behind.
Save the completed brief to `agents/<agent-slug>/context/inbox/<brief>.md`.
The brief must include task-id, scope, acceptance criteria, and the exact output path the agent must write to (Expected Outputs section).

### 2. Save the prompt to the audit log
Save the exact prompt you will pass to `claude --print` to:
```
agents/<agent-slug>/logs/YYYY-MM-DDTHH-MM-SSZ__prompt_<iter>_<task>.md
```
This is the literal string passed to the subagent (e.g. "Read your brief in context/inbox/ and respond in this format: ..."), not a copy of the brief.
Dispatch is not considered complete without this audit trail.

### 3. Add entry to plan.md (BEFORE spawning)
Open `orchestration/runs/<iter>/plan.md` and add an **unchecked** entry:
```
- [ ] T-00X: <agent-slug> — <one-line description> (in-flight)
```
Save immediately. The plan must reflect in-flight work — never add entries after spawning.

### 4. Remove stale output
```bash
rm -f agents/<agent-slug>/context/outbox/<file>.md
# or
rm -f agents/<agent-slug>/artifacts/draft/<file>.md
```
Prevents `wait_for_output.sh` from returning immediately with an old file.

### 4.5 Write agent in-progress state

Before spawning, signal the dashboard that this agent is running.

If `agents/<slug>/state/current-task.md` does not exist (first dispatch):
```bash
mkdir -p agents/<agent-slug>/state
printf '# Current Task\n\n- **Task ID**: <task-id>\n- **Brief**: <brief-filename>\n- **Iteration**: <iter>\n- **Status**: in-progress\n- **Started**: <ISO timestamp>\n- **Completed**: –\n' \
  > agents/<agent-slug>/state/current-task.md
```

If the file already exists (re-dispatch or update):
```bash
sed -i "s/\*\*Status\*\*: .*/\*\*Status\*\*: in-progress/" agents/<agent-slug>/state/current-task.md
```

Then refresh the dashboard to reflect the running state before spawning the agent:
```bash
make -C .aiworkflow dashboard
```

### 5. Spawn the agent
Construct the prompt inline — the same text you saved to the audit log in step 2.
The agent runs in the project root, not in its own workspace. Use the prompt template
from the **Prompt Template** section below. Every placeholder must be filled; no generics left.

```
Spawn the agent using the native Task tool. Pass the prompt as the task description.
The agent runs autonomously — do not use `claude --print` or shell invocation.
After the Task completes, save the agent's response to:
`.aiworkflow/orchestration/logs/<agent-slug>-run.log`
```

### 6. Block until output is ready
```bash
.aiworkflow/orchestration/scripts/wait_for_output.sh \
  agents/<agent-slug>/context/outbox/<file>.md --timeout 300
# or
.aiworkflow/orchestration/scripts/wait_for_output.sh \
  agents/<agent-slug>/artifacts/draft/<file>.md --timeout 300
```

### 7. Verify the output
Read the output file and confirm it satisfies the acceptance criteria from the brief.
Do not proceed if the output is missing or does not meet criteria.

### 7b. Zapiš metrics záznam agenta
Po verify output přečti výsledek Agent tool a zapiš do `agents/<slug>/metrics/<iter>.md`
(pokud soubor neexistuje, vytvoř ho s hlavičkou `# Agent Metrics: <slug> / <iter>`):
```
## <task-id>
- **Timestamp**: <ISO timestamp>
- **total_tokens**: <z Agent tool výsledku>
- **tool_uses**: <z Agent tool výsledku>
- **duration_ms**: <z Agent tool výsledku>
```
Pokud Agent tool výsledek neobsahuje usage data → zapiš `N/A`.
Orchestrátorské tokeny se nesledují — nejsou dostupné.

### 8. Tick plan.md immediately
Open `orchestration/runs/<iter>/plan.md`, find the task line, and change it:
```
- [ ] T-00X  →  - [x] T-00X
```
Do this **immediately** — not at the end of the iteration, not in a batch.

After ticking, refresh the dashboard:
```bash
make -C .aiworkflow dashboard
```

### 9. Write an internal summary
One short paragraph: what the agent produced, whether it met criteria, any caveats.
Then continue to the next task.

---

## Parallel Batch Dispatch

When dispatching multiple independent agents in one iteration step:

### 0.5 Lore Lookup pro každý task (POVINNÝ – před každým briefem)

Před zapsáním všech briefů proveď lore lookup pro každý task samostatně:

```bash
# Pro každý task v batchi:
LORE_HITS=$(grep -r "<task-keyword>" ~/.lore/knowledge/ ~/.lore/lessons/ 2>/dev/null \
  | grep -v "^Binary" | head -10)
```

Pravidla (stejná jako pro Single Dispatch):
- Použij 2–3 klíčová slova z popisu konkrétního tasku (ne sdílené keywords pro celý batch)
- Výsledek (nebo `—` pokud prázdný) vlož jako obsah sekce `## Lore Context` v briefu daného agenta
- Hard limit: max 5 relevantních hitů per brief
- Scope lookup: POUZE `~/.lore/knowledge/` + `~/.lore/lessons/`
- NIKDY: grep do `~/.lore/intel-pass/` (intel-pass je VŽDY manuální)
- NIKDY: grep do `~/.lore/clients/` automaticky
- `~/.lore/processes/` jen pro tasky o workflow procesech

Každý brief v batchi musí mít vyplněnou sekci `## Lore Context`; prázdný výsledek = `—`, sekce nesmí chybět.

### 1. Write all briefs
Use `.aiworkflow/shared/templates/brief-template.md` for each agent — fill every section, no placeholders left behind.
Save each completed brief to `agents/<agent-slug>/context/inbox/<brief>.md`.
Write all briefs and prompt logs for **every** agent before spawning any of them.

### 2. Add all entries to plan.md
Add all unchecked task entries at once. Save before spawning.

After saving plan.md entries, refresh the dashboard:
```bash
make -C .aiworkflow dashboard
```

### 3. Remove all stale outputs
```bash
rm -f agents/<agent-a>/context/outbox/<file>.md
rm -f agents/<agent-b>/artifacts/draft/<file>.md
...
```

### 4. Write the output manifest
```bash
cat > .aiworkflow/orchestration/tmp/expected-outputs.txt <<EOF
agents/<agent-a>/context/outbox/<file>.md
agents/<agent-b>/artifacts/draft/<file>.md
EOF
```

### 4.5 Write in-progress state for all agents

Before spawning, signal the dashboard that each agent is running.

For each agent, if `agents/<slug>/state/current-task.md` does not exist (first dispatch):
```bash
mkdir -p agents/<agent-slug>/state
printf '# Current Task\n\n- **Task ID**: <task-id>\n- **Brief**: <brief-filename>\n- **Iteration**: <iter>\n- **Status**: in-progress\n- **Started**: <ISO timestamp>\n- **Completed**: –\n' \
  > agents/<agent-slug>/state/current-task.md
```

If the file already exists (re-dispatch or update):
```bash
sed -i "s/\*\*Status\*\*: .*/\*\*Status\*\*: in-progress/" agents/<agent-slug>/state/current-task.md
```

After writing all agents' state, refresh the dashboard once:
```bash
make -C .aiworkflow dashboard
```

### 5. Spawn all agents before waiting on any
Construct each prompt inline using the **Prompt Template** below — filled separately for each agent.

```
Spawn all agents using the native Task tool — one Task call per agent.
Launch all tasks before awaiting any output.
Do not use `claude --print` or background shell processes.
```
After the Task completes, save the agent's responses to:
`.aiworkflow/orchestration/logs/<agent-slug>-run.log`

### 6. Block on all outputs in a single call
```bash
.aiworkflow/orchestration/scripts/wait_for_output.sh \
  --paths-file .aiworkflow/orchestration/tmp/expected-outputs.txt \
  --timeout 300
```
**Never** call `wait_for_output.sh` once per agent in a loop — pass all paths in one call
so the timeout is shared across all agents, not multiplied.

### 7. Verify all outputs
Read each output file and confirm all acceptance criteria are met.

### 7b. Zapiš metrics záznamy agentů
Po verify každého agenta přečti výsledek Agent tool a zapiš do `agents/<slug>/metrics/<iter>.md`
(pokud soubor neexistuje, vytvoř ho s hlavičkou `# Agent Metrics: <slug> / <iter>`):
```
## <task-id>
- **Timestamp**: <ISO timestamp>
- **total_tokens**: <z Agent tool výsledku>
- **tool_uses**: <z Agent tool výsledku>
- **duration_ms**: <z Agent tool výsledku>
```
Pokud Agent tool výsledek neobsahuje usage data → zapiš `N/A`.
Orchestrátorské tokeny se nesledují — nejsou dostupné.

### 8. Tick all plan.md entries
Tick every completed task immediately. Do not batch for later.

After ticking all entries, refresh the dashboard:
```bash
make -C .aiworkflow dashboard
```

### 9. Write a batch summary
What each agent produced, which outputs met criteria, any issues.

---

## Timeout Handling

If `wait_for_output.sh` exits 1:
1. Check which files arrived vs. which did not (the script reports this).
2. Read `.aiworkflow/orchestration/logs/<agent-slug>-run.log` to diagnose.
3. Add `[!] TIMED OUT` to the task entry in plan.md.
4. **Stop and ask the user** — do not proceed past a timeout.

---

## Prompt Template

Použij tento template doslova. Každý placeholder musí být vyplněn — žádné generické hodnoty.

```text
Jsi <agent-slug> agent pro <iter> <task-id> v repo <repo-path>. Nejsi sám v codebase; ignoruj cizí změny mimo svůj scope a nesahej na ně.

Povinné pořadí před zahájením práce:
1. Přečti .aiworkflow/agents/<agent-slug>/AGENTS.md
2. Přečti brief: .aiworkflow/agents/<agent-slug>/context/inbox/<brief-filename>
3. Teprve pak pracuj

Scope IN:
- <scope-item>

Scope OUT:
- <out-scope-item> (neřeš nic jiného)

Workflow povinnosti po dokončení:
- Aktualizuj .aiworkflow/agents/<agent-slug>/state/current-task.md → status: done
- Zapiš výstup do .aiworkflow/agents/<agent-slug>/<output-path>
- Zavolej: bash .aiworkflow/agents/<agent-slug>/scripts/handoff-out.sh <task-id> "<handoff-message>"

Validace před handoffem:
- <validation-command>

Vrať se až po dokončení všech kroků s krátkým shrnutím výsledku a validace.
```

### Placeholder reference

| Placeholder | Příklad | Pravidlo |
|---|---|---|
| `<agent-slug>` | `coder` | lowercase, odpovídá adresáři v `.aiworkflow/agents/` |
| `<iter>` | `iter-001` | aktivní iterace z `orchestration/plans/active.md` |
| `<task-id>` | `T-009` | singleton — stejná hodnota na všech místech v promptu |
| `<repo-path>` | `/home/user/project` | absolutní cesta, nikdy relativní |
| `<brief-filename>` | `brief_coder_T-009_iter-001.md` | přesný název souboru, nikdy jen složka |
| `<output-path>` | `artifacts/final/report_iter-001.md` nebo `context/outbox/handoff.md` | dle typu výstupu |
| `<handoff-message>` | `"implemented validator fix per brief"` | v uvozovkách, popisuje co bylo uděláno |
| `<validation-command>` | `bash -n createProject.sh` | spustitelný příkaz, ne obecný pokyn |

---

## Critical Invariants

| Invariant | Why |
|---|---|
| Brief must specify the exact output path | Orchestrator needs to know what to watch |
| Write plan.md entry **before** spawning | Plan must reflect in-flight work |
| Remove stale output **before** spawning | Prevents false-immediate return from wait script |
| Pass all paths to one `wait_for_output.sh` call in parallel batches | Shared wall-clock timeout, not multiplied |
| Tick plan.md **immediately** on completion | Not in batches, not at iteration end |
| Never proceed past a timeout | Report and ask user |
| Never use `claude --print` to spawn agents | Nested Claude Code sessions crash all active sessions |

