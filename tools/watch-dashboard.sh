#!/usr/bin/env bash
# Regeneruje dashboard každých N sekund (default: 10)
# Spuštění: bash tools/watch-dashboard.sh
# Zastavení: Ctrl+C
INTERVAL="${1:-10}"
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -lt 1 ]]; then
  printf 'Chyba: INTERVAL musí být kladné celé číslo (default: 10)\n' >&2
  exit 1
fi
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
trap "exit 0" SIGTERM SIGINT
while true; do
  make -C "$REPO_ROOT/.aiworkflow" dashboard 2>/dev/null
  sleep "$INTERVAL"
done
