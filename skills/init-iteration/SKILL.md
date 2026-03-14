---
name: init-iteration
version: "1.0"
author: spiderik
description: >
  Use when starting a new iteration. Triggers on: "zahaj iteraci",
  "init iteration", "nová iterace", "start iteration", "začni iter-XXX".
  Runs the full init sequence: detect or accept iter-ID → run make init-iteration
  → create git branch → fill plan.md (mandatory agent order + user tasks) →
  make dashboard → validate plan quality gate → summarize.
  Stops and asks the user for missing information (goal, task list).
examples:
  - "zahaj iteraci"
  - "nová iterace iter-011"
  - "start iteration iter-011 goal: přidat metriky"
  - "init iteration"
allowed-tools:
  - Bash
  - Read
  - Write   # pouze pro vytvoření plan.md pokud neexistuje (fallback); normálně vždy Edit
  - Edit
---

# Init Iteration

**Prováděj kroky v tomto pořadí. Nezastavuj se bez důvodu — ale zastav se vždy, když krok selže nebo vyžaduje rozhodnutí uživatele.**

---

## Preconditions

Před zahájením ověř, že jsou splněny tyto podmínky:

- Máš přístup k nástrojům **Bash**, **Read**, **Edit** (a **Write** jako fallback)
- Adresář `.aiworkflow/` existuje v kořenu projektu
- Soubor `Makefile` existuje a obsahuje cíl `init-iteration`
- Žádná aktivní iterace neexistuje: symlink `.aiworkflow/orchestration/plans/active.md` je broken nebo neexistuje

```bash
ls -la .aiworkflow/orchestration/plans/active.md
```

Pokud symlink existuje a ukazuje na platný soubor → **zastav se** a oznám uživateli:
„Iterace `<iter-ID>` je aktivní. Uzavři ji nejdřív pomocí `/close-iteration`."

Pokud jiná podmínka není splněna → zastav se a oznám uživateli, co chybí.

---

## Krok 1 – Zjisti iter-ID

Zjisti, jaké iter-ID použít pro novou iteraci.

