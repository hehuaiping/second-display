#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
WORKSPACE_DIRECTORY=${SCRIPT_DIRECTORY:h}
APP_VERSION=${APP_VERSION:-1.1.0}
APP_BUILD_NUMBER=${APP_BUILD_NUMBER:-1}
RELEASE_LABEL=${RELEASE_LABEL:-$APP_VERSION}
SIGN_IDENTITY=${MACOS_SIGN_IDENTITY:--}
INSTALL_LOCAL_PAIRING_IDENTITY=${INSTALL_LOCAL_PAIRING_IDENTITY:-1}
APP_NAME="Second Display"
EXECUTABLE_NAME="SecondDisplayMacApp"
BUNDLE_IDENTIFIER="com.cuihua.cloud.display.macos"
OUTPUT_DIRECTORY=${OUTPUT_DIRECTORY:-"$WORKSPACE_DIRECTORY/dist"}
APP_BUNDLE="$OUTPUT_DIRECTORY/$APP_NAME.app"
ARCHITECTURE=$(uname -m)
DMG_PATH="$OUTPUT_DIRECTORY/SecondDisplay-$RELEASE_LABEL-macos-$ARCHITECTURE.dmg"
TEMPORARY_DIRECTORY=$(mktemp -d /tmp/second-display-package.XXXXXX)
PAIRING_SOURCE="$WORKSPACE_DIRECTORY/.build/p3-poc-tls"
PAIRING_DESTINATION="$HOME/Library/Application Support/Second Display/Pairing"

cleanup() {
    rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT INT TERM

cd "$WORKSPACE_DIRECTORY"
if [[ "$INSTALL_LOCAL_PAIRING_IDENTITY" == "1" ]]; then
    "$WORKSPACE_DIRECTORY/tools/provision_p3_tls.sh"
    mkdir -p "$PAIRING_DESTINATION"
    chmod 700 "$PAIRING_DESTINATION"
    for FILE_NAME in identity.p12 password cert.pem
    do
        install -m 600 "$PAIRING_SOURCE/$FILE_NAME" "$PAIRING_DESTINATION/$FILE_NAME"
    done
elif [[ "$INSTALL_LOCAL_PAIRING_IDENTITY" != "0" ]]; then
    print -u2 "NET_PROTOCOL_MISMATCH: INSTALL_LOCAL_PAIRING_IDENTITY must be 0 or 1"
    exit 1
fi
swift build -c release --product "$EXECUTABLE_NAME"
SWIFT_BINARY_DIRECTORY=$(swift build -c release --show-bin-path)
EXECUTABLE_PATH="$SWIFT_BINARY_DIRECTORY/$EXECUTABLE_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    print -u2 "CAP_STREAM_STOPPED: release executable was not produced"
    exit 1
fi

mkdir -p "$OUTPUT_DIRECTORY"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
ditto "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
ditto "$WORKSPACE_DIRECTORY/packaging/macos/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$APP_BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$APP_BUNDLE/Contents/Info.plist"

ICON_SOURCE="$WORKSPACE_DIRECTORY/harmony/AppScope/resources/base/media/app_icon.svg"
ICON_BASE="$TEMPORARY_DIRECTORY/AppIcon.png"
ICONSET="$TEMPORARY_DIRECTORY/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -s format png "$ICON_SOURCE" --out "$ICON_BASE" >/dev/null
for SPECIFICATION in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    SIZE=${SPECIFICATION%% *}
    FILE_NAME=${SPECIFICATION#* }
    sips -z "$SIZE" "$SIZE" "$ICON_BASE" --out "$ICONSET/$FILE_NAME" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - --identifier "$BUNDLE_IDENTIFIER" "$APP_BUNDLE"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

DMG_STAGING="$TEMPORARY_DIRECTORY/dmg"
mkdir -p "$DMG_STAGING"
ditto "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create \
    -quiet \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

if [[ -n "${NOTARY_KEY_PATH:-}" || -n "${NOTARY_KEY_ID:-}" || -n "${NOTARY_ISSUER_ID:-}" ]]; then
    if [[ -z "${NOTARY_KEY_PATH:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
        print -u2 "NET_PROTOCOL_MISMATCH: notary API key configuration is incomplete"
        exit 1
    fi
    xcrun notarytool submit "$DMG_PATH" \
        --key "$NOTARY_KEY_PATH" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
elif [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        print "Notarization skipped for ad-hoc distribution"
    else
        print "Notarization skipped; set NOTARY_KEYCHAIN_PROFILE for Developer ID distribution"
    fi
fi

print "Created $APP_BUNDLE"
print "Created $DMG_PATH"
if [[ "$INSTALL_LOCAL_PAIRING_IDENTITY" == "1" ]]; then
    print "Installed local pairing identity at $PAIRING_DESTINATION"
fi
shasum -a 256 "$DMG_PATH"
