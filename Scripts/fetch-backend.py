"""Fetch only the pinned, hash-verified source archive; never execute downloads."""
import hashlib
import json
from pathlib import Path
import tarfile
import urllib.request

root = Path(__file__).resolve().parent.parent
lock = json.loads((root / "Dependencies.lock.json").read_text())["whisperCpp"]
dest = root / ".build" / "deps" / "whisper.cpp"
stamp = dest / ".clavune-source-sha256"
expected = lock["sourceArchiveSHA256"]
if stamp.exists():
    if stamp.read_text().strip() != expected:
        raise SystemExit("Dependency stamp mismatch; inspect the existing checkout.")
    raise SystemExit(0)
if dest.exists():
    # Permit the initial manually verified extraction only if its full archive matches.
    initial = root / ".planning" / "whisper.cpp-d1be6fde.tar.gz"
    if not initial.exists() or hashlib.sha256(initial.read_bytes()).hexdigest() != expected:
        raise SystemExit("Unmarked dependency directory exists; inspect it before proceeding.")
    stamp.write_text(expected + "\n")
    raise SystemExit(0)
dest.parent.mkdir(parents=True, exist_ok=True)
archive = dest.parent / "whisper.cpp.tar.gz"
with urllib.request.urlopen(lock["sourceArchive"], timeout=60) as response:
    with archive.open("wb") as output:
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > 50 * 1024 * 1024:
                raise SystemExit("Source archive exceeds expected safety budget.")
            output.write(chunk)
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit("Source archive SHA-256 mismatch.")
prefix = "whisper.cpp-" + lock["commit"]
with tarfile.open(archive) as source:
    for member in source.getmembers():
        if not (member.name == prefix or member.name.startswith(prefix + "/")):
            raise SystemExit("Unexpected source archive root.")
        if ".." in Path(member.name).parts or member.issym() or member.islnk():
            raise SystemExit("Unsafe source archive entry.")
    source.extractall(dest.parent, filter="data")
(dest.parent / prefix).rename(dest)
stamp.write_text(expected + "\n")
