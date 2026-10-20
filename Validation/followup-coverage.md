# Production-bound correctness follow-up

Base: 87a1fb975b3681980dd495af8d73fc09db6e8d1b. Current results are in checkpoint.json and regression-sensitivity.json; this is not a hardware acceptance report.

## Executed layers

| Layer | Actual production code exercised | Substituted or unexecuted boundary |
| --- | --- | --- |
| Coordinator/service integration | AppCoordinator.start/stop/cancel/quit, admission, task/resource phases, metrics; CaptureService.start/stop/cancel, serialized delivery, startup gates and active object identity | Injected clock, permission promise, device list, watchdog, picker and termination; fake CaptureRunning resources and InferenceServicing. No SwiftUI App entry point, AVAudioEngine, real TCC, actual inference or target app. |
| Stop endpoint primitives | Actual AudioEndpoint and AudioConversion with generated PCM | Existing SyntheticStopTransport is explicitly a composition fixture. It does not call CaptureSession.stop/pump or prove real callback endpoint behavior. The new actual coordinator/service test proves exact cutoff delivery to the resource boundary. |
| Clipboard actions | Actual PlainTranscriptTextView.copy/cut and LocalClipboard write policy; native selected-text deletion | Recording sink replaces clipboard writes; separate tests use unique named pasteboards. No general clipboard or Universal Clipboard behavior is tested. Menu/responder keyboard routing remains manual QA. |
| Batch allocation | Byte-identical extracted struct, whisper_batch_init and whisper_batch_free, actual ownership/check helpers | Allocator/free primitives are scoped test substitutions; no linked upstream initializer, decoder or graph. Fixed hashes reject source drift. |
| C bridge | Actual WhisperBridge.cpp compiled with real API declarations and sanitizers | Fake Whisper C entry points and test fingerprint. No upstream model/state/backend initialization or real inference. |
| Generic ownership | Actual generic ownership helper definitions | PartialState/BatchFixture/ModelFixture remain mirrored orchestration; sanitizer success is limited to that harness. |
| Review ZIP | Immutable commit membership/bytes, real staging cleanup; write/close failure/retry fixtures | Publication is injected in portable fixtures; the final local ZIP uses real macOS exclusive rename. |

The existing test target imports ClavuneApp on Swift 6.4; the four-target product structure is unchanged. CoordinatorEnvironment selects lazy system adapters only in the real app composition. CaptureService owns gate ordering; resource fakes contain no duplicate admission algorithm. Queued fake pump work follows startup resolution, and a later queued cancel cannot overtake a held start. Tests assert synchronous token invalidation while close acknowledgment waits for queue resumption.

## Confirmed shutdown repairs

An unanswered permission request owns no model/capture resources. Quit invalidates that startup without awaiting its user-dependent promise. Before any resource work, the main-actor startup task validates identity/phase/cancellation and records resource ownership before its first model await. Quit awaits already-admitted resource work, closes capture and unloads the engine. Its permanent admission flag is set before cancellation; repeated Quit is idempotent. Tests leave the fake permission unanswered until fake termination, then resolve it to verify late grants cannot load/open anything. Another test holds unload and attempts Start/import/unload again.

The pre-permission entry fixture holds the inherited startup task behind the current uninterrupted MainActor turn: Start and Cancel run before the first await. This uses actual executor ordering rather than an artificial service callback schedule. It checks zero permission requests. No real permission status/request API is selected by these fixtures.

## Regression sensitivity

Ten one-site mutations each rebuilt successfully, ran its intended test and failed the expected assertion. Production bytes were restored after every case; all restored-source tests then passed. Exact tested source and binary hashes are recorded in regression-sensitivity.json. A build/database error, missing intended assertion, or compilation failure is rejected rather than counted as a killed mutation.

Cases cover resampling in coordinator/service, ignoring raw review, constructing before startup authorization, opening without privacy revalidation, acknowledging close too early, awaiting unanswered permission on Quit, reopening shutdown admission, allocating cancellation after session admission, and prompting from a cancelled task. The executable and logs from each run are retained in ignored project evidence. No real model, memory exhaustion, microphone or permission change was used.

## Remaining integration gates

Actual CaptureSession/AVAudioEngine construction, tap delivery/teardown, physical microphone closure, TCC/Secure Input behavior, route changes and callback-stop blocking remain unexecuted. Actual import task/temp-file cleanup at application shutdown is source-reviewed; tiny ModelStore tests do not constitute a full coordinator import integration test. Actual upstream state/backend/KV/model/scheduler allocation/cleanup and loader/path exceptions remain unexecuted. Detailed native limits are in native-ownership-review.md and native-contract-fixtures.md. The bridge fixture's serial cancellation callbacks do not prove concurrent GPU cancellation.

Resource evidence remains a Python physical-tree audit plus inspection of this toolchain's generated Swift accessors. A relocated Swift resource lookup was not executed. Native UI presentation/keyboard routing, recognition quality, latency, CPU, memory, energy and clean-Mac installation remain unmeasured. Efficiency and release-readiness layers await independent correctness cross-verification.
