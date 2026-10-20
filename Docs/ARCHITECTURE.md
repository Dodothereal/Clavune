# Current architecture

Native menu-bar shell and a nonactivating recording/review panel depend on a MainActor coordinator. Presentation, product identity and editor configuration are separate from the core. SF Symbols are system-provided icons. Transition animation is event-driven and disabled for Reduce Motion; no idle animation timer exists.

The AVAudioEngine capture control queue creates one session. The input is captured at the native negotiated Float32 planar format. A deliberately selected input channel enters a preallocated C++ SPSC ring. The callback copies metadata and valid frames only. The worker detects gaps/loss, converts one continuous stream through AVAudioConverter to 16-kHz mono Float32, and stores it in one bounded allocation.

At stop, a monotonic cutoff is fixed. Capture stays visibly stopping until timestamp coverage reaches cutoff or times out. Audio after cutoff is trimmed. The engine/tap are stopped before converter drain and inference. A timeout or gap is an error. Physical endpoint preservation still requires device tests, especially Bluetooth; successful synthetic timeline tests are not hardware proof.

The final PCM handoff makes one bounded copy into an immutable Swift value. There are no preview snapshots or pending preview jobs. A serial inference queue owns one selected model context. The C bridge allocates fresh decoder state per call and uses a separately owned atomic cancellation token; no previous-session prompt context survives. A future workspace reuse optimization requires measured quality/latency evidence.

Batch decoder profile: multilingual transcription, Auto/de/en modes, no translation, no context carry, no prompt, greedy best_of=1, temperature=0, temperature_inc=0, VAD off, audio_ctx=0, no max-token truncation, Flash Attention off, two CPU threads, Metal enabled. Other heuristic thresholds retain pinned upstream defaults and are not yet quality-promoted. Full effective-parameter export and fallback accounting are still a release gate.

SessionMachine guards stale IDs and legal result transitions. The app prevents another operation while current work drains. Content-free milestones distinguish request, first source sample, cutoff, closed capture and final text. No insertion milestone is claimed.

Model import is deliberate, bounded and cancellable, hash checked, and separate from recognition. Four known candidates have no default or promoted quality status. Model selection is currently session-only; restoring an installed selection on relaunch is outstanding usability work.

The M2 insertion code is policy-only. Its isolated fixtures cover changed target/revision, nonempty selections, unsupported SelectedText, secure/unknown/terminal fields and exactly-once reservation. A real AX adapter, continuously invalidated target observation, configurable hotkey recorder and any clipboard transfer must pass further fixtures before activation.
