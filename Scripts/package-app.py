"""Assemble a portable development bundle. Does not launch, notarize or publish."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--bin-dir", required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
product = json.loads((root / "Config/Product.json").read_text())
name = product["executable"]
binary_directory = Path(args.bin_dir).resolve()
bundle = root / "artifacts" / (name + ".app")
if bundle.exists():
    raise SystemExit("Existing app artifact preserved. Move it aside before packaging another build.")
contents = bundle / "Contents"
(contents / "MacOS").mkdir(parents=True)
resources = contents / "Resources"
resources.mkdir()
shutil.copy2(binary_directory / name, contents / "MacOS" / name)
shutil.copytree(binary_directory / (name + "_ClavuneCore.bundle"), resources / (name + "_ClavuneCore.bundle"))
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
# Ad-hoc development signing: no identity, credential, network submission, or paid enrollment.
subprocess.run(["/usr/bin/codesign", "--sign", "-", "--options", "runtime",
                "--entitlements", str(root / "Config/Development.entitlements"), str(bundle)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)], check=True)
subprocess.run(["python3", str(root / "Scripts/audit-bundle.py"), str(bundle)], check=True)
print("Development app:", bundle.relative_to(root))
