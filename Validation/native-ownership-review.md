# Native backend ownership correctness review

This is a static review and isolated fault-fixture specification. Runtime results belong in the checkpoint command logs; preparation of a fixture is not a passing test result. No model, GPU, microphone or real audio was used for this review.

## Source provenance and scope

The patches derive from pinned whisper.cpp v1.9.5 commit `d1be6fde11ac6e0407606b4e42fe72d34add8037`, verified source archive SHA256 `645445da884df6dbd52b30f82d7be7c01d1767c938714e477e786b88d529e9f4`. The pristine `src/whisper.cpp` Git blob is `1675f33acf0b250bc9db648a3c2150fa6144f970`. Line references below refer to that pristine source. Apply patches in the dependency lock order; the fetch script verifies archive, patch hashes and the entire resulting source inventory. The downstream exported state-ownership revision marker is 1. Its Swift fixture forces linkage of the patched upstream archive; the backend fingerprint additionally binds the linked archive inventory.

| Patch | SHA256 | Correctness changes |
| --- | --- | --- |
| `0001-state-exception-ownership.patch` | `fdecbe22ec6f9c5a377cf5e81318183d414e2615e576fb393781546906914b0f` | Explicit empty batch; immediate value-initialized state owner; checked/owned partial batch allocation; backend-handle adoption; local KV context ownership; state-init exception boundary. |
| `0002-model-exception-ownership.patch` | `8c031d4707b90638bf4f981c4dbda071ecd45af06f5b4728655b87775650c784` | Model context/buffer adoption and temporary context ownership; reject null model buffer; complete partial-model cleanup; ownership through path assignment; close loader at most once and contain initialization exceptions. |

The decoder configuration, native 120-second admission bound, CPU/Metal selection, signing settings and successful initialization defaults are unchanged. These patches do not establish whole-backend out-of-memory safety.

## Confirmed static failure paths

- State allocation at 3455 originally left `batch` at 867 uninitialized. Early explicit cleanup before batch assignment could inspect indeterminate pointers. An exception during logits reserve (3565), any of the five decoder reserves (3570–3575), or graph metadata allocation (560–566, reached through four schedulers) could leak a state not yet returned to its caller. Patch 0001 initializes cleanup-visible state and owns it immediately, removes the twelve now-redundant manual frees and releases only on success. The outer catch returns null after unwinding.
- Backend setup (1341–1371) originally stored native handles in a vector with no cleanup owner. Vector insertion failure or CPU initialization failure after earlier backend acquisition leaked handles. A shared adoption helper owns the incoming handle through insertion; an owned local vector holds adopted handles until successful transfer.
- KV initialization obtains a local context at 1004. Null buffer failure at 1014–1017 or a subsequent exception missed `ggml_free` at 1022. A native guard now owns that context immediately and frees it on all exits. Backend buffers already adopted into the state remain state-owned.
- Batch allocation (491–499) originally dereferenced unchecked malloc results and left row-table entries indeterminate until visited. Each size is checked before multiplication, every malloc failure throws before dereference, and all row pointers including the terminator are zeroed before row acquisition. A local aggregate owner cleans partial allocations. The caller checks the completed top-level pointers before any batch preparation.
- Model `get_ctx` acquisition at 1709 could leak on map insertion (1714) or context-vector adoption (1715). The fresh context is now guarded through both operations. The temporary tensor metadata context at 1750 is guarded through all model vector/tensor preparation, with null checked before use. Its former manual free at 1857 is removed.
- Model buffer allocation at 1864 originally continued on null and could leak a nonnull handle if vector insertion at 1866 threw. Null now fails the load; the same adoption helper owns nonnull buffers through insertion.
- The top-level no-state model context allocation at 3822 originally preceded the exception handler. The failure branch at 3846 used `delete`, omitting native contexts/buffers freed by `whisper_free` at 3984. A value-initialized context is now immediately owned with the complete normal deleter. Cleanup reads only the initialized model vectors and state pointer. Loader close is attempted once across allocation/load/close exceptions. The file wrapper owns the returned model through `path_model` assignment at 3768, including allocation failure there.

