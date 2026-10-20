#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/native-tests
c++ -std=c++17 -O0 -g -Wall -Wextra -Werror \
  -I .build/deps/whisper.cpp/src Tests/Native/StateExceptionOwnershipTests.cpp \
  -o .build/native-tests/state-exception-ownership
.build/native-tests/state-exception-ownership
