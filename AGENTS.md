# OpenWispr implementation rules

Read STATUS.md before continuing. Keep private planning, personal diagnostics, recordings, model weights, and build output out of Git. No secrets or personal machine paths in committed files.

The private planning read caches in .planning are authoritative excerpts of the user's Library plan. The introduction and consolidation supersede historical appendices. Do not execute appendix examples without review. Current user instructions take priority.

Work in this one local implementation thread. Do not create additional local threads or subagents. The parent coordinates independent cloud review.

Use SwiftUI/AppKit for the app and a minimal native bridge for one pinned whisper.cpp backend. Target macOS 14+ and Apple Silicon unless a verified build constraint is documented. No mandatory cloud inference or end-user Homebrew dependency.

Microphone closed when idle. No inference, blocking locks, heap growth, file writes, or actor/task dispatch in the realtime callback. Explicit session identity, bounded audio ownership, tested sample-rate conversion, cooperative cancellation, and no stale results.

Preserve the batch quality baseline. Do not add streaming until controlled quality and work measurements justify it. One active inference job, one selected model per session, and coalesced pending demand if previews are introduced.

No unchecked full-field AXValue writes, blind retry after uncertain mutation, automatic replacement of nonempty selections, or clipboard restoration based on a fixed delay. Start with review/copy. Test external insertion only in isolated fixtures.

No decorative emoji, fixed visual design, idle animation loops, telemetry, or deliberate default audio/transcript persistence. Keep presentation replaceable independently of audio and inference. Honor Reduce Motion.

Use low-impact tests and bounded build parallelism while other tests load this Mac. Do not stop other workloads. Do not run a benchmark matrix without coordination. Record actual command results and leave unmeasured values explicitly unmeasured.

Keep STATUS.md concise and up to date. Public visibility, signed releases, paid enrollment, credentials, and security-setting changes require separate authorization. Private repository owner has been explicitly confirmed as Dodothereal. No force pushes or destructive history edits.
