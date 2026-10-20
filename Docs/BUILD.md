# Build and test

Clavune is the selected provisional name. The historical plan uses LocalFlow and OpenWispr. The existing private repository was renamed in place; the local project directory was intentionally left unchanged.

Developer prerequisites: Apple Silicon, Xcode/Command Line Tools with a macOS SDK supporting macOS 14, Python 3.12+ and CMake. No software is installed by these scripts. End users should not need these tools once a release is validated.

From the repository root:

    bash Scripts/build-backend.sh
    bash Scripts/swift.sh build --jobs 2
    bash Scripts/swift.sh test --jobs 2
    bash Scripts/build-app.sh

The backend fetch script independently reconstructs the locked source archive and applies only the ordered, SHA-256-locked downstream patches. It compares the entire source inventory, including executable bits, before trusting an existing tree; changed trees are preserved and refused. `python3 Scripts/fetch-backend.py --offline` uses an already verified cached archive. Patch provenance is written only after verification. It builds only the whisper target for arm64/macOS 14, static CPU/Accelerate and Metal support with embedded Metal sources, no Core ML, examples, server, curl or OpenMP. GGML_NATIVE is off.

The Swift wrapper retains SwiftPM sandboxing and keeps cache/security/configuration/output locations inside .build. If the host executor cannot initialize a nested sandbox, obtain normal build execution approval; do not disable the sandbox or security controls.

The app script stages artifacts/Clavune.app in an owned temporary container, signs it ad hoc with Hardened Runtime and only audio-input entitlement, checks the signature, and audits architecture, minimum OS and dynamic dependencies. Only after signing and audit does an exclusive rename expose the final name. Failures remove only that invocation’s staging container. Existing app artifacts are preserved. It does not launch the app, trigger permissions, notarize, create a signing identity, submit a release, or publish anything.

An ad-hoc development bundle is not a notarized release. Do not disable Gatekeeper or remove quarantine to make a public download appear supported.

Config/Product.json controls package product name, display/bundle identity and packaged storage identity. ProductIdentity.swift is the standalone development fallback. Target/module names are implementation details. Before another rename, keep historical private evidence unchanged and rerun tests and bundle checks.

Four project targets: ClavuneApp, ClavuneCore, NativeBridge and ClavuneCoreTests. whisper.cpp's internal CMake targets are dependency build details, not additional app products.

Synthetic tests use generated PCM and temporary files inside the project. They do not use the microphone, load a real model, mutate another app, or run a performance matrix. No synthetic timing is an ASR speed claim.

Additional deterministic checks:

    python3 -m unittest discover -s Tests/Python -v
    bash Scripts/test-state-ownership.sh

The native runner uses the installed production ownership helpers with counting fake resources and controlled allocation failures. It does not load a model or inject faults into actual GGML/Metal APIs. See Validation/native-ownership-review.md for the exact distinction. Clipboard tests use unique named pasteboards and never the general clipboard. Model tests use tiny synthetic hash fixtures.

The backend build generates a header containing an archive-and-lock fingerprint. The bridge embeds that fingerprint and references the patched upstream revision symbol, providing explicit linkage evidence. Config-only manifest and external archive-only relink probes did not reproduce stale results on Swift 6.4; no cache workaround is claimed.

Prepare a read-only review ZIP from a committed revision:

    python3 Scripts/prepare-review.py --commit HEAD

Both membership and bytes are read from that immutable commit tree, independent of the current index. Private/build/audio/model paths and personal absolute paths are refused.
