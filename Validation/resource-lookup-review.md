# Packaged resource lookup review

Reviewed generated Swift 6.4 accessors for the current Clavune Debug and Release builds. Paths below replace the private project root with the PROJECT placeholder.

    <PROJECT>/.build/swift/out/Intermediates.noindex/Clavune.build/Debug/ClavuneCore-t.build/DerivedSources/resource_bundle_accessor.swift
    <PROJECT>/.build/swift/out/Intermediates.noindex/Clavune.build/Release/ClavuneCore-t.build/DerivedSources/resource_bundle_accessor.swift

Both generated source files contain this lookup:

    let bundleName = "Clavune_ClavuneCore"
    let candidates = overrides + [
        Bundle.main.resourceURL,
        Bundle(for: BundleFinder.self).resourceURL,
        Bundle.main.bundleURL,
    ]

The accessor appends Clavune_ClavuneCore.bundle to each candidate. No mainPath, buildPath, absolute source directory or absolute build-directory fallback occurs in either current accessor.

The generated source includes conditional DEBUG-only PACKAGE_RESOURCE_BUNDLE_PATH and PACKAGE_RESOURCE_BUNDLE_URL environment overrides. The Release branch sets overrides to an empty array.

Scripts/package-app.py places the resource bundle at:

    Clavune.app/Contents/Resources/Clavune_ClavuneCore.bundle

This matches the first app lookup candidate. The resource bundle contains:

    Contents/Resources/Resources/resource-policy.json
    Contents/Resources/Resources/candidates.json

The second Resources component comes from the package's copy of the Resources directory; the core's Resources subdirectory lookups match it. No placement mismatch was found. The generated resource bundle's identifier still derives from the original local project directory; its CFBundleName and the actual lookup name are Clavune_ClavuneCore.

Added an independent packaged-tree validator invoked by Scripts/audit-bundle.py. It accepts only an explicit app tree, checks physical resource placement and bundle identity, rejects symlinks, validates the bounded JSON payloads and reports their SHA-256 hashes. It has no source/build search, development fallback, environment lookup or application execution.

Seven isolated Python fixtures cover valid payload hashes/shapes, a missing packaged file with a valid development decoy, invalid policy/hash, duplicate model identity, symlink escape and malformed JSON. These fixtures use synthetic metadata only. They have not been executed by this reviewer; the parent will run validation sequentially. No app launch, microphone access, permission prompt, model inference or clipboard operation was performed.

## Root execution evidence

Root ran all seven packaged-resource Python fixtures within the 23-test suite and audited the prior baseline app from its supplied packaged tree without a development lookup. Final corrected bundle evidence is recorded in checkpoint.json.

This evidence is physical-tree validation in Python plus generated-accessor inspection. It is not an executed relocated Swift lookup or a launched app. The follow-up Release artifact was built with the same Swift 6.4 default swiftbuild engine in an owned temporary namespace; its packaged tree is audited independently. Runtime resource lookup on a clean supported Mac remains a release gate.
