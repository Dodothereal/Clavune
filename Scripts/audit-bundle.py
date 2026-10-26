"""Fail on non-system dynamic dependencies or an incorrect architecture/deployment target."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from resource_validation import ResourceValidationError, validate_packaged_resources
from license_audit import LicenseAuditError, validate_packaged_licenses

def validate_macos_deployment(load_commands: str) -> None:
    """Require one unambiguous macOS deployment command, not just any minos token."""
    deployments = []
    for block in re.split(r"^Load command \d+\s*$", load_commands, flags=re.MULTILINE)[1:]:
        commands = re.findall(r"^\s*cmd\s+(\S+)\s*$", block, re.MULTILINE)
        if any(command == "LC_BUILD_VERSION" or command.startswith("LC_VERSION_MIN_")
               for command in commands):
            if len(commands) != 1:
                raise SystemExit("Ambiguous deployment load command.")
            deployments.append((commands[0], block))
    if len(deployments) != 1:
        raise SystemExit("Expected exactly one macOS deployment load command.")
    command, block = deployments[0]
    minimums = re.findall(r"^\s*minos\s+(\S+)", load_commands, re.MULTILINE)
    if command == "LC_BUILD_VERSION":
        platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", block, re.MULTILINE)
        if platforms not in (["1"], ["MACOS"]):
            raise SystemExit("Unexpected app platform: " + repr(platforms))
        scoped_minimums = re.findall(r"^\s*minos\s+(\S+)\s*$", block, re.MULTILINE)
        if minimums != ["14.0"] or scoped_minimums != ["14.0"]:
            raise SystemExit("Unexpected minimum macOS: " + repr(scoped_minimums))
    elif command == "LC_VERSION_MIN_MACOSX":
        versions = re.findall(r"^\s*version\s+(\S+)\s*$", block, re.MULTILINE)
        if minimums or versions != ["14.0"]:
            raise SystemExit("Unexpected minimum macOS: " + repr(versions))
    else:
        raise SystemExit("Non-macOS deployment load command: " + command)


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
validate_macos_deployment(load_commands)
try:
    resources = validate_packaged_resources(bundle, info["CFBundleExecutable"])
except ResourceValidationError as error:
    raise SystemExit("Packaged resource audit failed: " + str(error)) from error
try:
    licenses = validate_packaged_licenses(Path(__file__).resolve().parent.parent, bundle)
except LicenseAuditError as error:
    raise SystemExit("Packaged license audit failed: " + str(error)) from error
print("Bundle audit passed: arm64, macOS 14.0 minimum, system-only dynamic dependencies.")
print("Packaged resources passed: " + resources["resourceBundle"] +
      " (packaged files validated; runtime lookup not observed).")
for name, digest in resources["sha256"].items():
    print("Resource SHA-256 " + name + ": " + digest)
for name, digest in licenses.items():
    print("Packaged notice/license SHA-256 " + name + ": " + digest)
