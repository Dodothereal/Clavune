# Build and test

## Requirements

- Apple Silicon Mac; deployment target macOS 14.0.
- Xcode or Command Line Tools with a compatible macOS SDK and Swift toolchain.
- Python 3.12+ and CMake available on PATH.
- Network access for the pinned backend source on the first uncached build.

Scripts do not install these tools, acquire signing credentials, enroll in paid
programs, download speech models, launch the app, or change security settings.
The minimum deployment target is not evidence of a successful macOS 14 runtime test.

## Check the build identity first

The normal development configuration uses:

```json
{
  "bundleIdentifier": "org.clavune.development",
  "storageDirectory": "Clavune"
}
```

These fields are in `Config/Product.json`. A comparison build using the fixed
`org.clavune.observatory.qa.20261023.adaptive.main.v3` identifier deliberately
selects synthetic functional QA. It must not be described or distributed as
normal dictation. Do not reuse a comparison app as a normal build, and do not
rewrite an already signed bundle to change identity.

## Portable checks

```sh
python3 -B -m unittest discover -s Tests/Python -v
```

These inspect source contracts and exercise synthetic tooling. They are useful on
Linux, but do not compile Swift, exercise AppKit, validate macOS codecs or run the
native app. Run without Python optimization so integrity assertions remain enabled.

## Native build

```sh
bash Scripts/build-backend.sh
bash Scripts/swift.sh build --jobs 2
bash Scripts/swift.sh test --jobs 2 --no-parallel
bash Scripts/build-app.sh
```

The dependency lock pins the whisper.cpp archive and ordered downstream patches.
Source inventory and hashes are checked before reusing an existing dependency tree.
An unexpected cache is preserved and rejected, not silently trusted or overwritten.
For an already available verified archive, `python3 Scripts/fetch-backend.py --offline`
prepares the source without downloading it. The subsequent CMake configuration uses
static CPU/Accelerate and Metal support, without a server or cloud SDK.

The Swift wrapper keeps its normal sandbox enabled and writes command evidence to
task-owned locations under `.build`. A sandbox/tool error is not a reason to disable
security controls. Do not commit those logs or caches.

Packaging stages an owned app, signs it ad hoc, verifies it and audits its architecture,
minimum OS, resources, licenses and dynamic dependencies before exposing the result
under `artifacts/Clavune.app`. Existing artifacts are preserved. Ad-hoc signing is
not Developer ID signing, notarization or clean-machine installation acceptance.

## Additional native contracts

After the backend inputs have been prepared:

```sh
bash Scripts/test-state-ownership.sh
bash Scripts/test-native-contracts.sh
bash Scripts/test-native-contracts.sh --sanitize
```

These use bounded synthetic/fake resources, not a real microphone, speech model
or GGML/Metal fault injection. Swift offscreen editor tests and native diagnostics
have separate opt-in flags. Read each fixture before enabling it; a count of
discovered tests is not a count of tests executed.

## Known limitations

The latest cloud candidate has not been compiled or run on macOS. The previous
native launch returned `-10827` / Cocoa error `259`; its cause remains unresolved.
Real Open/Save/Cancel, marked-text composition and visible UI acceptance remain
separate gates. See [validation status](VALIDATION.md). Do not publish a binary or
claim a successful native build based on the portable checks alone.

## Manual native workflow

The existing self-hosted workflow is manual-only and has a job-level guard that
requires the event repository to be private. **For dispatch events created while
the repository is public, that job is skipped before it is sent to a runner.**
This event-time guard does not cancel private-repository jobs already queued or
running; recheck those before changing visibility. A skipped check is not a
passing native test or verified public CI. No public runner, automatic PR workflow,
paid compute or new access is configured by this source proposal. Establishing
public native CI requires a separately reviewed, appropriately isolated runner.
