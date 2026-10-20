# Clavune

Native offline macOS dictation, currently a private development checkpoint. Clavune is the user's selected provisional name; public naming and trademark clearance remain pending. The project was previously called OpenWispr, and the private source plan uses LocalFlow.

## What exists

- SwiftUI/AppKit menu-bar shell with a separate nonactivating recording/review panel.
- Explicit recording/cancel controls, native-rate bounded ingress and continuous 16-kHz mono conversion.
- Pinned embedded whisper.cpp v1.9.5 with static CPU/Accelerate and Metal support.
- Deliberate hash-checked local model import; four candidates, no promoted default.
- In-memory batch transcription, unmodified raw result, editable preview and deliberate copy.
- Optional development Carbon chord, Ctrl–Option–Space, with hold/toggle handling.
- Isolated insertion policy foundations. External insertion and automatic paste are not enabled.

Build and tests: [Docs/BUILD.md](Docs/BUILD.md). Current evidence and outstanding work: [STATUS.md](STATUS.md).

## Current limits

The app compiles and a local ad-hoc signed development bundle passes architecture/dependency checks. Sixteen deterministic tests pass. No microphone session, real-model transcription, quality benchmark, real target insertion, macOS 14 runtime test or clean-Mac installation has been performed. This is not a notarized public release.

The development session limit is 120 seconds. An unconfirmed endpoint, stop-queue race, overflow, device gap or limit produces an error. Model selection is session-only for now. Hotkey configuration and real-device robustness are still incomplete.

No account, mandatory cloud inference, subscription, telemetry or automatic content history. No private plan, personal recording, machine inventory, model weights or build cache is committed.

See [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [Docs/RELEASE_CHECKLIST.md](Docs/RELEASE_CHECKLIST.md). The source uses a proposed MIT license pending final public-release review.
