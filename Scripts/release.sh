#!/bin/sh
# Builds, signs, notarizes and publishes a SwiftSoql release, with the Sparkle appcast that
# tells existing copies about it.
#
#   Scripts/release.sh 1.1 2 notes.md # marketing version, build number (must go up each release),
#                                     # and release notes
#
# Every release says what changed. The notes file is Markdown in the form of earlier releases:
# "## What's new in SwiftSoql <version>", a bullet for each change with a bold lead-in, and a
# "### Fixes" section for fixes. It becomes the GitHub release's notes, above GitHub's changelog
# link, and is embedded in the appcast, so the app's update window shows it too.
#
# Needs, once per Mac:
#   - The "Developer ID Application" certificate for team 77X7425ATW in the login Keychain.
#   - Notarization credentials saved as the "SwiftSoql" profile:
#       xcrun notarytool store-credentials SwiftSoql --apple-id <you@example.com> --team-id 77X7425ATW
#   - Sparkle's EdDSA private key in the login Keychain (its public key is SUPublicEDKey in
#     SwiftSoql-Info.plist). Back it up with: <Sparkle bin>/generate_keys -x sparkle-private-key
#   - The GitHub CLI, logged in (gh auth login).
#
# SKIP_NOTARIZE=1 and SKIP_PUBLISH=1 stop before those steps, for trying the build.
#
# Before running it, push main: the release's tag is made from GitHub's main, not the local one.
#
# After every release, update the website: swiftsoql/index.html in the jimmitchell.dev repo
# describes what the app does, and its screenshots show it. Bring them in line with the release,
# then commit, push and deploy with `npx wrangler deploy` (that repo's README says how to check
# the deploy). Its download link goes to /releases/latest, so it never needs a version number.
set -eu

usage="usage: Scripts/release.sh <version> <build> <release-notes.md>"
version="${1:?$usage}"
build="${2:?$usage}"
notes="${3:?$usage}"
[ -s "$notes" ] || { echo "No release notes in $notes" >&2; exit 1; }
notes="$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/release-$version"
packages="$root/build/SourcePackages"
sparkle_bin="$packages/artifacts/sparkle/Sparkle/bin"
repo="jimmitchell/SwiftSoql"
zip="SwiftSoql-$version.zip"

rm -rf "$out"
mkdir -p "$out/updates"

echo "== Archiving $version ($build)"
xcodebuild archive -project "$root/SwiftSoql.xcodeproj" -scheme SwiftSoql -configuration Release \
    -archivePath "$out/SwiftSoql.xcarchive" -clonedSourcePackagesDirPath "$packages" \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" -quiet

echo "== Exporting with Developer ID"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>77X7425ATW</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/SwiftSoql.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -quiet
app="$out/export/SwiftSoql.app"
codesign --verify --deep --strict "$app"

if [ "${SKIP_NOTARIZE:-0}" != 1 ]; then
    echo "== Notarizing"
    ditto -c -k --keepParent "$app" "$out/notarize.zip"
    xcrun notarytool submit "$out/notarize.zip" --keychain-profile SwiftSoql --wait
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose "$app"
fi

echo "== Packaging"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/updates/$zip"
# A notes file named after the zip is the update's release notes.
cp "$notes" "$out/updates/${zip%.zip}.md"
"$sparkle_bin/generate_appcast" --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
    --embed-release-notes -o "$out/updates/appcast.xml" "$out/updates"

if [ "${SKIP_PUBLISH:-0}" != 1 ]; then
    echo "== Publishing v$version"
    gh release create "v$version" "$out/updates/$zip" "$out/updates/appcast.xml" --repo "$repo" \
        --title "SwiftSoql $version" --notes-file "$notes" --generate-notes
fi
echo "== Done: $out/updates"
echo "== Now update the SwiftSoql page on jimmitchell.dev for $version and deploy it (see the top of this script)"
