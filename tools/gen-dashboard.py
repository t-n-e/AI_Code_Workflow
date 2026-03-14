#!/usr/bin/env python3
"""
gen-dashboard.py – generuje dashboard.html ze stavu .aiworkflow/

Použití:
  python3 gen-dashboard.py          # z adresáře .aiworkflow/
  make dashboard                    # přes Makefile
"""
import sys, json, re, os
from pathlib import Path
from datetime import datetime, timezone

ROOT = Path(__file__).parent
OUT  = ROOT / "dashboard.html"


# ─────────────────────────────────────────────────────────────────────────────
# Data collection
# ─────────────────────────────────────────────────────────────────────────────

def read_file(p):
    try:
        return Path(p).read_text(encoding="utf-8")
    except Exception:
        return ""


def parse_active_iteration():
    link = ROOT / "orchestration/plans/active.md"
    if not link.exists():
        return None

    plan_text = read_file(link)
    iter_id = "unknown"
    try:
        target = os.readlink(str(link))
        m = re.search(r"iter-\d+", target)
        if m:
            iter_id = m.group(0)
    except Exception:
        pass

    # Goal: supports "- **Goal**: text" and "**Goal**: text"
    goal = ""
    for line in plan_text.splitlines():
        m = re.search(r"\*\*Goal\*\*[:\s]+(.+)", line)
        if m:
            val = m.group(1).strip().lstrip("<!-- ").rstrip(" -->")
            if val and val not in ("jedna věta", "–", "-"):
                goal = val
                break

    # Status
    status = "active"
    for line in plan_text.splitlines():
        m = re.search(r"\*\*Status\*\*[:\s]+(.+)", line)
        if m:
            status = m.group(1).strip().split()[0]
            break

    # Master Checklist (T-xxx items only – skip Quality Gates etc.)
    tasks = []
    in_master = False
    for line in plan_text.splitlines():
        if re.match(r"^## Master Checklist", line):
            in_master = True
            continue
        if re.match(r"^## ", line) and in_master:
            in_master = False
        if in_master:
            m = re.match(r"^- \[([x ])\] (.+)$", line.strip())
            if m:
                done = m.group(1) == "x"
                text = m.group(2).strip()
                tid_m = re.match(r"^(T-\d+)[:\s](.*)", text)
                tasks.append({
                    "id":   tid_m.group(1) if tid_m else "",
                    "text": tid_m.group(2).strip() if tid_m else text,
                    "done": done,
                })

    return {
        "id":         iter_id,
        "goal":       goal,
        "status":     status,
        "tasks":      tasks,
        "total":      len(tasks),
        "done_count": sum(1 for t in tasks if t["done"]),
    }


def parse_closed_iterations(active_id):
    runs = ROOT / "orchestration/runs"
    if not runs.exists():
        return []
    return sorted(
        d.name for d in runs.iterdir()
        if d.is_dir() and d.name != active_id
    )


def parse_agent_state(state_text):
    fields = {
        "status":    "idle",
        "task_id":   "",
        "brief":     "",
        "iteration": "",
        "started":   "",
        "completed": "",
    }
    key_map = {
        "task id":   "task_id",
        "brief":     "brief",
        "iteration": "iteration",
        "status":    "status",
        "started":   "started",
        "completed": "completed",
    }
    for line in state_text.splitlines():
        m = re.match(r"^-\s*\*\*(.+?)\*\*[:\s]+(.+)$", line.strip())
        if not m:
            continue
        key = m.group(1).strip().lower()
        val = m.group(2).strip().split("<!--")[0].strip()
        if val in ("–", "-", ""):
            continue
        if key in key_map:
            fields[key_map[key]] = val
    return fields


def collect_agents():
    agents_dir = ROOT / "agents"
    if not agents_dir.exists():
        return []
    agents = []
    for d in sorted(agents_dir.iterdir()):
        if not d.is_dir():
            continue
        state = parse_agent_state(read_file(d / "state/current-task.md"))
        agents.append({"slug": d.name, **state})
    return agents


def parse_handoff_file(f):
    """Parse a done_*.md handoff file and return {task, completed, description}."""
    meta = {"task": "", "completed": "", "description": ""}
    text = read_file(f)
    for line in text.splitlines():
        for field, key in [("Task", "task"), ("Completed", "completed"), ("Description", "description")]:
            m = re.match(rf"^- {field}: (.+)", line)
            if m:
                meta[key] = m.group(1).strip()
    return meta


