#!/bin/zsh
# Builds SiriMouse.app into ./build. Usage: ./build.sh [--install] [--run]
#   --install  copy the app to /Applications (needed for Launch at Login)
#   --run      launch it after building
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SiriMouse"

APP="build/SiriMouse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SiriMouse"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity when one exists: macOS ties Accessibility and Input Monitoring
# grants to the signature, so ad-hoc signing means re-granting them after every rebuild.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
  # Hardened runtime and a secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp \
    --entitlements Resources/SiriMouse.entitlements --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Signed with: ${IDENTITY:-ad-hoc}"

if [[ " $* " == *" --install "* ]]; then
  pkill -x SiriMouse || true
  rm -rf /Applications/SiriMouse.app
  cp -R "$APP" /Applications/
  APP="/Applications/SiriMouse.app"
  echo "Installed to $APP"
fi

if [[ " $* " == *" --run "* ]]; then
  pkill -x SiriMouse || true
  open "$APP"
fi
echo "Built $APP"
