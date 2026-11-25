#!/bin/bash
# Builds build/Tuno.app.
#
#   ./build.sh                     sign with Kaan Firat's Developer ID certificate
#   IDENTITY="…" ./build.sh        sign with another certificate
#   IDENTITY=- ./build.sh          ad-hoc signing
#   CONFIGURATION=debug ./build.sh a debug build, with the mock player:
#                                  open build/Tuno.app --args --mock-player
#
# For a notarized release, use scripts/release.sh instead.
#
# A stable signing identity matters: macOS ties the Accessibility grant to it,
# so ad-hoc builds lose the permission on every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Tuno.app"
CONTENTS="$APP/Contents"
IDENTITY="${IDENTITY:-Developer ID Application: Kaan Firat (SGWP227GBQ)}"
MIN_MACOS="12.0"
CONFIGURATION="${CONFIGURATION:-release}"
if [[ "$CONFIGURATION" == "debug" ]]; then
    SWIFT_FLAGS=(-Onone -D DEBUG)
else
    SWIFT_FLAGS=(-O)
fi

rm -rf build
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "→ TunoBridge.dylib"
clang -dynamiclib -fobjc-arc -fvisibility=hidden -O2 -Wall \
    -mmacosx-version-min="$MIN_MACOS" \
    -framework Foundation \
    -o "$CONTENTS/Resources/TunoBridge.dylib" \
    Sources/Bridge/TunoBridge.m

echo "→ Tuno"
swiftc "${SWIFT_FLAGS[@]}" \
    -target "$(uname -m)-apple-macos$MIN_MACOS" \
    -framework AppKit \
    -o "$CONTENTS/MacOS/Tuno" \
    Sources/App/*.swift

cp Resources/Info.plist "$CONTENTS/Info.plist"
install -m 755 Resources/tuno-bridge.pl "$CONTENTS/Resources/tuno-bridge.pl"
# Regenerate with scripts/make-icns.sh after editing Resources/Icon/AppIcon.svg.
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# The layered Liquid Glass icon (macOS 26+), from Resources/Icon/Tuno.icon.
# Needs Xcode 26's actool; without it the .icns above is the icon.
echo "→ Assets.car"
PARTIAL="$(mktemp)"
if xcrun actool Resources/Icon/Tuno.icon --compile "$CONTENTS/Resources" --platform macosx \
        --minimum-deployment-target "$MIN_MACOS" --app-icon Tuno \
        --output-partial-info-plist "$PARTIAL" >/dev/null 2>&1; then
    # actool also writes a sparse Tuno.icns; AppIcon.icns is the better fallback.
    rm -f "$CONTENTS/Resources/Tuno.icns"
else
    echo "warning: couldn't compile Tuno.icon (needs Xcode 26); using AppIcon.icns only" >&2
fi
rm -f "$PARTIAL"

if [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    echo "warning: signing identity \"$IDENTITY\" not found, signing ad-hoc" >&2
    IDENTITY="-"
fi

# Notarization needs the hardened runtime and a secure timestamp, which only
# make sense for a Developer ID build.
SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
fi

echo "→ codesign ($IDENTITY)"
xattr -cr "$APP"
codesign "${SIGN_FLAGS[@]}" "$CONTENTS/Resources/TunoBridge.dylib"
codesign "${SIGN_FLAGS[@]}" --entitlements Resources/Tuno.entitlements "$APP"

echo "Built $APP — run with: open $APP"