def collect_outputs():
    agents_dir = ROOT / "agents"
    if not agents_dir.exists():
        return []
    outputs = []
    for agent_dir in sorted(agents_dir.iterdir()):
        if not agent_dir.is_dir():
            continue

        # Load handoff metadata from outbox for task-id / timestamp / description pairing
        handoff_index = {}  # task_id -> {completed, description}
        outbox = agent_dir / "context/outbox"
        if outbox.exists():
            for hf in sorted(outbox.glob("done_*.md")):
                meta = parse_handoff_file(hf)
                if meta.get("task"):
                    handoff_index[meta["task"]] = meta

        # Scan artifacts/final/ and artifacts/draft(s)/
        for artifact_type_dir, artifact_type_label in [
            ("artifacts/final",  "final"),
            ("artifacts/drafts", "draft"),
            ("artifacts/draft",  "draft"),
        ]:
            artifacts_dir = agent_dir / artifact_type_dir
            if not artifacts_dir.exists():
                continue
            for f in sorted(artifacts_dir.iterdir()):
                if f.name == ".gitkeep" or not f.is_file():
                    continue
                # Extract task-id from filename (e.g. T-001)
                tid_match = re.search(r"T-\d+", f.name)
                task_id = tid_match.group(0) if tid_match else ""
                # Pair with handoff metadata
                handoff = handoff_index.get(task_id, {})
                # completed: prefer handoff timestamp, fallback to file mtime
                completed = handoff.get("completed", "")
                if not completed:
                    try:
                        mtime = f.stat().st_mtime
                        completed = datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    except Exception:
                        completed = ""
                outputs.append({
                    "agent":       agent_dir.name,
                    "file":        str(f.relative_to(ROOT)),
                    "type":        artifact_type_label,
                    "name":        f.name,
                    "task":        task_id,
                    "completed":   completed,
                    "description": handoff.get("description", ""),
                })
    return outputs


def collect_agent_tokens(active_iter_id):
    """Return dict: agent_slug -> total_tokens sum across all tasks in active iteration."""
    if not active_iter_id or active_iter_id == "unknown":
        return {}
    agents_dir = ROOT / "agents"
    if not agents_dir.exists():
        return {}
    result = {}
    for agent_dir in sorted(agents_dir.iterdir()):
        if not agent_dir.is_dir():
            continue
        metrics_file = agent_dir / "metrics" / f"{active_iter_id}.md"
        if not metrics_file.exists():
            continue
        text = read_file(metrics_file)
        total = 0
        found = False
        for line in text.splitlines():
            m = re.match(r"^- \*\*total_tokens\*\*[:\s]+(\d+)", line.strip())
            if m:
                total += int(m.group(1))
                found = True
        if found:
            result[agent_dir.name] = total
    return result


def collect_metrics():
    metrics = {}
    metrics_dir = ROOT / "orchestration/metrics"
    if not metrics_dir.exists():
        return metrics
    for f in sorted(metrics_dir.rglob("*.json")):
        if f.stat().st_size == 0:
            continue
        try:
            key = str(f.relative_to(metrics_dir)).replace("/", "_").replace(".json", "")
            metrics[key] = json.loads(f.read_text())
        except Exception:
            pass
    for f in sorted(metrics_dir.rglob("*.md")):
        if f.name == ".gitkeep" or f.stat().st_size == 0:
            continue
        key = str(f.relative_to(metrics_dir)).replace("/", "_").replace(".md", "")
        metrics[key] = {"raw": read_file(f)}
    return metrics


# ─────────────────────────────────────────────────────────────────────────────
# Assemble data
# ─────────────────────────────────────────────────────────────────────────────

ts_now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
iteration = parse_active_iteration()
active_iter_id = iteration["id"] if iteration else ""
data = {
    "generated":        ts_now,
    "iteration":        iteration,
    "closed_iterations": parse_closed_iterations(active_iter_id),
    "agents":           collect_agents(),
    "outputs":          collect_outputs(),
    "metrics":          collect_metrics(),
    "agent_tokens":     collect_agent_tokens(active_iter_id),
}
DATA_JSON = json.dumps(data, ensure_ascii=False, indent=2)


# ─────────────────────────────────────────────────────────────────────────────
# HTML template
# ─────────────────────────────────────────────────────────────────────────────

