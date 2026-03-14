#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn


REQUIRED_STRING_FIELDS = (
    "role",
    "gallup_profile",
    "mission",
    "primary_inputs",
    "required_outputs",
    "handoff_targets",
    "quality_gate",
    "ask_first_triggers",
    "extra_rules",
)

SLUG_RE = re.compile(r"^[a-z0-9-]+$")
FILENAME_RE = re.compile(r"^(?P<prefix>\d+)-(?P<slug>[a-z0-9-]+)\.json$")


@dataclass(frozen=True)
class AgentDefinition:
    path: Path
    name: str
    slug: str
    order: int
    role: str
    gallup_profile: str
    mission: str
    primary_inputs: str
    required_outputs: str
    handoff_targets: str
    quality_gate: str
    ask_first_triggers: str
    extra_rules: str


def die(message: str) -> NoReturn:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: Path) -> dict:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"definition file not found: {path}")
    except json.JSONDecodeError as exc:
        die(f"invalid JSON in {path}: {exc}")

    if not isinstance(raw, dict):
        die(f"definition must be a mapping: {path}")
    return raw


def require_string(mapping: dict, key: str, path: Path) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        die(f"missing or empty string field '{key}' in {path}")
    return value.rstrip()


def load_definition(path: Path) -> AgentDefinition:
    raw = load_json(path)
    if raw.get("apiVersion") != "aiworkflow/v1":
        die(f"unsupported apiVersion in {path}: {raw.get('apiVersion')!r}")
    if raw.get("kind") != "AgentDefinition":
        die(f"unsupported kind in {path}: {raw.get('kind')!r}")

    metadata = raw.get("metadata")
    if not isinstance(metadata, dict):
        die(f"missing metadata mapping in {path}")

    name = require_string(metadata, "name", path)
    slug = require_string(metadata, "slug", path)
    if not SLUG_RE.match(slug):
        die(f"invalid slug in {path}: {slug!r}")
    validate_table_cell(name, "metadata.name", path)

    order = metadata.get("order")
    if not isinstance(order, int):
        die(f"metadata.order must be an integer in {path}")

    match = FILENAME_RE.match(path.name)
    if not match:
        die(f"definition filename must match NN-slug.json: {path.name}")
    file_slug = match.group("slug")
    file_order = int(match.group("prefix"))
    if file_slug != slug:
        die(f"filename slug {file_slug!r} does not match metadata.slug {slug!r} in {path}")
    if file_order != order:
        die(f"filename order {file_order} does not match metadata.order {order} in {path}")

    values = {field: require_string(raw, field, path) for field in REQUIRED_STRING_FIELDS}
    validate_table_cell(values["role"], "role", path)

    return AgentDefinition(
        path=path,
        name=name,
        slug=slug,
        order=order,
        role=values["role"],
        gallup_profile=values["gallup_profile"],
        mission=values["mission"],
        primary_inputs=values["primary_inputs"],
        required_outputs=values["required_outputs"],
        handoff_targets=values["handoff_targets"],
        quality_gate=values["quality_gate"],
        ask_first_triggers=values["ask_first_triggers"],
        extra_rules=values["extra_rules"],
    )


def iter_definition_files(directory: Path) -> list[Path]:
    if not directory.is_dir():
        die(f"definitions directory not found: {directory}")
    files = sorted(p for p in directory.iterdir() if p.is_file() and p.suffix == ".json")
    if not files:
        die(f"no agent definitions found in {directory}")
    return files


def validate_table_cell(value: str, field_name: str, path: Path) -> None:
    if "\n" in value or "|" in value:
        die(f"field '{field_name}' in {path} must stay single-line and must not contain '|'")


def load_definitions(directory: Path) -> list[AgentDefinition]:
    definitions = [load_definition(path) for path in iter_definition_files(directory)]

    slugs: dict[str, Path] = {}
    orders: dict[int, Path] = {}
    for definition in definitions:
        if definition.slug in slugs:
            die(
                f"duplicate slug {definition.slug!r} in {definition.path} and {slugs[definition.slug]}"
            )
        if definition.order in orders:
            die(
                f"duplicate order {definition.order} in {definition.path} and {orders[definition.order]}"
            )
        slugs[definition.slug] = definition.path
        orders[definition.order] = definition.path

    if "orchestrator" not in slugs:
        die("missing required orchestrator definition")

    return sorted(definitions, key=lambda item: (item.order, item.slug))


def command_validate_dir(args: argparse.Namespace) -> int:
    load_definitions(Path(args.directory))
    return 0


def command_shell_fields(args: argparse.Namespace) -> int:
    definition = load_definition(Path(args.file))
    values = (
        definition.name,
        definition.slug,
        definition.role,
        definition.gallup_profile,
        definition.mission,
        definition.primary_inputs,
        definition.required_outputs,
        definition.handoff_targets,
        definition.quality_gate,
        definition.ask_first_triggers,
        definition.extra_rules,
    )
    sys.stdout.buffer.write(b"\0".join(value.encode("utf-8") for value in values))
    sys.stdout.buffer.write(b"\0")
    return 0


