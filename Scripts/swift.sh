#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p .build/ModuleCache .build/swift-cache .build/swift-config .build/swift-security
swift "$@" --cache-path "$PWD/.build/swift-cache" \
  --config-path "$PWD/.build/swift-config" --security-path "$PWD/.build/swift-security" \
  --scratch-path "$PWD/.build/swift"
