#!/bin/bash
# Builds Worktrees.app, signs it and zips it for a GitHub release.
# Usage: scripts/release.sh   -> build/Worktrees-<version>.zip, its SHA-256, and build/worktrees.rb
#
# With a "Developer ID Application" certificate in the keychain, the app is signed with the
# hardened runtime. With notary credentials saved too
#   xcrun notarytool store-credentials worktrees-notary --apple-id <id> --team-id <team>
# it is notarized and the ticket stapled, so it opens with a double-click. Without either it is
# ad hoc signed, and the first launch needs System Settings > Privacy & Security > Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh
APP=build/Worktrees.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="build/Worktrees-$VERSION.zip"
PROFILE=worktrees-notary
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)

if [[ -n "$IDENTITY" ]]; then
    # No entitlements needed: running git and gh is allowed under the hardened runtime.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        # The zip sent to Apple carries no ticket; the app is stapled afterwards and zipped again.
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
        xcrun stapler staple "$APP"
        spctl --assess --type execute --verbose=2 "$APP"
        SIGNED="signed with $IDENTITY and notarized"
    else
        SIGNED="signed with $IDENTITY, not notarized (no $PROFILE keychain profile)"
    fi
else
    SIGNED="ad hoc signed (no Developer ID Application certificate)"
fi

rm -f "$ZIP"
# ditto keeps the bundle's resource forks and signature intact, unlike plain zip.
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/homebrew/worktrees.rb > build/worktrees.rb

echo "Built $ZIP, $SIGNED."
echo "SHA-256: $SHA"
echo "Homebrew cask: build/worktrees.rb"
