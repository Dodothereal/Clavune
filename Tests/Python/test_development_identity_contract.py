"""Offline configuration/source contracts, not a macOS launch test."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DevelopmentIdentityContractTests(unittest.TestCase):
    def test_default_build_uses_existing_normal_development_identity(self):
        product = json.loads((ROOT / "Config/Product.json").read_text())
        self.assertEqual(product["bundleIdentifier"], "org.clavune.development")
        self.assertEqual(product["storageDirectory"], "Clavune")
        self.assertEqual(product["displayName"], "Clavune")
        self.assertEqual(product["executable"], "Clavune")

    def test_default_identity_cannot_select_the_implicit_synthetic_comparison_profile(self):
        product = json.loads((ROOT / "Config/Product.json").read_text())
        source = (ROOT / "Sources/ClavuneApp/AppLaunchConfiguration.swift").read_text()
        match = re.search(r'private static let stableComparisonBundleID = "([^"]+)"', source)
        self.assertIsNotNone(match)
        self.assertNotEqual(product["bundleIdentifier"], match.group(1))
        self.assertNotIn(".qa.", product["bundleIdentifier"])

    def test_explicit_comparison_bundle_keeps_its_fail_closed_synthetic_route(self):
        source = (ROOT / "Sources/ClavuneApp/AppLaunchConfiguration.swift").read_text()
        begin = source.index("if bundleIdentifier == stableComparisonBundleID {")
        end = source.index('guard let profile = environment["CLAVUNE_QA_PROFILE"]', begin)
        route = source[begin:end]
        self.assertIn("profile != stableComparisonProfile", route)
        self.assertIn("throw ConfigurationError.invalidQAProfile", route)
        self.assertIn("AppLaunchConfiguration(qaProfile: stableComparisonProfile, functional: true,", route)
        self.assertIn("nativePanels: nativePanels != nil)", route)

    def test_normal_no_override_parse_route_remains_production(self):
        source = (ROOT / "Sources/ClavuneApp/AppLaunchConfiguration.swift").read_text()
        self.assertIn('guard let profile = environment["CLAVUNE_QA_PROFILE"] else {\n'
                      '            guard functional == nil else { throw ConfigurationError.invalidFunctionalQA }\n'
                      '            guard nativePanels == nil else { throw ConfigurationError.invalidNativePanelQA }\n'
                      '            return .production\n        }', source)

    def test_packager_takes_bundle_and_storage_identity_from_checked_configuration(self):
        source = (ROOT / "Scripts/package-app.py").read_text()
        self.assertIn('product = json.loads((root / "Config/Product.json").read_text())', source)
        self.assertIn('"CFBundleIdentifier": product["bundleIdentifier"]', source)
        self.assertIn('"ProductStorageDirectory": product["storageDirectory"]', source)

    def test_native_parse_regressions_still_cover_normal_and_comparison_ids(self):
        source = (ROOT / "Tests/ClavuneCoreTests/AppLaunchConfigurationTests.swift").read_text()
        self.assertIn('bundleIdentifier: "org.clavune.development").isQA)', source)
        self.assertIn('AppLaunchConfiguration.parse(environment: [:], bundleIdentifier: qaID)', source)
        self.assertIn('"CLAVUNE_QA_FUNCTIONAL": "synthetic-v1"', source)


if __name__ == "__main__":
    unittest.main()
