# Build reliability review

The confirmed packaging issue was control flow: the earlier script created the final app directory before signing and auditing. A failed check could leave a partial final artifact that blocked a clean retry.

The packaging script now creates a unique staging container under artifacts, assembles and signs the app there, verifies its signature, and runs the bundle audit before exposing the final name. Publication uses macOS renamex_np with RENAME_EXCL so an existing final entry cannot be overwritten. Cleanup removes only the invocation's owned staging container, including on failure; it never removes an existing final app.

Seven Python fixtures use synthetic files and mocked subprocesses/publication. They cover checked publication, signing failure followed by retry, audit failure cleanup, existing-final preservation, a concurrent final collision, the exclusive native publication flag and invalid product names. This reviewer did not execute the fixtures, signing, app launch or a build.

The external Product.json manifest-invalidation concern remained a candidate until measured. The parent reported two isolated probes on the installed Swift 6.4 toolchain:

- A Config-only dump-package change produced ProbeBefore followed by ProbeAfter without touching Package.swift.
- A static archive-only change behind the same external linker flags produced return value 1 followed by 2 after an incremental rebuild.

Neither a stale manifest nor a stale external-archive link was reproduced in those probes. Scripts/swift.sh remains unchanged, and no product-content cache namespace or broad cache deletion was added. These results are specific to the probed toolchain and do not certify every future SwiftPM version. Any separate backend fingerprint/patch marker records explicit provenance; it is not described as a fix for a reproduced cache failure.

## Root execution evidence

Root ran the full Python suite: 23 tests, zero failures, including all seven packaging fixtures and the immutable review snapshot fixtures. Final real bundle signing/audit results are recorded in checkpoint.json.
