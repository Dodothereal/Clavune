# Release gates

- [ ] User-approved name, copyright/license and destination reviewed; practical collision screen is not legal trademark clearance.
- [ ] M1 microphone, first-buffer, stop-tail and cancel behavior tested on real supported devices without ambient capture.
- [ ] macOS 14 and current supported OS clean-Mac tests, including Apple Silicon without Xcode/Homebrew/Python.
- [ ] Model conversion provenance/license and engine compatibility verified; no placeholder provenance in a release manifest.
- [ ] German, English, code-switching, technical terms, numbers and negations evaluated against manually verified references; standard model chosen only after quality gates.
- [ ] Silence, noise, short audio, endpoint words and long-session resource behavior tested.
- [ ] Full decoder parameters and any internal retry work exported without content.
- [ ] Current/peak memory, CPU, energy and load measured separately for shell, weights and active inference; actual first-sample, stop-to-text and verified insertion endpoints reported.
- [ ] Configurable hotkeys, lost-up events, Secure Input, Sleep/Wake, route changes, permission revocation and model cancellation validated.
- [ ] Real insertion adapters and selection/clipboard races tested in isolated fixtures; no unchecked AXValue write, blind retry or timer-only restore.
- [ ] Portable release bundle and all linked resource licenses audited.
- [ ] Public file set excludes plans, private paths, personal audio/logs, credentials and diagnostic caches.
- [ ] Authorized Developer-ID identity, Hardened Runtime, notarized outer DMG and clean supported Mac installation verified.
- [ ] Release artifact provenance, hashes and source archive recorded.

Do not publish, change visibility, create paid enrollment, generate credentials, sign with a new identity, or submit notarization from this development checkpoint.
