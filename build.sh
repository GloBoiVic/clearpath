#!/bin/sh
set -eu
cd "$(dirname "$0")"
bundle=artifacts/Clearpath.app
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swift build --package-path native --scratch-path artifacts/native-build --product clearpath-service
swift build --package-path native --scratch-path artifacts/native-build --product clearpath-filter
bin="$(swift build --package-path native --scratch-path artifacts/native-build --show-bin-path)"
cp "$bin/clearpath-service" "$bin/clearpath-filter" "$bundle/Contents/MacOS/"
"$bin/clearpath-service" browser-profile > "$bundle/Contents/Resources/Clearpath Browser Policies.mobileconfig"
swiftc -target "$(uname -m)-apple-macos15.0" -parse-as-library -module-cache-path artifacts/swift-module-cache app/*.swift -o "$bundle/Contents/MacOS/Clearpath"
cp clearpath/partner-copy.json app/AppIcon.icns app/default-policy.json "$bundle/Contents/Resources/"
cp app/Info.plist "$bundle/Contents/Info.plist"
for tool in clearpath-service clearpath-filter; do
  codesign --force --sign - "$bundle/Contents/MacOS/$tool"
done
codesign --force --sign - "$bundle"
codesign --verify --strict --deep "$bundle"
case "${1:-}" in
  --build-only) ;;
  "") open "$bundle" ;;
  *) echo "Usage: ./build.sh [--build-only]" >&2; exit 2 ;;
esac
