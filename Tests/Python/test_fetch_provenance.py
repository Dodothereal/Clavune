import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("clavune_fetch", PROJECT / "Scripts/fetch-backend.py")
FETCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FETCH)


class FetchProvenanceTests(unittest.TestCase):
    def setUp(self):
        parent = PROJECT / ".build/python-fixtures"
        parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=parent, prefix="source-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.commit = "a" * 40
        self.archive = self.root / "source.tar.gz"
        prefix = "whisper.cpp-" + self.commit
        with tarfile.open(self.archive, "w:gz") as archive:
            for directory in [prefix, prefix + "/src"]:
                entry = tarfile.TarInfo(directory)
                entry.type = tarfile.DIRTYPE
                entry.mode = 0o755
                archive.addfile(entry)
            for name, data in [("src/source.cpp", b"source\n"), ("LICENSE", b"fixture license\n")]:
                entry = tarfile.TarInfo(prefix + "/" + name)
                entry.mode = 0o644
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        self.lock = {
            "commit": self.commit,
            "sourceArchive": "https://example.invalid/not-used-offline",
            "sourceArchiveSHA256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            "patches": [],
        }
        self.write_lock()
        self.dest = self.root / ".build/deps/whisper.cpp"

    def write_lock(self):
        (self.root / "Dependencies.lock.json").write_text(json.dumps({"whisperCpp": self.lock}))

    def prepare(self):
        return FETCH.prepare_backend(self.root, self.archive, allow_download=False)

    def test_forged_existing_tree_is_preserved_despite_matching_archive_and_stamp(self):
        (self.dest / "src").mkdir(parents=True)
        source = self.dest / "src/source.cpp"
        source.write_text("altered source\n")
        marker = self.dest / ".clavune-source-sha256"
        marker.write_text(self.lock["sourceArchiveSHA256"] + "\n")
        with self.assertRaises(FETCH.SourceVerificationError):
            self.prepare()
        self.assertEqual(source.read_text(), "altered source\n")
        self.assertEqual(marker.read_text().strip(), self.lock["sourceArchiveSHA256"])
        self.assertFalse((self.dest / FETCH.PROVENANCE_FILE).exists())

    def test_valid_provenance_is_not_trusted_after_source_mutation(self):
        original = self.prepare()
        provenance = self.dest / FETCH.PROVENANCE_FILE
        saved = provenance.read_bytes()
        source = self.dest / "src/source.cpp"
        source.write_text("modified after verification\n")
        with self.assertRaises(FETCH.SourceVerificationError):
            self.prepare()
        self.assertEqual(source.read_text(), "modified after verification\n")
        self.assertEqual(provenance.read_bytes(), saved)
        self.assertEqual(json.loads(saved)["treeSHA256"], original["treeSHA256"])

    def test_unexpected_extra_file_is_not_blessed(self):
        self.prepare()
        extra = self.dest / "unexpected.cpp"
        extra.write_text("unexpected fixture\n")
        with self.assertRaises(FETCH.SourceVerificationError):
            self.prepare()
        self.assertTrue(extra.exists())

    def test_genuine_existing_tree_is_compared_and_gets_full_inventory(self):
        self.prepare()
        (self.dest / FETCH.PROVENANCE_FILE).unlink()
        (self.dest / ".openwispr-source-sha256").write_text("untrusted legacy marker\n")
        result = self.prepare()
        self.assertEqual(result["inventory"]["src/source.cpp"]["sha256"],
                         hashlib.sha256(b"source\n").hexdigest())
        self.assertEqual(result["treeSHA256"], FETCH.inventory_digest(result["inventory"]))
        self.assertEqual(result["patches"], [])

    def test_locked_patch_changes_verified_tree_and_is_recorded(self):
        patch = self.root / "Patches/whisper.cpp/0001-fixture.patch"
        patch.parent.mkdir(parents=True)
        patch.write_text("diff --git a/src/source.cpp b/src/source.cpp\n"
                         "--- a/src/source.cpp\n+++ b/src/source.cpp\n"
                         "@@ -1 +1 @@\n-source\n+patched\n")
        self.lock["patches"] = [{
            "path": patch.relative_to(self.root).as_posix(),
            "sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
        }]
        self.write_lock()
        result = self.prepare()
        self.assertEqual((self.dest / "src/source.cpp").read_text(), "patched\n")
        self.assertEqual(result["patches"], self.lock["patches"])
        self.assertEqual(result["inventory"]["src/source.cpp"]["sha256"],
                         hashlib.sha256(b"patched\n").hexdigest())
        patch.write_text(patch.read_text() + "\n")
        with self.assertRaises(FETCH.SourceVerificationError):
            self.prepare()

    def test_unlisted_patch_is_rejected_without_installation(self):
        patch = self.root / "Patches/whisper.cpp/unlisted.patch"
        patch.parent.mkdir(parents=True)
        patch.write_text("unlisted fixture\n")
        with self.assertRaises(FETCH.SourceVerificationError):
            self.prepare()
        self.assertFalse(self.dest.exists())


if __name__ == "__main__":
    unittest.main()
