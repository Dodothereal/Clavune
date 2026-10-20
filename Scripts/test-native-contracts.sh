#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="normal"
flags=(-std=c++17 -O0 -g -Wall -Wextra -Werror -UNDEBUG)
if [[ "${1:-}" == "--sanitize" && "$#" == 1 ]]; then
  mode="sanitized"
  flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
elif [[ "$#" != 0 ]]; then
  echo "Usage: bash Scripts/test-native-contracts.sh [--sanitize]" >&2
  exit 2
fi
python3 Scripts/prepare-native-contract-inputs.py
output=".build/native-contracts"
includes=(-I "$output/generated" -I Sources/NativeBridge/include
          -I .build/deps/whisper.cpp/include -I .build/deps/whisper.cpp/src
          -I .build/deps/whisper.cpp/ggml/include)
c++ "${flags[@]}" "${includes[@]}" Tests/Native/ProductionBatchTests.cpp \
  -o "$output/production-batch-$mode"
c++ "${flags[@]}" "${includes[@]}" Sources/NativeBridge/WhisperBridge.cpp \
  Tests/Native/BridgeContractTests.cpp -o "$output/bridge-contract-$mode"
python3 Scripts/prepare-native-contract-inputs.py --verify-only
"$output/production-batch-$mode"
"$output/bridge-contract-$mode"
