# Security

## Reporting

Do not post credentials, private recordings/transcripts, or exploit details in
public issues. Use GitHub's private vulnerability reporting option if it is enabled
for this repository. If no private route is offered, open a **content-free** issue
requesting a private contact before sharing the report. No private reporting
service or response-time commitment is currently promised.

## Scope and development status

Clavune is experimental. The latest source-only candidate is not a supported,
notarized release. A successful build or synthetic test suite is not a security
certification. Native launch, UI lifecycle and real-device acceptance remain open.

The source is designed to enforce:

- Pinned backend source archives and hash-locked downstream patches.
- Exact model size/SHA-256 checks before activation; no arbitrary model executable.
- Explicit HTTPS model downloads with a restricted redirect-host policy.
- Bounded recording/import buffers, one admitted inference job, and cancellation
  ownership that does not free resources still in use.
- Explicit transcript saving and clipboard transfer; no automatic paste or remote
  transcription fallback.
- Local, content-free diagnostics rather than transcript/audio logging.

These are source-level boundaries, not guarantees against all implementation,
framework, filesystem, decoder or operating-system vulnerabilities. In-memory
processing does not promise forensic erasure: macOS may use swap and caches.

## Build and CI safety

Keep SwiftPM sandboxing and macOS security controls enabled. Do not remove quarantine
or disable Gatekeeper to treat a failed development launch as a supported release.
Never run untrusted contributions on a personal/self-hosted runner. The historical
manual native workflow is not proof that a safe public CI runner is configured.

See [Privacy](PRIVACY.md) and [Build](Docs/BUILD.md) for data and execution boundaries.

The manual native workflow is guarded at the job level to run only while its event
repository is private. Dispatch events created while public are deliberately
skipped; this is not evidence of passing public CI. The guard does not cancel
already queued/running private-event jobs; check them before a visibility change. Do not remove the guard merely to obtain a green workflow.
Any future public native CI needs an explicitly reviewed isolated-runner design.