HTML = """<!DOCTYPE html>
<html lang="cs">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI Workflow Dashboard</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg:        #0d1117;
    --surface:   #161b22;
    --border:    #30363d;
    --text:      #e6edf3;
    --muted:     #8b949e;
    --idle:      #484f58;
    --progress:  #1f6feb;
    --done:      #238636;
    --blocked:   #da3633;
    --warn:      #9e6a03;
  }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    font-size: 14px;
    line-height: 1.5;
    padding: 16px;
  }

  /* ── Header ─────────────────────────────────────────────── */
  .header {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 20px;
    flex-wrap: wrap;
  }
  .header h1 {
    font-size: 18px;
    font-weight: 600;
    color: var(--text);
  }
  .badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 12px;
    font-weight: 600;
    background: #1f6feb33;
    color: #58a6ff;
    border: 1px solid #1f6feb66;
  }
  .badge.no-iter {
    background: #48505833;
    color: var(--muted);
    border-color: #48505866;
  }
  .header-right {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .ts {
    font-size: 12px;
    color: var(--muted);
  }
  button.refresh {
    background: var(--surface);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 5px 12px;
    border-radius: 6px;
    font-size: 13px;
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  button.refresh:hover { border-color: #58a6ff; color: #58a6ff; }

  /* ── Layout ──────────────────────────────────────────────── */
  .grid-top {
    display: grid;
    grid-template-columns: 380px 1fr;
    gap: 16px;
    margin-bottom: 16px;
  }
  @media (max-width: 900px) {
    .grid-top { grid-template-columns: 1fr; }
  }

  /* ── Cards ───────────────────────────────────────────────── */
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 16px;
  }
  .card-title {
    font-size: 13px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: .05em;
    color: var(--muted);
    margin-bottom: 14px;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .section { margin-bottom: 16px; }

  /* ── Progress bar ────────────────────────────────────────── */
  .progress-wrap { margin-bottom: 14px; }
  .progress-label {
    font-size: 12px;
    color: var(--muted);
    margin-bottom: 4px;
    display: flex;
    justify-content: space-between;
  }
  .progress-bar {
    height: 6px;
    background: var(--border);
    border-radius: 3px;
    overflow: hidden;
  }
  .progress-fill {
    height: 100%;
    background: var(--done);
    border-radius: 3px;
    transition: width .3s;
  }

  /* ── Checklist ───────────────────────────────────────────── */
  .task-list { list-style: none; }
  .task-list li {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: 5px 0;
    border-bottom: 1px solid #21262d;
    font-size: 13px;
  }
  .task-list li:last-child { border-bottom: none; }
  .task-check {
    width: 16px;
    height: 16px;
    border-radius: 3px;
    border: 1.5px solid var(--border);
    flex-shrink: 0;
    margin-top: 2px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 10px;
  }
  .task-check.done {
    background: var(--done);
    border-color: var(--done);
    color: #fff;
  }
  .task-tid {
    font-size: 11px;
    color: var(--muted);
    white-space: nowrap;
    flex-shrink: 0;
    font-family: monospace;
  }
  .task-text { color: var(--text); }
  .task-text.done { color: var(--muted); text-decoration: line-through; }

  /* ── Agents grid ──────────────────────────────────────────── */
  .agents-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 8px;
  }
  .agent-card {
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 10px 12px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .agent-card.status-idle     { border-color: var(--idle); opacity: .55; }
  .agent-card.status-in-progress { border-color: var(--progress); }
  .agent-card.status-done     { border-color: var(--done); }
  .agent-card.status-blocked  { border-color: var(--blocked); }

  .agent-slug {
    font-size: 13px;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 5px;
  }
  .status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .dot-idle        { background: var(--idle); }
  .dot-in-progress { background: var(--progress); }
  .dot-done        { background: var(--done); }
  .dot-blocked     { background: var(--blocked); }

  .agent-meta {
    font-size: 11px;
    color: var(--muted);
  }
  .agent-brief {
    font-size: 12px;
    color: var(--text);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  /* ── Outputs table ────────────────────────────────────────── */
  .output-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
  }
  .output-table th {
    text-align: left;
    padding: 6px 10px;
    font-size: 11px;
    color: var(--muted);
    border-bottom: 1px solid var(--border);
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: .04em;
  }
  .output-table td {
    padding: 7px 10px;
    border-bottom: 1px solid #21262d;
    vertical-align: top;
  }
  .output-table tr:last-child td { border-bottom: none; }
  .output-table tr:hover td { background: #1c2128; }
  .output-table a {
    color: #58a6ff;
    text-decoration: none;
  }
  .output-table a:hover { text-decoration: underline; }
  .tag {
    display: inline-block;
    background: #1f6feb22;
    color: #58a6ff;
    border: 1px solid #1f6feb44;
    border-radius: 4px;
    padding: 1px 6px;
    font-size: 11px;
    font-family: monospace;
  }

  /* ── Metrics ──────────────────────────────────────────────── */
  .metrics-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: 10px;
  }
  .metric-card {
    background: #1c2128;
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 12px;
    text-align: center;
  }
  .metric-value {
    font-size: 28px;
    font-weight: 700;
    color: var(--text);
    line-height: 1.2;
  }
  .metric-label {
    font-size: 11px;
    color: var(--muted);
    margin-top: 2px;
  }
  .metrics-empty {
    color: var(--muted);
    font-size: 13px;
    font-style: italic;
  }

  /* ── Closed iterations ────────────────────────────────────── */
  details summary {
    cursor: pointer;
    color: var(--muted);
    font-size: 12px;
    user-select: none;
  }
  details summary:hover { color: var(--text); }
  details[open] summary { margin-bottom: 8px; }
  .closed-list {
    list-style: none;
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 8px;
  }
  .closed-list a {
    background: #21262d;
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 3px 8px;
    font-size: 12px;
    color: var(--muted);
    text-decoration: none;
    font-family: monospace;
  }
  .closed-list a:hover { color: var(--text); border-color: var(--muted); }

  .empty-state {
    color: var(--muted);
    font-size: 13px;
    font-style: italic;
    padding: 8px 0;
  }
  .goal-text {
    font-size: 14px;
    margin-bottom: 12px;
    color: var(--text);
    font-style: italic;
  }
  .no-goal {
    color: var(--muted);
    font-style: italic;
  }

  /* ── Agent card token badge ───────────────────────────────── */
  .agent-card {
    position: relative;
  }
  .token-badge {
    position: absolute;
    top: 8px;
    right: 8px;
    font-size: 10px;
    font-weight: 600;
    color: var(--muted);
    background: #21262d;
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1px 5px;
    font-family: monospace;
    line-height: 1.4;
  }

  /* ── Output type badge ────────────────────────────────────── */
  .tag-final {
    display: inline-block;
    background: #23863622;
    color: #3fb950;
    border: 1px solid #23863644;
    border-radius: 4px;
    padding: 1px 6px;
    font-size: 11px;
    font-family: monospace;
  }
  .tag-draft {
    display: inline-block;
    background: #9e6a0322;
    color: #d29922;
    border: 1px solid #9e6a0344;
    border-radius: 4px;
    padding: 1px 6px;
    font-size: 11px;
    font-family: monospace;
  }
</style>
</head>
<body>
<div id="root"></div>

<script>
const DATA = __DATA_JSON__;

// ── Helpers ───────────────────────────────────────────────────────────────────
const el = (tag, attrs = {}, ...children) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k === 'html')  e.innerHTML = v;
    else e.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c == null) continue;
    e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return e;
};

const statusDotClass = s => `status-dot dot-${s}`;
const statusLabel = {
  'idle': 'idle',
  'in-progress': 'běží',
  'done': 'hotovo ✓',
  'blocked': 'blokován ✗',
};

// ── Reload helper (used by button and auto-refresh) ─────────────────────────────
function reloadDashboard() {
  fetch(location.href, {cache: 'no-cache'})
    .then(r => r.text())
    .then(html => {
      document.open(); document.write(html); document.close();
    })
    .catch(() => location.reload());
}

// Auto-refresh every 10 seconds
setInterval(reloadDashboard, 10000);

// ── Header ─────────────────────────────────────────────────────────────────────
function renderHeader() {
  const iter  = DATA.iteration;
  const badge = iter
    ? el('span', {class: 'badge'}, iter.id)
    : el('span', {class: 'badge no-iter'}, 'bez aktivní iterace');

  const ts = el('span', {class: 'ts'}, 'Vygenerováno: ' + DATA.generated.replace('T', ' ').replace('Z', ' UTC'));
  const btn = el('button', {class: 'refresh'}, '↻ Refresh');
  btn.addEventListener('click', reloadDashboard);

  return el('div', {class: 'header'},
    el('h1', {}, 'AI Workflow Dashboard'),
    badge,
    el('div', {class: 'header-right'}, ts, btn)
  );
}

// ── Iteration Plan ─────────────────────────────────────────────────────────────
function renderPlan() {
  const iter = DATA.iteration;

  // Closed iterations (always shown at bottom of plan card)
  const closedSection = (() => {
    if (!DATA.closed_iterations?.length) return null;
    const links = DATA.closed_iterations.map(id => {
      const a = el('a', {href: `orchestration/runs/${id}/plan.md`, target: '_blank'}, id);
      return el('li', {}, a);
    });
    return el('details', {},
      el('summary', {}, `Uzavřené iterace (${DATA.closed_iterations.length})`),
      el('ul', {class: 'closed-list'}, ...links)
    );
  })();

  if (!iter) {
    return el('div', {class: 'card'},
      el('div', {class: 'card-title'}, 'Iterace'),
      el('p', {class: 'empty-state'}, 'Žádná aktivní iterace.'),
      closedSection
    );
  }

  const pct = iter.total > 0 ? Math.round(iter.done_count / iter.total * 100) : 0;

  const progressBar = el('div', {class: 'progress-wrap'},
    el('div', {class: 'progress-label'},
      el('span', {}, 'Checklist'),
      el('span', {}, `${iter.done_count} / ${iter.total}`)
    ),
    el('div', {class: 'progress-bar'},
      el('div', {class: 'progress-fill', style: `width:${pct}%`})
    )
  );

  const taskItems = iter.tasks.map(t =>
    el('li', {},
      el('span', {class: `task-check${t.done ? ' done' : ''}`}, t.done ? '✓' : ''),
      t.id ? el('span', {class: 'task-tid'}, t.id) : null,
      el('span', {class: `task-text${t.done ? ' done' : ''}`}, t.text)
    )
  );

  const goalEl = iter.goal
    ? el('p', {class: 'goal-text'}, iter.goal)
    : el('p', {class: 'goal-text no-goal'}, '(goal nevyplněn)');

  return el('div', {class: 'card'},
    el('div', {class: 'card-title'},
      'Iterace',
    ),
    goalEl,
    iter.total > 0 ? progressBar : null,
    iter.total > 0 ? el('ul', {class: 'task-list'}, ...taskItems) : el('p', {class: 'empty-state'}, 'Master checklist je prázdný.'),
    closedSection ? el('div', {style: 'margin-top:14px'}, closedSection) : null
  );
}

// ── Agent summary metrics (inline in agents card title) ───────────────────────
function agentSummary(agents) {
  const cnt = { 'in-progress': 0, done: 0, blocked: 0, idle: 0 };
  for (const a of agents) cnt[a.status] = (cnt[a.status] || 0) + 1;
  const parts = [];
  if (cnt['in-progress']) parts.push(`${cnt['in-progress']} běží`);
  if (cnt.done)           parts.push(`${cnt.done} hotovo`);
  if (cnt.blocked)        parts.push(`${cnt.blocked} blokováno`);
  return parts.length ? parts.join(' · ') : `${cnt.idle} idle`;
}

// ── Agents ─────────────────────────────────────────────────────────────────────
function renderAgents() {
  const agents = DATA.agents || [];
  const agentTokens = DATA.agent_tokens || {};

  const cards = agents.map(a => {
    const metaParts = [];
    if (a.task_id)   metaParts.push(a.task_id);
    if (a.iteration) metaParts.push(a.iteration);

    // Token badge: show X.XK if data available
    const rawTokens = agentTokens[a.slug];
    const tokenBadge = (rawTokens != null && rawTokens !== 'N/A')
      ? el('span', {class: 'token-badge'}, (rawTokens / 1000).toFixed(1) + 'K')
      : null;

    return el('div', {class: `agent-card status-${a.status}`},
      tokenBadge,
      el('div', {class: 'agent-slug'},
        el('span', {class: statusDotClass(a.status)}),
        a.slug
      ),
      metaParts.length ? el('div', {class: 'agent-meta'}, metaParts.join(' · ')) : null,
      a.brief ? el('div', {class: 'agent-brief', title: a.brief}, a.brief) : null,
      a.status !== 'idle' && a.completed
        ? el('div', {class: 'agent-meta'}, '✓ ' + a.completed.replace('T', ' ').slice(0, 19))
        : null
    );
  });

  return el('div', {class: 'card'},
    el('div', {class: 'card-title'},
      el('span', {}, 'Agenti'),
      el('span', {style: 'font-size:11px; font-weight:400'}, agentSummary(agents))
    ),
    agents.length
      ? el('div', {class: 'agents-grid'}, ...cards)
      : el('p', {class: 'empty-state'}, 'Žádní agenti nenalezeni.')
  );
}

// ── Outputs ────────────────────────────────────────────────────────────────────
function renderOutputs() {
  const outputs = DATA.outputs || [];

  if (!outputs.length) {
    return el('div', {class: 'card'},
      el('div', {class: 'card-title'}, 'Výstupy agentů'),
      el('p', {class: 'empty-state'}, 'Žádné výstupy.')
    );
  }

  const rows = outputs.map(o => {
    // Link leads to artifact file
    const link = el('a', {href: o.file, target: '_blank'}, '→ zobrazit');
    // Task tag: fallback to filename if task is empty
    const taskTag = el('span', {class: 'tag'}, o.task || o.name);
    // Type badge: final (green) or draft (yellow)
    const typeBadge = el('span', {class: o.type === 'final' ? 'tag-final' : 'tag-draft'}, o.type || '–');
    return el('tr', {},
      el('td', {}, taskTag),
      el('td', {}, o.agent),
      el('td', {}, typeBadge),
      el('td', {}, o.description || '–'),
      el('td', {}, o.completed ? o.completed.replace('T', ' ').replace('Z', '').slice(0, 16) : '–'),
      el('td', {}, link)
    );
  });

  return el('div', {class: 'card'},
    el('div', {class: 'card-title'}, 'Výstupy agentů'),
    el('table', {class: 'output-table'},
      el('thead', {},
        el('tr', {},
          el('th', {}, 'Task'),
          el('th', {}, 'Agent'),
          el('th', {}, 'Typ'),
          el('th', {}, 'Popis'),
          el('th', {}, 'Dokončeno'),
          el('th', {}, '')
        )
      ),
      el('tbody', {}, ...rows)
    )
  );
}

// ── Metrics ────────────────────────────────────────────────────────────────────
function renderMetrics() {
  const metrics = DATA.metrics || {};
  const keys = Object.keys(metrics);

  // Build KPI cards from flat numeric values in JSON metrics
  const kpis = [];
  for (const [key, val] of Object.entries(metrics)) {
    if (val.raw) continue; // skip raw MD metrics
    for (const [k, v] of Object.entries(val)) {
      if (typeof v === 'number') {
        kpis.push({ label: `${key} / ${k}`, value: v });
      }
    }
  }

  // Raw markdown metrics
  const raws = Object.entries(metrics).filter(([, v]) => v.raw);

  const inner = [];
  if (kpis.length) {
    inner.push(
      el('div', {class: 'metrics-grid'},
        ...kpis.map(k =>
          el('div', {class: 'metric-card'},
            el('div', {class: 'metric-value'}, String(k.value)),
            el('div', {class: 'metric-label'}, k.label)
          )
        )
      )
    );
  }
  for (const [key, val] of raws) {
    inner.push(
      el('details', {style: 'margin-top:10px'},
        el('summary', {}, key),
        el('pre', {style: 'margin-top:8px; font-size:12px; color:var(--muted); white-space:pre-wrap'}, val.raw)
      )
    );
  }
  if (!inner.length) {
    inner.push(el('p', {class: 'metrics-empty'}, 'Žádná data. Metriky se plní po spuštění agentů.'));
  }

  return el('div', {class: 'card'},
    el('div', {class: 'card-title'}, 'Metriky'),
    ...inner
  );
}

// ── Render all ─────────────────────────────────────────────────────────────────
function render() {
  const root = document.getElementById('root');
  root.appendChild(renderHeader());

  const top = el('div', {class: 'grid-top'});
  top.appendChild(renderPlan());
  top.appendChild(renderAgents());
  root.appendChild(top);

  root.appendChild(el('div', {class: 'section'}, renderOutputs()));
  root.appendChild(el('div', {class: 'section'}, renderMetrics()));
}

render();
</script>
</body>
</html>
"""

# ─────────────────────────────────────────────────────────────────────────────
# Write output
# ─────────────────────────────────────────────────────────────────────────────

html = HTML.replace("__DATA_JSON__", DATA_JSON)
OUT.write_text(html, encoding="utf-8")
print(f"Dashboard vygenerován: {OUT}")
