#!/bin/bash
# Runs a separate test copy of the app on throwaway fixture repos, for trying every feature by hand.
# Usage: scripts/test-app.sh               build fixtures, build and open "Worktrees Test"
#        scripts/test-app.sh --onboarding  the same, starting at first-launch onboarding, which
#                                          looks for project folders in the fixtures, not your home
#        scripts/test-app.sh --clean       quit it, delete its fixtures and its settings
#
# The copy has its own bundle id (me.apek.worktrees.test), so its settings, folders and window
# state live apart from the real app's. It scans only the fixtures, answers PR lookups from a
# fake gh (the real one is blocked), keeps the user's git config out, keeps its own Trash folder,
# and never posts notifications or registers a login item.
set -euo pipefail
cd "$(dirname "$0")/.."

ID=me.apek.worktrees.test
APP=build/WorktreesTest.app
FIXTURES="${TMPDIR:-/tmp}/worktrees-e2e"

osascript -e "quit app id \"$ID\"" 2>/dev/null || true
if [[ "${1:-}" == "--clean" ]]; then
    rm -rf "$FIXTURES" "$APP"
    defaults delete "$ID" 2>/dev/null || true
    echo "Cleaned up the test app, its fixtures and its settings."
    exit 0
fi

rm -rf "$FIXTURES"
python3 -I scripts/make-fixtures.py "$FIXTURES" >/dev/null
ROOT=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["root"])' "$FIXTURES/fixtures.json")

scripts/bundle.sh >/dev/null
rm -rf "$APP"
cp -R build/Worktrees.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" -c "Set :CFBundleName Worktrees Test" -c "Set :CFBundleDisplayName Worktrees Test" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null

# No windows restored from an earlier run.
rm -rf "$HOME/Library/Saved Application State/$ID.savedState"

# Fresh settings every run: only the fixtures are scanned, PRs come from the fake gh, and Move to
# Trash uses a folder next to the fixtures. These live in the copy's own settings, so reopening it
# from the Dock or Finder keeps them.
defaults delete "$ID" 2>/dev/null || true
if [[ "${1:-}" == "--onboarding" ]]; then
    defaults write "$ID" testHome "$FIXTURES"
else
    defaults write "$ID" roots -array "$ROOT"
    defaults write "$ID" onboarded -bool true
fi
defaults write "$ID" testFakeGh "$FIXTURES/fake-gh"
defaults write "$ID" testTrash "$FIXTURES/Trash"

open -n "$APP"
echo "Opened Worktrees Test on $ROOT"
echo "Fixture keys and paths: $FIXTURES/fixtures.json"
