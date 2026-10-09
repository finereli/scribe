#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# SIGN=1     → sign with Developer ID (hardened runtime + timestamp).
# NOTARIZE=1 → sign + submit to Apple notary + staple. Implies SIGN=1.
# Default is an unsigned ad-hoc build (fast local iteration).
NOTARIZE="${NOTARIZE:-0}"
SIGN="${SIGN:-0}"
if [ "$NOTARIZE" = "1" ]; then SIGN=1; fi
DEVELOPER_ID="Developer ID Application: ELI FINER (A59G53TN44)"
NOTARY_PROFILE="YOULEARN_NOTARY"
APP="Scribe.app"

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Scribe" "$APP/Contents/MacOS/Scribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/claude.pdf Resources/chatgpt.pdf "$APP/Contents/Resources/"

if [ "$SIGN" = "1" ]; then
    echo "Signing with Developer ID (hardened runtime + timestamp)…"
    codesign --force --options runtime --timestamp \
        --entitlements Resources/Scribe.entitlements \
        --sign "$DEVELOPER_ID" "$APP/Contents/MacOS/Scribe"
    codesign --force --options runtime --timestamp \
        --entitlements Resources/Scribe.entitlements \
        --sign "$DEVELOPER_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
fi

if [ "$NOTARIZE" = "1" ]; then
    SUBMIT_ZIP="$(mktemp -d)/Scribe-submit.zip"
    ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
    echo "Submitting to Apple notary service (this can take a few minutes)…"
    xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "Stapling notarization ticket…"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$SUBMIT_ZIP"
fi

if [ "$SIGN" != "1" ]; then
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
echo "Run: open $APP"
