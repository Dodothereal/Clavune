# Contributing

Clavune is an experimental macOS application. Prefer small changes with a clear
failure case, a regression test and an exact description of what was actually run.

## Before a change

1. Read [Build](Docs/BUILD.md), [Privacy](PRIVACY.md) and [Security](SECURITY.md).
2. Identify the commit and affected workflow. Keep unrelated fixes separate.
3. Use synthetic text/audio and temporary directories owned by the test. Do not
   include private recordings, transcripts, home-directory paths, credentials,
   model weights or build logs in a contribution.

## Tests and evidence

Run `python3 -B -m unittest discover -s Tests/Python -v`. Native changes also need
the applicable macOS Swift/native suites and a broader regression pass after
integration. Keep pass, fail, skip, timeout and never-run results distinct.

- Do not weaken assertions, substitute sleeps for synchronization, or count a
  timeout/compiler failure as a reproduced product defect.
- Wait for admitted work to drain before deleting its resources. A cancellation
  request alone does not establish resource release.
- Preserve exact bytes, Unicode/IME composition, selection and Undo/Redo when
  changing editor/file boundaries.
- A source assertion is not an execution test. A fake-service test is not a real
  microphone/model test. Historical evidence does not validate a different tree.

Do not run untrusted pull-request code on a personal/self-hosted machine. Native
validation workflows require a separately authorized, appropriate runner.

## Reporting a problem

Provide the source revision, macOS/toolchain versions, reproducible steps and a
small synthetic example. Review diagnostics before sharing them; remove private
paths and content. For vulnerabilities, follow [Security](SECURITY.md) rather than
posting sensitive details in a public issue.
