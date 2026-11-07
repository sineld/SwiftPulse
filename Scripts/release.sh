#!/bin/zsh
# Usage: DEVELOPMENT_TEAM=… NOTARY_KEY_ID=… NOTARY_ISSUER=… Scripts/release.sh
# Builds dist/SwiftPulse-<version>.dmg: universal, Developer ID signed, notarized by Apple and stapled.
# Notarization uses an App Store Connect API key (NOTARY_KEY_PATH defaults to the usual .p8 location).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple Team ID}"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER:?set NOTARY_ISSUER}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${NOTARY_KEY_ID}.p8}"

notarize() {
    xcrun notarytool submit "$1" --wait --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
}

xcodegen generate
# Release builds both architectures; Developer ID signing needs the hardened runtime (set in project.yml) and a timestamp.
# Notarization rejects the get-task-allow entitlement Xcode would otherwise inject.
# The prefix maps turn source paths baked into the binary (#file in our code and the packages) into relative ones,
# so the release doesn't carry the builder's home folder. Set on the command line so the packages get them too.
xcodebuild -project SwiftPulse.xcodeproj -scheme SwiftPulse -configuration Release \
    -derivedDataPath .build/DerivedData -skipPackagePluginValidation -skipMacroValidation \
    ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $PWD=." OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$PWD=." \
    clean build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP=dist/SwiftPulse.app
rm -rf "$APP"
mkdir -p dist
ditto .build/DerivedData/Build/Products/Release/SwiftPulse.app "$APP"
codesign --verify --deep --strict "$APP"
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/SwiftPulse")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/SwiftPulse-$VERSION.dmg"
STAGE=$(mktemp -d)
RW_DMG="$STAGE.dmg"
trap 'rm -rf "$STAGE" "$RW_DMG"' EXIT

# Notarize and staple the app itself, so it also opens offline once copied out of the DMG.
ditto -c -k --keepParent "$APP" "$STAGE/notarize.zip"
notarize "$STAGE/notarize.zip"
rm "$STAGE/notarize.zip"
xcrun stapler staple "$APP"

# DMG with a drag-to-Applications window (layout matches Scripts/make_dmg_background.swift).
ditto "$APP" "$STAGE/SwiftPulse.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Scripts/assets/dmg-background.png "$STAGE/.background/background.png"
chflags hidden "$STAGE/.background"

if [[ -d /Volumes/SwiftPulse ]]; then hdiutil detach /Volumes/SwiftPulse -force; fi
hdiutil create -quiet -volname SwiftPulse -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW_DMG"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk '/^\/dev\// {print $1; exit}')

osascript <<'EOF'
tell application "Finder"
    tell disk "SwiftPulse"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 660×440 background plus ~70 pt for the toolbar newer Finders keep showing; extra space below is white.
        set the bounds of container window to {200, 120, 860, 630}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.png"
        set position of item "SwiftPulse.app" of container window to {180, 220}
        set position of item "Applications" of container window to {480, 220}
        set extension hidden of item "SwiftPulse.app" to true
        -- park dot-items outside the window for people who show hidden files
        try
            set position of item ".background" of container window to {900, 900}
        end try
        try
            set position of item ".fseventsd" of container window to {1000, 900}
        end try
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

sync
hdiutil detach "$DEVICE" -quiet
rm -f "$DMG"
hdiutil convert "$RW_DMG" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"

codesign --force --timestamp --sign "Developer ID Application" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
echo "ready: $DMG (sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1))"
