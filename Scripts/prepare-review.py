"""Create a read-only ZIP entirely from one immutable Git commit tree."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
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


def prepare_review(root, revision="HEAD"):
    root = Path(root).resolve()
    commit, payloads, blobs = committed_payloads(root, revision)
    out = root / "artifacts" / ("Clavune-review-" + commit[:12] + ".zip")
    out.parent.mkdir(exist_ok=True)
    if out.exists():
        raise ReviewSnapshotError("Existing review bundle preserved.")
    metadata = {
        "commit": commit, "repository": "https://github.com/Dodothereal/Clavune",
        "visibility": "private", "releaseApproved": False, "files": blobs,
    }
    with zipfile.ZipFile(out, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in list(payloads.items()) + [
                ("REVIEW_COMMIT.json", json.dumps(metadata, sort_keys=True, indent=2).encode())]:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = 0o100444 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content)
    out.chmod(0o444)
    return out, commit


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
