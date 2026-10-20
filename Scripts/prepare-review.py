"""Create a read-only ZIP from an explicit Git-tracked checkpoint, never from the workspace tree."""
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
out = root / "artifacts" / ("Clavune-review-" + commit[:12] + ".zip")
out.parent.mkdir(exist_ok=True)
if out.exists():
    raise SystemExit("Existing review bundle preserved.")
payloads = {}
for name in filter(None, paths):
    path = Path(name)
    if path.parts[0] in {".planning", ".build", "artifacts", ".git"}:
        raise SystemExit("Private/build path is tracked; stop and inspect.")
    if path.suffix in {".wav", ".bin", ".pcm", ".m4a", ".mp3"} or path.name.startswith(".env"):
        raise SystemExit("Private content candidate is tracked; stop and inspect.")
    content = subprocess.check_output(["git", "show", commit + ":" + name], cwd=root)
    if (b"/" + b"Users/") in content:
        raise SystemExit("Personal absolute path in tracked file: " + name)
    payloads[name] = content
with zipfile.ZipFile(out, "x", compression=zipfile.ZIP_DEFLATED) as archive:
    for name, content in payloads.items():
        info = zipfile.ZipInfo(name)
        info.external_attr = 0o100444 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, content)
    info = zipfile.ZipInfo("REVIEW_COMMIT.json"); info.external_attr = 0o100444 << 16
    archive.writestr(info, json.dumps({"commit": commit, "repository": "https://github.com/Dodothereal/Clavune",
                                     "visibility": "private", "releaseApproved": False}, indent=2))
out.chmod(0o444)
print(out.relative_to(root))
print("SHA-256:", hashlib.sha256(out.read_bytes()).hexdigest())
