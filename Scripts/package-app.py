"""Assemble a portable development bundle. Does not launch, notarize or publish."""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


def _publish_exclusive(staged: Path, destination: Path) -> None:
    """Same-filesystem publication that cannot overwrite an existing final entry."""
    if sys.platform != "darwin":
        raise OSError("Atomic development-app publication requires macOS.")
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # RENAME_EXCL = 0x4, available since macOS 10.12; do not emulate with racy exists/rename.
    if rename(os.fsencode(staged), os.fsencode(destination), 0x4) != 0:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise FileExistsError(code, "Existing app artifact preserved.", str(destination))
        raise OSError(code, os.strerror(code), str(destination))


def package_app(root: Path, binary_directory: Path, *, run=None, publish=None) -> Path:
    """Sign/audit an owned staging app, then expose its final name only after success."""
    root = root.resolve()
    binary_directory = binary_directory.resolve()
    product = json.loads((root / "Config/Product.json").read_text())
    name = product["executable"]
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", name):
        raise ValueError("Invalid app executable identity.")
    artifacts = root / "artifacts"
    if artifacts.is_symlink():
        raise ValueError("The project artifact directory must not be a symlink.")
    artifacts.mkdir(exist_ok=True)
    destination = artifacts / (name + ".app")
    if destination.exists() or destination.is_symlink():
        raise FileExistsError("Existing app artifact preserved. Move it aside before packaging another build.")
    runner = run if run is not None else subprocess.run
    publisher = publish if publish is not None else _publish_exclusive
    staging = Path(tempfile.mkdtemp(prefix="." + name + "-stage-", dir=artifacts))
    staged_app = staging / (name + ".app")
    try:
        contents = staged_app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        resources = contents / "Resources"
        resources.mkdir()
        shutil.copy2(binary_directory / name, contents / "MacOS" / name)
        shutil.copytree(binary_directory / (name + "_ClavuneCore.bundle"),
                        resources / (name + "_ClavuneCore.bundle"))
        shutil.copytree(root / "ThirdPartyLicenses", resources / "ThirdPartyLicenses")
        shutil.copy2(root / "THIRD_PARTY_NOTICES.md", resources / "THIRD_PARTY_NOTICES.md")
        info = {
            "CFBundleName": product["displayName"], "CFBundleDisplayName": product["displayName"],
            "CFBundleIdentifier": product["bundleIdentifier"], "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": product["version"],
            "CFBundleVersion": product["build"], "LSMinimumSystemVersion": "14.0",
            "LSUIElement": True, "NSHighResolutionCapable": True,
            "ProductStorageDirectory": product["storageDirectory"],
            "NSMicrophoneUsageDescription": product["displayName"] + " benötigt das Mikrofon ausschließlich für bewusst gestartete lokale Diktate.",
        }
        with (contents / "Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        # Ad-hoc only: no identity, credentials, network submission or paid enrollment.
        runner(["/usr/bin/codesign", "--sign", "-", "--options", "runtime",
                "--entitlements", str(root / "Config/Development.entitlements"), str(staged_app)], check=True)
        runner(["/usr/bin/codesign", "--verify", "--strict", str(staged_app)], check=True)
        runner([sys.executable, str(root / "Scripts/audit-bundle.py"), str(staged_app)], check=True)
        publisher(staged_app, destination)
        return destination
    finally:
        # Only this invocation's uniquely owned container is cleaned, never the final app.
        if staging.is_symlink():
            staging.unlink()
        elif staging.exists():
            shutil.rmtree(staging)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    bundle = package_app(root, Path(args.bin_dir))
    print("Development app:", bundle.relative_to(root))


if __name__ == "__main__":
    main()
