"""Validate only resources physically shipped in the explicitly supplied app.

No source tree, build directory, environment override, Bundle.main fallback or
application execution is used here.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import re


class ResourceValidationError(ValueError):
    pass


def _require_path(root: Path, path: Path, *, directory: bool = False) -> Path:
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise ResourceValidationError("Resource path escapes the app bundle.") from error
    candidate = root
    for part in relative.parts:
        candidate = candidate / part
        if candidate.is_symlink():
            raise ResourceValidationError("Symlinked packaged resources are not accepted.")
    if not path.resolve().is_relative_to(root):
        raise ResourceValidationError("Resource path resolves outside the app bundle.")
    if directory and not path.is_dir():
        raise ResourceValidationError("Required packaged resource directory is missing.")
    if not directory and not path.is_file():
        raise ResourceValidationError("Required packaged resource file is missing.")
    return path


def _read_bounded(root: Path, path: Path) -> bytes:
    _require_path(root, path)
    with path.open("rb") as source:
        data = source.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise ResourceValidationError("Packaged metadata exceeds the 1-MiB audit budget.")
    return data


def _integer_between(value: object, low: int, high: int) -> bool:
    return type(value) is int and low <= value <= high


def _validate_policy(policy: object) -> None:
    if not isinstance(policy, dict):
        raise ResourceValidationError("Resource policy must be a JSON object.")
    bounds = {
        "sessionLimitSeconds": (1, 120),  # Retain the native bridge's independent hard limit.
        "ringSlots": (2, 128),
        "maxNativeBlockFrames": (128, 16384),
        "pumpIntervalMilliseconds": (1, 100),
        "maxInputChannels": (1, 32),
        "inferenceThreads": (1, 8),
    }
    if type(policy.get("schemaVersion")) is not int or policy["schemaVersion"] != 1:
        raise ResourceValidationError("Unsupported packaged policy schema.")
    if type(policy.get("sampleRate")) is not int or policy["sampleRate"] != 16000:
        raise ResourceValidationError("Packaged PCM rate must be 16000 Hz.")
    if any(not _integer_between(policy.get(key), *span) for key, span in bounds.items()):
        raise ResourceValidationError("Packaged resource policy contains invalid bounds.")
    for key, low, high in [
        ("firstBufferTimeoutSeconds", 0.1, 10),
        ("stopDrainTimeoutSeconds", 0.1, 5),
    ]:
        value = policy.get(key)
        if type(value) not in {int, float} or not low <= value <= high:
            raise ResourceValidationError("Packaged timeout bounds are invalid.")
    if type(policy.get("activeInferenceJobs")) is not int or policy["activeInferenceJobs"] != 1:
        raise ResourceValidationError("Packaged baseline must admit one inference job.")
    if policy.get("previewEnabled") is not False:
        raise ResourceValidationError("Packaged batch baseline must keep previews disabled.")


def _validate_candidates(manifest: object) -> None:
    if not isinstance(manifest, dict):
        raise ResourceValidationError("Candidate manifest must be a JSON object.")
    if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1:
        raise ResourceValidationError("Unsupported packaged candidate schema.")
    if manifest.get("releaseApproved") is not False or manifest.get("defaultModel") is not None:
        raise ResourceValidationError("This development manifest must not promote a default or release.")
    models = manifest.get("models")
    if not isinstance(models, list) or not 1 <= len(models) <= 16:
        raise ResourceValidationError("Packaged model candidate list is missing or unbounded.")
    names, hashes = set(), set()
    for model in models:
        if not isinstance(model, dict):
            raise ResourceValidationError("Candidate entry must be a JSON object.")
        name, digest = model.get("fileName"), model.get("sha256")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.bin", name):
            raise ResourceValidationError("Invalid packaged model filename.")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ResourceValidationError("Invalid packaged model SHA-256.")
        if name in names or digest in hashes:
            raise ResourceValidationError("Duplicate packaged model identity.")
        if not _integer_between(model.get("sizeBytes"), 1, 16 * 1024 * 1024 * 1024):
            raise ResourceValidationError("Invalid packaged model size.")
        if model.get("qualityGate") != "unmeasured" or model.get("license") != "MIT":
            raise ResourceValidationError("Unexpected candidate quality/license state.")
        names.add(name)
        hashes.add(digest)


def validate_packaged_resources(app_bundle: Path, executable: str) -> dict[str, object]:
    if app_bundle.is_symlink() or not app_bundle.is_dir():
        raise ResourceValidationError("An explicit nonsymlink app directory is required.")
    root = app_bundle.resolve()
    if not isinstance(executable, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", executable):
        raise ResourceValidationError("Invalid app executable identity.")
    name = executable + "_ClavuneCore"
    resource_bundle = root / "Contents" / "Resources" / (name + ".bundle")
    _require_path(root, resource_bundle, directory=True)
    try:
        info = plistlib.loads(_read_bounded(root, resource_bundle / "Contents" / "Info.plist"))
    except (plistlib.InvalidFileException, ValueError, TypeError) as error:
        raise ResourceValidationError("Packaged resource bundle metadata is invalid.") from error
    if not isinstance(info, dict) or info.get("CFBundleName") != name or info.get("CFBundlePackageType") != "BNDL":
        raise ResourceValidationError("Packaged resource bundle identity does not match the app.")
    resources = resource_bundle / "Contents" / "Resources" / "Resources"
    _require_path(root, resources, directory=True)
    payloads = {}
    for filename in ["resource-policy.json", "candidates.json"]:
        data = _read_bounded(root, resources / filename)
        try:
            payloads[filename] = (json.loads(data), hashlib.sha256(data).hexdigest())
        except (ValueError, UnicodeError) as error:
            raise ResourceValidationError("Packaged JSON metadata is malformed.") from error
    _validate_policy(payloads["resource-policy.json"][0])
    _validate_candidates(payloads["candidates.json"][0])
    return {
        "resourceBundle": str(resource_bundle.relative_to(root)),
        "sha256": {name: value[1] for name, value in payloads.items()},
        "lookup": "explicit-packaged-tree-only",
    }
