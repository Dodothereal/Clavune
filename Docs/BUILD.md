# Build and test

Clavune is the selected provisional name. The historical plan uses LocalFlow and OpenWispr. The existing private repository was renamed in place; the local project directory was intentionally left unchanged.

Developer prerequisites: Apple Silicon, Xcode/Command Line Tools with a macOS SDK supporting macOS 14, Python 3.12+ and CMake. No software is installed by these scripts. End users should not need these tools once a release is validated.

From the repository root:

    bash Scripts/build-backend.sh
    bash Scripts/swift.sh build --jobs 2
    bash Scripts/swift.sh test --jobs 2
    bash Scripts/build-app.sh

The backend fetch script verifies the locked source archive before extraction. It builds only the whisper target for arm64/macOS 14, static CPU/Accelerate and Metal support with embedded Metal sources, no Core ML, examples, server, curl or OpenMP. GGML_NATIVE is off.

The Swift wrapper retains SwiftPM sandboxing and keeps cache/security/configuration/output locations inside .build. If the host executor cannot initialize a nested sandbox, obtain normal build execution approval; do not disable the sandbox or security controls.

The app script produces artifacts/Clavune.app, signs it ad hoc with Hardened Runtime and only audio-input entitlement, checks the signature, and audits architecture, minimum OS and dynamic dependencies. It preserves any existing app artifact rather than overwriting it. It does not launch the app, trigger permissions, notarize, create a signing identity, submit a release, or publish anything.

An ad-hoc development bundle is not a notarized release. Do not disable Gatekeeper or remove quarantine to make a public download appear supported.

Config/Product.json controls package product name, display/bundle identity and packaged storage identity. ProductIdentity.swift is the standalone development fallback. Target/module names are implementation details. Before another rename, keep historical private evidence unchanged and rerun tests and bundle checks.

Four project targets: ClavuneApp, ClavuneCore, NativeBridge and ClavuneCoreTests. whisper.cpp's internal CMake targets are dependency build details, not additional app products.

Synthetic tests use generated PCM and temporary files inside the project. They do not use the microphone, load a real model, mutate another app, or run a performance matrix. No synthetic timing is an ASR speed claim.
