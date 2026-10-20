"""Fail on non-system dynamic dependencies or an incorrect architecture/deployment target."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from resource_validation import ResourceValidationError, validate_packaged_resources

bundle = Path(sys.argv[1])
info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
deps = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
for line in deps.splitlines()[1:]:
    dependency = line.strip().split(" (", 1)[0]
    if not dependency.startswith(("/System/Library/", "/usr/lib/")):
        raise SystemExit("Non-system dynamic dependency: " + dependency)
architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).strip()
if architecture != "arm64":
    raise SystemExit("Unexpected app architecture: " + architecture)
load_commands = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True)
minimums = re.findall(r"^\s*minos\s+(\S+)", load_commands, re.MULTILINE)
if minimums != ["14.0"]:
    raise SystemExit("Unexpected minimum macOS: " + repr(minimums))
try:
    resources = validate_packaged_resources(bundle, info["CFBundleExecutable"])
except ResourceValidationError as error:
    raise SystemExit("Packaged resource audit failed: " + str(error)) from error
print("Bundle audit passed: arm64, macOS 14.0 minimum, system-only dynamic dependencies.")
print("Packaged resources passed: " + resources["resourceBundle"] + " (no development lookup).")
for name, digest in resources["sha256"].items():
    print("Resource SHA-256 " + name + ": " + digest)
