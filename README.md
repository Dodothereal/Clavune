# Clavune

**An experimental, local-first speech-to-text app for Apple Silicon Macs.**

Clavune combines a SwiftUI/AppKit interface with an embedded whisper.cpp backend.
The aim is a simple workflow: record or import audio, transcribe on your Mac,
review the text, and deliberately copy or save it.

> **Development source, not a supported release.** Native launch and several
> Open/Save/IME workflows remain unresolved. There is no notarized download and
> the latest cloud-reviewed changes have not passed native Swift compilation or
> the complete macOS test suite. See [validation status](Docs/VALIDATION.md).

## What's in the source

- Native recording and review UI, editable transcript, explicit copy and UTF-8 save.
- Local audio-file import: WAV, MP3, supported AAC and ALAC containers.
- A bounded, 120-second batch pipeline; imported audio exceeding the limit is rejected.
- Deliberate model import/download with exact size and SHA-256 verification.
- A local statistics view backed by content-free, on-device metrics.
- Synthetic regression fixtures for cancellation, resource ownership, file handling,
  model installation and editor behavior.

There is no account, remote transcription service, telemetry upload, automatic
paste into other apps, or automatic model download. This is not streaming dictation
and there is no validated default model or accuracy/performance promise.

## Build from source

The native app targets **Apple Silicon and macOS 14 or newer**. Building requires
Xcode or Command Line Tools with a suitable macOS SDK, CMake, and Python 3.12+.
Linux can run the portable Python checks, not the macOS app.

```sh
python3 -B -m unittest discover -s Tests/Python -v
bash Scripts/build-app.sh
```

The app build downloads the pinned whisper.cpp **source dependency** when needed;
it does not download speech models. It creates an ad-hoc-signed development app,
not a notarized release, and does not launch it. Read the
[build guide](Docs/BUILD.md) before running it. Do not disable Gatekeeper or other
system protections to work around launch failures.

## Models and privacy

Model weights are not included. Import a matching local model or explicitly choose
a catalogue download. The catalogue currently contains files from roughly 574 MB
to 3.10 GB; those are disk sizes, not RAM requirements. A verified hash identifies
the selected artifact—it does not certify quality or runtime compatibility.

Recognition is intended to run locally after model setup. The explicit model
download is the app's network path; audio and transcripts are not uploaded by that
path. Transcripts persist only when you explicitly save them. Clipboard managers
and the destination folder's synchronization rules are outside Clavune's control.

**Local metrics are enabled by default, without a user-facing off switch.** They
contain timing, model/language identifiers, outcomes and counts, not transcript
text or audio. See [Privacy](PRIVACY.md) for storage, limits and caveats.

## Contributing

Small, reproducible fixes are welcome. Use generated fixtures, preserve cancellation
and privacy guarantees, and distinguish source checks from actual native execution.
See [Contributing](CONTRIBUTING.md) and [Security](SECURITY.md).

## License

The project includes an [MIT license](LICENSE). Backend and model notices are
listed separately in [Third-party notices](THIRD_PARTY_NOTICES.md). Model weights,
Apple frameworks and system symbols are not relicensed by the project license.
