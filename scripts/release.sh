#!/bin/bash
# Builds, signs, notarizes and publishes a LogLens release.
#
#   scripts/release.sh 1.2.0
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode > Settings > Accounts > Manage Certificates, or developer.apple.com).
#   2. Notarization credentials stored in the keychain:
#      xcrun notarytool store-credentials LogLens --apple-id you@example.com --team-id 7VT5H6VPXH
#      (use an app-specific password from appleid.apple.com)
#   3. gh CLI logged in with push access to the repo.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>   e.g. 1.2.0}"
PROFILE="${NOTARY_PROFILE:-LogLens}"
cd "$(dirname "$0")/.."

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No 'Developer ID Application' certificate found in your keychain." >&2
  echo "Create one in Xcode > Settings > Accounts > Manage Certificates, then run this again." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree has uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

DIST=dist
rm -rf "$DIST"; mkdir -p "$DIST"
BUILD_NUMBER="$(git rev-list --count HEAD)"

echo "==> Bumping version to $VERSION (build $BUILD_NUMBER)"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml
xcodegen generate

echo "==> Archiving"
xcodebuild -project LogLens.xcodeproj -scheme LogLens -configuration Release \
  -archivePath "$DIST/LogLens.xcarchive" archive -quiet

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$DIST/LogLens.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$DIST/export" -quiet
APP="$DIST/export/LogLens.app"

ZIP="$DIST/LogLens-$VERSION.zip"
echo "==> Notarizing (this usually takes a few minutes)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"      # re-zip with the ticket stapled
spctl -a -vv "$APP"
(cd "$DIST" && shasum -a 256 "LogLens-$VERSION.zip" > "LogLens-$VERSION.zip.sha256")

echo "==> Committing version bump and publishing GitHub release"
git add project.yml LogLens.xcodeproj
git commit -m "Release v$VERSION" -q
git push
gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" --title "LogLens $VERSION" --generate-notes

echo
echo "Done: https://github.com/HugoPrinsloo/LogLens/releases/tag/v$VERSION"
