#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/clavune-ingress-close.XXXXXX")"
trap 'rm -rf "$work"' EXIT
"${CXX:-c++}" -std=c++17 -O1 -Wall -Wextra -Werror \
  -I "$root/Sources/NativeBridge/include" \
  "$root/Sources/NativeBridge/Ingress.cpp" \
  "$root/Tests/Native/IngressCloseContractTests.cpp" -o "$work/ingress-close"
"$work/ingress-close"
