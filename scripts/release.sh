#!/bin/bash
# Builds a notarized, stapled dist/Tuno-<version>.dmg and .zip.
#
#   scripts/release.sh
#   NOTARIZE=0 scripts/release.sh     skip notarization, to check the dmg layout
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
WORK="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$WORK"' EXIT
mkdir -p dist
rm -f "$DMG" "$ZIP"

echo "→ $DMG"
VOLUME="Tuno"
ditto build/Tuno.app "$STAGE/Tuno.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Resources/DMG/background.tiff "$STAGE/.background/background.tiff"

# Lay the window out in a writable image first; Finder saves the icon
# positions and background into the volume's .DS_Store.
hdiutil detach -quiet "/Volumes/$VOLUME" 2>/dev/null || true
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach -quiet -noautoopen "$WORK/rw.dmg"
chflags hidden "/Volumes/$VOLUME/.background"
# Positions are in the 660×400 background's coordinates. Finder places the
# icon about 45 pt below the given point, so these land the icons' centres at
# y 200, just above the glow spots in Resources/DMG/background.tiff.
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 12
        set background picture of options to file ".background:background.tiff"
        set position of item "Tuno.app" of container window to {180, 155}
        set position of item "Applications" of container window to {480, 155}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
rm -rf "/Volumes/$VOLUME/.fseventsd"
sync
hdiutil detach -quiet "/Volumes/$VOLUME"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

# Notarizing the dmg covers the app inside it; stapling both means Gatekeeper
# doesn't need to go online the first time either one is opened.
if [[ "${NOTARIZE:-1}" == 1 ]]; then
    echo "→ notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler staple build/Tuno.app
fi

echo "→ $ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Tuno.app "$ZIP"

[[ "${NOTARIZE:-1}" == 1 ]] && spctl --assess --type open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG" "$ZIP"
