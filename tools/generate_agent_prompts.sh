#!/usr/bin/env bash
# generate_agent_prompts.sh
# Generates agent-prompts/<group>/<slug>.md for every agents/**/*.json definition.
# Usage: bash tools/generate_agent_prompts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEMPLATE="$SCRIPT_DIR/agent-prompt-template.md"
README_TEMPLATE="$SCRIPT_DIR/agent-prompts-readme-template.md"
AGENTS_DIR="$REPO_ROOT/agents"
OUT_DIR="$REPO_ROOT/agent-prompts"
PARSER="$SCRIPT_DIR/parse_agent_definitions.py"

# Static slug→group map
declare -A GROUP_MAP=(
    [orchestrator]="core"
    [requirements]="business"
    [product-strategist]="business"
    [cto]="business"
    [cio]="business"
    [cfo]="business"
    [architect]="business"
    [finops-domain-expert]="business"
    [creative]="learning"
    [learning-designer]="learning"
    [content-writer]="learning"
    [workshop-facilitator]="learning"
    [exercise-designer]="learning"
    [audience-adapter]="learning"
    [storyline-crafter]="learning"
    [prototype]="engineering"
    [coder]="engineering"
    [reviewer]="engineering"
    [tester]="engineering"
    [process]="engineering"
    [challenger]="qa-feedback"
    [security]="qa-feedback"
    [bfu]="qa-feedback"
)

if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: template not found: $TEMPLATE" >&2
    exit 1
fi

if [[ ! -f "$README_TEMPLATE" ]]; then
    echo "Error: README template not found: $README_TEMPLATE" >&2
    exit 1
fi

if [[ ! -d "$AGENTS_DIR" ]]; then
    echo "Error: agents directory not found: $AGENTS_DIR" >&2
    exit 1
fi

# Create subdirectories
mkdir -p "$OUT_DIR/core"
mkdir -p "$OUT_DIR/business"
mkdir -p "$OUT_DIR/learning"
mkdir -p "$OUT_DIR/engineering"
mkdir -p "$OUT_DIR/qa-feedback"

# Pass GROUP_MAP as a JSON-style string for Python consumption
GROUP_MAP_JSON=$(python3 -c "
import json, sys
m = {}
$(for slug in "${!GROUP_MAP[@]}"; do echo "m['$slug'] = '${GROUP_MAP[$slug]}'"; done)
print(json.dumps(m))
")

# Python handles null-delimited shell-fields output safely.
# For each JSON file: call parse_agent_definitions.py shell-fields,
# read the null-delimited fields, fill the template, write <group>/<slug>.md.
python3 - "$PARSER" "$TEMPLATE" "$AGENTS_DIR" "$OUT_DIR" "$GROUP_MAP_JSON" <<'PYEOF'
import subprocess
import sys
import json
from pathlib import Path

parser_path = sys.argv[1]
template_path = sys.argv[2]
agents_dir = Path(sys.argv[3])
out_dir = Path(sys.argv[4])
group_map = json.loads(sys.argv[5])

template = Path(template_path).read_text(encoding="utf-8")

json_files = sorted(agents_dir.rglob("*.json"))
if not json_files:
    print(f"Error: no agent JSON files found in {agents_dir}", file=sys.stderr)
    sys.exit(1)

for json_file in json_files:
    result = subprocess.run(
        ["python3", parser_path, "shell-fields", str(json_file)],
        capture_output=True,
    )
    if result.returncode != 0:
        print(result.stderr.decode("utf-8", errors="replace"), file=sys.stderr)
        sys.exit(result.returncode)

    # Fields are null-delimited; trailing null produces an empty last element
    fields = [f.decode("utf-8") for f in result.stdout.split(b"\0") if f]
    # Order: name, slug, role, gallup_profile, mission, primary_inputs,
    #        required_outputs, handoff_targets, quality_gate,
    #        ask_first_triggers, extra_rules
    (name, slug, role, gallup, mission,
     primary_inputs, required_outputs, handoff_targets,
     quality_gate, ask_first_triggers, extra_rules) = fields[:11]

    group = group_map.get(slug)
    if not group:
        print(f"Warning: slug '{slug}' not found in GROUP_MAP, skipping", file=sys.stderr)
        continue

    content = template
    content = content.replace("{{NAME}}", name)
    content = content.replace("{{ROLE}}", role)
    content = content.replace("{{GALLUP}}", gallup)
    content = content.replace("{{MISSION}}", mission)
    content = content.replace("{{PRIMARY_INPUTS}}", primary_inputs)
    content = content.replace("{{REQUIRED_OUTPUTS}}", required_outputs)
    content = content.replace("{{QUALITY_GATE}}", quality_gate)
    content = content.replace("{{ASK_FIRST_TRIGGERS}}", ask_first_triggers)
    content = content.replace("{{EXTRA_RULES}}", extra_rules)

    out_file = out_dir / group / f"{slug}.md"
    out_file.write_text(content, encoding="utf-8")
    print(f"Generated: agent-prompts/{group}/{slug}.md")
PYEOF

# Copy README from template (overwrites existing)
cp "$README_TEMPLATE" "$OUT_DIR/README.md"
echo "Generated: agent-prompts/README.md"
echo "Done."
