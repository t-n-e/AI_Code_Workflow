---
name: close-iteration
version: "1.1"
author: spiderik
description: >
  Use when closing the current iteration. Triggers on: "uzavři iteraci",
  "close iteration", "zavři iteraci", "dokončíme iteraci".
  Runs the full close sequence: verify plan → check branch → commit → push →
  ask about PR → call close-iteration.sh. Stops and asks the user if open
  tasks are found. PR is optional — not a hard blocker.
examples:
  - "uzavři iteraci"
  - "zavři iteraci iter-002"
  - "close iteration"
  - "dokončíme iteraci, udělej PR"
allowed-tools:
  - Bash
  - Read
  - Edit
---

# Close Iteration

**Prováděj kroky v tomto pořadí. Nezastavuj se bez důvodu — ale zastav se vždy, když krok selže nebo vyžaduje rozhodnutí uživatele.**

---

## Preconditions

Před zahájením ověř, že jsou splněny tyto podmínky:

- Máš přístup k nástroji **Bash** (pro git příkazy a spuštění skriptů)
- Máš přístup k nástroji **Read** (pro čtení plan.md a dalších souborů)
- Máš přístup k nástroji **Edit** (pro odškrtávání tasků v plan.md)
- Adresář `.aiworkflow/` existuje v kořenu projektu
- Symlink `.aiworkflow/orchestration/plans/active.md` je dostupný

Pokud některá z podmínek není splněna → zastav se a oznám uživateli, co chybí.

---

## Krok 1 – Zjisti aktivní iteraci

Přečti `orchestration/plans/active.md` (symlink na aktuální plan.md).

```bash
# Ověř, že symlink existuje a není broken
ls -la .aiworkflow/orchestration/plans/active.md
```

Pokud symlink neexistuje nebo je broken → **zastav se a oznám uživateli**: žádná aktivní iterace.

Z plan.md zjisti:
- `iter-ID` (z názvu souboru nebo hlavičky)
- Status (`active` / `closed`)

Pokud status = `closed` → zastav se: iterace je už uzavřená.

---

## Krok 2 – Zkontroluj master checklist

Přečti plan.md a spočítej otevřené tasky (`- [ ]`).

**Pokud jsou otevřené tasky:**
- Vypiš je uživateli
- Zeptej se: *„Jsou otevřené tasky. Chceš (a) odškrtnout je jako hotové, (b) přeskočit a zavřít i tak, nebo (c) zrušit uzavření?"*
- Počkej na odpověď a postupuj podle ní
- Pokud (c) → zastav se

**Pokud jsou všechny tasky odškrtnuté** → pokračuj.

---

## Krok 3 – Ověř git větev

```bash
git branch --show-current
```

Očekávaná větev: název odvozený od iterace nebo feature, **nikdy `main` nebo `master`**.

**Pokud jsme na `main` nebo `master`:**
- Zeptej se uživatele na název větve
- Nejdřív proveď `git fetch`, pak `git checkout <branch>` nebo `git checkout -b <branch>` podle situace

**Pokud jsme na jiné feature větvi než očekávané:**
- Oznám uživateli aktuální větev a zeptej se, zda je správná
- Pokračuj až po potvrzení

---

## Krok 4 – Commit

Zkontroluj stav repozitáře:

```bash
git status
git diff --stat
```

Pokud jsou neuložené změny nebo untracked soubory relevantní pro iteraci:

- Přečti výstup `git status` a přidávej **pouze soubory relevantní pro tuto iteraci**
- **NIKDY nepoužívej `git add .`** bez předchozí kontroly — vždy přidávej konkrétní soubory
- Commit message formát: `feat(iter-XXX): <stručný popis>`

```bash
git add <konkrétní relevantní soubory>
git commit -m "feat(<iter-ID>): <stručná zpráva popisující uzavření iterace>"
```

Příklad: `feat(iter-002): add close-iteration skill`

Pokud nejsou žádné změny k commitnutí → přeskoč commit, pokračuj pushem.

Pokud commit selže → vypiš chybu a zastav se.

---

## Krok 5 – Push do originu

```bash
git push -u origin <branch>
```

Pokud push selže → vypiš celý výstup chyby a zastav se. Nepokoušej se opravit bez uživatele.

---

## Krok 6 – Volitelné PR

Zeptej se uživatele: *„Chceš teď vytvořit PR do main? (y/N)"*

**Pokud ano:**
```bash
gh pr create --title "<iter-ID>: <stručný popis>" --body "$(cat <<'EOF'
## Summary
- <bullet body>

## Test plan
- [ ] Review proběhl bez blokujících nálezů
- [ ] Smoke test prošel

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

**Pokud `gh` CLI není nainstalováno nebo příkaz selže** → oznám uživateli, přeskoč PR (není blocker) a pokračuj Krokem 7.

**Pokud ne** → pokračuj bez PR. PR lze vytvořit kdykoliv později.

---

## Krok 7 – Uzavři iteraci

Nejdřív ověř, že skript existuje:

```bash
ls -la .aiworkflow/orchestration/scripts/close-iteration.sh
```

Pokud skript neexistuje → **zastav se, kritická chyba** — skript je nutný pro uzavření iterace.

Pokud skript existuje → spusť uzavření:

```bash
echo "y" | bash .aiworkflow/orchestration/scripts/close-iteration.sh .aiworkflow <iter-ID>
```

Ověř výstup — musí obsahovat `Iterace <iter-ID> uzavřena.`

Pokud výstup tento řetězec neobsahuje nebo skript skončí s chybou → vypiš výstup a zastav se. Ověř stav ručně.

---

## Krok 7b – Aktualizuj per-agent metrics summary

Po úspěšném výstupu `close-iteration.sh` otevři (nebo vytvoř) `orchestration/metrics/<iter>/summary.md`.

Zapiš nebo aktualizuj tabulku per-agent metrik z `agents/*/metrics/<iter>.md`:

```markdown
# Orchestration Metrics: <iter>

- **Closed**: <datum>

## Per-Agent Metrics

| Agent | Task | total_tokens | tool_uses | duration_ms |
|-------|------|-------------|-----------|-------------|
| coder | T-001 | 12345 | 20 | 95000 |
| reviewer | T-002 | 8900 | 15 | 60000 |
| ... | ... | ... | ... | ... |

> Orchestrátorské tokeny nejsou dostupné (N/A).
```

Pokud žádné `agents/*/metrics/<iter>.md` neexistují → zapiš prázdnou tabulku s poznámkou „metriky nebyly zaznamenány".

---

## Krok 8 – Shrnutí

Informuj uživatele:
- Iterace uzavřena: `<iter-ID>`
- Větev: `<branch>`
- Commit: `<hash>` (nebo „žádný nový commit")
- Push: OK
- PR: vytvořen `<URL>` / přeskočen
- Exit summary: `.aiworkflow/orchestration/runs/<iter-ID>/exit-summary.md`
- Tip: příští iterace → `make init-iteration ITER=iter-XXX`
