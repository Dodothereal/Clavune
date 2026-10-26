# Clavune status

26 October 2026 — **experimental source candidate, not a supported release**.

The source contains a native SwiftUI/AppKit app, bounded local recording/audio
import, an embedded pinned whisper.cpp backend, verified model setup, editable
transcript review and local statistics. No account, cloud transcription service,
automatic model download, automatic paste or remote telemetry is included.

The proposed current source passed **246 portable Python tests** using the ordinary
README command in an isolated source/support/documentation assembly. The production
C++ ingress-close fixture passed on Linux normally and with UBSan-only instrumentation.
The combined ASan/LSan attempt is inconclusive because LeakSanitizer rejected the
host's ptrace environment; its failure is retained.

These results are not native Swift, macOS app, microphone, model, visible UI or
clean-install acceptance. The latest source has not been compiled/run on macOS.
Earlier launch failures (`-10827` / Cocoa `259`), Open/Save/Cancel/IME behavior and
real-device validation remain unresolved.

See [validation status](Docs/VALIDATION.md) for exact source identities and test
boundaries, [build instructions](Docs/BUILD.md) for supported commands, and the
[publication checklist](Docs/PUBLICATION_CHECKLIST.md) for remaining owner/security
decisions. Historical files under [Validation](Validation/README.md) are retained
for provenance, not presented as evidence for the current source.

Publishing an explicitly experimental source repository does not establish a
working signed/notarized binary. No public visibility or binary release is approved
by this status file.
