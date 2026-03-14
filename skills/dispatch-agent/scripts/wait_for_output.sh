#!/usr/bin/env bash
# wait_for_output.sh — Block until one or more expected output files appear
#
# Usage:
#   wait_for_output.sh <path> [<path> ...] [--timeout <secs>] [--interval <secs>] [--min-size <bytes>]
#
# Exit codes:
#   0 — all files found and ready
#   1 — timeout reached, one or more files never appeared
#   2 — bad arguments
#
# Examples:
#   # Single file
#   wait_for_output.sh outputs/report.md
#
#   # Multiple files (parallel subagents)
#   wait_for_output.sh outputs/a.md outputs/b.md outputs/c.md --timeout 300
#
#   # From a file listing paths (one per line)
#   wait_for_output.sh --paths-file .claude-local/tmp/expected-outputs.txt

set -euo pipefail

ART_DIR="${CLAUDE_ARTIFACTS_DIR:-.claude-local}"
LOG_FILE="${ART_DIR}/run-logs/wait_for_output.log"

# ── defaults ──────────────────────────────────────────────────────────────────
TIMEOUT=300
INTERVAL=5
MIN_SIZE=1
PATHS_FILE=""
declare -a EXPECTED_PATHS=()

# ── helpers ───────────────────────────────────────────────────────────────────
log()  { printf '%s [WAIT] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE"; }
emit() { printf '%s\n' "$*"; log "$*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <path> [<path> ...] [OPTIONS]
       $(basename "$0") --paths-file <file> [OPTIONS]

Arguments:
  <path> ...             one or more output paths to wait for

Options:
  --paths-file <file>    read expected paths from file (one per line, # = comment)
  --timeout <seconds>    shared wall-clock timeout (default: ${TIMEOUT})
  --interval <seconds>   polling interval (default: ${INTERVAL})
  --min-size <bytes>     minimum file size to count as ready (default: ${MIN_SIZE})
  -h, --help             show this help

Exit codes:
  0  all files appeared and are ready
  1  timeout — one or more files never appeared
  2  bad arguments
EOF
  exit 2
}

# ── arg parsing ───────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)    TIMEOUT="$2";    shift 2 ;;
    --interval)   INTERVAL="$2";   shift 2 ;;
    --min-size)   MIN_SIZE="$2";   shift 2 ;;
    --paths-file) PATHS_FILE="$2"; shift 2 ;;
    -h|--help)    usage ;;
    --*) printf 'ERROR: Unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)   EXPECTED_PATHS+=("$1");   shift ;;
  esac
done

# load from paths file if given
if [[ -n "$PATHS_FILE" ]]; then
  [[ -f "$PATHS_FILE" ]] || { printf 'ERROR: --paths-file not found: %s\n' "$PATHS_FILE" >&2; exit 2; }
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue
    EXPECTED_PATHS+=("$line")
  done < "$PATHS_FILE"
fi

[[ ${#EXPECTED_PATHS[@]} -eq 0 ]] && { printf 'ERROR: no paths provided\n' >&2; exit 2; }

mkdir -p "${ART_DIR}/run-logs" "${ART_DIR}/tmp"

# ── state tracking ────────────────────────────────────────────────────────────
TOTAL=${#EXPECTED_PATHS[@]}
declare -A READY_AT=()

is_ready() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  local size
  size=$(wc -c < "$path" 2>/dev/null || echo 0)
  [[ "$size" -ge "$MIN_SIZE" ]]
}

# ── startup summary ───────────────────────────────────────────────────────────
log "Starting. Waiting for ${TOTAL} file(s). Timeout: ${TIMEOUT}s, interval: ${INTERVAL}s"
emit "WAITING for ${TOTAL} file(s) (timeout: ${TIMEOUT}s):"
for p in "${EXPECTED_PATHS[@]}"; do
  emit "  - ${p}"
done

# ── main wait loop ────────────────────────────────────────────────────────────
START=$(date +%s)
DEADLINE=$((START + TIMEOUT))

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))

  # check each path not yet marked ready
  for path in "${EXPECTED_PATHS[@]}"; do
    [[ -v READY_AT["$path"] ]] && continue
    if is_ready "$path"; then
      SIZE=$(wc -c < "$path")
      READY_AT["$path"]=$ELAPSED
      REMAINING_COUNT=$((TOTAL - ${#READY_AT[@]}))
      emit "  READY ${path} (${ELAPSED}s, ${SIZE} bytes) — ${REMAINING_COUNT} remaining"
    fi
  done

  READY_COUNT=${#READY_AT[@]}

  # all done?
  if [[ "$READY_COUNT" -eq "$TOTAL" ]]; then
    emit ""
    emit "READY ALL ${TOTAL}/${TOTAL} files ready after ${ELAPSED}s"
    for path in "${EXPECTED_PATHS[@]}"; do
      emit "  ✓ ${path} (ready at ${READY_AT[$path]}s)"
    done
    exit 0
  fi

  # timeout?
  if [[ "$NOW" -ge "$DEADLINE" ]]; then
    emit ""
    emit "TIMEOUT after ${ELAPSED}s — ${READY_COUNT}/${TOTAL} files ready"
    for path in "${EXPECTED_PATHS[@]}"; do
      if [[ -v READY_AT["$path"] ]]; then
        emit "  ✓ ${path} (ready at ${READY_AT[$path]}s)"
      else
        emit "  ✗ ${path} (never appeared)"
      fi
    done
    exit 1
  fi

  REMAINING=$((DEADLINE - NOW))
  log "Progress: ${READY_COUNT}/${TOTAL} ready. Elapsed: ${ELAPSED}s, remaining: ${REMAINING}s"
  sleep "$INTERVAL"
done
