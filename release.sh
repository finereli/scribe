#!/bin/bash
# Build a notarized Scribe and package it as a zip and a dmg for a GitHub
# release. Usage: ./release.sh   (version comes from Resources/Info.plist)
set -euo pipefail
cd "$(dirname "$0")"

DEVELOPER_ID="Developer ID Application: ELI FINER (A59G53TN44)"
NOTARY_PROFILE="YOULEARN_NOTARY"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="Scribe-$VERSION.zip"
DMG="Scribe-$VERSION.dmg"

NOTARIZE=1 ./build.sh

rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent Scribe.app "$ZIP"

# A dmg with the app and an Applications shortcut to drag it onto.
STAGE="$(mktemp -d)/Scribe"
mkdir -p "$STAGE"
cp -R Scribe.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Scribe" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"

codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "Ready: $ZIP $DMG"
