# Agent Definitions

Versioned zdroj definic agentů je `./agents/`.
`createProject.sh` z těchto JSON souborů bootstrapuje lokální runtime kopie do `.aiworkflow/agent_definitions/`.

Pravidla pro Iteration 1:
- Jeden agent = jeden JSON soubor.
- Název souboru musí být `NN-slug.json`.
- `metadata.slug` a `metadata.order` musí odpovídat názvu souboru.
- Obsahové sekce jsou prosté JSON stringy, aby zůstal bootstrap kompatibilní s aktuálním generováním `AGENTS.md`.

Povinná pole:
- `apiVersion`
- `kind`
- `metadata.name`
- `metadata.slug`
- `metadata.order`
- `role`
- `gallup_profile`
- `mission`
- `primary_inputs`
- `required_outputs`
- `handoff_targets`
- `quality_gate`
- `ask_first_triggers`
- `extra_rules`

Validace:
```bash
python3 tools/parse_agent_definitions.py validate-dir agents
```
