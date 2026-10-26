# Source publication and binary release are separate gates

## Experimental source repository

- [ ] Bind the proposed public file set to an exact Git commit and review its complete tree.
- [ ] Scan all reachable branch/tag history—not just the default branch—for secrets,
      private paths/content, models, recordings, diagnostic caches and unwanted assets.
- [ ] Review repository metadata, issues/PRs, releases, Actions logs/artifacts and other
      content whose visibility may change with the repository.
- [ ] Confirm the existing MIT license, copyright attribution, dependency notices,
      synthetic-fixture provenance and rights to every included asset/name.
- [ ] Include the exact dependency lock and all hash-matched patches; verify a fresh
      developer setup without relying on private or missing files.
- [ ] Confirm normal development identity rather than an implicit synthetic-QA build.
- [ ] Review CI permissions and self-hosted-runner exposure before making the repository public.
- [ ] Provide an honest README, build steps, privacy disclosure, security reporting path
      and validation status without misleading badges/screenshots/performance claims.
- [ ] Independently review the final source/docs and rerun applicable tests on that exact tree.
- [ ] Obtain explicit owner approval for the exact push and visibility change.

A clean heuristic scan is useful evidence, not a guarantee of no secrets. Removing
a sensitive file from the current tree does not remove it from Git history or logs.
Do not rewrite or delete history, rotate credentials, change access, or publish
without the relevant explicit authorization.

## Supported binary release — additional work

- [ ] Pass exact-source native compilation and targeted/full regression suites.
- [ ] Resolve launch, real file-panel, IME/Undo, capture/cancel and lifecycle issues.
- [ ] Validate supported macOS versions and clean Apple Silicon Macs without build tools.
- [ ] Establish model provenance, compatibility, quality and resource measurements.
- [ ] Inspect actual bundle inventory, licenses, embedded paths and runtime privacy behavior.
- [ ] Obtain authorized signing/notarization and verify the final distributable on a clean Mac.
- [ ] Record source/build/toolchain identity, artifact hashes and remaining limitations.

No supported binary release is claimed by the current source preview.