## Isolated fixture and limits

`Scripts/test-state-ownership.sh` compiles `Tests/Native/StateExceptionOwnershipTests.cpp` against the actual private production helper header installed by patch 0001. It uses tiny counting fake native resources, controlled C malloc failures and selected real C++ allocation failures. It checks matching live-resource identities before free; no real exhaustion is used.

| Fixture cases | What is actually exercised |
| --- | --- |
| Failed state allocation; empty-backend early return; 30 reserve failures | Production value-initializing owner and full fake-state deleter. Ten real vector reserves represent logits, five decoder reserves and four graph metadata stages, each after zero/one/two native acquisitions. |
| First vector growth failure; GPU/CPU adoption failure; CPU failure after GPU; success transfer | Production adoption and owned-handle-vector helpers. The first std::vector insertion uses real allocation failure; named GPU/CPU cases use a deterministic throwing destination and counting handles. |
| Null context, null backend buffer, throw after buffer adoption, success | Production native handle guard plus outer state owner, using fake context/buffer acquisition and the same ownership pattern. |
| Every batch top-level allocation plus every one of five rows; overflow; success | Production checked-malloc, checked-size and aggregate-owner helpers. The fixture mirrors the zeroed row-table/sentinel protocol with five rows and ten allocation sites. |
| Model allocation; null permanent/temporary context; map insertion; context/buffer adoption; temporary metadata reserve; null buffer; later false return; path assignment; throwing close; nonstandard throw | Actual production ownership helpers with a fake model and loader. Map/vector/string storage failures are real C++ allocation failures where specified. The close-once and model wiring are mirrored fixtures rather than calls to the production loader. Twelve failure stages repeat over eight recovery cycles. |
| Failure then fresh successful owner | Sixteen state recovery cycles and eight model recovery cycles with resource counters returning to baseline; successful handles transfer once. |

Still unexercised: actual `whisper_init_state` reserve/graph failure injection, actual GGML/Metal/CPU initialization failures, real `ggml_init`/backend-buffer null returns, full real-model parser allocation failure, actual file-wrapper path assignment failure, and real loader-close callback failure. The fixture proves the shared ownership helpers under controlled failures and statically connects their call sites; it does not prove those complete integrations under fault injection. Actual app cancellation/unload/new-session sequencing is covered separately by core/session fixtures; this native harness tests only ownership recovery, not app cancellation. Backend abort/assert paths, failures inside opaque backend APIs before a handle returns, experimental backend/VAD-specific allocation paths, parser security and arbitrary caller callback failures are outside this bounded patch review. No whole-process leak, performance, energy or quality measurement is claimed.

## Optional encoder environment

Pinned `src/CMakeLists.txt:193` compiles the ANEForge adapter. `src/whisper.cpp:3553–3560` reads `ANEFORGE_ENCODER`; `src/aneforge/whisper-aneforge.cpp:54–59` reads `ANEFORGE_DYLIB` and uses `dlopen` with `RTLD_NOW | RTLD_LOCAL`. The bridge rejects either variable being present, including an empty value, both before model creation and immediately before decoder-state initialization. The pure predicate fixture does not set process environment variables, load a model or exercise dlopen. This guard addresses inherited optional encoder configuration; it is not a security boundary against arbitrary hostile code already executing inside the process or concurrent environment mutation by such code.

## Root execution evidence

Root applied both locked patches and the out-of-tree CMake patch from the verified archive. The helper matrix compiled and ran with exit 0, then compiled and ran with AddressSanitizer and UndefinedBehaviorSanitizer with exit 0 and no sanitizer diagnostics. Final Swift suite: 48 tests, zero failures, including the revision marker and fingerprint fixture. The final optimized app contains the exact backend fingerprint and patched upstream symbol; engine creation checks revision 1. Complete actual GGML/Metal/model fault injection remains unexercised as listed above.
