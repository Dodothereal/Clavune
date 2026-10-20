# Security and implementation boundaries

Report suspected security issues privately to the repository owner while this repository is private. A public reporting channel will be specified before release.

- One pinned backend is statically linked. Source retrieval checks the exact archive SHA-256 and rejects unexpected archive paths or links. Core transcription has no downloader.
- Models must match recorded size and SHA-256. Import verifies a new private copy and never changes the source. No arbitrary model is executed as a program.
- The native tap performs a fixed-capacity copy and atomic publication. No file writes, decoder call, heap growth, lock, or Swift task dispatch is performed in the callback.
- One capture session owns a separate ingress, converter and bounded canonical PCM allocation. Decoder state is fresh for each request; weights have a separate serial lifetime. Cooperative cancellation never frees an active context.
- The application blocks re-entry until active work returns. Cancelling inference discards stale results; it cannot promise instantaneous GPU interruption.
- The native bridge independently rejects PCM longer than 120 seconds. Its limit remains unchanged. The bundled development resource policy also caps sessions at 120 seconds; policy changes must remain within this native bound.
- No external AX mutation or synthetic paste adapter is enabled. Selected-text capability, unchanged identity/selection, explicit replacement intent, secure-target blocking and an attempt fence are isolated policy prerequisites.
- SwiftPM sandbox remains enabled. Local cache paths are redirected into the project. In this executor, normal sandboxed builds required tool execution approval because nested sandbox initialization failed inside the outer tool sandbox.
- No TCC, Gatekeeper, SIP, system keyboard setting, login item, paid enrollment, credential or signing identity is changed.

Current review limits: microphone/device timing, route changes, actual cancellation under a loaded model, model compatibility, old-OS behavior, and complete UI lifecycle behavior have not yet been exercised. A code build and synthetic tests do not certify them.