def command_count(args: argparse.Namespace) -> int:
    definitions = load_definitions(Path(args.directory))
    print(len(definitions))
    return 0


def command_list_slugs(args: argparse.Namespace) -> int:
    definitions = load_definitions(Path(args.directory))
    for definition in definitions:
        print(definition.slug)
    return 0


def command_slug_list(args: argparse.Namespace) -> int:
    definitions = load_definitions(Path(args.directory))
    print(", ".join(definition.slug for definition in definitions))
    return 0


def command_catalog_table(args: argparse.Namespace) -> int:
    definitions = load_definitions(Path(args.directory))
    print("| Agent | Slug | Role |")
    print("|---|---|---|")
    for definition in definitions:
        print(f"| {definition.name} | {definition.slug} | {definition.role} |")
    return 0


def render_agent_doc(definition: AgentDefinition) -> str:
    return f"""# {definition.name}

## Role
{definition.role}

## Gallup Talent Profile
{definition.gallup_profile}

## Mission
{definition.mission}

## Primary Inputs
{definition.primary_inputs}

## Required Outputs
{definition.required_outputs}

## Handoff Targets
{definition.handoff_targets}

## Working Style
- Buď věcný, stručný a přesný.
- Před prací si ověř kontext ve složce `context/inbox/` a reference ve `context/refs/`.
- Pokud něco zásadního chybí, polož max 3 cílené otázky.
- Preferuj rozhodnutí s jasným odůvodněním (trade-offs, rizika, dopady).
- Zapisuj průběh do `logs/` a průběžné poznámky do `state/`.

## Checkpoint Protokol (POVINNÉ)
Po každém dokončeném dílčím úkolu:
1. Aktualizuj `state/current-task.md` → status: done
2. Zavolej `bash scripts/handoff-out.sh <task-id> "<popis>"`
3. Orchestrátor tím dostane signál a odškrtne úkol v master checklistu.

Nedokončuj práci bez splnění všech tří kroků. Pokud jsi zablokován, nastav status: blocked a zavolej handoff-out.sh s důvodem.

## Dílčí checklist (udržuj aktuální)
Orchestrátor ti pošle task list v briefu. Kopíruj ho sem a odškrtávej průběžně – ihned po dokončení každého bodu, ne nakonec.

```
<!-- Sem zkopíruj checklist z briefu -->
```

## Quality Gate (Definition of Done)
{definition.quality_gate}

## Ask-first Triggers (max 3 otázky)
{definition.ask_first_triggers}

## File Conventions
- Vstupy od orchestrace: `context/inbox/*.md`
- Vlastní pracovní poznámky: `state/`
- Výstupní deliverables: `artifacts/final/`
- Dočasné návrhy: `artifacts/drafts/`
- Handoff metadata (co posílám dál): `context/outbox/`
- Log běhu: `logs/YYYY-MM-DD_run.log`
- Prompt předaný jinému agentovi: `agents/<slug>/logs/YYYY-MM-DDTHH-MM-SSZ__prompt_<iter>_<task>.md`

## Do / Don't
- Do: explicitně uveď předpoklady a nejistoty.
- Do: navrhuj varianty, pokud jsou relevantní.
- Do: odškrtávej checklist průběžně, ne nakonec.
- Don't: neměň scope bez uvedení důvodu a eskalace na Orchestrátora.
- Don't: netvrď rozhodnutí bez kritérií.
- Don't: nezavírej task bez zavolání handoff-out.sh.

## Extra Rules
{definition.extra_rules}
"""


def command_render_agent_doc(args: argparse.Namespace) -> int:
    definition = load_definition(Path(args.file))
    print(render_agent_doc(definition), end="")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate and render agent definitions.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_dir = subparsers.add_parser("validate-dir")
    validate_dir.add_argument("directory")
    validate_dir.set_defaults(func=command_validate_dir)

    shell_fields = subparsers.add_parser("shell-fields")
    shell_fields.add_argument("file")
    shell_fields.set_defaults(func=command_shell_fields)

    count = subparsers.add_parser("count")
    count.add_argument("directory")
    count.set_defaults(func=command_count)

    list_slugs = subparsers.add_parser("list-slugs")
    list_slugs.add_argument("directory")
    list_slugs.set_defaults(func=command_list_slugs)

    slug_list = subparsers.add_parser("slug-list")
    slug_list.add_argument("directory")
    slug_list.set_defaults(func=command_slug_list)

    catalog_table = subparsers.add_parser("catalog-table")
    catalog_table.add_argument("directory")
    catalog_table.set_defaults(func=command_catalog_table)

    render_agent = subparsers.add_parser("render-agent-doc")
    render_agent.add_argument("file")
    render_agent.set_defaults(func=command_render_agent_doc)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
