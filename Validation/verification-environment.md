# Verification environment and rejected build attempts

The accepted follow-up tests and optimized app use the installed Swift 6.4 default swiftbuild engine, two jobs and normal SwiftPM sandboxing. The source wrapper remains unchanged. The regression script invokes Swift directly with explicit cache/config/security/scratch paths; it does not pass an alternative scratch argument through Scripts/swift.sh, whose own appended scratch path would take precedence.

Accepted command shape:

    swift test --build-system swiftbuild --jobs 2 --filter <targeted-test> \
      --cache-path <owned-temporary-build-root>/cache \
      --config-path <owned-temporary-build-root>/config \
      --security-path <owned-temporary-build-root>/security \
      --scratch-path <owned-temporary-build-root>/scratch

The restored full-suite command omits --filter. Release compilation uses swift build --configuration release --jobs 2 with those same explicit build paths, followed by package-app.py with the reported Release bin directory. The app is ad-hoc signed/audited and never launched. CLANG_MODULE_CACHE_PATH and SWIFTPM_MODULECACHE_OVERRIDE point to that owned build root; MACOSX_DEPLOYMENT_TARGET is 14.0. The source, logs, evidence snapshots and app stay inside the project. SQLite build/cache files were placed in a task-owned temporary directory because project-local verification encountered reproducible I/O failures.

## Observed failures, not accepted test evidence

1. The initial mutation attempt used bash Scripts/swift.sh test --jobs 2 --filter AppCoordinatorIntegrationTests/testStopTimestampTraversesActualCoordinatorAndServiceBeforeDelayedDelivery. Its effective database was .build/swift/out/Intermediates.noindex/XCBuildData/build.db. Compilation reported a disk I/O error and then an older test binary ran; the mutation was rejected and source bytes restored.
2. Explicit direct Swift commands with a fresh project-local cache/scratch initially passed a baseline and coordinator mutation. The following service mutation encountered another build-database I/O error; its stale preceding binary failed, but this was rejected because the mutant had not built successfully.
3. A fresh project-local namespace for every invocation still produced an I/O error in the baseline, despite twelve test assertions passing. No mutation was attempted in that run.
4. The installed alternative native builder was tried in another fresh project-local namespace. It also reported a build.db I/O error and was rejected. It was not adopted for product builds or accepted evidence.

Representative error, normalized to avoid personal paths:

    error: error: accessing build database "<project>/.build/.../build.db": disk I/O error

A small WAL-mode SQLite probe inside the project initially committed and passed integrity_check. Across subsequent tool boundaries, that probe and project build databases had link count 2, while a newly created project probe started at 1. A task-owned temporary probe retained link count 1 across the same boundaries. The accepted temporary build namespace avoided the observed failures. This supports an execution-environment/checkpoint interaction as an explanation; the implementation of that environment and the precise SQLite failure cause were not independently verified. Free disk space was available, and no unrelated cache or process was changed.

Private logs preserve every rejected attempt, actual unredacted command/cache/scratch paths, return codes and available fingerprints. Initial rejected attempts did not snapshot every binary at failure time; no retrospective binary identity is claimed for those runs. Accepted baseline/mutants/restored suite have per-command source hashes, copied test executable hashes and effective product paths. subprocess return codes are consumed directly; no tee pipeline hides a failure. Compiled-evidence copies remain ignored.

These observed database errors do not establish the earlier manifest-invalidation or external-library stale-link hypotheses. Those hypotheses were not reproduced by the earlier isolated Swift 6.4 probes. No sandbox disabling, security-setting change, broad cache deletion, process termination or software installation was used.
