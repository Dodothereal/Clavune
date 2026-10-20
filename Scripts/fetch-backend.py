"""Prepare independently verified pinned sources; cache stamps never confer trust."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
import tempfile
import urllib.request

MAX_ARCHIVE_BYTES = 50 * 1024 * 1024
MAX_EXPANDED_BYTES = 256 * 1024 * 1024
MAX_MEMBERS = 20000
MAX_PATCH_BYTES = 4 * 1024 * 1024
PROVENANCE_FILE = ".clavune-source-provenance.json"
LEGACY_MARKERS = {".clavune-source-sha256", ".openwispr-source-sha256"}


class SourceVerificationError(RuntimeError):
    pass


def sha256_file(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as file:
        while block := file.read(1024 * 1024):
            hasher.update(block)
    return hasher.hexdigest()


def source_inventory(directory, ignore_metadata=False):
    """Inspect every source entry, including unexpected files and executable bits."""
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise SourceVerificationError("Source root is not a regular directory.")
    inventory = {}
    for entry in sorted(directory.rglob("*")):
        relative = entry.relative_to(directory).as_posix()
        mode = entry.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise SourceVerificationError("Unsafe source entry: " + relative)
        if ".git" in entry.relative_to(directory).parts:
            raise SourceVerificationError("Unexpected embedded Git metadata.")
        if ignore_metadata and relative in LEGACY_MARKERS | {PROVENANCE_FILE}:
            if not stat.S_ISREG(mode):
                raise SourceVerificationError("Invalid source metadata entry.")
            continue
        if stat.S_ISDIR(mode):
            inventory[relative] = {"kind": "directory"}
        else:
            inventory[relative] = {
                "kind": "file", "bytes": entry.stat().st_size,
                "sha256": sha256_file(entry), "executable": bool(mode & 0o111),
            }
    return inventory


def inventory_digest(inventory):
    encoded = json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def locked_patches(root, lock):
    entries = lock.get("patches", [])
    if not isinstance(entries, list):
        raise SourceVerificationError("Patch lock must be an ordered array.")
    checked, seen, snapshots = [], set(), {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise SourceVerificationError("Invalid locked patch record.")
        name, expected = entry.get("path", ""), entry.get("sha256", "")
        relative = PurePosixPath(name)
        if (relative.is_absolute() or ".." in relative.parts or
                relative.parent != PurePosixPath("Patches/whisper.cpp") or
                relative.suffix != ".patch" or name in seen or
                not re.fullmatch(r"[0-9a-f]{64}", expected)):
            raise SourceVerificationError("Invalid locked patch entry.")
        path = root / name
        if (not path.resolve().is_relative_to(root) or path.is_symlink() or not path.is_file()):
            raise SourceVerificationError("Missing or mismatched locked patch: " + name)
        with path.open("rb") as file:
            content = file.read(MAX_PATCH_BYTES + 1)
        if len(content) > MAX_PATCH_BYTES or hashlib.sha256(content).hexdigest() != expected:
            raise SourceVerificationError("Missing or mismatched locked patch: " + name)
        checked.append({"path": name, "sha256": expected})
        snapshots[name] = content
        seen.add(name)
    patch_directory = root / "Patches/whisper.cpp"
    if not patch_directory.resolve().is_relative_to(root) or patch_directory.is_symlink():
        raise SourceVerificationError("Patch directory must not be a symlink.")
    actual = {path.relative_to(root).as_posix() for path in patch_directory.glob("*.patch")}
    if actual != seen:
        raise SourceVerificationError("Every local backend patch must be pinned in the dependency lock.")
    return checked, snapshots


def verified_archive(root, lock, archive_path, allow_download):
    expected = lock["sourceArchiveSHA256"]
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise SourceVerificationError("Invalid archive hash in dependency lock.")
    candidates = [Path(archive_path)] if archive_path else [
        root / ".build/deps/whisper.cpp.tar.gz",
        root / ".planning" / ("whisper.cpp-" + lock["commit"][:8] + ".tar.gz"),
    ]
    for candidate in candidates:
        if candidate.exists() or candidate.is_symlink():
            if candidate.is_symlink() or not candidate.is_file():
                raise SourceVerificationError("Archive cache is not a regular file.")
            if candidate.stat().st_size > MAX_ARCHIVE_BYTES or sha256_file(candidate) != expected:
                raise SourceVerificationError("Archive cache hash/size mismatch; existing file preserved.")
            return candidate
    if archive_path or not allow_download:
        raise SourceVerificationError("Verified source archive is unavailable offline.")
    url = lock["sourceArchive"]
    if not isinstance(url, str) or not url.startswith("https://"):
        raise SourceVerificationError("Source download must use HTTPS.")
    parent = root / ".build/deps"
    with tempfile.NamedTemporaryFile(dir=parent, prefix=".archive-", delete=False) as output:
        temporary = Path(output.name)
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                if not response.geturl().startswith("https://"):
                    raise SourceVerificationError("Source redirect left HTTPS.")
                total = 0
                while block := response.read(1024 * 1024):
                    total += len(block)
                    if total > MAX_ARCHIVE_BYTES:
                        raise SourceVerificationError("Source archive exceeds its safety budget.")
                    output.write(block)
            output.flush()
            if sha256_file(temporary) != expected:
                raise SourceVerificationError("Downloaded source archive SHA-256 mismatch.")
            target = parent / "whisper.cpp.tar.gz"
            if target.exists() or target.is_symlink():
                raise SourceVerificationError("Archive cache changed during preparation; preserved.")
            temporary.rename(target)
            return target
        finally:
            if temporary.exists():
                temporary.unlink()


def extract_reference(archive, destination, commit):
    prefix = "whisper.cpp-" + commit
    with tarfile.open(archive) as source:
        members = []
        expanded, names = 0, set()
        for member in source:
            if len(members) >= MAX_MEMBERS:
                raise SourceVerificationError("Source archive has too many entries.")
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or member.name in names or
                    not (member.name == prefix or member.name.startswith(prefix + "/")) or
                    not (member.isdir() or member.isfile()) or ".git" in path.parts):
                raise SourceVerificationError("Unsafe source archive entry.")
            expanded += member.size
            if expanded > MAX_EXPANDED_BYTES:
                raise SourceVerificationError("Expanded source exceeds its safety budget.")
            names.add(member.name)
            members.append(member)
        source.extractall(destination, members=members, filter="data")
    reference = destination / prefix
    if not reference.is_dir():
        raise SourceVerificationError("Source archive root is missing.")
    return reference


def apply_patches(reference, patches, snapshots):
    # Run git apply as a standalone file operation, never against the enclosing app index.
    environment = os.environ.copy()
    environment["GIT_CEILING_DIRECTORIES"] = str(reference.parent.resolve())
    for patch in patches:
        try:
            for options in [["--check"], []]:
                subprocess.run(["git", "apply", "--whitespace=error-all", *options, "-"],
                               cwd=reference, env=environment, check=True,
                               input=snapshots[patch["path"]],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as error:
            raise SourceVerificationError("Locked patch cannot be applied: " + patch["path"]) from error


def prepare_backend(root, archive_path=None, allow_download=True):
    root = Path(root).resolve()
    lock = json.loads((root / "Dependencies.lock.json").read_text())["whisperCpp"]
    if not re.fullmatch(r"[0-9a-f]{40}", lock["commit"]):
        raise SourceVerificationError("Invalid pinned backend commit.")
    parent = root / ".build/deps"
    if not parent.resolve().is_relative_to(root):
        raise SourceVerificationError("Dependency directory escapes the project.")
    parent.mkdir(parents=True, exist_ok=True)
    dest = parent / "whisper.cpp"
    if dest.is_symlink():
        raise SourceVerificationError("Existing source root is a symlink; preserved.")
    patches, patch_snapshots = locked_patches(root, lock)
    archive = verified_archive(root, lock, archive_path, allow_download)
    with tempfile.TemporaryDirectory(dir=parent, prefix=".verify-source-") as temporary:
        reference = extract_reference(archive, Path(temporary), lock["commit"])
        apply_patches(reference, patches, patch_snapshots)
        expected_inventory = source_inventory(reference)
        if dest.exists():
            actual_inventory = source_inventory(dest, ignore_metadata=True)
            if actual_inventory != expected_inventory:
                changed = sorted(name for name in set(actual_inventory) | set(expected_inventory)
                                 if actual_inventory.get(name) != expected_inventory.get(name))
                raise SourceVerificationError("Existing source tree differs from verified archive/patches; "
                                              "preserved. Inspect: " + ", ".join(changed[:5]))
        else:
            # Exclusive creation preserves existing trees. A partial preparation fails
            # the next full comparison instead of being trusted by a cache stamp.
            dest.mkdir(mode=0o700)
            for entry in reference.iterdir():
                entry.rename(dest / entry.name)
        provenance = {
            "schemaVersion": 1, "commit": lock["commit"],
            "sourceArchiveSHA256": lock["sourceArchiveSHA256"],
            "patches": patches, "treeSHA256": inventory_digest(expected_inventory),
            "inventory": expected_inventory,
        }
        with tempfile.NamedTemporaryFile(dir=dest, prefix=".provenance-", mode="w",
                                         delete=False) as output:
            json.dump(provenance, output, sort_keys=True, indent=2)
            output.write("\n")
            metadata_temp = Path(output.name)
        metadata_temp.replace(dest / PROVENANCE_FILE)
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    try:
        result = prepare_backend(Path(__file__).resolve().parent.parent, args.archive, not args.offline)
    except (SourceVerificationError, OSError, ValueError, KeyError, tarfile.TarError) as error:
        raise SystemExit(str(error)) from error
    print("Backend source verified:", len(result["inventory"]), "entries; tree SHA-256:", result["treeSHA256"])


if __name__ == "__main__":
    main()
