#!/bin/bash
# Builds VolumeMixer.app and copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Apple's Command Line Tools first:"
  echo "    xcode-select --install"
  exit 1
fi

APP="build/VolumeMixer.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling..."
swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos15.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/VolumeMixer"

cp Info.plist "$APP/Contents/Info.plist"

# Sign with a stable personal certificate so macOS keeps permissions across
# rebuilds. Falls back to ad-hoc signing (permissions may reset) if that fails.
IDENTITY="VolumeMixer Local Signing"
if /bin/bash ./setup-signing.sh && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with \"$IDENTITY\"."
else
  echo "Warning: couldn't use \"$IDENTITY\", signing ad-hoc instead. Permissions may reset after rebuilds."
  codesign --force --sign - "$APP"
fi

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/VolumeMixer.app"
cp -R "$APP" "$HOME/Applications/"

echo "Done: ~/Applications/VolumeMixer.app"
open "$HOME/Applications/VolumeMixer.app"
