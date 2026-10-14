#!/usr/bin/env python3
"""Fail-closed release evidence and CI source claims; all hardware calls are fakes."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('retain_beta', ROOT / 'engineering/scripts/retain-beta.py')
retain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retain)


class ReleaseEvidenceTests(unittest.TestCase):
    def test_symbols_must_match_the_installer_binary_not_another_build(self):
        with patch.object(retain, 'uuids', side_effect=[[('A', 'arm64')], [('B', 'arm64')]]):
            with self.assertRaisesRegex(ValueError, 'UUID mismatch'): retain.verify_symbols(Path('app'), Path('symbols'))
        with patch.object(retain, 'uuids', side_effect=[[('A', 'arm64')], [('A', 'arm64')]]):
            self.assertEqual(retain.verify_symbols(Path('app'), Path('symbols')), [('A', 'arm64')])

    def test_no_uuids_cannot_pass(self):
        with patch.object(retain, 'uuids', return_value=[]):
            with self.assertRaises(ValueError): retain.verify_symbols(Path('app'), Path('symbols'))

    def test_build_log_requires_exact_input_and_retains_only_safe_overrides(self):
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / 'build.log'
            log.write_text('    PADINK_SOURCE_SHA256 = digest\n    PADINK_SOURCE_REVISION = commit\n    PADINK_NOTARY_PASSWORD = NEVER_RETAIN\n    DEVELOPMENT_TEAM = PRIVATE_ID\n    ARCHS = arm64\n -swift-version 5 -target arm64-apple-macos14.0\n')
            result = retain.extract_build_settings(log, {'head': 'commit', 'sourceSHA256': 'digest'})
            self.assertEqual(result['overrides']['ARCHS'], 'arm64')
            self.assertNotIn('NEVER_RETAIN', str(result)); self.assertNotIn('PRIVATE_ID', str(result))
            with self.assertRaises(ValueError): retain.extract_build_settings(log, {'head': 'other', 'sourceSHA256': 'digest'})

    def test_ci_checks_event_checkout_without_upload_or_signing_secrets(self):
        workflow = (ROOT / '.github/workflows/check.yml').read_text()
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('PADINK_CHECK_SCOPE: ci', workflow)
        self.assertNotIn('uses: actions/upload-artifact', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('pull_request_target:', workflow)
        self.assertNotIn('head.sha', workflow)  # Default event checkout; PR integration SHA is recorded.
        source = (ROOT / 'engineering/scripts/check-provenance.py').read_text()
        self.assertIn("event_sha != source['head']", source)
        self.assertIn("source['dirty']", source)
        self.assertIn('current != before', source)

    def test_shared_entry_checks_current_materials_and_submission_binding(self):
        entry = (ROOT / 'engineering/scripts/build-and-test.sh').read_text()
        self.assertIn('test-store-materials.py', entry)
        self.assertIn('test-release-evidence.py', entry)
        self.assertIn('store-materials.py "${material_options[@]}"', entry)
        self.assertIn('--release "$PADINK_FROZEN_RELEASE"', entry)
        self.assertIn('--require-ready', entry)
        self.assertNotIn('store-materials.py || true', entry)


if __name__ == '__main__':
    unittest.main()
