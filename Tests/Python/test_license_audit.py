"""Synthetic license/notice bundle inputs; no codesign, app launch or native build."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("clavune_license_audit", PROJECT / "Scripts/license_audit.py")
license_audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(license_audit)


class LicenseAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clavune-license-audit-")
        self.addCleanup(self.temporary.cleanup)
        parent = Path(self.temporary.name)
        self.source = parent / "source"
        self.app = parent / "Synthetic.app"
        self.resources = self.app / "Contents/Resources"
        self.source.mkdir()
        self.resources.mkdir(parents=True)
        for relative in license_audit.REQUIRED:
            for root in (self.source, self.resources):
                file = root / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("synthetic " + relative + "\n")

    def test_matching_inventory_and_bytes_pass(self):
        digests = license_audit.validate_packaged_licenses(self.source, self.app)
        self.assertEqual(set(digests), set(license_audit.REQUIRED))
        self.assertTrue(all(len(value) == 64 for value in digests.values()))

    def test_missing_or_modified_project_license_or_notice_fails(self):
        (self.resources / "LICENSE").write_text("tampered")
        with self.assertRaisesRegex(license_audit.LicenseAuditError, "differs"):
            license_audit.validate_packaged_licenses(self.source, self.app)
        (self.resources / "LICENSE").unlink()
        with self.assertRaisesRegex(license_audit.LicenseAuditError, "Missing"):
            license_audit.validate_packaged_licenses(self.source, self.app)
        (self.resources / "LICENSE").write_text((self.source / "LICENSE").read_text())
        (self.resources / "THIRD_PARTY_NOTICES.md").unlink()
        with self.assertRaisesRegex(license_audit.LicenseAuditError, "Missing"):
            license_audit.validate_packaged_licenses(self.source, self.app)

    def test_extra_or_symlinked_third_party_license_fails(self):
        directory = self.resources / "ThirdPartyLicenses"
        extra = directory / "undeclared.txt"
        extra.write_text("synthetic extra")
        with self.assertRaisesRegex(license_audit.LicenseAuditError, "Unexpected"):
            license_audit.validate_packaged_licenses(self.source, self.app)
        extra.unlink()
        target = directory / "Whisper-MIT.txt"
        target.unlink()
        target.symlink_to(self.source / "ThirdPartyLicenses/Whisper-MIT.txt")
        with self.assertRaisesRegex(license_audit.LicenseAuditError, "Symlinked"):
            license_audit.validate_packaged_licenses(self.source, self.app)

    def test_each_third_party_license_must_match_source_bytes(self):
        for relative in ("ThirdPartyLicenses/Whisper-MIT.txt",
                         "ThirdPartyLicenses/whisper.cpp-MIT.txt"):
            path = self.resources / relative
            original = path.read_bytes()
            try:
                path.write_bytes(original + b"synthetic tampering\n")
                with self.assertRaisesRegex(license_audit.LicenseAuditError, "differs"):
                    license_audit.validate_packaged_licenses(self.source, self.app)
            finally:
                path.write_bytes(original)

    def test_symlinked_root_license_is_not_followed(self):
        target = self.resources / "LICENSE"
        target.unlink()
        target.symlink_to(self.source / "LICENSE")
        with self.assertRaisesRegex(license_audit.LicenseAuditError, "Symlinked"):
            license_audit.validate_packaged_licenses(self.source, self.app)


if __name__ == "__main__":
    unittest.main()
