"""Bind rebuilt static archives to a tracked NativeBridge compiler input.

Only the generated header changes when the archive/provenance digest changes.
The bridge includes it, so normal dependency tracking recompiles and relinks the
affected native target without deleting unrelated caches.
"""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
build = root / ".build/backend"
libraries = [
    "src/libwhisper.a",
    "ggml/src/libggml.a",
    "ggml/src/libggml-base.a",
    "ggml/src/libggml-cpu.a",
    "ggml/src/ggml-blas/libggml-blas.a",
    "ggml/src/ggml-metal/libggml-metal.a",
]
hasher = hashlib.sha256()
records = {}
for relative in libraries:
    file = build / relative
    digest = hashlib.sha256()
    with file.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    records[relative] = digest.hexdigest()
    hasher.update((relative + "\0" + records[relative] + "\n").encode())
lock_data = (root / "Dependencies.lock.json").read_bytes()
hasher.update(lock_data)
provenance_digest = hashlib.sha256(lock_data).hexdigest()
fingerprint = hasher.hexdigest()
header = build / "ClavuneBackendFingerprint.h"
content = (
    "// Generated from the exact linked archives and dependency lock; do not edit.\n"
    "#ifndef CLAVUNE_BACKEND_FINGERPRINT_H\n#define CLAVUNE_BACKEND_FINGERPRINT_H\n"
    '#define CLAVUNE_BACKEND_FINGERPRINT "' + fingerprint + '"\n'
    "#endif\n"
)
if not header.exists() or header.read_text() != content:
    header.write_text(content)
(build / "clavune-backend-fingerprint.json").write_text(json.dumps({
    "schemaVersion": 1, "fingerprint": fingerprint,
    "dependencyLockSHA256": provenance_digest, "archiveSHA256": records
}, indent=2) + "\n")
print("Backend link fingerprint:", fingerprint)
