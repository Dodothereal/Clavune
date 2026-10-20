"""Extract exact pinned batch source; prepare no-backend native contract inputs.

This performs source verification/file generation only. It never compiles, loads
an app/backend/model, downloads files or edits the dependency source tree.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".build/native-contracts/generated"
MANIFEST = "Tests/Native/ProductionBatchInputs.json"
DEPENDENCY = ".build/deps/whisper.cpp/"
FIXTURE_INPUTS = [
    MANIFEST, "Scripts/prepare-native-contract-inputs.py", "Scripts/test-native-contracts.sh",
    "Tests/Native/NativeContractChecks.h", "Tests/Native/ProductionBatchTests.cpp",
    "Tests/Native/BridgeContractTests.cpp", "Sources/NativeBridge/WhisperBridge.cpp",
    "Sources/NativeBridge/include/ClavuneBridge.h",
]
FIXTURE_FINGERPRINT = "b" * 64


class InputError(RuntimeError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_regular(relative):
    path = ROOT / relative
    if (not path.resolve().is_relative_to(ROOT) or path.is_symlink() or not path.is_file()
            or path.stat().st_size > 2 * 1024 * 1024):
        raise InputError("Missing, oversized or unsafe input: " + relative)
    return path.read_bytes()


def single_index(source, marker):
    if source.count(marker) != 1:
        raise InputError("Expected source boundary is absent or ambiguous.")
    return source.index(marker)


def function_slice(source, marker, ending):
    start = single_index(source, marker)
    end = source.find(ending, start)
    if end < start:
        raise InputError("Expected source terminator is absent.")
    return source[start:end + len(ending)]


def verified_inputs():
    expected = json.loads(read_regular(MANIFEST))
    if expected.get("schemaVersion") != 1:
        raise InputError("Unsupported fixture input manifest.")
    snapshots = {}
    for name, wanted in expected["files"].items():
        data = read_regular(name)
        if digest(data) != wanted:
            raise InputError("Pinned fixture input drift; review required: " + name)
        snapshots[name] = data
    lock = json.loads(snapshots["Dependencies.lock.json"])["whisperCpp"]
    if (lock["commit"] != expected["commit"] or
            lock["sourceArchiveSHA256"] != expected["archiveSHA256"]):
        raise InputError("Dependency identity differs from the reviewed fixture.")
    for patch in lock["patches"]:
        data = read_regular(patch["path"])
        if digest(data) != patch["sha256"]:
            raise InputError("Locked patch input drift: " + patch["path"])
        snapshots[patch["path"]] = data
    # The stamp alone never confers trust: all consumed source/header bytes above
    # must independently match the reviewed fixture's fixed hashes.
    provenance = json.loads(read_regular(DEPENDENCY + ".clavune-source-provenance.json"))
    if (provenance["commit"] != lock["commit"] or provenance["patches"] != lock["patches"]
            or provenance["sourceArchiveSHA256"] != lock["sourceArchiveSHA256"]):
        raise InputError("Prepared-source provenance differs from the locked inputs.")
    for name in expected["files"]:
        if name.startswith(DEPENDENCY):
            entry = provenance["inventory"].get(name[len(DEPENDENCY):], {})
            if entry.get("kind") != "file" or entry.get("sha256") != digest(snapshots[name]):
                raise InputError("Consumed source disagrees with verified inventory: " + name)
    source = snapshots[DEPENDENCY + "src/whisper.cpp"]
    start = single_index(source, b"struct whisper_batch {\n")
    end = single_index(source, b"\nstatic void whisper_batch_prep_legacy(")
    if end <= start:
        raise InputError("Production batch boundaries are out of order.")
    parts = {
        "structure": function_slice(source, b"struct whisper_batch {\n", b"\n};\n"),
        "init": function_slice(source, b"static struct whisper_batch whisper_batch_init(", b"\n}\n"),
        "free": function_slice(source, b"static void whisper_batch_free(struct whisper_batch batch) {", b"\n}\n"),
        "coupled_batch": source[start:end],
    }
    actual_slices = {name: {"bytes": len(data), "sha256": digest(data)} for name, data in parts.items()}
    if actual_slices != expected["slices"]:
        raise InputError("Exact production batch structure/function hashes drifted.")
    for name in FIXTURE_INPUTS:
        snapshots[name] = read_regular(name)
    generated = {
        "ClavuneProductionBatch.inc": parts["coupled_batch"],
        "ClavuneBackendFingerprint.h": (
            "// Test fingerprint only; no production backend is linked.\n"
            '#define CLAVUNE_BACKEND_FINGERPRINT "' + FIXTURE_FINGERPRINT + '"\n'
        ).encode(),
    }
    report = {
        "schemaVersion": 1, "backendLinked": False, "modelsLoaded": False,
        "sourceCommit": lock["commit"], "sourceTreeSHA256": provenance["treeSHA256"],
        "sourceSlices": actual_slices,
        "compiledInputs": {name: digest(data) for name, data in sorted(snapshots.items())},
        "generatedInputs": {name: digest(data) for name, data in generated.items()},
        "batchAllocationSeams": ["whisper_checked_malloc allocator argument", "free call boundary"],
        "bridgeWhisperSymbols": "real declarations with test implementations; no libwhisper or GGML library",
        "fixtureFingerprint": FIXTURE_FINGERPRINT,
    }
    generated["compile-inputs.json"] = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode()
    return generated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    generated = verified_inputs()
    if not OUTPUT.resolve().is_relative_to(ROOT) or OUTPUT.is_symlink():
        raise InputError("Unsafe fixture output directory.")
    if not args.verify_only:
        OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, data in generated.items():
        target = OUTPUT / name
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise InputError("Unsafe generated fixture entry: " + name)
        if args.verify_only:
            if not target.is_file() or target.read_bytes() != data:
                raise InputError("Fixture inputs changed after preparation: " + name)
        else:
            target.write_bytes(data)
    print("Native contract inputs verified; exact batch source and real bridge inputs recorded.")


if __name__ == "__main__":
    try:
        main()
    except (InputError, KeyError, ValueError, OSError) as error:
        print("Native contract input preparation refused: " + str(error), file=sys.stderr)
        raise SystemExit(2)
