"""Pure filesystem/JSON fixtures: no application, microphone, model or clipboard use."""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / "Scripts"))
from resource_validation import ResourceValidationError, validate_packaged_resources


class PackagedResourceTests(unittest.TestCase):
    def setUp(self):
        (PROJECT / ".build").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="resource-fixture-", dir=PROJECT / ".build")
        self.root = Path(self.temporary.name)
        self.app = self.root / "Clavune.app"
        self.resources = self.app / "Contents/Resources/Clavune_ClavuneCore.bundle/Contents/Resources/Resources"
        self.resources.mkdir(parents=True)
        info = {"CFBundleName": "Clavune_ClavuneCore", "CFBundlePackageType": "BNDL"}
        (self.resources.parents[1] / "Info.plist").write_bytes(plistlib.dumps(info))
        self.policy = {
            "schemaVersion": 1, "sampleRate": 16000, "sessionLimitSeconds": 120,
            "ringSlots": 64, "maxNativeBlockFrames": 4096, "pumpIntervalMilliseconds": 10,
            "firstBufferTimeoutSeconds": 3, "stopDrainTimeoutSeconds": 0.5,
            "maxInputChannels": 32, "inferenceThreads": 2, "activeInferenceJobs": 1,
            "previewEnabled": False,
        }
        self.manifest = {
            "schemaVersion": 1, "defaultModel": None, "releaseApproved": False,
            "models": [{"fileName": "synthetic-candidate.bin", "sizeBytes": 123,
                        "sha256": "a" * 64, "qualityGate": "unmeasured", "license": "MIT"}],
        }
        self.write_payloads()

    def tearDown(self):
        self.temporary.cleanup()

    def write_payloads(self):
        (self.resources / "resource-policy.json").write_text(json.dumps(self.policy))
        (self.resources / "candidates.json").write_text(json.dumps(self.manifest))

    def test_packaged_shapes_and_exact_payload_hashes(self):
        result = validate_packaged_resources(self.app, "Clavune")
        self.assertEqual(result["lookup"], "explicit-packaged-tree-only")
        self.assertEqual(result["resourceBundle"], "Contents/Resources/Clavune_ClavuneCore.bundle")
        for name in ["resource-policy.json", "candidates.json"]:
            self.assertEqual(result["sha256"][name], hashlib.sha256((self.resources / name).read_bytes()).hexdigest())

    def test_missing_packaged_resource_never_uses_valid_development_decoy(self):
        decoy = self.root / "development/Clavune_ClavuneCore.bundle/Contents/Resources/Resources"
        decoy.mkdir(parents=True)
        for name in ["resource-policy.json", "candidates.json"]:
            (decoy / name).write_bytes((self.resources / name).read_bytes())
        (decoy.parents[1] / "Info.plist").write_bytes(
            (self.resources.parents[1] / "Info.plist").read_bytes())
        (self.resources / "resource-policy.json").unlink()
        with patch.dict(os.environ, {
            "PACKAGE_RESOURCE_BUNDLE_PATH": str(decoy.parents[2].parent),
            "PACKAGE_RESOURCE_BUNDLE_URL": str(decoy.parents[2].parent),
        }):
            with self.assertRaises(ResourceValidationError):
                validate_packaged_resources(self.app, "Clavune")

    def test_invalid_policy_shape_is_rejected(self):
        self.policy["sampleRate"] = True
        self.write_payloads()
        with self.assertRaises(ResourceValidationError):
            validate_packaged_resources(self.app, "Clavune")

    def test_invalid_model_hash_is_rejected(self):
        self.manifest["models"][0]["sha256"] = "not-a-sha256"
        self.write_payloads()
        with self.assertRaises(ResourceValidationError):
            validate_packaged_resources(self.app, "Clavune")

    def test_duplicate_model_identity_is_rejected(self):
        self.manifest["models"].append(copy.deepcopy(self.manifest["models"][0]))
        self.write_payloads()
        with self.assertRaises(ResourceValidationError):
            validate_packaged_resources(self.app, "Clavune")

    def test_symlinked_packaged_payload_is_rejected(self):
        payload = self.resources / "candidates.json"
        outside = self.root / "outside-candidates.json"
        outside.write_bytes(payload.read_bytes())
        payload.unlink()
        payload.symlink_to(outside)
        with self.assertRaises(ResourceValidationError):
            validate_packaged_resources(self.app, "Clavune")

    def test_malformed_json_is_rejected(self):
        (self.resources / "resource-policy.json").write_text("{")
        with self.assertRaises(ResourceValidationError):
            validate_packaged_resources(self.app, "Clavune")


if __name__ == "__main__":
    unittest.main()
