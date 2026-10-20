"""Fail on non-system dynamic dependencies or an incorrect architecture/deployment target."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

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
print("Bundle audit passed: arm64, macOS 14.0 minimum, system-only dynamic dependencies.")
