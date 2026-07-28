#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/Perch.app"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Perch"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Perch.icns "$APP/Contents/Resources/Perch.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> done: $APP"
echo "    open $APP"
