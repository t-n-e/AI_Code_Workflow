# AI Code Workflow

EN: [README.en.md](README.en.md)

Nástroj pro vývojáře, kteří chtějí řídit složitější projekty pomocí specializovaných AI agentů v Claude Code. Každý agent má svou roli (architekt, coder, reviewer…), workflow koordinuje orchestrátor a výsledný runtime vznikne v lokálním `.aiworkflow/` tvého projektu.

Repo obsahuje versioned zdroj bootstrapu pro lokální multi-agent workflow (spolupráce specializovaných AI agentů řízených orchestrátorem). Zdrojové soubory jsou v GitHub repu, bootstrap (jednorázové spuštění `createProject.sh`) si je defaultně stáhne ze stable tagu a výsledný runtime vygeneruje do lokálního `.aiworkflow/`, které se necommití.

## Co je v repu

- `createProject.sh`: bootstrap skript, který založí nebo reinitializuje lokální workflow v cílovém projektu.
- `agents/<type>/*.json`: versioned definice agentů rozdělené do typových podsložek (např. `core/`, `business/`, `enablement/`).
- `agents/README.md`: stručná pravidla pro formát agent definic.
- `skills/<název>/SKILL.md`: zdrojová knihovna projektových skills kopírovaných při bootstrapu do `.claude/commands/` cílového projektu.
- `tools/parse_agent_definitions.py`: validace a pomocné výpisy nad `agents/**/*.json`.

Repo root neobsahuje hotový workflow template jako versioned strom. Ten vzniká až spuštěním `createProject.sh`.

## Rychlý start

Vytvoření nového projektu:

```bash
bash createProject.sh ./my-project
```

Bootstrap z vývojového refu `develop`:

```bash
bash createProject.sh --develop ./my-project
```

Bootstrap čistě z lokálních `agents/` a `tools/`:

```bash
bash createProject.sh --local-only ./my-project
```

Bootstrap nad už existujícím repem nebo adresářem:

```bash
bash createProject.sh ./already-cloned-repo
```

Vynucená reinitializace existujícího `.aiworkflow/`:

```bash
bash createProject.sh --reinit ./already-cloned-repo
```

Bootstrap s vlastním zadáním projektu:

```bash
bash createProject.sh ./my-project ./zadani_projektu.my-project.md
```

## Co `createProject.sh` udělá

Skript:

1. načte bootstrap source:
   - defaultně z repo refu `stable`
   - přes `--develop` z refu `develop`
   - přes `--local-only` z lokálních `./agents` a `./tools`
2. validuje `agents/**/*.json` přes `tools/parse_agent_definitions.py`
3. vytvoří v cílovém adresáři `.aiworkflow/`
4. zkopíruje definice agentů do `.aiworkflow/agent_definitions/`
5. z každého JSON souboru vygeneruje `agents/<slug>/AGENTS.md` a pracovní adresáře agenta
6. vytvoří kořenové entrypointy `AGENTS.md`, `CLAUDE.md`, `CODEX.md`
7. zkopíruje `skills/*/SKILL.md` do `.claude/commands/` jako projektové skills
8. doplní `.gitignore` o `.aiworkflow/`, `.claude/`, `AGENTS.md`, `CLAUDE.md`, `CODEX.md`
9. pokud cílový adresář ještě není git repo, provede `git init`

Defaultní remote režim vyžaduje přístup do repa a důvěru ve zvolený remote ref. Pokud přístup nechcete nebo nemáte, použijte `--local-only` a mějte vedle skriptu připravené lokální adresáře `agents/` a `tools/`.

Pokud `.aiworkflow/` už existuje a není prázdné, skript:

- v interaktivním shellu nabídne přepsání
- v neinteraktivním režimu skončí chybou, pokud nepoužijete `--reinit`

Nápověda:

```bash
bash createProject.sh --help
```

## Versioned zdroj vs. lokální runtime

Versioned zdroj v tomto repu:

```text
createProject.sh
agents/
  core/
    00-orchestrator.json
    10-requirements.json
    ...
  business/
    15-product-strategist.json
    ...
  enablement/
    51-learning-designer.json
    ...
  README.md
skills/
  dispatch-agent/
    SKILL.md
    scripts/wait_for_output.sh
tools/
  parse_agent_definitions.py
```

Lokální výstup po bootstrapu v cílovém projektu:

```text
<project>/
  .aiworkflow/
  .claude/              ← gitignored
    commands/
      dispatch-agent.md
  AGENTS.md
  CLAUDE.md -> AGENTS.md
  CODEX.md  -> AGENTS.md
```