**Pokud uživatel zadal iter-ID v příkazu** (např. „nová iterace iter-011") → použij ho přímo.

Ověř formát: musí odpovídat `iter-NNN` (tři číslice, nuly vlevo: `iter-011`, ne `iter-11`).

Pokud formát neodpovídá `iter-NNN` → **zastav se** a oznám uživateli: „Iter-ID musí být ve formátu iter-NNN (tři číslice, nuly vlevo). Zadej správný formát."

**Pokud uživatel iter-ID nezadal** → automaticky detekuj:

```bash
ls .aiworkflow/orchestration/runs/ 2>/dev/null | grep '^iter-' | sort | tail -1
```

Vezmi poslední číslo a přičti 1. Pokud příkaz vrátí prázdný výsledek nebo složka `runs/` neexistuje → začni od `iter-001`.

Oznám uživateli navržené iter-ID a zeptej se na potvrzení před pokračováním.

---

## Krok 2 – Spusť make init-iteration

Spusť inicializaci iterace:

```bash
make init-iteration ITER=<iter-ID>
```

Ověř výstup: musí obsahovat `Iterace vytvořena:`. Pokud příkaz selže nebo výstup neobsahuje tento řetězec → **zastav se**, vypiš výstup a oznám uživateli chybu.

Po úspěchu ověř, že symlink existuje a ukazuje na správný soubor:

```bash
ls -la .aiworkflow/orchestration/plans/active.md
```

Symlink musí ukazovat na `.aiworkflow/orchestration/runs/<iter-ID>/plan.md`.

---

## Krok 3 – Vytvoř git větev

Zkontroluj aktuální větev a stav working tree:

```bash
git branch --show-current
git status --short
```

**Pokud `git status` ukazuje uncommitted changes** → **zastav se** a oznám uživateli situaci. Zeptej se, zda chce:
- **(a) Commitnout změny** (`git add -A && git commit -m "..."`)
- **(b) Stashovat změny** (`git stash`)
- **(c) Přerušit a vyřešit ručně**

Počkej na odpověď a postupuj podle ní. Nepokračuj na vytvoření větve dokud není working tree čistý.

Po vyřešení (nebo pokud byl tree čistý) zkontroluj aktuální větev:

**Pokud jsme na `main` nebo `master`:**
```bash
git checkout -b feature/<iter-ID>-init
```

**Pokud větev `feature/<iter-ID>-init` již existuje** → přepni na ni bez vytváření:
```bash
git checkout feature/<iter-ID>-init
```

**Pokud nejsme na `main`/`master`** → oznám uživateli aktuální větev a zeptej se, zda pokračovat na stávající větvi nebo přepnout. Počkej na odpověď.

---

## Krok 4 – Vyplň plan.md

Přečti čerstvě vytvořený plan.md:

```bash
# přes symlink
cat .aiworkflow/orchestration/plans/active.md
```

### 4a – Goal

Pokud uživatel zadal goal v příkazu → použij ho.

Pokud goal chybí → **zastav se** a zeptej se: „Jaký je cíl této iterace? (jedna věta)"

Počkej na odpověď a pokračuj.

Vyplň do plan.md (použij **Edit** tool, ne Write – zachovej strukturu template):
- Nahraď placeholder pro Goal hodnotou od uživatele
- Nahraď placeholder pro Created aktuálním datem ve formátu `YYYY-MM-DD`
- Nastav Status na `active`

### 4b – Mandatorní prefix Master Checklistu

Toto pořadí je POVINNÉ pro každou iteraci. Nevynechávej ani neměň pořadí:

```markdown
- [ ] T-001: architect – Navrhnout architekturu řešení pro <goal> (struktura, komponenty, alternativy, rizika)
- [ ] T-002: reviewer – Review architektury (všechny nálezy, nejen blockery)
- [ ] T-003: architect – Zapracovat nálezy z review (pokud reviewer něco našel)
- [ ] T-004: human – Review a schválení architektury uživatelem (blocker před implementací)
```

Poznámka k T-003: skill vždy vloží celý mandatorní prefix včetně T-003. Teprve po dokončení T-002 orchestrátor rozhodne, zda je T-003 relevantní nebo se odškrtne jako N/A. Skill tuto podmíněnost nevyhodnocuje.

Vyplň tyto čtyři tasky do plan.md pomocí Edit tool (nahraď placeholder v Master Checklistu).

### 4c – Implementační tasky

Pokud uživatel zadal konkrétní tasky → přidej je za T-004 jako T-005, T-006, …

Pokud tasky nebyly zadány → **zastav se** a zeptej se: „Jaké implementační tasky mají být v plánu? (jeden task na řádek, nebo 'zatím ne')"

Pokud uživatel odpoví „zatím ne" → nechej v plan.md viditelný placeholder:
```markdown
- [ ] T-005: <agent> – <popis>
```
A přidej výrazné upozornění do shrnutí: **POZOR: Plan obsahuje placeholder tasky – musíš je vyplnit před zahájením dispatche.**

### 4d-human – Povinný závěrečný human task (closing gate)

Za všemi implementačními tasky přidej jako úplně poslední task v Master Checklistu:

```markdown
- [ ] T-NNN: human – Schválení uzavření iterace (review výsledků před /close-iteration)
```

Kde `NNN` = číslo za posledním implementačním taskem. Příklady:
- Implementační tasky T-005 … T-008 → closing gate = T-009
- Žádné implementační tasky (jen placeholder T-005) → closing gate = T-006

Toto pravidlo je POVINNÉ. Bez tohoto tasku by orchestrátor mohl zavolat `/close-iteration` bez souhlasu uživatele.

### 4e – Quality Gates sekce

Ověř nebo doplň, že plan.md obsahuje sekci Quality Gates:

```markdown
## Quality Gates
- [ ] Plan neobsahuje orchestratora jako agenta u žádného tasku
- [ ] Architect návrh prošel reviewer review a případnou opravou (T-002, T-003)
- [ ] Architect návrh schválen uživatelem (T-004)
- [ ] Code review (Reviewer)
- [ ] QA validace (Tester)
```

---

## Krok 4.5 – Regeneruj dashboard

Po vyplnění plan.md spusť regeneraci dashboardu:

```bash
make dashboard
```

Ověř, že příkaz skončil s exit code 0. Pokud selže → **zastav se**, vypiš výstup a oznám uživateli chybu.

Dashboard musí reflektovat novou iteraci a její tasky. Spouštěj dashboard vždy po vyplnění plan.md a před quality gate.

---

## Krok 5 – Quality gate: validace plan.md

Ověř, že žádný task v Master Checklistu neobsahuje orchestrátora jako agenta:

```bash
grep -in "^\- \[.\] T-[0-9]\{3\}:.*orchestrat" .aiworkflow/orchestration/plans/active.md
```

Výsledek musí být **prázdný** (0 řádků).

**Pokud grep nalezne shodu** → **zastav se**:
- Vypiš nalezené řádky
- Oznám: „Plan obsahuje orchestratora jako agenta. Oprav tasky – orchestrátor přiděluje práci, nevykonává ji."
- Počkej na opravu uživatele nebo proveď opravu v plan.md, poté zopakuj validaci.

Pokud validace projde → pokračuj.

---

## Krok 6 – Shrnutí

Informuj uživatele o výsledku inicializace:

- **Iterace vytvořena**: `<iter-ID>`
- **Git větev**: `<branch>`
- **Plan**: `.aiworkflow/orchestration/runs/<iter-ID>/plan.md`
- **Active symlink**: `.aiworkflow/orchestration/plans/active.md`
- **Dashboard**: regenerován (`make dashboard` OK)
- **Quality gate**: PASSED
- **Mandatorní start**: T-001 architect → T-002 reviewer → T-003 architect → T-004 human → implementace → T-NNN human (closing gate)

Pokud plan obsahuje placeholder tasky → přidej výrazné varování:
**POZOR: Plan obsahuje placeholder tasky (`T-NNN: <agent> – <popis>`). Vyplň je před zahájením dispatche, jinak nelze začít práci.**

Tip: „Zahaj dispatch architekta pomocí `/dispatch-agent`"
