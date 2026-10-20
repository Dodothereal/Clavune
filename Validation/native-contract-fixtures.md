# Exact batch and bridge contract fixtures

These fixtures were prepared after the coverage review of checkpoint `87a1fb975b3681980dd495af8d73fc09db6e8d1b`. Preparation did not compile or run them. Root must record actual command results before calling them passing. No production source, dependency patch, dependency lock, decoder default, signing flag or native 120-second guard was changed for these fixtures.

## Exact production batch source

`Scripts/prepare-native-contract-inputs.py` reads the already prepared, verified patched source. `Tests/Native/ProductionBatchInputs.json` pins the complete `src/whisper.cpp`, ownership helper, real Whisper/GGML headers and dependency lock hashes. It also checks each locked patch hash and the consumed files against the source inventory. The inventory stamp alone does not confer trust; consumed bytes must independently match the fixed reviewed hashes. This local preparation performs no download, backend initialization or dependency-tree mutation and does not replace the fetch script's whole-tree verification.

The script mechanically copies the exact contiguous production `struct whisper_batch`, free forward declaration, `whisper_batch_init` and `whisper_batch_free` bytes into ignored build output. No layout, init loop or cleanup body is handwritten in the test. Missing/ambiguous boundaries, a full-source hash mismatch or an individual slice mismatch fail closed before compilation. A deliberate upstream/source change requires review and a new fixture hash manifest.

| Reviewed input | Bytes | SHA256 |
| --- | --- | --- |
| Full patched `src/whisper.cpp` | 346401 | `f0380cd7b9a347f435da6d7d392efc0b0c5ec9f6fb7bf74430ceeffd5ff5b686` |
| Actual batch structure | 267 | `33bd6211156f06e8e886e79e51877e98141657584e77d563afba3edb2fc67498` |
| Actual batch init function | 1347 | `84dcf71c7d401e28fbd7aaa40e2350c972ddf0568ee94d8bf94652c9b1fe542e` |
| Actual batch free function | 388 | `da9fafa9ee37fe5fad5acf64f5f6bbb4fee202f953c2821fbeef4ffab24a908b` |
| Complete coupled include | 2065 | `005051b9e2816b8c9d6583c51ed94cb552bf5c29745f389f3a66837e94a579dc` |

`Tests/Native/ProductionBatchTests.cpp` includes the real pinned `whisper.h` and ownership helper first. Test-only macros, scoped solely around the extracted bytes, pass a counting allocator to the actual `whisper_checked_malloc` helper and redirect `free` to a counting release function. The init/free functions' actual owner, size checks, pointer-table initialization, row loop, success release and cleanup order execute. The input source bytes are preserved; allocation/free calls are deliberately substituted in this test executable. This is extracted-function coupling, not a call into the application's linked archive.

With five tokens and three sequence slots, there are ten allocation attempts: token, position, sequence count, row-pointer table, five rows, and logits. Each attempt fails individually. Newly allocated bytes are poisoned before the actual code initializes them. A fixed-capacity table records each live pointer and size; a free must match one live identity before `std::free` is called. Requests must be nonzero and at most 256 bytes. Success verifies all actual typed allocation sizes, the sentinel, writable element bounds and zero live allocations after actual batch cleanup. Empty batch cleanup and six zero/negative dimension pairs are checked. Four recovery cycles repeat the matrix; no particular heap-address reuse is forced or claimed. Checks use an always-active aborting macro, independent of NDEBUG.

Not covered by this fixture: `whisper_init_state`'s batch-completeness admission before preparation, real batch preparation in a decoder graph, large valid dimensions, malformed model dimensions, real allocator exhaustion or state/model ownership wiring. Pinning/drift rejection is a source-coupling check; it is not a recorded runtime mutation-sensitivity experiment.

## Actual bridge source with fake Whisper entry points

The bridge executable compiles the actual `Sources/NativeBridge/WhisperBridge.cpp` as a separate translation unit with `Tests/Native/BridgeContractTests.cpp`. It uses the real `ClavuneBridge.h`, pinned `whisper.h` and transitive GGML headers. The test defines only the C entry points referenced by the bridge, with those real declarations. It does not compile or link `src/whisper.cpp`, `libwhisper.a`, any GGML archive, Foundation, AppKit, microphone capture or a model. The fake opaque context/state objects have their own small test layouts; they do not mirror private upstream structures or claim upstream initializer coverage.

