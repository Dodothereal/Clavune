"""Packaging control-flow fixtures; subprocesses and publication are mocked."""
import ctypes
import errno
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("clavune_packaging", PROJECT / "Scripts/package-app.py")
packaging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packaging)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        (PROJECT / ".build").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="packaging-fixture-", dir=PROJECT / ".build")
        self.root = Path(self.temporary.name)
        (self.root / "Config").mkdir()
        self.product = {
            "displayName": "Clavune", "executable": "Clavune",
            "bundleIdentifier": "org.clavune.synthetic", "storageDirectory": "Clavune",
            "version": "0.0.0", "build": "0",
        }
        self.write_product()
        (self.root / "Config/Development.entitlements").write_text("synthetic entitlement placeholder")
        self.binary_directory = self.root / "bin"
        self.binary_directory.mkdir()
        (self.binary_directory / "Clavune").write_bytes(b"synthetic, nonexecutable fixture")
        resources = self.binary_directory / "Clavune_ClavuneCore.bundle"
        resources.mkdir()
        (resources / "placeholder").write_text("synthetic resource")
        (self.root / "ThirdPartyLicenses").mkdir()
        (self.root / "ThirdPartyLicenses/fixture.txt").write_text("synthetic license")
        (self.root / "THIRD_PARTY_NOTICES.md").write_text("synthetic notices")
        self.final = self.root / "artifacts/Clavune.app"
        self.commands = []

    def tearDown(self):
        self.temporary.cleanup()

    def write_product(self):
        (self.root / "Config/Product.json").write_text(json.dumps(self.product))

    def runner(self, command, *, check):
        self.assertTrue(check)
        self.assertFalse(self.final.exists(), "Final app must not appear before every check succeeds.")
        staged = Path(command[-1])
        self.assertEqual(staged.name, "Clavune.app")
        self.assertTrue(staged.is_dir())
        self.assertTrue(staged.parent.name.startswith(".Clavune-stage-"))
        self.assertEqual(staged.parent.parent, self.root / "artifacts")
        self.commands.append(command)
        return subprocess.CompletedProcess(command, 0)

    def publisher(self, staged, destination):
        self.assertEqual(len(self.commands), 3)
        self.assertFalse(destination.exists())
        staged.rename(destination)  # Fixture-only publication; native API is mocked separately.

    def assertNoStaging(self):
        if (self.root / "artifacts").exists():
            self.assertFalse(any(p.name.startswith(".Clavune-stage-") for p in (self.root / "artifacts").iterdir()))

    def test_success_publishes_only_after_sign_verify_and_audit(self):
        original = (self.binary_directory / "Clavune").read_bytes()
        result = packaging.package_app(self.root, self.binary_directory, run=self.runner, publish=self.publisher)
        self.assertEqual(result, self.final)
        info = plistlib.loads((self.final / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleExecutable"], "Clavune")
        self.assertEqual((self.binary_directory / "Clavune").read_bytes(), original)
        self.assertNoStaging()

    def test_signing_failure_cleans_owned_staging_and_allows_retry(self):
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        sentinel = artifacts / "unrelated.txt"
        sentinel.write_text("keep")
        failing = Mock(side_effect=subprocess.CalledProcessError(1, ["synthetic-sign"]))
        with self.assertRaises(subprocess.CalledProcessError):
            packaging.package_app(self.root, self.binary_directory, run=failing, publish=self.publisher)
        self.assertFalse(self.final.exists())
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertNoStaging()
        packaging.package_app(self.root, self.binary_directory, run=self.runner, publish=self.publisher)
        self.assertTrue(self.final.is_dir())
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertNoStaging()

    def test_audit_failure_leaves_no_partial_final_app(self):
        def fail_audit(command, *, check):
            self.runner(command, check=check)
            if len(self.commands) == 3:
                raise subprocess.CalledProcessError(1, command)
        publisher = Mock()
        with self.assertRaises(subprocess.CalledProcessError):
            packaging.package_app(self.root, self.binary_directory, run=fail_audit, publish=publisher)
        publisher.assert_not_called()
        self.assertFalse(self.final.exists())
        self.assertNoStaging()

    def test_existing_final_app_is_preserved_without_starting_checks(self):
        self.final.mkdir(parents=True)
        marker = self.final / "existing.txt"
        marker.write_text("keep existing app")
        runner, publisher = Mock(), Mock()
        with self.assertRaises(FileExistsError):
            packaging.package_app(self.root, self.binary_directory, run=runner, publish=publisher)
        runner.assert_not_called()
        publisher.assert_not_called()
        self.assertEqual(marker.read_text(), "keep existing app")
        self.assertNoStaging()

    def test_concurrent_final_entry_is_preserved_when_publication_refuses(self):
        def concurrent_entry(staged, destination):
            destination.mkdir()
            (destination / "concurrent.txt").write_text("keep concurrent app")
            raise FileExistsError("synthetic publication collision")
        with self.assertRaises(FileExistsError):
            packaging.package_app(self.root, self.binary_directory, run=self.runner, publish=concurrent_entry)
        self.assertEqual((self.final / "concurrent.txt").read_text(), "keep concurrent app")
        self.assertNoStaging()

    def test_native_publisher_uses_exclusive_flag_and_reports_collision(self):
        rename = Mock(return_value=-1)
        library = Mock()
        library.renamex_np = rename
        with patch.object(packaging.sys, "platform", "darwin"), \
             patch.object(packaging.ctypes, "CDLL", return_value=library), \
             patch.object(packaging.ctypes, "get_errno", return_value=errno.EEXIST):
            with self.assertRaises(FileExistsError):
                packaging._publish_exclusive(Path("staged.app"), Path("final.app"))
        rename.assert_called_once_with(b"staged.app", b"final.app", 0x4)
        self.assertEqual(rename.argtypes, [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint])

    def test_invalid_product_identity_cannot_escape_artifact_directory(self):
        self.product["executable"] = "../escape"
        self.write_product()
        runner = Mock()
        with self.assertRaises(ValueError):
            packaging.package_app(self.root, self.binary_directory, run=runner, publish=self.publisher)
        runner.assert_not_called()
        self.assertFalse((self.root / "artifacts").exists())


if __name__ == "__main__":
    unittest.main()
