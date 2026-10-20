"""Create a read-only ZIP entirely from one immutable Git commit tree."""
import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import zipfile


class ReviewSnapshotError(RuntimeError):
    pass


def git(root, *arguments):
    return subprocess.check_output(["git", *arguments], cwd=root)


def committed_payloads(root, revision):
    commit = git(root, "rev-parse", "--verify", "--end-of-options", revision + "^{commit}").decode().strip()
    entries = git(root, "ls-tree", "-r", "-z", "--full-tree", commit).split(b"\0")
    payloads, blobs = {}, {}
    for entry in filter(None, entries):
        metadata, encoded_name = entry.split(b"\t", 1)
        mode, kind, object_id = metadata.decode().split()
        name = encoded_name.decode("utf-8")
        path = PurePosixPath(name)
        if (path.is_absolute() or ".." in path.parts or
                path.parts[0] in {".planning", ".build", "artifacts", ".git"}):
            raise ReviewSnapshotError("Private/build path in commit tree; inspect before review export.")
        if (path.suffix in {".wav", ".bin", ".gguf", ".pcm", ".m4a", ".mp3", ".flac", ".aiff", ".aif", ".aac"} or
                path.name.startswith(".env") or name == "REVIEW_COMMIT.json"):
            raise ReviewSnapshotError("Private or reserved content candidate in commit tree: " + name)
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise ReviewSnapshotError("Review source must contain regular files only: " + name)
        content = git(root, "cat-file", "blob", object_id)
        if (b"/" + b"Users/") in content:
            raise ReviewSnapshotError("Personal absolute path in committed file: " + name)
        payloads[name] = content
        blobs[name] = {"gitBlob": object_id, "sha256": hashlib.sha256(content).hexdigest()}
    return commit, payloads, blobs


def _publish_exclusive(staged, destination):
    """Publish on the same macOS filesystem without replacing any existing entry."""
    if sys.platform != "darwin":
        raise OSError("Atomic review publication requires macOS.")
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # RENAME_EXCL = 0x4; never replace it with an exists/rename race.
    if rename(os.fsencode(staged), os.fsencode(destination), 0x4) != 0:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise FileExistsError(code, "Existing review bundle preserved.", str(destination))
        raise OSError(code, os.strerror(code), str(destination))


def prepare_review(root, revision="HEAD", *, publish=None, zip_factory=None):
    root = Path(root).resolve()
    commit, payloads, blobs = committed_payloads(root, revision)
    out = root / "artifacts" / ("Clavune-review-" + commit[:12] + ".zip")
    if out.parent.is_symlink():
        raise ReviewSnapshotError("Artifact directory must not be a symlink.")
    out.parent.mkdir(exist_ok=True)
    if out.exists() or out.is_symlink():
        raise ReviewSnapshotError("Existing review bundle preserved.")
    metadata = {
        "commit": commit, "repository": "https://github.com/Dodothereal/Clavune",
        "visibility": "private", "releaseApproved": False, "files": blobs,
    }
    publisher = publish if publish is not None else _publish_exclusive
    make_zip = zip_factory if zip_factory is not None else zipfile.ZipFile
    staging = Path(tempfile.mkdtemp(prefix=".Clavune-review-stage-", dir=out.parent))
    staged_archive = staging / out.name
    try:
        with make_zip(staged_archive, "x", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, content in list(payloads.items()) + [
                    ("REVIEW_COMMIT.json", json.dumps(metadata, sort_keys=True, indent=2).encode())]:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = 0o100444 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, content)
        staged_archive.chmod(0o444)
        publisher(staged_archive, out)
        return out, commit
    finally:
        # Clean only this invocation's staging container, never the destination.
        if staging.is_symlink():
            staging.unlink()
        elif staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", default="HEAD", help="Commit or ref to resolve once before export.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        out, commit = prepare_review(root, args.commit)
    except (ReviewSnapshotError, OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
    print(out.relative_to(root))
    print("Commit:", commit)
    print("SHA-256:", hashlib.sha256(out.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
