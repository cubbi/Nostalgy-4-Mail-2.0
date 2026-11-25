#!/bin/bash
# Builds Nostalgy-4-Mail and packs it as build/Nostalgy-4-Mail.zip for a GitHub release.
#
#   ./release.sh             build the zip only
#   ./release.sh --publish   also create the GitHub release v<version> with the zip attached
#                            (needs the GitHub CLI, signed in: gh auth login)
#
# The zip keeps the same name in every release, so the website can always link to
# https://github.com/<user>/<repo>/releases/latest/download/Nostalgy-4-Mail.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP=build/Nostalgy-4-Mail.app
ZIP=build/Nostalgy-4-Mail.zip

./build.sh
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "Packed $ZIP (version $VERSION)"
echo "SHA-256 $SHA"

if [[ "${1:-}" == "--publish" ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "Commit your changes first: the release is made from the pushed main branch." >&2
        exit 1
    fi
    gh release create "v$VERSION" "$ZIP" \
        --title "Nostalgy-4-Mail $VERSION" \
        --notes "Download **Nostalgy-4-Mail.zip** below, unzip it and move Nostalgy-4-Mail to Applications.

The app is not notarized by Apple, so macOS blocks it the first time: open it once, then go to System Settings › Privacy & Security and click **Open Anyway**.

SHA-256 of Nostalgy-4-Mail.zip: \`$SHA\`"
fi
