"""Run the real auditor with synthetic bundles and mocked Apple-tool output only."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import runpy
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]


def build_version(platform="1", minimum="14.0", index=0):
    return (f"Load command {index}\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n"
            f" platform {platform}\n    minos {minimum}\n      sdk 14.0\n"
            "   ntools 1\n     tool 3\n  version 1.0\n")


def legacy_version(command="LC_VERSION_MIN_MACOSX", minimum="14.0", index=0):
    return (f"Load command {index}\n      cmd {command}\n  cmdsize 16\n"
            f"  version {minimum}\n      sdk 14.0\n")


class BundleAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bundle-audit-synthetic-")
        self.root = Path(self.temporary.name)
        self.scripts = self.root / "Scripts"
        self.scripts.mkdir()
        for name in ["audit-bundle.py", "resource_validation.py", "license_audit.py"]:
            shutil.copyfile(PROJECT / "Scripts" / name, self.scripts / name)
        self.app = self.root / "Synthetic.app"
        self.resources = self.app / "Contents/Resources"
        data = self.resources / "Clavune_ClavuneCore.bundle/Contents/Resources/Resources"
        data.mkdir(parents=True)
        (data.parents[1] / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleName": "Clavune_ClavuneCore", "CFBundlePackageType": "BNDL"}))
        policy = {"schemaVersion": 1, "sampleRate": 16000, "sessionLimitSeconds": 120,
            "ringSlots": 64, "maxNativeBlockFrames": 4096, "pumpIntervalMilliseconds": 10,
            "firstBufferTimeoutSeconds": 3, "stopDrainTimeoutSeconds": .5,
            "maxInputChannels": 32, "inferenceThreads": 2, "activeInferenceJobs": 1,
            "previewEnabled": False}
        candidates = {"schemaVersion": 1, "releaseApproved": False, "defaultModel": None,
            "models": [{"fileName": "synthetic.bin", "sizeBytes": 123, "sha256": "a" * 64,
                        "qualityGate": "unmeasured", "license": "MIT"}]}
        for name, value in [("resource-policy.json", policy), ("candidates.json", candidates)]:
            (data / name).write_text(json.dumps(value))
        for relative in ["LICENSE", "THIRD_PARTY_NOTICES.md",
                         "ThirdPartyLicenses/Whisper-MIT.txt", "ThirdPartyLicenses/whisper.cpp-MIT.txt"]:
            for directory in [self.root, self.resources]:
                path = directory / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("Synthetic matching notice: " + relative + "\n")
        (self.app / "Contents/MacOS").mkdir()
        self.binary = self.app / "Contents/MacOS/Clavune"
        self.binary.write_bytes(b"Synthetic non-executable fixture; no code is run.\n")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Clavune"}))

    def tearDown(self):
        self.temporary.cleanup()

    def audit(self, commands, *, architecture="arm64", dependency="/usr/lib/libSystem.B.dylib"):
        def output(command, *, text):
            self.assertIs(text, True)
            self.assertEqual(command[-1], str(self.binary))
            if command[:2] == ["/usr/bin/otool", "-L"]:
                return str(self.binary) + ":\n\t" + dependency + " (compatibility version 1.0.0, current version 1.0.0)\n"
            if command[:2] == ["/usr/bin/lipo", "-archs"]:
                return architecture + "\n"
            if command[:2] == ["/usr/bin/otool", "-l"]:
                return str(self.binary) + ":\n" + commands
            self.fail("Unexpected native command: " + repr(command))
        captured = io.StringIO()
        with patch.object(sys, "argv", [str(self.scripts / "audit-bundle.py"), str(self.app)]), \
             patch.object(sys, "path", [str(self.scripts), *sys.path]), \
             patch("subprocess.check_output", side_effect=output), contextlib.redirect_stdout(captured):
            runpy.run_path(str(self.scripts / "audit-bundle.py"), run_name="__main__")
        return captured.getvalue()

    def test_accepts_numeric_macos_build_version(self):
        self.assertIn("Bundle audit passed", self.audit(build_version()))

    def test_accepts_apple_verbose_macos_build_version(self):
        self.assertIn("Bundle audit passed", self.audit(build_version("MACOS")))

    def test_accepts_legacy_macos_version_command(self):
        self.assertIn("Bundle audit passed", self.audit(legacy_version()))

    def test_rejects_other_platforms_in_numeric_and_verbose_forms(self):
        for platform in ["2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12",
                         "IOS", "TVOS", "WATCHOS", "BRIDGEOS", "MACCATALYST",
                         "IOSSIMULATOR", "TVOSSIMULATOR", "WATCHOSSIMULATOR",
                         "DRIVERKIT", "XROS", "XROSSIMULATOR"]:
            with self.subTest(platform=platform), self.assertRaisesRegex(SystemExit, "platform"):
                self.audit(build_version(platform))

    def test_rejects_unknown_platform(self):
        for platform in ["0", "999", "UNKNOWN", "MACOS extra"]:
            with self.subTest(platform=platform), self.assertRaisesRegex(SystemExit, "platform"):
                self.audit(build_version(platform))

    def test_rejects_missing_platform(self):
        with self.assertRaisesRegex(SystemExit, "platform"):
            self.audit(build_version().replace(" platform 1\n", ""))

    def test_rejects_duplicate_or_conflicting_platform_fields(self):
        for extra in ["1", "2", "MACOS"]:
            with self.subTest(extra=extra), self.assertRaisesRegex(SystemExit, "platform"):
                self.audit(build_version().replace(" platform 1\n", f" platform 1\n platform {extra}\n"))

    def test_rejects_missing_deployment_command(self):
        with self.assertRaisesRegex(SystemExit, "exactly one"):
            self.audit("Load command 0\n      cmd LC_SEGMENT_64\n  cmdsize 72\n")

    def test_rejects_version_tokens_outside_a_load_command(self):
        with self.assertRaisesRegex(SystemExit, "exactly one"):
            self.audit("cmd LC_BUILD_VERSION\nplatform 1\nminos 14.0\n")

    def test_rejects_minimum_borrowed_from_unrelated_command(self):
        commands = build_version().replace("    minos 14.0\n", "")
        commands += "Load command 1\n      cmd LC_SEGMENT_64\n    minos 14.0\n"
        with self.assertRaisesRegex(SystemExit, "minimum macOS"):
            self.audit(commands)

    def test_rejects_multiple_deployment_commands(self):
        for second in [build_version(index=1), build_version("2", index=1), legacy_version(index=1)]:
            with self.subTest(second=second), self.assertRaisesRegex(SystemExit, "exactly one"):
                self.audit(build_version() + second)

    def test_rejects_multiple_command_tags_inside_one_block(self):
        with self.assertRaisesRegex(SystemExit, "Ambiguous"):
            self.audit(build_version().replace("  cmdsize 32", "      cmd LC_VERSION_MIN_MACOSX\n  cmdsize 32"))

    def test_rejects_nonmacos_or_unknown_legacy_deployment(self):
        for command in ["LC_VERSION_MIN_IPHONEOS", "LC_VERSION_MIN_TVOS",
                        "LC_VERSION_MIN_WATCHOS", "LC_VERSION_MIN_UNKNOWN"]:
            with self.subTest(command=command), self.assertRaisesRegex(SystemExit, "Non-macOS"):
                self.audit(legacy_version(command))

    def test_retains_exact_modern_minimum_policy(self):
        for minimum in ["13.0", "15.0", "14.0.0", "invalid", "14.0 extra"]:
            with self.subTest(minimum=minimum), self.assertRaisesRegex(SystemExit, "minimum macOS"):
                self.audit(build_version(minimum=minimum))

    def test_rejects_missing_or_duplicate_modern_minimum(self):
        for replacement in ["", "    minos 14.0\n    minos 14.0\n"]:
            with self.subTest(replacement=replacement), self.assertRaisesRegex(SystemExit, "minimum macOS"):
                self.audit(build_version().replace("    minos 14.0\n", replacement))

    def test_requires_exact_legacy_minimum(self):
        for minimum in ["13.0", "15.0", "14.0.0", "invalid"]:
            with self.subTest(minimum=minimum), self.assertRaisesRegex(SystemExit, "minimum macOS"):
                self.audit(legacy_version(minimum=minimum))

    def test_rejects_missing_duplicate_or_mixed_legacy_minimum(self):
        for commands in [legacy_version().replace("  version 14.0\n", ""),
                         legacy_version().replace("  version 14.0\n", "  version 14.0\n  version 14.0\n"),
                         legacy_version() + "    minos 14.0\n"]:
            with self.subTest(commands=commands), self.assertRaisesRegex(SystemExit, "minimum macOS"):
                self.audit(commands)

    def test_architecture_rejection_is_unchanged(self):
        for architecture in ["x86_64", "arm64 x86_64", "arm64e", ""]:
            with self.subTest(architecture=architecture), self.assertRaisesRegex(SystemExit, "architecture"):
                self.audit(build_version(), architecture=architecture)

    def test_nonsystem_dependency_rejection_is_unchanged(self):
        with self.assertRaisesRegex(SystemExit, "Non-system dynamic dependency"):
            self.audit(build_version(), dependency="@rpath/synthetic.dylib")

    def test_real_resource_validation_remains_required(self):
        (self.resources / "Clavune_ClavuneCore.bundle/Contents/Resources/Resources/resource-policy.json").unlink()
        with self.assertRaisesRegex(SystemExit, "resource audit failed"):
            self.audit(build_version())

    def test_real_license_validation_remains_required(self):
        (self.resources / "LICENSE").write_text("changed synthetic notice")
        with self.assertRaisesRegex(SystemExit, "license audit failed"):
            self.audit(build_version())

    def test_resource_success_does_not_claim_runtime_lookup_observed(self):
        output = self.audit(build_version())
        self.assertIn("packaged files validated; runtime lookup not observed", output)
        self.assertNotIn("no development lookup", output)


if __name__ == "__main__":
    unittest.main()
