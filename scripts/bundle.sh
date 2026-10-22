#!/bin/bash
# Builds a release binary and wraps it in Worktrees.app (ad-hoc signed).
# Usage: scripts/bundle.sh [--install]   (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Worktrees.app
# The one place the version lives; a release bumps it.
VERSION=$(tr -d '[:space:]' < VERSION)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Worktrees "$APP/Contents/MacOS/Worktrees"
# The 3D icon the onboarding Welcome step shows.
cp Sources/Worktrees/Resources/icon-3d.png "$APP/Contents/Resources/icon-3d.png"

# App icon: draw at 1024px, scale to every iconset size, pack as .icns.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift build/icon_1024.png >/dev/null
for size in 16 32 128 256 512; do
    sips -z $size $size build/icon_1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon_1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Worktrees</string>
    <key>CFBundleDisplayName</key><string>Worktrees</string>
    <key>CFBundleIdentifier</key><string>me.apek.worktrees</string>
    <key>CFBundleExecutable</key><string>Worktrees</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Worktrees.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Worktrees.app"
fi
