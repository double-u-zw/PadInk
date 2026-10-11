#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("rc_release_config", ROOT / "engineering/scripts/rc-release.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
VALID = """DEVELOPMENT_TEAM = ABC1234567
PADINK_BUNDLE_PREFIX = com.example.padink
PADINK_MAC_BUNDLE_ID = com.example.padink.mac
PADINK_IPAD_BUNDLE_ID = com.example.padink.ipad
PADINK_MAC_SIGN_IDENTITY = Developer ID Application: Team (ABC1234567)
PADINK_IPAD_SIGN_IDENTITY = Apple Distribution
PADINK_NOTARY_PROFILE = local-profile-name
"""


class ReleaseConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "Config").mkdir()
        self.path = self.root / "Config/Release.local.xcconfig"

    def tearDown(self): self.temporary.cleanup()

    def test_missing_paid_config_never_falls_back_to_free_signing(self):
        (self.root / "Config/Signing.local.xcconfig").write_text("DEVELOPMENT_TEAM = FREE123456\n")
        with self.assertRaises(module.ReleaseError): module.paid_config(self.root, "mac")

    def test_example_placeholders_fail_closed(self):
        self.path.write_bytes((ROOT / "Config/Release.example.xcconfig").read_bytes())
        with self.assertRaises(module.ReleaseError): module.paid_config(self.root, "mac")
        with self.assertRaises(module.ReleaseError): module.paid_config(self.root, "ipad")

    def test_explicit_config_is_read_without_mutating_developer_identity(self):
        developer = self.root / "Config/Signing.local.xcconfig"
        developer.write_text("DEVELOPMENT_TEAM = FREE123456\nPADINK_BUNDLE_PREFIX = dev.padink03.free123456\n")
        previous = developer.read_bytes()
        self.path.write_text(VALID)
        self.assertEqual(module.paid_config(self.root, "mac")["DEVELOPMENT_TEAM"], "ABC1234567")
        self.assertEqual(module.paid_config(self.root, "ipad")["PADINK_IPAD_BUNDLE_ID"], "com.example.padink.ipad")
        self.assertEqual(developer.read_bytes(), previous)

    def test_identical_platform_bundle_ids_are_rejected(self):
        self.path.write_text(VALID.replace("com.example.padink.ipad", "com.example.padink.mac"))
        with self.assertRaises(module.ReleaseError): module.paid_config(self.root, "ipad")

    def test_build_metadata_overrides_match_frozen_release(self):
        self.path.write_text(VALID)
        manifest = {"release": {"version": "0.3.0", "build": "12"}, "source": {"head": "a" * 40, "sourceSHA256": "b" * 64, "label": "a" * 12 + "+" + "b" * 12}}
        values = module.build_settings(manifest, module.paid_config(self.root, "ipad"), "ipad")
        self.assertIn("PADINK_SOURCE_REVISION=" + "a" * 40, values)
        self.assertIn("PADINK_SOURCE_SHA256=" + "b" * 64, values)
        self.assertIn("CURRENT_PROJECT_VERSION=12", values)
        self.assertIn("PADINK_RELEASE_CHANNEL=rc", values)
        self.assertIn("PADINK_DISTRIBUTION=testflight", values)


if __name__ == "__main__": unittest.main()
