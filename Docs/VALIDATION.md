# Validation status — 26 October 2026

**Experimental source preview, not a working-release declaration.** Historical
results apply only to their recorded source/build and cannot validate later changes.

## Source-only candidate

The reviewed cloud input is R2
`b509ee40a24f6c63bb8974ae4f57055d60ccdba8d506180a45b8263de5b6d9e4`,
a SHA-256 manifest of 186 selected inputs—not a Git commit or complete repository.

Two previously separate source-reviewed proposals have been composed in memory:

1. Create the delegate-retaining download session only after throwing pre-request
   setup succeeds; close the file on seek failure and snapshot its configuration.
2. Replace the affected ETag fixture's timing assumption with an explicit 1 MiB
   writer acknowledgement and bounded completion/drain checks.

The composition is
`85ac7acb71339a9c780d70e158d0348e9504220b31f0b4c7c24bcc573db18d13`.
A separate proposed configuration correction restores the existing normal development
identity instead of the cloud comparison build's implicit synthetic-QA identity.
With six additional configuration contracts, that candidate is
`ffb12ab8e8dce5683dd9fdda0fb54bde2393e1c36d16bb14eb716d7e9160673b`
over 187 selected inputs. Neither candidate is a claim of adoption by the repository.

## Evidence actually obtained

| Check | Result | Scope |
| --- | --- | --- |
| Original R2 Python suite | 240 passed | 117 source contracts + 123 synthetic tooling checks |
| Composed candidate source contracts | 117 passed | Unchanged Python tests reading the exact proposed bytes |
| Lifecycle proposal checks | 10 passed | Source/provenance and negative controls; not a leak reproduction |
| ETag fixture proposal checks | 11 passed | Source/provenance and negative controls; not a native download run |
| Normal configuration contracts | 6 passed | Exact proposed config and preserved QA routes |
| Configuration negative control | 2 intended failures in 6 tests | Original synthetic config is detected |
| Unchanged contracts after config correction | 117 passed | Source checks only |
| Synthetic tooling after config correction | 123 passed | Eight fresh-process Python modules on the exact proposed bytes |
| Final proposed portable Python total | 246 passed | 117 unchanged contracts + 6 identity contracts + 123 tooling checks |
| Swift tests added by the two download proposals | 4 authored | **Not compiled or run** |
| Production C++ ingress-close fixture | Passed on Linux | Original code, synthetic buffers; not AVAudioEngine or hardware |
| Same ingress fixture with UBSan only | Passed on Linux | Undefined-behavior instrumentation, not leak/Apple-platform coverage |
| ASan/UBSan ingress attempt | Inconclusive | Compiled; LeakSanitizer terminated because the host uses ptrace |

Static Swift discovery goes from 548 to 552 tests in the composed proposal. This
is a source inventory, not native execution. The fixture synchronization gap is
not a proven explanation for the historical ETag failure.
The failed sanitizer attempt is retained; no runtime sanitizer setting was disabled
to relabel it a pass. The separate UBSan-only run does not supply missing leak coverage.

## Unresolved native gates

- Compile the exact integrated source and execute targeted plus full native suites.
- Diagnose the earlier `-10827` / Cocoa `259` launch failure on the exact artifact.
- Verify normal Open, Save, Cancel, Quit, relaunch and multiple-window workflows.
- Verify real marked-text/IME composition, selection and Undo/Redo across Open
  cancellation/read failure as well as Save; the Open diagnostic is not yet implemented.
- Validate microphone lifecycle, supported OS/hardware and clean-machine installation.
- Audit the final actual binary/resources, signing, privacy behavior and dependencies.

Publishing an explicitly experimental source repository and distributing a supported
binary are different decisions. Neither the portable tests nor this document grant
publication approval, licensing clearance, native acceptance or notarization.
