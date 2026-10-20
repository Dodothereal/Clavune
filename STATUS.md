# Clavune status

2026-10-20 — corrected source/build checkpoint, awaiting exact-commit cross-verification. Efficiency work remains deferred.

## Verified implementation

- Actual Apple Silicon executor, home and empty target were verified before creation. Product name is Clavune; the authorized original local folder remains OpenWispr. Swift 6.4, selected Xcode, raw OS report macOS 27.2 (26B5112a). Minimum deployment target is macOS 14; no macOS 14 runtime test. Actual session model/reasoning settings are not exposed; requested gpt-6.1-sol / ultra cannot be independently confirmed.
- Authoritative Library introduction, consolidation, master milestones and technical excerpts through line 3520 were read into ignored planning caches. Historical appendices were not executed. The source ZIP was not materialized after its supported helper became unavailable; caches are excerpts, not a byte-exact full download.
- Four targets: native SwiftUI/AppKit shell, core, minimal C++ bridge, core tests. Embedded static whisper.cpp v1.9.5 is archive/hash pinned, with three separately hashed correctness patches. One CPU/Accelerate/Metal backend, no mandatory cloud/account/subscription/telemetry or end-user Homebrew.
- Bounded native-rate ingress, tested 16-kHz mono conversion, explicit immutable stop cutoff, per-session startup/cancel gates, independent capture-close state, and in-memory batch decoding. No preview streaming. One active decoder, selected model per session, native 120-second guard retained.
- Deliberate verified model import with bounded corrupt-file recovery, preview/edit/raw/copy, current-host native copy policy, optional validated provisional shortcuts. Ctrl–Option–Space is rejected for VoiceOver. No external insertion adapter is enabled; insertion policy remains isolated-fixture-only.
- User confirmed GitHub ownership. Same repository was renamed in place after name selection: https://github.com/Dodothereal/Clavune, PRIVATE verified again before the corrected push. The final commit is reported in the thread/review metadata. No public release or second repository.
- Proposed MIT source license, third-party notices, model hash manifest, privacy/security/build docs, manual-only CI and release checklist are present. Naming, model conversion provenance and public release clearance remain open.

## Correctness validation

- 48 XCTest cases, zero failures: synthetic PCM/cutoff, startup/cancel ordering, state, ingress chunk/timestamp/capacity, meter, named pasteboard, tiny model recovery, shortcuts and insertion-policy fixtures. Exact sanitized output: Validation/synthetic-tests.txt.
- 23 offline Python tests, zero failures: fetch provenance, immutable review snapshot, packaged-only resources and failure-safe app packaging.
- Native ownership helper matrix passed both normally and with AddressSanitizer/UndefinedBehaviorSanitizer. Controlled fake native resources and real selected C++ allocation failures exercise production helpers. Actual GGML/Metal/model failure injection remains unexercised; see Validation/native-ownership-review.md.
- Two-job backend and optimized app builds passed. Final bundle is staged, ad-hoc signed with Hardened Runtime/audio-input entitlement, verified and exclusively published under artifacts/Clavune.app. Earlier bundles and dependency trees are preserved under ignored project output.
- Independent reconstruction verifies the patched source inventory after CMake configuration/build. Archive-and-lock fingerprint and patched revision are checked against the final link. Build metadata and artifact sizes/hashes: Validation/checkpoint.json.
- Packaged resources pass without a development lookup. The reported resource-path bug was disproved by this Swift 6.4 accessor. Config-only manifest and archive-only relink staleness were not reproduced; Swift wrapper cache behavior remains unchanged.
- Finding-by-finding disposition, including confirmed fixes, conditional limits and untested integrations: Validation/correctness-issue-ledger.md. Read-only review ZIP is generated from immutable committed files only.

## Unmeasured and remaining

No app launch, real microphone/TCC prompt, user audio, real model load/inference, target-app mutation, substantial benchmark, signed/notarized release or clean-Mac installation ran. Other workloads were not stopped. Initial load averages were about 8. Recognition quality, capture hardware endpoint, latency, CPU, peak/RSS memory and energy are unmeasured; bundle size is not RAM.

Next: independent cross-verification of the corrected commit, then a separate efficiency review. Hardware/permission/route/VoiceOver/Sleep-Wake integration, chosen-model persistence, full shortcut recorder, effective parameter export, real AX fixtures, German/English/code-switching/numbers/negations quality gates and controlled performance runs remain open. Do not promote a default model or quantization before quality gates.

## Retained boundaries and prior denials

Auto-review rejected persisting --disable-sandbox and separately rejected removing the native 120-second guard. Neither proposal executed or was retried/bypassed. SwiftPM sandbox remains enabled; normal execution approval was used for nested-sandbox builds. Sandbox-denied hardware sysctl reads were not retried; no inferred hardware quantities. No current permission prompt is pending for this source checkpoint. Signing identities, paid enrollment, credentials, security-setting changes, notarization and public publication remain outside this authorization.
