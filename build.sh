#!/bin/sh
set -eu
cd "$(dirname "$0")"
bundle=artifacts/Clearpath.app
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swift build --package-path native --scratch-path artifacts/native-build --product clearpath-service
bin="$(swift build --package-path native --scratch-path artifacts/native-build --show-bin-path)"
cp "$bin/clearpath-service" "$bundle/Contents/MacOS/"
"$bin/clearpath-service" browser-profile > "$bundle/Contents/Resources/Clearpath Browser Policies.mobileconfig"
swiftc -parse-as-library -module-cache-path artifacts/swift-module-cache app/*.swift -o "$bundle/Contents/MacOS/Clearpath"
cp clearpath/partner-copy.json app/AppIcon.icns "$bundle/Contents/Resources/"
cp app/Info.plist "$bundle/Contents/Info.plist"
case "${1:-}" in
  --build-only) ;;
  "") open "$bundle" ;;
  *) echo "Usage: ./build.sh [--build-only]" >&2; exit 2 ;;
esac
