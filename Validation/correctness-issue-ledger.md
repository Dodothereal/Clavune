# Correctness repair disposition

This pass is limited to correctness. Efficiency work starts only after independent cross-verification of the corrected commit. Synthetic fixtures do not certify real microphone, permission, GPU, insertion or model behavior.

| Finding | Disposition and regression evidence |
| --- | --- |
| Stop cutoff sampled after task delivery | Source-confirmed. An immutable CaptureStopRequest carries the synchronous event timestamp. Actual coordinator/service delivery now runs with an injected clock and queued resource boundary; reverting either timestamp fix fails that test. Separate primitive fixtures exclude post-request signal or fail closed; actual CaptureSession pump remains hardware-unverified. |
| Tap request treated as a maximum callback size | Source-confirmed. Native ingress preflights and atomically publishes bounded chunks. Fixtures cover 10,000-frame buffers, native-rate timestamps, capacity and wrapping. Callbacks beyond total ring capacity still fail visibly. |
| Cancellation/privacy changes during startup | Source-confirmed. Per-session startup authorization is invalidated synchronously and checked before construction and around engine start. Actual coordinator/service ordering fixtures cover delayed start, pre-permission cancellation, queue-delayed token invalidation, and revocation with fake engine resources. OS start and privacy state are not one atomic operation; in-flight revoked starts are immediately closed. |
| Late start completion after failure | Source-confirmed. Session identity and preparing phase must both match before accepting recording. |
| Raw transcript retained after edited text emptied | Source-confirmed. Actual coordinator cancellation after an empty edit clears review/raw content; reverting the coordinator guard fails that test. |
| Normal native selection copying bypasses clipboard policy | Source-confirmed. Native selection hooks and actual Copy/Cut actions share currentHostOnly plain-text export. A recording write sink asserts exact host-only options and string type, failed Cut preserves text, and readonly Cut does nothing. Other tests use unique named pasteboards; cross-device clipboard behavior is untested. |
| Modal import allows nested hotkey start | Source-confirmed admission gap. OperationAdmission remains held across the picker and cancellation. Actual Carbon delivery during modal UI remains untested. |
| Corrupt installed model prevents deliberate reimport | Source-confirmed. Verified new inode plus one bounded no-overwrite recovery backup; six tiny SHA fixtures. Two renames are not a crash-durable transaction. |
| Quit can leave an in-flight import temp file | Source-confirmed. Quit awaits cancelled outer import and its detached copy/hash cleanup. Cooperative chunk checks do not bound blocked filesystem I/O or provide crash cleanup. |
| Cancelled import status remains checking | Source-confirmed. Status changes after awaited cleanup, preserving any previously selected model. |
| Optional encoder environment selects another backend | Source-confirmed in pinned upstream. Bridge rejects present ANEFORGE encoder/library variables, including empty values, before model and decoder creation. Pure predicate fixtures; no environment or model execution required. |
| Conditional state/model allocation ownership leaks | Source-confirmed in pinned upstream. Locked 0001/0002 patches establish immediate ownership, checked batch allocation and C-boundary failure returns. Native helper matrix injects fake-resource failures; actual GGML/Metal/model allocation faults are unexercised. |
| Upstream CMake mutates verified source | Observed configured JavaScript package file in old source cache. Old cache preserved; locked 0003 directs generation into build output. |
| Final app path exists before signing/audit succeeds | Source-confirmed. Owned staging, verified audit, exclusive publication and seven mocked packaging fixtures. |
| Existing dependency tree trusted from archive hash alone | Source-confirmed. Independent extraction, exact ordered patch hashes and whole-tree inventory comparison. Six offline fetch fixtures; changed existing trees are preserved. |
| Review export membership follows mutable index | Source-confirmed. Membership and bytes now derive from one commit tree and blob IDs; three snapshot fixtures. |
| Menu appears idle while capture close is outstanding | Source-confirmed. Actual coordinator/service cancellation retains closing indication while the control queue is paused; acknowledging close before the awaited service fails the regression. AppIcon consumes that state; native rendering remains untested. |
| Failed/cancelled floating panel cannot be dismissed | Source-confirmed. Nonbusy, microphone-closed panel has an explicit Hide action. Native interaction untested. |
| Intermediate meter peaks lost between emissions | Source-confirmed. Peak accumulator resets only after emission; two pure fixtures. |
| Cancellation-token allocation leaves preparing phase | Source-confirmed in original order. Fallible resource factory runs before session admission; injected throw retains prior review and permits a later start. |
| Development shortcut conflicts with VoiceOver | Source-confirmed chord overlap. Ctrl–Option–Space and its modifier extensions are rejected. Two explicit provisional alternatives are configurable while off; registration is opt-in. Further system/app conflicts and accessibility interaction remain untested. No settings changed. |
| Packaged resource path alleged mismatch | Disproved on installed Swift 6.4 generated Debug/Release accessors: Bundle.main.resourceURL includes packaged resource bundle. Seven packaged-only audit fixtures exclude a development-path rescue; see resource-lookup-review.md. |
| Release dead-strips unused provenance getters | Observed during final binary inspection. Initialization now requires the patched revision; local session metrics consume the archive fingerprint. Final binary contains both exact fingerprint and patch symbol. |
| Config-only manifest staleness / archive-only stale relink | Not reproduced in isolated Swift 6.4 probes. No wrapper cache workaround. Backend fingerprint and linked patch marker provide provenance, not evidence of a reproduced cache defect. |

## Conditional upstream limitation

Pinned upstream can free caller-owned decoder state when expanding KV storage for multiple decoders. The application fixes greedy best_of=1, no temperature fallback and one decoder, so this path is outside the current profile. The ownership patches do not claim safety for arbitrary upstream decoder configurations. Before changing that profile, repair and fault-test this path separately.

## Remaining validation

No app launch, microphone/TCC prompt, real model, GPU allocation-fault run, external target mutation, substantial benchmark or clean supported-Mac installation occurred. Recognition quality, completion latency, peak resident memory, CPU and energy remain unmeasured. The per-operation core fixtures do not substitute for full AppCoordinator/hardware integration tests. Public visibility, signed/notarized distribution and release remain blocked pending review and separate authorization.

Upstream generated ggml version banners can inherit the enclosing app repository commit because the dependency is a verified archive without its own Git directory. Do not use that banner to infer backend identity; the dependency lock, patch hashes, reconstructed tree and archive fingerprint are authoritative. Manual CI includes Python/native/Swift checks but was not triggered or used to install a runner.

## Production-bound follow-up

Two additional confirmed shutdown defects are fixed: Quit no longer awaits an unanswered permission prompt, and quitRequested permanently closes Start/import/unload admission. Another entry guard prevents a cancelled scheduled task from invoking permission APIs. Actual coordinator/service tests cover these paths and ten deliberate one-site reversions fail their expected assertions before all restored-source tests pass. Generic helper fixtures remain a separate layer; the added exact production batch and actual bridge/fake contracts do not execute upstream state/KV/model/graph orchestration. See followup-coverage.md and regression-sensitivity.json. Review ZIP publication now uses owned staging and exclusive rename, with write/close failure retry fixtures. Resource audit remains physical-tree plus generated-source inspection, without relocated Swift execution.
