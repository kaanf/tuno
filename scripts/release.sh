#!/bin/bash
# Builds a notarized, stapled dist/Tuno-<version>.dmg and .zip.
#
#   scripts/release.sh
#
# Needs a "Developer ID Application" certificate in the keychain and a
# notarytool profile saved once with:
#
#   xcrun notarytool store-credentials tuno --apple-id <apple id> --team-id SGWP227GBQ
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:-tuno}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
if [[ -z "$IDENTITY" ]]; then
    echo "error: no Developer ID Application certificate in the keychain" >&2
    exit 1
fi

IDENTITY="$IDENTITY" ./build.sh

DMG="dist/Tuno-$VERSION.dmg"
ZIP="dist/Tuno-$VERSION.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p dist
rm -f "$DMG" "$ZIP"

echo "→ $DMG"
ditto build/Tuno.app "$STAGE/Tuno.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Tuno $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

# Notarizing the dmg covers the app inside it; stapling both means Gatekeeper
# doesn't need to go online the first time either one is opened.
echo "→ notarizing"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler staple build/Tuno.app

echo "→ $ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Tuno.app "$ZIP"

spctl --assess --type open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG" "$ZIP"