The actual bridge executes its admission checks, environment gates, allocation/error/cancel handling, state-owner scope, explicit decoder-profile assignments, segment copying and result accessors/destructors. Fake context/state identity counters verify the bridge invokes the expected release exactly once and retains model ownership between decodes. A test-only replacement C++ new/delete in this standalone executable counts fixed-capacity heap identities and injects selected wrapper/result/string allocation failures; it does not interpose platform malloc or modify the shipped target. Primitive fake exceptions test the real bridge catch paths. Fake Whisper defaults are inert, so only explicit bridge profile forwarding is checked; upstream heuristic defaults and recognition quality are untested.

Cases include:

- Null path, wrong fake patch revision, null/throwing fake model initialization, engine-wrapper allocation failure and cancellation-token allocation failure.
- Actual own-process environment reads at engine creation and immediately before state creation. The fixture sets/unsets only its own ANEFORGE variables using fixed empty/nonempty test constants; it does not inspect or log inherited values or change parent/host settings. Neither fake nor actual dlopen runs.
- Null engine/token/PCM, zero samples, wrong rate, more than 120 seconds, more than C-int range, null/unsupported language, thread bounds, NaN and infinity. The maximum accepted 120-second PCM buffer is not allocated or exercised.
- Result allocation failure; cancellation before state creation and during the fake decode; real bridge abort/encoder callbacks and post-decode cancellation priority. These are deterministic serial callbacks, not concurrent GPU cancellation.
- Fake state null/throw, decode return error/throw, language/segment/text extraction throws and text allocation failure. The actual bridge's state owner releases the acquired fake resource while the engine context remains live.
- Auto/de/en and thread settings 1/2/8; explicit documented batch-profile forwarding. Three decodes obtain fresh fake state generations. The fixture overwrites fake upstream text storage and destroys state/context/token before checking each actual result still owns its copied Unicode text and language, then releases the results and returns heap counters to baseline.
- Null-safe result accessors and null destroy/set functions. The linked revision and fingerprint implementations here are deliberately fake, including a 64-character `b` fingerprint. Their values are not production backend provenance evidence.

This fixture tests the bridge's real control flow against controlled dependencies. It does not test `whisper_init_state`, `whisper_free_state`, `whisper_backend_init`, KV creation/free, graph scheduler creation/unwind, `whisper_model_load`, full model cleanup, loader callbacks, post-load path assignment or actual inference/cancellation inside upstream code. Actual ANEForge environment handling/dlopen remains unexecuted; only the bridge's refusal paths execute. AppCoordinator/hardware lifecycle and concurrent ownership races remain separate coverage.

## Compile inputs and execution

Run sequentially, from the project root:

    bash Scripts/test-native-contracts.sh
    bash Scripts/test-native-contracts.sh --sanitize

The runner prepares source inputs, compiles the batch executable, compiles the actual-bridge executable, rechecks all recorded input/generated bytes for drift, and only then runs the two executables sequentially. It does not build or execute a backend or app. Both modes use C++17, `-O0 -g -Wall -Wextra -Werror -UNDEBUG`. Sanitizer mode additionally uses `-fsanitize=address,undefined -fno-omit-frame-pointer`. SDK, compiler and C++ standard library remain host toolchain inputs; they are not content-pinned by the fixture manifest.

Exact compile units:

- Batch: `Tests/Native/ProductionBatchTests.cpp`, generated `ClavuneProductionBatch.inc`, `NativeContractChecks.h`, actual ownership helper and real Whisper/GGML declaration headers.
- Bridge: actual `Sources/NativeBridge/WhisperBridge.cpp` plus `Tests/Native/BridgeContractTests.cpp`, real bridge/Whisper/GGML declaration headers, `NativeContractChecks.h` and generated test-only `ClavuneBackendFingerprint.h`. No additional archive/library linker flags are used.

Include directories are `.build/native-contracts/generated`, `Sources/NativeBridge/include`, `.build/deps/whisper.cpp/include`, `.build/deps/whisper.cpp/src` and `.build/deps/whisper.cpp/ggml/include`. The generated `compile-inputs.json` records all consumed project/dependency source hashes, exact extracted slice hashes and generated input hashes. It must remain with the corresponding run evidence. Outputs stay in ignored `.build/native-contracts`: generated inputs, `production-batch-normal` / `bridge-contract-normal`, and sanitizer variants. A passing run reports only the executed exact batch functions and actual bridge/fake dependency contracts. The older generic-helper harness remains a different coverage layer.

## Root execution evidence

Root compiled and executed both fixtures normally and with AddressSanitizer/UndefinedBehaviorSanitizer; both commands exited 0 without sanitizer diagnostics. Per-allocation/per-contract output is in native-contract-results.txt; consumed source hashes and binary hashes are in native-contract-inputs.json and checkpoint.json. The production patch chain and bridge source remained unchanged. Actual upstream state/KV/backend/model/graph initialization and teardown remain unexecuted.
