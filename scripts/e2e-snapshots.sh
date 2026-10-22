#!/bin/bash
# Renders the app on fixture repos with different settings, without opening a window.
# Usage: scripts/e2e-snapshots.sh [out dir]   (default .build/e2e)
# Each picture shows one feature working; look at them after a change. Settings go in as launch
# arguments, so nothing is saved and the real app's settings are never read.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-.build/e2e}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixtures"
python3 -I scripts/make-fixtures.py "$FIX" >/dev/null
ROOT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["root"])' "$FIX/fixtures.json")
export WORKTREES_GH="$FIX/fake-gh" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GH_CONFIG_DIR="$TMP/gh-config"
swift build >/dev/null
B=.build/debug/Worktrees
mkdir -p "$OUT"

# Overview: tags, failing checks, one failed lookup (gamma) in the footer.
$B --snapshot "$OUT/overview.png" --real "$ROOT"
# Tidy up with defaults: 4 merged, 1 closed, 2 stale (unticked).
$B --snapshot "$OUT/tidy-default.png" --real "$ROOT" --tidy
# 7 days, stale ticked, Trash wording, release protected: 3 merged, 1 closed, 3 stale, all ticked.
$B --snapshot "$OUT/tidy-7days.png" --real "$ROOT" --tidy -staleDays 7 -preselectStale YES -trashOnDelete YES -protectedBranches '(main, release)'
# One repo's worktrees, grouped like the Overview with the main checkout on top.
$B --snapshot "$OUT/repo-alpha.png" --real "$ROOT" --folder alpha
# Claude Code and Codex tags hidden.
$B --snapshot "$OUT/overview-hidden-tags.png" --real "$ROOT" -hiddenTools '("claude-code", codex)'
# Scan depth 5 finds deeprepo; skipping sandbox drops sandboxed.
$B --snapshot "$OUT/overview-depth5-skip.png" --real "$ROOT" -scanDepth 5 -skippedFolders '(sandbox)'
# Each onboarding step, dark.
for s in welcome folders github ready; do
    $B --snapshot "$OUT/onboarding-$s.png" --onboarding "$s" --dark
done
# Every Settings page, light and dark.
for p in general folders tidy github tools advanced; do
    $B --snapshot "$OUT/settings-$p.png" --settings "$p"
    $B --snapshot "$OUT/settings-$p-dark.png" --settings "$p" --dark
done
echo "Pictures in $OUT"
