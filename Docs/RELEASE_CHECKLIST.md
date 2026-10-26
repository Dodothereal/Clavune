# Release gates

An experimental **source publication** and a supported **binary release** have
different requirements. The current owner decisions and source/privacy/CI gates
are in [Publication checklist](PUBLICATION_CHECKLIST.md). Current test limitations
are in [Validation status](VALIDATION.md).

Before distributing a supported binary, additionally verify:

- [ ] Exact-source native compilation and targeted/full regression suites.
- [ ] Normal launch, Open/Save/Cancel/Quit, IME composition, selection and Undo/Redo.
- [ ] Supported macOS versions and clean Apple Silicon installations without build tools.
- [ ] Real microphone endpoints, first-buffer/stop-tail behavior, device/route changes,
      permission changes, hotkeys, Sleep/Wake and cancellation.
- [ ] Model conversion provenance/license, runtime compatibility and documented quality
      gates for German, English, code-switching, numbers, negations and noisy/silent audio.
- [ ] Source-bound timings and resource measurements, without substituting disk size
      for RAM or synthetic timings for recognition performance.
- [ ] Actual bundle resources, dependency licenses, embedded paths and runtime privacy.
- [ ] Separately authorized signing/notarization and clean-machine acceptance of the
      exact final artifact, with source/build identity and hashes recorded.

Source review or a green portable suite alone satisfies none of the missing native
gates. Do not change public visibility, acquire credentials/paid enrollment, submit
notarization or distribute a binary without the relevant explicit authorization.
