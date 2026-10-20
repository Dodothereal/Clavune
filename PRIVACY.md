# Privacy

Clavune transcribes on the Mac with an embedded whisper.cpp backend. The current application has no network client, telemetry, account, cloud inference, automatic updater, or hidden fallback.

Recording starts only after an explicit app or enabled-hotkey action and microphone permission. The microphone is stopped before inference. Idle does not capture pre-roll. The first usable buffer is distinguished from an engine start. Device changes, sleep, session resignation, cancellation, missing buffers, overflow, and the session limit close capture.

Audio and transcripts stay in bounded memory during the current session. They are not deliberately written to recording, history, log, or temporary WAV files. Models are deliberately imported as verified copies into the app's model directory. macOS may use swap and framework caches; in-memory processing is not a guarantee of forensic erasure or no physical storage.

The default development session limit is 120 seconds. An overflow, limit, or unconfirmed endpoint produces an error and no falsely complete transcript. Recording may remain in a clearly displayed stopping phase for up to the provisional drain timeout to receive samples through the fixed cutoff; samples after cutoff are excluded.

The preview is editable and has automatic spelling, quotes, dashes, and text replacements disabled. Raw recognition output is retained separately for the current session. No automatic semantic rewriting or translation is applied.

Copy is explicit and deliberately replaces the clipboard. It uses the current-host-only option and performs no automatic restoration. Other local applications and clipboard managers may read it. Text manually pasted into another application follows that application's storage and synchronization rules.

External insertion and automatic clipboard transfer are not enabled. The current insertion code is a policy foundation tested with isolated metadata fixtures. No Accessibility permission is requested by this checkpoint.

No default content diagnostics are persisted. In-memory milestones contain timestamps, sample counts, and load/decode durations, not spoken words, model paths, clipboard contents, or target text.
