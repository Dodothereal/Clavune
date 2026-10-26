# Clavune contributor instructions

Read `STATUS.md`, `Docs/BUILD.md` and `Docs/VALIDATION.md` before changing code.
The repository is an experimental source project, not a supported binary release.
Builds and contributions must be understandable from committed source and docs;
do not depend on private plans, personal files or machine-specific caches.

## Architecture and scope

- Use SwiftUI/AppKit and a minimal native bridge to one pinned whisper.cpp backend.
  Target macOS 14+ and Apple Silicon unless a reviewed constraint changes that scope.
- No mandatory cloud inference, account/subscription, or end-user Homebrew dependency.
- Preserve the bounded batch-quality baseline. Do not add streaming or alternate
  backends without explicit scope, quality and resource evidence.
- Keep presentation replaceable independently of capture and inference. Honor Reduce
  Motion and avoid idle animation loops.

## Resource and privacy invariants

- Microphone capture is closed when idle. The realtime callback must not perform
  inference, blocking locks, heap growth, file writes or actor/task dispatch.
- Preserve explicit session identity, bounded audio ownership, sample-rate conversion,
  cooperative cancellation, drain-before-release and rejection of stale results.
- Keep one active inference job and the native 120-second safety bound. Tests and
  documentation must distinguish live-prefix handling from strict overlong imports.
- Keep recordings, transcripts, model weights, secrets, private paths, diagnostic
  caches and build output out of Git. Use synthetic fixtures and owned temporary roots.
- No remote telemetry or deliberate default audio/transcript persistence. Local
  content-free metrics must remain accurately disclosed in `PRIVACY.md`.
- No unchecked AXValue mutation, blind retry after uncertain mutation, automatic
  replacement of selections or timer-only clipboard restoration. External insertion
  remains disabled; new adapters require isolated review and tests.

## Verification and collaboration

- Prefer narrow changes with a reproducible failure and a regression test. Preserve
  exact bytes, IME composition, selection and Undo/Redo at editor/file boundaries.
- Run portable Python checks and applicable native tests. Report the exact source,
  command, pass/fail/skip counts and never-run stages. Do not weaken an assertion or
  count a timeout/compiler error as a successful regression reproduction.
- Use low-impact tests and bounded build parallelism. Coordinate heavy builds and
  benchmarks; never stop unrelated workloads or use another person's recordings.
- Synthetic source/fake-service tests are not hardware, model-quality, macOS GUI or
  clean-install acceptance. Keep unmeasured values explicitly unmeasured.
- Preserve SwiftPM sandboxing and operating-system security controls. Do not run
  untrusted contributions on a personal/self-hosted runner.

## Publication and licensing

Keep `STATUS.md` concise and current. Preserve existing licenses and attribution.
Source publication, release distribution, signing/notarization, paid enrollment,
credentials, access/security changes and destructive Git-history operations require
the relevant explicit project-owner authorization. Do not force-push or rewrite
history as a privacy cleanup without a separately reviewed plan.

Use the current Clavune name consistently. Historical names in code/evidence are
not permission for an unreviewed identity/storage migration or a trademark-clearance
claim. See `Docs/PUBLICATION_CHECKLIST.md` for source and binary-release gates.
