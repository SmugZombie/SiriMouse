#!/bin/zsh
# Builds SiriMouse.app into ./build. Usage: ./build.sh [--arm64] [--install] [--run]
#   --arm64    Apple silicon only (default is a universal arm64 + x86_64 binary)
#   --install  copy the app to /Applications (needed for Launch at Login)
#   --run      launch it after building
set -euo pipefail
cd "${0:A:h}"

# Universal binary: runs natively on Apple silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
[[ " $* " == *" --arm64 "* ]] && ARCHS=(--arch arm64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/SiriMouse"

APP="build/SiriMouse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SiriMouse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity when one exists: macOS ties Accessibility and Input Monitoring
# grants to the signature, so ad-hoc signing means re-granting them after every rebuild.
# Always prefer the same certificate: switching between Developer ID and Apple Development
# changes the signature's designated requirement and revokes the grants.
IDENTITIES="$(security find-identity -v -p codesigning)"
IDENTITY="${SIGN_IDENTITY:-$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<< "$IDENTITIES")}"
IDENTITY="${IDENTITY:-$(awk -F'"' '/Apple Development/ {print $2; exit}' <<< "$IDENTITIES")}"
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
