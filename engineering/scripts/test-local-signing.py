#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("local_signing", Path(__file__).parent / "lib/local_signing.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LocalSigningTests(unittest.TestCase):
    def test_multiple_accounts_preserve_all_teams_and_deduplicate(self):
        settings = {"IDEProvisioningTeamByIdentifier": {
            "account-a": [{"teamID": "ABC1234567", "teamName": "Personal Team"}, {"teamID": "invalid"}],
            "account-b": [{"teamID": "XYZ1234567", "teamName": "Organization"}, {"teamID": "ABC1234567", "teamName": "Personal Team"}]}}
        self.assertEqual(module.teams_from_settings(settings), [("XYZ1234567", "Organization"), ("ABC1234567", "Personal Team")])

    def test_multiple_teams_require_an_explicit_choice(self):
        teams = [("ABC1234567", "One"), ("XYZ1234567", "Two")]
        with self.assertRaises(ValueError):
            module.choose_team(teams, interactive=False)
        with patch("builtins.input", return_value="2"):
            self.assertEqual(module.choose_team(teams, interactive=True), "XYZ1234567")

    def test_invalid_team_never_writes_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                module.write_identity(root, "bad\nPADINK_BUNDLE_PREFIX = changed")
            self.assertFalse((root / "Config").exists())

    def test_repeated_setup_preserves_identity_and_rejects_team_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(module.write_identity(root, "abc1234567"), "dev.padink03.abc1234567")
            path = root / "Config/Signing.local.xcconfig"
            original = path.read_bytes()
            self.assertEqual(module.write_identity(root, "ABC1234567"), "dev.padink03.abc1234567")
            with self.assertRaises(ValueError):
                module.write_identity(root, "XYZ1234567")
            self.assertEqual(path.read_bytes(), original)

    def test_mismatched_existing_prefix_stops_before_reinstall(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Signing.local.xcconfig"
            path.write_text("DEVELOPMENT_TEAM = ABC1234567\nPADINK_BUNDLE_PREFIX = dev.padink03.someoneelse\n")
            with self.assertRaises(ValueError):
                module.existing_identity(path)


if __name__ == "__main__":
    unittest.main()
