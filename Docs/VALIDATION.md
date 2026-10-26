# Validation status — 26 October 2026

**Experimental source preview, not a supported-release declaration.** Native
compilation and a narrow development-Mac smoke check now have evidence. The full
Swift suite is **not fully passing**, and important hardware/accessibility/install
work remains unverified.

## Exact source boundary

The repair starts from commit
`c669082d2e2e9663b3d5fb02d64e9b2b891e7d4c`, Git tree
`5ac1612d17f4f5d0c41bd91b1f7c3b58809b2e03` (226 files).

The seven-path native repair produces Git tree
`b43df86a56164030dd69480d499af0287f991236` (227 files). The combined repair patch
has SHA-256
`ece705ae7c92b41c6a6ca5f61cdd3cd9bdd64495af1f4cd96c83059debe9575c`.
This is a file-tree identity, not a new commit identifier. Later status-documentation
edits preserve this tree's application, configuration, dependency and test bytes.

The repair:

- Commits pending native marked text before Open publishes the admission that
  disables its editor host. Preparation remains guarded against reentrant Cancel,
  privacy changes and Quit, stale review identity and late reads.
- Adds native offscreen regressions for declined Open, read failure and cancellation,
  preserving transcript bytes, selection and Undo/Redo.
- Allows only the exact macOS `/private` spelling alternative for an owned synthetic
  QA temporary path, preserving directory/inode/content and symlink safeguards.
- Documents the explicit native-test fixture opt-ins. It does not enable a real
  microphone, download a model or perform speech recognition.

## Evidence on the repair

| Check | Result | What this establishes |
| --- | --- | --- |
| Native focused regressions | 29 passed | Bounded synthetic/native test fixtures on the development Mac |
| Full Swift suite with documented fixture opt-ins | **558 passed, 1 failed, 1 skipped** | Native compilation/execution occurred; **not a full-suite pass** |
| Remaining Swift failure | Hidden Settings accessibility control lookup | Controls absent in the hidden test host; cause unresolved and assertions unchanged |
| Skipped Swift test | App-content render opt-in/source binding absent | Intentionally not executed; not a render pass |
| Normal-development Release app | Launch, Open synthetic text, Quit passed | Corrected, ad-hoc-signed artifact on one development Mac only |
| Portable Python suite | 246 passed | Independently rerun in cloud on the exact 227-file repair tree |
| Python/shell syntax and local Markdown links | Passed | Static/portable checks; not native acceptance |

The full Swift command and its three fixture opt-ins are in the
[build guide](BUILD.md). Offscreen AppKit editor tests exercise genuine native
marked-text state with synthetic boundaries; they are not a test using a physical
IME, microphone or speech model. A discovered or skipped test is not an executed
passing test. The real app exposes the Settings controls, but the hidden-host
projection failure remains unresolved; that observation does not waive the failing
assertion.

The normal app smoke check is deliberately narrower than the prior native document
workflow checks on baseline commit `c669082d2e2e9663b3d5fb02d64e9b2b891e7d4c`
(Open/edit, menu Undo/Redo, Copy/Paste, Save/Cancel, Quit cancellation, saved-file
reopen and invalid-file handling). Those older flows are **not** promoted to
repair-tree acceptance. The corrected Release artifact's launch success does not
certify an older app that failed with `-10827` / Cocoa `259`, nor a fresh uncached
build or installation on another Mac.

## Earlier portable evidence — separate scope

The earlier source-reviewed download-lifecycle and ETag-fixture proposals, plus the
normal-development-identity correction, remain in the baseline. Their original
selected-input SHA-256 was
`ffb12ab8e8dce5683dd9fdda0fb54bde2393e1c36d16bb14eb716d7e9160673b`
over 187 selected inputs. This manifest is not a Git commit or complete repository.

Earlier Linux runs of the production C++ ingress-close fixture passed normally and
with UBSan-only instrumentation using synthetic buffers. The combined ASan/LSan
attempt remained inconclusive because LeakSanitizer rejected the host's ptrace
environment. Its failure is retained; no sanitizer/security setting was disabled
to relabel it a pass. These results supply neither leak coverage nor Apple-platform,
AVAudioEngine or physical-device acceptance. Do not add historical counts to the
current suite total.

## Still open

- Resolve and rerun the Settings accessibility-test failure; obtain a fully passing
  exact-source native suite without weakening its assertions.
- Exercise the separately gated app-content render check with its required binding.
- Revalidate broader normal-app Open/Save/Cancel/Quit, relaunch and multi-window flows
  on the final artifact rather than relying on the prior native baseline checks.
  Window-only reopening remains unconfirmed.
- Validate physical IME input, selection and Undo/Redo, VoiceOver and motion settings.
- Validate real microphone/model recognition, supported OS/hardware, resource use
  and quality; no live-ASR or accuracy/performance result is claimed.
- Verify fresh developer setup and clean-machine installation; audit the exact
  distributable's resources, licenses, signing and runtime privacy behavior.

Publishing an explicitly experimental source repository and distributing a supported
binary are different decisions. These checks grant neither publication approval,
licensing clearance, full native acceptance nor notarization.
