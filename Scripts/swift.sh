#!/bin/bash
set -euo pipefail

# Some macOS point updates pair Command Line Tools with Swift interfaces from a different SDK.
# Pin the known-compatible SDK only for that CLT-only configuration.
if [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
fi
export CLANG_MODULE_CACHE_PATH="/private/tmp/web-time-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/web-time-swiftpm-cache"
exec swift "$@"
