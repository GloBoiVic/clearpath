#!/bin/sh
# Build the VM helpers into artifacts/vm-tools/. The guest helpers must target
# macOS 15 or the macOS 26 guest won't run them (the same cause as #33).
# VM_ARCH only changes the target so the tests can run the helpers on this Mac.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out="$root/artifacts/vm-tools"
arch="${VM_ARCH:-arm64}"
mkdir -p "$out" "$root/artifacts/swift-module-cache"
for tool in vm-click vm-key vm-windowid vm-typepw vm-ocr; do
  swiftc -O -target "$arch-apple-macos15.0" -module-cache-path "$root/artifacts/swift-module-cache" \
    "$here/$tool.swift" -o "$out/$tool"
done
echo "Built $out"
