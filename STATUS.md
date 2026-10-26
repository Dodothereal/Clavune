# Clavune status

26 October 2026 — **experimental source candidate, not a supported release**.

Clavune contains a native SwiftUI/AppKit app, bounded local recording/audio import,
an embedded pinned whisper.cpp backend, verified model setup, editable transcript
review and local statistics. No account, cloud transcription service, automatic
model download, automatic paste or remote telemetry is included.

The current native repair fixes Open's marked-text preparation boundary and the
synthetic QA fixture's exact macOS temporary-directory alias handling. Its source
snapshot is Git tree `b43df86a56164030dd69480d499af0287f991236`; subsequent status
documentation does not alter application or test bytes.

- **246 portable Python tests passed**, independently rerun on the exact repair tree.
- **29 focused native tests passed** on the development Mac.
- The full native Swift run reported **558 passed, one Settings accessibility-test
  failure and one intentionally skipped render test**. It is not a full-suite pass.
- A corrected Release, ad-hoc-signed normal-development app passed launch,
  Open with synthetic text and Quit on that Mac. This is not clean-install acceptance.

Live speech recognition, physical IME behavior, VoiceOver, motion settings and
clean-machine installation remain unverified; window-only reopening is unconfirmed.
Broader native document workflow checks from an earlier
baseline are not promoted to acceptance of the repair tree. No supported signed/
notarized binary or accuracy/performance result is claimed.

See [validation status](Docs/VALIDATION.md) for identities and evidence boundaries,
[build instructions](Docs/BUILD.md) for commands, and the
[publication checklist](Docs/PUBLICATION_CHECKLIST.md) for source/privacy/CI and
owner decisions. [Historical validation](Validation/README.md) remains historical.

Source publication and binary distribution are separate decisions. This status
file does not authorize a push, visibility change or binary release.
