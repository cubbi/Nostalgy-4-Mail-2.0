#!/bin/bash
# Builds build/Nostalgy-4-Mail.app. Needs only the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Nostalgy-4-Mail.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# A universal app (Apple silicon and Intel) that runs on macOS 12 and later.
# Keep MIN_MACOS in step with LSMinimumSystemVersion in Info.plist.
MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)
OBJ=build/obj
mkdir -p "$OBJ"
for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos$MIN_MACOS" -o "$OBJ/Nostalgy-4-Mail-$ARCH" \
        Sources/*.swift -framework Cocoa -framework Carbon
done
lipo -create -output "$APP/Contents/MacOS/Nostalgy-4-Mail" "$OBJ"/Nostalgy-4-Mail-arm64 "$OBJ"/Nostalgy-4-Mail-x86_64
cp Info.plist "$APP/Contents/Info.plist"
iconutil --convert icns --output "$APP/Contents/Resources/Nostalgy-4-Mail.icns" Resources/Nostalgy-4-Mail.iconset
codesign --force --sign - "$APP"

echo "Built $APP — move it to /Applications and open it."
