#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("build_identity", Path(__file__).with_name("build-identity.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildIdentityTest(unittest.TestCase):
    def test_source_edits_change_label_but_notes_and_local_signing_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "SOURCE_COMMIT").write_text("33be0b0d98c0b22311bd562cf97b24961952b805")
            (root / "Sources").mkdir()
            source = root / "Sources" / "main.swift"
            source.write_text("let a = 1")
            before = module.identity(root)
            (root / "notes.md").write_text("private note")
            (root / "Config").mkdir()
            (root / "Config" / "Signing.local.xcconfig").write_text("private signing settings")
            self.assertEqual(before, module.identity(root))
            source.write_text("let a = 2")
            after = module.identity(root)
            self.assertNotEqual(before["label"], after["label"])
            self.assertEqual(len(after["label"]), 25)
            self.assertEqual(after["head"], before["head"])
            self.assertEqual(set(after["files"]), {"Sources/main.swift"})


    def test_version_and_privacy_changes_change_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "SOURCE_COMMIT").write_text("33be0b0d98c0b22311bd562cf97b24961952b805")
            (root / "Config").mkdir()
            version = root / "Config/Version.xcconfig"
            version.write_text("CURRENT_PROJECT_VERSION = 1")
            first = module.identity(root)
            version.write_text("CURRENT_PROJECT_VERSION = 2")
            second = module.identity(root)
            self.assertNotEqual(first["sourceSHA256"], second["sourceSHA256"])
            (root / "Hosts/iPad").mkdir(parents=True)
            (root / "Hosts/iPad/PrivacyInfo.xcprivacy").write_text("privacy")
            self.assertNotEqual(second["sourceSHA256"], module.identity(root)["sourceSHA256"])

if __name__ == "__main__":
    unittest.main()
