# Agent Prompts

Tato složka obsahuje system prompty pro všechny agenty tohoto workflow. Jsou určeny pro ruční použití v Claude.ai nebo jiném LLM chatu – bez nutnosti Claude Code. Soubory jsou generovány automaticky ze šablon v `.aiworkflow/agents/`.

---

## Rozcestník

### Core

| Agent | Popis |
|---|---|
| [orchestrator](./core/orchestrator.md) | Koordinátor agentů, iterací a quality gates |

### Business

| Agent | Popis |
|---|---|
| [requirements](./business/requirements.md) | Business analytik – co uživatel skutečně chce a potřebuje |
| [product-strategist](./business/product-strategist.md) | Product strategist – definuje produktovou pozici a value proposition |
| [cto](./business/cto.md) | Chief Technology Officer – technologická strategie a směr platformy |
| [cio](./business/cio.md) | Chief Information Officer – IT operating model a governance informačních služeb |
| [cfo](./business/cfo.md) | Chief Financial Officer – finanční směr, investiční disciplína, ekonomické guardraily |
| [architect](./business/architect.md) | Solution architect – navrhuje strukturu systémů a technologická rozhodnutí |
| [finops-domain-expert](./business/finops-domain-expert.md) | FinOps domain expert – doménové pravdy a capability mapa cloudu |

### Learning

| Agent | Popis |
|---|---|
| [creative](./learning/creative.md) | UX a product thinker – vidí produkt očima uživatele |
| [learning-designer](./learning/learning-designer.md) | Learning designer – převádí cíle školení do osnovy a učební cesty |
| [content-writer](./learning/content-writer.md) | Content writer – finální texty pro školení, handouty a slide decky |
| [workshop-facilitator](./learning/workshop-facilitator.md) | Workshop facilitator – navrhuje průběh session a facilitation cues |
| [exercise-designer](./learning/exercise-designer.md) | Exercise designer – vytváří cvičení, zadání a expected outcomes |
| [audience-adapter](./learning/audience-adapter.md) | Audience adapter – přizpůsobuje téma různým publikům |
| [storyline-crafter](./learning/storyline-crafter.md) | Storyline crafter – staví framing, příběh a zapamatovatelnou linku |

### Engineering

| Agent | Popis |
|---|---|
| [prototype](./engineering/prototype.md) | Rapid prototyper – ověřuje proveditelnost před plnou implementací |
| [coder](./engineering/coder.md) | Senior software engineer – implementuje podle schváleného návrhu |
| [reviewer](./engineering/reviewer.md) | Code a output reviewer – kvalita, rizika, maintainability |
| [tester](./engineering/tester.md) | QA engineer – validace, testy a ověření acceptance criteria |
| [process](./engineering/process.md) | Engineering process advisor – vývojové procesy a týmová efektivita |

### QA & Feedback

| Agent | Popis |
|---|---|
| [challenger](./qa-feedback/challenger.md) | Technický skeptik a kritický oponent návrhů |
| [security](./qa-feedback/security.md) | Security engineer – bezpečnostní review aplikací a infrastruktury |
| [bfu](./qa-feedback/bfu.md) | Běžný frustrovaný uživatel – zastupuje netechnického koncového uživatele |

---

## Jak použít agent prompt

1. Najdi agenta podle skupiny v rozcestníku výše.
2. Klikni na odkaz a otevři `.md` soubor.
3. Zkopíruj celý obsah souboru.
4. V Claude.ai (nebo jiném LLM chatu) vlož obsah jako System Prompt nebo první zprávu.
5. Začni konverzaci – agent se chová podle své definice.

> Volitelně: po nastavení agenta přidej jako další zprávu kontext svého projektu (cíl, existující materiály, otázky).

---

## Tipy a typické use cases

**Tip 1 – Technický projekt**
Použij sekvenci `requirements` → `architect` → `coder` → `reviewer`. Výstup každého agenta vlož jako vstup dalšímu – každý navazuje na výsledky předchozího.

**Tip 2 – Vzdělávací projekt nebo workshop**
Sekvence `learning-designer` → `content-writer` → `workshop-facilitator` pokryje celou přípravu školení nebo kurzu: od osnovy přes texty až po facilitation plán. Každý agent dostane jako kontext výstup předchozího.

**Tip 3 – Rychlá kritika nebo review**
`challenger` nebo `bfu` jako samostatný agent: vlož libovolný návrh, dokument nebo text a dostaneš strukturovanou kritiku. `challenger` útočí z technické stránky, `bfu` reaguje z pohledu netechnického uživatele.

---

> **Poznámka k iter-006:** Flat seznam souborů byl reorganizován do podadresářů (`core/`, `business/`, `learning/`, `engineering/`, `qa-feedback/`). Přímé cesty `agent-prompts/<slug>.md` jsou přerušeny – použij relativní cesty z rozcestníku výše.