Prakticky: definice a bootstrap držíte ve versioned repu, ale denní práce agentů, briefy, artefakty a iterace žijí jen v lokálním `.aiworkflow/`.

## Režimy source

- `default`: bootstrap si stáhne `agents/` a `tools/` z GitHub repa, stable ref `stable`
- `--develop`: bootstrap si stáhne `agents/` a `tools/` z refu `develop`
- `--local-only`: bootstrap použije lokální `./agents` a `./tools` vedle skriptu a nic nestahuje

Pro GitHub remote bootstrap skript nejdřív zkusí neinteraktivní `git clone` nad zadanou URL. Když přímý clone selže, zkusí ještě GitHub SSH URL a teprve potom retry přes `gh repo clone`, pokud je `gh auth status` funkční. Tím se neobjeví username/password prompt a preferuje se SSH cesta.

Pokud remote fetch selže nebo požadovaný ref neexistuje, skript skončí s chybou a doporučí použít `--local-only`.

## `agents/` adresář

Každý agent má jeden JSON soubor pojmenovaný jako `NN-slug.json`.

Příklady z aktuálního repa:

- `agents/00-orchestrator.json`
- `agents/51-learning-designer.json`
- `agents/52-content-writer.json`
- `agents/53-workshop-facilitator.json`
- `agents/54-exercise-designer.json`
- `agents/55-prototype.json`
- `agents/56-audience-adapter.json`
- `agents/57-storyline-crafter.json`
- `agents/60-coder.json`
- `agents/70-reviewer.json`

Číselný prefix určuje pořadí. `metadata.order` musí odpovídat prefixu souboru a `metadata.slug` musí odpovídat slug části názvu souboru.

Aktuální validace:

```bash
python3 tools/parse_agent_definitions.py validate-dir agents
python3 tools/parse_agent_definitions.py count agents
python3 tools/parse_agent_definitions.py slug-list agents
python3 tools/parse_agent_definitions.py catalog-table agents
```

## Význam polí v agent JSON definici

Každý soubor musí mít `apiVersion: "aiworkflow/v1"` a `kind: "AgentDefinition"`.

- `metadata.name`: čitelný název agenta, například `Coder`
- `metadata.slug`: stabilní identifikátor použitý v adresářích, například `coder`
- `metadata.order`: pořadí agenta v katalogu a při bootstrapu
- `role`: krátký popis role, zobrazuje se v generovaném `AGENTS.md`
- `gallup_profile`: styl práce a talentový profil agenta
- `mission`: hlavní účel agenta
- `primary_inputs`: s čím agent vstupuje do práce
- `required_outputs`: co má agent dodat
- `handoff_targets`: komu typicky předává výstup
- `quality_gate`: definice hotového výsledku pro daného agenta
- `ask_first_triggers`: kdy se má nejdřív doptat
- `extra_rules`: další pravidla specifická pro roli

Parser navíc kontroluje:

- JSON musí být objekt
- všechny povinné obsahové sekce musí být neprázdné stringy
- `metadata.slug` smí obsahovat jen `a-z`, `0-9` a `-`
- orchestrator musí existovat
- `metadata.name` a `role` musí být jednorázové řádky bez znaku `|`

## Konkrétní JSON příklad

Zkrácený příklad podle aktuálního formátu:

```json
{
  "apiVersion": "aiworkflow/v1",
  "kind": "AgentDefinition",
  "metadata": {
    "name": "Coder",
    "slug": "coder",
    "order": 60
  },
  "role": "Senior software engineer – implementuje podle schváleného návrhu.",
  "gallup_profile": "**Domény:** Executing ...",
  "mission": "Implementuj schválená rozhodnutí architekta.",
  "primary_inputs": "- Schválená architektura\n- Task assignment s AC",
  "required_outputs": "- Implementace (kód)\n- Krátký technický záznam změn",
  "handoff_targets": "- Reviewer\n- Tester\n- Orchestrator",
  "quality_gate": "- Implementace odpovídá návrhu",
  "ask_first_triggers": "- Jaký je přesný scope tasku?",
  "extra_rules": "- Nejdřív čti existující kód, pak piš."
}
```

Reálné soubory v tomto repu obsahují delší Markdown texty, ale pořád jako JSON stringy. To je důležité: bootstrap z nich generuje finální `AGENTS.md` soubory pro jednotlivé agenty.

## Jak vypadá výsledný `.aiworkflow/`

Po bootstrapu vznikne v projektu zhruba tato struktura:

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

Každý agent má vlastní workspace:

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

Smysl hlavních částí:

- `agent_definitions/`: runtime kopie versioned JSON definic
- `agents/<slug>/`: pracovní prostor konkrétní role
- `orchestration/`: iterace, checklisty, brief dispatch, decision records
- `project/`: zadání, návrh, plánování a další projektové podklady
- `shared/`: sdílené šablony a konvence
- `tools/`: pomocné skripty workflow

## Jak workflow prakticky funguje

Typický průchod jednou iterací:

1. bootstrap vytvoří `.aiworkflow/`
2. orchestrator začne podle `.aiworkflow/AGENTS.md`
3. vytvoří iteraci přes `make init-iteration ITER=iter-001`
4. vyplní `orchestration/plans/active.md`
5. rozešle briefy do `agents/<slug>/context/inbox/`
6. agent zpracuje task a průběžně vede `state/current-task.md`
7. po dokončení zavolá `bash scripts/handoff-out.sh <task-id> "<popis>"`
8. skript zapíše handoff do `context/outbox/` agenta a zkopíruje notifikaci orchestrátorovi do `agents/orchestrator/context/inbox/`
9. orchestrator odškrtne master checklist a případně pošle další kolo review/testů

Nejpoužívanější příkazy uvnitř vygenerovaného `.aiworkflow/`:

```bash
make list-agents
make status
make init-iteration ITER=iter-001
make dispatch-brief AGENT=coder BRIEF=/cesta/k/brief.md
make reopen-task AGENT=coder TASK=T-001 REASON="fix issue"
make close-iteration ITER=iter-001
make validate
make tree
make dashboard
```

`make dashboard` vygeneruje `.aiworkflow/dashboard.html` – otevři ho v prohlížeči. Dashboard zobrazuje stav aktivní iterace (checklist, progress), agenty (status, spotřebované tokeny), výstupy agentů (odkaz na artifact soubory) a metriky. Stránka se automaticky refreshuje každých 10 s.

## Agent Prompts

Adresář `agent-prompts/` obsahuje připravené system prompty pro každého agenta. Tyto soubory lze použít přímo jako systémový prompt nebo jako první zprávu v Claude chatu bez potřeby Claude Code.

## Skills

Adresář `skills/` obsahuje zdrojové soubory projektových skills. Skill je promptový dokument, který Claude čte a provádí jako sekvenci kroků. Na rozdíl od agentů jsou skills spouštěné explicitně uživatelem pomocí lomítkového příkazu (např. `/dispatch-agent`). Lomítkový příkaz zadáváš přímo v Claude Code – v terminálu nebo IDE kde běží Claude Code session.

Při bootstrapu `createProject.sh` zkopíruje každou `skills/<název>/SKILL.md` do `.claude/commands/<název>.md` v cílovém projektu. Tím jsou skills dostupné jako projektové příkazy v Claude Code, ale nejsou globální ani commitnuté v projektu.

Přidání nové skill: vytvoř `skills/<název>/SKILL.md` v tomto repu. Žádná změna `createProject.sh` není nutná.

### dispatch-agent

**Účel**: Vynucuje správný protokol při dispatchování subagentů – audit log, zápis do plan.md před spawnem, čekání na výstup a okamžité odškrtnutí po dokončení.

**Kdy použít**: Pokaždé, když orchestrátor spouští agenta přes `claude --print`. Skill pokrývá celou sekvenci: napsat brief → uložit prompt do audit logu → přidat záznam do plan.md → smazat stale výstup → spustit agenta → počkat na výstup → ověřit → odškrtnout.

**Trigger**: `/dispatch-agent`

### close-iteration

**Účel**: Standardizuje a zautomatizuje uzavírání iterace – nahrazuje zdlouhavý manuální proces opakovatelnou procedurou (kontrola checklistu, commit, push, volitelný PR, spuštění close-iteration.sh, výstupní shrnutí).

**Kdy použít**: Na konci každé iterace, když jsou všechny tasky hotové (nebo uživatel rozhodl o jejich stavu) a je třeba archivovat výstupy, pushnout větev a zavřít active.md.

**Trigger**: `/close-iteration`

## Kdy upravovat co

- chcete změnit chování bootstrapu: upravte `createProject.sh`
- chcete změnit roli nebo instrukce agenta: upravte `agents/<NN-slug>.json`
- chcete ověřit konzistenci definic: spusťte `tools/parse_agent_definitions.py`
- chcete pracovat na konkrétním projektu: pracujte až v jeho lokálním `.aiworkflow/`

## Ověření po změnách

Minimální kontrola nad tímto repem:

```bash
python3 tools/parse_agent_definitions.py validate-dir agents
bash -n createProject.sh
```
