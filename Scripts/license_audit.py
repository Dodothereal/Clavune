"""Check development-app license/notice inventory against exact local source bytes.

This does not assess legal sufficiency, upstream provenance, Developer ID or notarization.
"""
import hashlib
from pathlib import Path


class LicenseAuditError(ValueError):
    pass


REQUIRED = (
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "ThirdPartyLicenses/Whisper-MIT.txt",
    "ThirdPartyLicenses/whisper.cpp-MIT.txt",
)
MAX_TEXT_BYTES = 1024 * 1024


def _read_regular_bounded(root: Path, relative: str) -> bytes:
    path = root
    for part in Path(relative).parts:
        path = path / part
        if path.is_symlink():
            raise LicenseAuditError("Symlinked license/notice entry: " + relative)
    if not path.is_file():
        raise LicenseAuditError("Missing regular license/notice entry: " + relative)
    with path.open("rb") as stream:
        data = stream.read(MAX_TEXT_BYTES + 1)
    if len(data) > MAX_TEXT_BYTES:
        raise LicenseAuditError("License/notice exceeds audit budget: " + relative)
    return data


def validate_packaged_licenses(source_root: Path, app_bundle: Path) -> dict[str, str]:
    """Reject missing, changed, symlinked, or unexpected third-party license entries."""
    source_root = Path(source_root)
    app_bundle = Path(app_bundle)
    if app_bundle.is_symlink() or not app_bundle.is_dir():
        raise LicenseAuditError("A nonsymlink app directory is required")
    contents = app_bundle / "Contents"
    resources = contents / "Resources"
    license_directory = resources / "ThirdPartyLicenses"
    if (contents.is_symlink() or resources.is_symlink() or license_directory.is_symlink()
            or not license_directory.is_dir()):
        raise LicenseAuditError("Missing regular app license resource directory")
    expected_third_party = {Path(name).name for name in REQUIRED if name.startswith("ThirdPartyLicenses/")}
    actual_third_party = {entry.name for entry in license_directory.iterdir()}
    if actual_third_party != expected_third_party:
        raise LicenseAuditError("Unexpected third-party license inventory")
    digests = {}
    for relative in REQUIRED:
        source = _read_regular_bounded(source_root, relative)
        packaged = _read_regular_bounded(resources, relative)
        if packaged != source:
            raise LicenseAuditError("Packaged license/notice differs from source: " + relative)
        digests[relative] = hashlib.sha256(packaged).hexdigest()
    return digests
