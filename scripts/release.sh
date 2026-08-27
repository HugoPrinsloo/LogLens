#!/bin/zsh
# Builds a Developer ID-signed, notarized, stapled LogLens release (zip + dmg) and publishes it on GitHub.
#
# Usage: scripts/release.sh <version>              e.g. scripts/release.sh 1.2.0
#        scripts/release.sh <version> --no-publish  build and notarize only
#
# Signing uses Xcode's cloud-managed Developer ID certificate for team 7VT5H6VPXH
# (-allowProvisioningUpdates), so nothing has to be installed in the local keychain.
# Notarization credentials are read from the keychain profile below. Create them once with:
#   xcrun notarytool store-credentials "LogLens-Notary" --apple-id <you@example.com> --team-id 7VT5H6VPXH
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--no-publish]}"
PUBLISH="${2:-}"
PROJECT="LogLens.xcodeproj"
SCHEME="LogLens"
APP_NAME="LogLens.app"
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
ARCHIVE="build/LogLens.xcarchive"
EXPORT_DIR="build/export"
DIST_DIR="dist"
APP="$EXPORT_DIR/$APP_NAME"
DMG="$DIST_DIR/LogLens-$VERSION.dmg"
ZIP="$DIST_DIR/LogLens-$VERSION.zip"

step() { echo "\n▸ $*"; }

command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }

# Use the first notarization profile that exists (shared personal-team credentials).
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [[ -z "$NOTARY_PROFILE" ]]; then
  for candidate in LogLens-Notary NetworkBlocker-Notary; do
    if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then NOTARY_PROFILE="$candidate"; break; fi
  done
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
  cat >&2 <<MSG
No notarization credentials found in the keychain. Create them once (needs an app-specific
password from https://account.apple.com):
  xcrun notarytool store-credentials "LogLens-Notary" --apple-id <your Apple ID email> --team-id 7VT5H6VPXH
MSG
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree has uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

step "Setting version $VERSION in project.yml"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
xcodegen generate --quiet

step "Archiving $VERSION (build $BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p build "$DIST_DIR"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates archive > build/archive.log 2>&1 \
  || { grep -E "error:" build/archive.log | sort -u; echo "Archive failed - see build/archive.log" >&2; exit 1; }

step "Exporting with Developer ID signing"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates > build/export.log 2>&1 \
  || { grep -E "error" build/export.log | sort -u; echo "Export failed - see build/export.log" >&2; exit 1; }
codesign -dvv "$APP" 2>&1 | grep -q "^Authority=Developer ID Application" \
  || { echo "Exported app is not Developer ID signed" >&2; exit 1; }

step "Notarizing the app (profile: $NOTARY_PROFILE)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the zip contains the stapled app

step "Creating disk image"
rm -f "$DMG"
STAGING="build/dmg"
rm -rf "$STAGING"; mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "LogLens" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

step "Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

step "Verifying"
spctl -a -vv "$APP" 2>&1 | tail -2
xcrun stapler validate "$DMG" | tail -1
(cd "$DIST_DIR" && shasum -a 256 "LogLens-$VERSION.dmg" "LogLens-$VERSION.zip" | tee "LogLens-$VERSION.sha256")

if [[ "$PUBLISH" == "--no-publish" ]]; then
  echo "\n✓ Release $VERSION built (not published):\n   $DMG\n   $ZIP"
  exit 0
fi

step "Committing version bump and publishing GitHub release v$VERSION"
git add project.yml LogLens.xcodeproj
git commit -qm "Release v$VERSION" || true
git push -q
gh release create "v$VERSION" "$DMG" "$ZIP" "$DIST_DIR/LogLens-$VERSION.sha256" \
  --title "LogLens $VERSION" --generate-notes

echo "\n✓ https://github.com/HugoPrinsloo/LogLens/releases/tag/v$VERSION"
