#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
WORKSPACE_DIRECTORY=${SCRIPT_DIRECTORY:h}
DMG_PATH=${1:-"$WORKSPACE_DIRECTORY/dist/SecondDisplay-1.0.1-macos-$(uname -m).dmg"}
EXPECTED_BUNDLE_ID="com.cuihua.cloud.display.macos"
TEMPORARY_DIRECTORY=$(mktemp -d /tmp/second-display-verify.XXXXXX)
MOUNT_POINT="$TEMPORARY_DIRECTORY/mount"
mkdir -p "$MOUNT_POINT"
IS_ATTACHED=0

cleanup() {
    if [[ "$IS_ATTACHED" == "1" ]]; then
        hdiutil detach "$MOUNT_POINT" -quiet || true
    fi
    rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$DMG_PATH" ]]; then
    print -u2 "VD_APPLY_FAILED: DMG does not exist at $DMG_PATH"
    exit 1
fi

hdiutil verify "$DMG_PATH"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" -quiet
IS_ATTACHED=1
APP_PATH="$MOUNT_POINT/Second Display.app"
if [[ ! -d "$APP_PATH" ]]; then
    print -u2 "VD_APPLY_FAILED: DMG does not contain Second Display.app"
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_INFORMATION=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)
if print -r -- "$SIGNATURE_INFORMATION" | grep -q '^Signature=adhoc$'; then
    print "Ad-hoc signature confirmed"
elif [[ "${REQUIRE_ADHOC:-0}" == "1" ]]; then
    print -u2 "VD_APPLY_FAILED: ad-hoc signature is required"
    exit 1
else
    print "Developer identity signature detected"
fi
ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
if [[ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    print -u2 "VD_APPLY_FAILED: bundle identifier changed to $ACTUAL_BUNDLE_ID"
    exit 1
fi

if find "$APP_PATH" -type f \( -name '*.plist' -o -name '*.xpc' \) | grep -E 'LaunchAgents|LaunchDaemons|PrivilegedHelperTools' >/dev/null; then
    print -u2 "VD_APPLY_FAILED: unexpected persistent helper is embedded"
    exit 1
fi

if spctl --assess --type execute --verbose=2 "$APP_PATH"; then
    print "Gatekeeper assessment passed"
elif [[ "${REQUIRE_GATEKEEPER:-0}" == "1" ]]; then
    print -u2 "VD_APPLY_FAILED: Gatekeeper assessment failed"
    exit 1
else
    print "Gatekeeper assessment not passed (expected for ad-hoc/local builds)"
fi

if xcrun stapler validate "$DMG_PATH"; then
    print "Notarization staple validated"
elif [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
    print -u2 "VD_APPLY_FAILED: notarization staple is required"
    exit 1
else
    print "Notarization not present; set REQUIRE_NOTARIZATION=1 for release validation"
fi

print "Distribution structure, signature, bundle identity, and helper-residue checks passed"
