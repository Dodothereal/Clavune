# OpenWispr

Native macOS dictation application in development. Working name; naming and trademark clearance are pending before public release.

## Current state

M0 inventory and architecture preparation. No application has been implemented, launched, or performance tested yet. See [STATUS.md](STATUS.md).

## Intended product

- SwiftUI/AppKit menu-bar application for Apple Silicon, targeting macOS 14 or later.
- One embedded, pinned whisper.cpp backend; offline dictation after deliberate local model import or verified installation.
- Explicit recording state, microphone closed when idle, bounded in-memory audio, safe cancellation, and a batch quality reference.
- Review and deliberate copying first; verified selection-aware insertion follows with isolated fixtures.
- German, English, mixed language, technical terms, numbers, and negations evaluated before performance promotion.
- Replaceable presentation components; no fixed visual design and no decorative emoji.
- No mandatory account, cloud inference, telemetry, subscription, or automatic content history.

## Development and release boundaries

No end-user Homebrew dependency is intended. Build and test instructions will be added with the first implementation checkpoint. Private planning documents, recordings, model weights, diagnostic inventories, and local build output are excluded from Git.

The proposed source license is MIT; see LICENSE. Final copyright, name, license, and release destination require review before public visibility. Signing, notarization, clean-Mac installation, model quality gates, and release performance measurements are not complete.
