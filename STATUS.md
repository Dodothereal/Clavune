# Clavune status

2026-10-20 — first source/build review checkpoint. This same local thread will continue after parent review.

## Completed

- Verified the actual local executor, home and target. The project directory was empty; no existing work was overwritten. The authorized directory remains unchanged after renaming the product.
- Apple Silicon arm64; raw OS output macOS 27.2 (26B5112a); selected Xcode; Swift 6.4. Actual session model/reasoning are not exposed. Parent reports requesting gpt-6.1-sol / ultra; no independent confirmation claimed.
- Read Library introduction, binding consolidation and master milestones first. Retrieved technical/efficiency content through line 3520 into private read caches. Historical appendix snippets were not executed.
- Pinned whisper.cpp v1.9.5 commit d1be6fde11ac6e0407606b4e42fe72d34add8037 and verified the source archive hash. Built static arm64 backend with embedded Metal sources and two jobs.
- Implemented four targets: app, core, native bridge and tests. Native-rate bounded SPSC ingress, continuous tested 16-kHz conversion, monotonic cutoff, closed capture before batch inference, independent session cancellation and decoder state, deliberate verified model import, review/edit/raw/copy shell.
- Optional fixed Carbon development chord is off by default. External insertion is not enabled; its policy is tested with isolated metadata fixtures.
- User confirmed GitHub ownership. Created the private repository, then renamed that same repository in place after the user selected Clavune and an exact destination check found no conflict. Verified https://github.com/Dodothereal/Clavune remains PRIVATE. No second repository or public release created.
- Centralized product identity in Config/Product.json and the standalone ProductIdentity fallback. Historical private plan evidence remains unchanged. Naming selection is provisional, not legal clearance.
- Added build scripts, privacy/security documentation, proposed MIT license, third-party licenses, resource policy/model hashes, manual-only CI and release checklist.
- Initial 10 synthetic tests passed; after naming and insertion-policy fixtures, 15 passed. Focused read-only reviews found endpoint/cancel/import issues, fixed before this checkpoint. Expanded suite reports 16 tests and 0 failures. Exact sanitized output is in Validation/synthetic-tests.txt.
- Optimized ad-hoc development app packages successfully. Bundle audit verifies arm64, macOS 14 minimum load command and system-only dynamic dependencies. This does not prove macOS 14 runtime compatibility. Artifact: artifacts/Clavune.app. The previous development bundle is preserved separately under artifacts.

## Validation and review

Commands and results: Validation/checkpoint.json. Read-only review findings/fixes and open coverage: Validation/review-notes.md. Raw local command logs remain private in .planning. A read-only source ZIP is produced from the exact committed files by Scripts/prepare-review.py.

No app launch, microphone access, audio recording, real-model loading/inference, target-app mutation or substantial performance benchmark has run. No other workloads were stopped. Observed initial load averages were about 8; RAM, CPU during inference, energy, real recognition quality and latency remain unmeasured. Bundle byte size is not process RAM.

## Retained safety limits and approval outcomes

- Native decode guard: Sources/NativeBridge/WhisperBridge.cpp rejects more than 16000 * 120 samples. Resource policy and policy validation also cap the development session at 120 seconds. This is a provisional product bound, not a speed guarantee. At limit/loss/uncertain endpoint, capture fails visibly instead of returning a falsely complete transcript.
- Auto-review rejected adding --disable-sandbox to the Swift wrapper. The patch did not execute. SwiftPM sandbox remains enabled; ordinary sandboxed builds succeeded with normal tool execution approval and project-local caches.
- Auto-review separately rejected removing the native 120-second guard. The proposal arose while attempting to make the resource manifest the single numerical source; removal would weaken independent native admission. It did not execute. Both limits remain. No retry or workaround of either rejected change was used.
- Hardware model/memory/CPU sysctl reads were denied by the execution sandbox. No retries or inferred quantities.
- No pending user approval is required for this source checkpoint. Account ownership is resolved. Signing identities, paid enrollment, security-setting changes, notarization and publication are not authorized here.

## Remaining work

1. Parent/cloud code review of this exact checkpoint; fix findings and improve deterministic concurrent/cancellation fixtures.
2. Deliberate model selection/import and first real microphone/batch session when user and machine load permit. Validate endpoint and route behavior, especially Bluetooth. The conservative queued-stop race currently reports an endpoint error rather than trying to repair already-converted data.
3. Restore chosen installed model across launches, provide a proper hotkey recorder, show verified actual input identity, test Sleep/Wake/device/permission/error behavior and model cancellation.
4. Add validated AX adapters and isolated real-selection fixtures before enabling external insertion. Clipboard transfer remains deferred; explicit copying already works in code.
5. Freeze personal quality references for German/English/code-switching/terms/numbers/negations. No standard model or quantization winner is selected. Full effective decoder parameter export remains open.
6. Only then consider measured preview optimization, performance/resource profiles, DMG, Developer-ID/notarization authorization and clean supported Mac installation.

## Access limits

Library direct reads succeeded. The cloud skill/download helper became unavailable mid-turn, so the source ZIP was not materialized and read caches are excerpts, not a byte-exact Library download. Conventional targeted model-directory checks did not find a model; no broad scan of personal data was performed. These limits do not block code review but real inference still needs a deliberate verified model import.
