#!/bin/bash
# Times the app on a big fake setup: 200 repos, 1,000 linked worktrees, some with 2,000 files.
# Usage: scripts/perf.sh [fixture dir]   reuses the dir if it already holds the fixtures
# Building them takes a couple of minutes (thousands of git calls), so this stays out of CI.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="${1:-${TMPDIR:-/tmp}/worktrees-perf}"
if [[ ! -f "$DIR/fixtures.json" ]]; then
    rm -rf "$DIR"
    echo "Building 200 repos in $DIR…"
    python3 -I scripts/make-fixtures.py "$DIR" --many 200 >/dev/null
fi
WORKTREES_PERF="$DIR" swift test --no-parallel --filter PerfTests 2>&1 | grep -E "PERF|passed|failed|issue"
