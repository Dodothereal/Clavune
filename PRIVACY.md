# Privacy

This describes the reviewed source design, not a runtime audit of a released app.
Clavune is experimental; see [validation status](Docs/VALIDATION.md).

## Audio and transcription

Recognition uses an embedded local whisper.cpp backend after a model has been
installed. There is no account, remote transcription fallback, telemetry upload,
automatic updater, or automatic model download.

Recording requires an explicit app/enabled-hotkey action and microphone permission.
There is no idle pre-roll. Audio is processed in bounded memory rather than
deliberately saved as recordings or temporary WAV files. Live recording is capped
at 120 seconds; only a valid contiguous prefix through that limit is transcribed.
An unconfirmed endpoint, overflow or continuity error fails closed.

Explicit audio import reads the selected supported file, up to 64 MiB and 120
seconds. Overlong decoded audio is rejected, not silently truncated. Import does
not open the microphone or modify the original file. The app does not deliberately
retain an audio copy or import-path history. A selected file may itself be located
on a network/synchronized provider.

Local processing is not secure erasure. macOS, decoders and filesystem providers
may use caches, swap or other storage outside these application guarantees.

## Model setup and network access

Model import makes and verifies a managed copy; the original is not changed.
Downloads happen only after a deliberate catalogue choice. The downloader uses
pinned HTTPS Hugging Face source revisions and permits HTTPS redirects only to
the explicit delivery hosts `huggingface.co`, `cdn-lfs.huggingface.co`,
`cas-bridge.xethub.hf.co` and `transfer.xethub.hf.co`.

Those servers receive ordinary request/network metadata such as the model URL
and the client's IP address. Audio and transcript contents are not part of the
download request. Partial model bytes and a small resume record can remain locally;
validated resume requires a matching strong ETag, otherwise transfer restarts.
Exact file size and SHA-256 are checked before activation. Do not delete unknown
recovery files merely to force a retry.

No model weights are bundled, selected as a validated default, or certified for
quality/runtime compatibility by the current catalogue.

## Transcripts and clipboard

The editable transcript and raw recognition result are held for the current session.
There is no autosave, automatic transcript history, or automatic reopening.
Open reads a deliberately selected UTF-8 file up to 4 MiB; successful replacement
requires the app's review-protection policy. Native Open/Cancel/IME behavior is
still under validation.

Save writes only the selected edited-text snapshot. It uses a private-mode temporary
sibling and atomic replacement after a successful write. A crash can leave a staging
file; a committed write cannot be undone by later cancellation. This is not encryption,
backup, ACL isolation, secure erasure or a power-loss durability guarantee. The
destination's access controls and synchronization—including iCloud/network folders—
still apply. macOS file panels may retain location metadata.

Copy deliberately replaces the clipboard using a current-host-only option. Other
local apps and clipboard managers may read it. Copy does not save a document.
No automatic external paste or Accessibility text insertion is enabled.

## Local metrics and statistics

**Production metrics are on by default, with no user-facing off switch.** When
private Application Support storage is available, the app keeps a local append-only,
schema-versioned JSONL journal with a new segment per launch and a 10 MiB total
ceiling. It does not prune old history. If the writer cannot acquire ownership,
storage is full, or privacy checks fail, metrics stop without blocking dictation.
Synthetic QA profiles suppress production journal writes.

Records contain session outcomes, requested/detected language identifiers, model
filename/hash, backend fingerprint, audio rates/duration/frame counts when known,
word/revision counts, pipeline timings, and explicit review-action outcomes. They
do not store transcript text, audio, selected paths, clipboard contents, window
titles, or arbitrary error descriptions. No metrics are sent off the Mac.

WPM uses the full audio duration including pauses; it is not speaking-only speed.
Editor revision count is not a count of corrected words. CPU time is a process
delta; high-water RSS is a process-wide observation, not an isolated session peak.
These statistics are not accuracy/WER or energy measurements.

The statistics export action is deliberate and writes a local export to a user-chosen
destination. Treat even content-free model/language/use metadata as potentially
sensitive before sharing it; destination-folder synchronization rules still apply.

## Remaining verification

This source description does not establish the contents of a built binary, actual
runtime file/network behavior, clean-machine installation or complete UI acceptance.
Native build, launch, file-panel, IME and real-device tests remain separate gates.
