#!/bin/bash
set -euo pipefail

# Some macOS beta/point updates briefly leave Command Line Tools with a newer Swift compiler
# than the default SDK's Swift interfaces. The older installed SDK remains compatible with our
# macOS 13 deployment target, so select it only for that CLT-only configuration.
if [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
fi
export CLANG_MODULE_CACHE_PATH="/private/tmp/web-time-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/web-time-swiftpm-cache"
exec swift "$@"
