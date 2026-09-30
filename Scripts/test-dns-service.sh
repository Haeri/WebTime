#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# CLT-only Macs do not ship XCTest. Compile the actual daemon components into a
# standalone regression runner, using the same SDK selection as the normal build.
# Build WebTimeCore directly rather than relying on SwiftPM's internal output layout,
# which differs between toolchain versions.
OUT_DIR="$PROJECT_DIR/.build/dns-service-tests"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
./Scripts/swift.sh --compiler -parse-as-library -swift-version 6 \
    -module-name WebTimeCore -emit-module -emit-module-path "$OUT_DIR/WebTimeCore.swiftmodule" \
    -emit-library -static -o "$OUT_DIR/libWebTimeCore.a" \
    Sources/WebTimeCore/*.swift
./Scripts/swift.sh --compiler -parse-as-library -swift-version 6 \
    -I "$OUT_DIR" -L "$OUT_DIR" -lWebTimeCore \
    Sources/WebTimeDaemon/DNSService.swift \
    Sources/WebTimeDaemon/DNSTransport.swift \
    Sources/WebTimeDaemon/NetworkDNS.swift \
    Tests/WebTimeDaemonTests/DNSServiceTests.swift \
    -o "$OUT_DIR/WebTimeDNSServiceTests"
"$OUT_DIR/WebTimeDNSServiceTests"
