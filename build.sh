#!/bin/sh
set -eu
cd "$(dirname "$0")"
bundle=artifacts/Clearpath.app
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swiftc -parse-as-library -module-cache-path artifacts/swift-module-cache app/Clearpath.swift app/PartnerSettings.swift -o "$bundle/Contents/MacOS/Clearpath"
cp clearpath/partner-copy.json "$bundle/Contents/Resources/"
cp app/Info.plist "$bundle/Contents/Info.plist"
case "${1:-}" in
  --build-only) ;;
  "") open "$bundle" ;;
  *) echo "Usage: ./build.sh [--build-only]" >&2; exit 2 ;;
esac
