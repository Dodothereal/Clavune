import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("clavune_review", PROJECT / "Scripts/prepare-review.py")
REVIEW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REVIEW)


class ReviewSnapshotTests(unittest.TestCase):
    def setUp(self):
        parent = PROJECT / ".build/python-fixtures"
        parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=parent, prefix="review-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = os.environ.copy()
        self.environment["GIT_CONFIG_NOSYSTEM"] = "1"
        self.environment["GIT_CONFIG_GLOBAL"] = os.devnull
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", os.devnull)

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.root,
                                       env=self.environment, stderr=subprocess.PIPE).decode().strip()

    def commit_initial(self):
        (self.root / "committed.txt").write_text("committed content\n")
        (self.root / "index-removed.txt").write_text("still in commit\n")
        self.git("add", "committed.txt", "index-removed.txt")
        self.git("commit", "-m", "fixture checkpoint")
        return self.git("rev-parse", "HEAD")

    def test_snapshot_membership_and_bytes_ignore_staged_changes(self):
        original = self.commit_initial()
        (self.root / "committed.txt").write_text("staged replacement\n")
        (self.root / "staged-extra.txt").write_text("must not enter snapshot\n")
        self.git("add", "committed.txt", "staged-extra.txt")
        self.git("rm", "--cached", "index-removed.txt")
        archive, commit = REVIEW.prepare_review(self.root, original)
        self.assertEqual(commit, original)
        with zipfile.ZipFile(archive) as snapshot:
            self.assertEqual(set(snapshot.namelist()),
                             {"committed.txt", "index-removed.txt", "REVIEW_COMMIT.json"})
            self.assertEqual(snapshot.read("committed.txt"), b"committed content\n")
            self.assertEqual(snapshot.read("index-removed.txt"), b"still in commit\n")
            metadata = json.loads(snapshot.read("REVIEW_COMMIT.json"))
            self.assertEqual(metadata["commit"], original)
            self.assertEqual(set(metadata["files"]), {"committed.txt", "index-removed.txt"})
            self.assertEqual(metadata["files"]["committed.txt"]["sha256"],
                             hashlib.sha256(b"committed content\n").hexdigest())
            self.assertTrue(all((entry.external_attr >> 16) & 0o222 == 0
                                for entry in snapshot.infolist()))

    def test_explicit_old_commit_does_not_follow_new_head(self):
        original = self.commit_initial()
        (self.root / "later.txt").write_text("later revision\n")
        self.git("add", "later.txt")
        self.git("commit", "-m", "later fixture")
        archive, commit = REVIEW.prepare_review(self.root, original)
        self.assertEqual(commit, original)
        with zipfile.ZipFile(archive) as snapshot:
            self.assertNotIn("later.txt", snapshot.namelist())
            self.assertEqual(json.loads(snapshot.read("REVIEW_COMMIT.json"))["commit"], original)

    def test_private_path_in_commit_is_rejected(self):
        self.commit_initial()
        private = self.root / ".planning/private.txt"
        private.parent.mkdir()
        private.write_text("private fixture\n")
        self.git("add", ".planning/private.txt")
        self.git("commit", "-m", "unsafe fixture")
        with self.assertRaises(REVIEW.ReviewSnapshotError):
            REVIEW.prepare_review(self.root)
        self.assertFalse((self.root / "artifacts").exists())


if __name__ == "__main__":
    unittest.main()
