#!/bin/bash
# Builds Worktrees.app and zips it for a GitHub release.
# Usage: scripts/release.sh            -> build/Worktrees-<version>.zip
# The app is ad-hoc signed, not notarized. First launch needs right-click, then Open.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Worktrees.app/Contents/Info.plist)
ZIP="build/Worktrees-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the bundle's resource forks and signature intact, unlike plain zip.
ditto -c -k --keepParent build/Worktrees.app "$ZIP"
echo "Built $ZIP"
echo "Upload it to a GitHub release tagged v$VERSION."
