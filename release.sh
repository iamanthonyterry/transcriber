#!/bin/bash
# Builds, notarizes and packages a release. Usage: ./release.sh 2.0.1 [--publish]
#   without --publish: stops after producing build/Transcriber-<version>.zip + build/appcast.xml
#   with --publish:    also commits the version, tags v<version>, and creates the GitHub release
# One-time: `xcrun notarytool store-credentials AC_PASSWORD ...` (same profile Canopy uses) and the Sparkle
# signing key in your login keychain (same key as Canopy; its public half is in Support/Info.plist).
set -euo pipefail
cd "$(dirname "$0")"

[ $# -ge 1 ] || { echo "Usage: ./release.sh <version, e.g. 2.0.1> [--publish]"; exit 1; }
VERSION="$1"
PUBLISH="${2:-}"
REPO="iamanthonyterry/transcriber"
ZIP="build/Transcriber-$VERSION.zip"

echo "$VERSION" > VERSION
./build_app.sh "$VERSION"

echo "==> Notarizing"
ditto -c -k --keepParent build/Transcriber.app build/notarize.zip
xcrun notarytool submit build/notarize.zip --keychain-profile AC_PASSWORD --wait
rm -f build/notarize.zip
xcrun stapler staple build/Transcriber.app

echo "==> Packaging"
rm -f build/Transcriber-*.zip build/appcast.xml
ditto -c -k --keepParent build/Transcriber.app "$ZIP"
spctl --assess --type execute -v build/Transcriber.app
# Sparkle appcast, signed with the EdDSA key in the keychain, pointing at this release's download.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" build

echo "Built $ZIP and build/appcast.xml"
if [ "$PUBLISH" = "--publish" ]; then
  git add -A && git commit -m "Release $VERSION" || true
  git tag "v$VERSION"
  git push origin HEAD "v$VERSION"
  gh release create "v$VERSION" "$ZIP" build/appcast.xml --repo "$REPO" --title "$VERSION" --generate-notes
  echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "Not published. Re-run with --publish to tag and create the GitHub release."
fi
