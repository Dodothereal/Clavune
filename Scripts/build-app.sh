#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/build-backend.sh
bash Scripts/swift.sh build --configuration release --jobs 2
product_bin="$(bash Scripts/swift.sh build --configuration release --show-bin-path)"
python3 Scripts/package-app.py --bin-dir "$product_bin"
