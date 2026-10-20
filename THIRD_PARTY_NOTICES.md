# Third-party notices

Clavune is a provisional product name. The repository is private; this document is an initial inventory, not public release clearance.

| Component | Version / provenance | License | Distribution |
| --- | --- | --- | --- |
| whisper.cpp and its included ggml sources | v1.9.5, commit d1be6fde11ac6e0407606b4e42fe72d34add8037; full source archive locked in Dependencies.lock.json | MIT | Statically linked. License in ThirdPartyLicenses/whisper.cpp-MIT.txt |
| OpenAI Whisper model candidates | File SHA-256 and sizes in Sources/ClavuneCore/Resources/candidates.json | MIT | No weights bundled or downloaded. Original license in ThirdPartyLicenses/Whisper-MIT.txt |
| Apple system frameworks and SF Symbols system images | Supplied by macOS | Apple platform terms | System APIs/images used in the native app; no separately copied symbol artwork, font or framework |

The Whisper license text was retrieved at upstream openai/whisper commit 86098128c0b4f24f0e2aa2994de830614b474227. Model conversion revision and runtime compatibility still need verification for release; the manifest marks them unverified. A matching hash establishes file identity against the recorded metadata, not an independent provenance or quality certification.

No other UI framework, VAD model, updater, cloud SDK, icon package, or second inference backend is included.
