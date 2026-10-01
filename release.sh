#!/bin/zsh
# Builds, notarizes and publishes a GitHub release. Usage: ./release.sh 1.0.0
# One-time setup: xcrun notarytool store-credentials notary --apple-id <id> --team-id <team>
set -euo pipefail
cd "${0:A:h}"

VERSION="${1:?usage: ./release.sh <version>}"
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
[[ "$PLIST_VERSION" == "$VERSION" ]] || { echo "Info.plist says $PLIST_VERSION, not $VERSION"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first"; exit 1; }

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$SIGN_IDENTITY" ]] || { echo "A Developer ID Application certificate is required"; exit 1; }
APP="build/SiriMouse.app"

# Builds, notarizes and zips one flavor: package <zip> [build.sh flags]
package() {
  local zip="$1"; shift
  SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh "$@"
  rm -f "$zip"
  ditto -c -k --keepParent "$APP" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "${NOTARY_PROFILE:-notary}" --wait
  xcrun stapler staple "$APP"
  rm -f "$zip"
  ditto -c -k --keepParent "$APP" "$zip"
  spctl --assess --type execute --verbose "$APP"
}

# Universal last, so build/SiriMouse.app is the universal app afterwards.
ARM_ZIP="build/SiriMouse-$VERSION-arm64.zip"
ZIP="build/SiriMouse-$VERSION.zip"
package "$ARM_ZIP" --arm64
package "$ZIP"

git tag -a "v$VERSION" -m "SiriMouse $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" "$ARM_ZIP" --title "SiriMouse $VERSION" --notes-file "${NOTES:-/dev/null}"
